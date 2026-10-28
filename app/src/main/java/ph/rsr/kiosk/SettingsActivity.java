package ph.rsr.kiosk;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.text.InputType;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

/**
 * Passcode-protected settings. Also the first-run setup (tablet name + exit passcode).
 * Built in code (no layout files) to keep the app small and simple.
 */
public class SettingsActivity extends Activity {
    static final String EXTRA_SETUP = "setup";
    static final String EXTRA_REMOTE = "remote";
    private static final long IDLE_CLOSE_MS = 3 * 60_000L;

    private Prefs prefs;
    private LinearLayout box;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private final Runnable idleClose = this::finish;
    private boolean setup;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        setup = getIntent().getBooleanExtra(EXTRA_SETUP, false) || !prefs.hasPasscode();
        if (getIntent().getBooleanExtra(EXTRA_REMOTE, false) && !prefs.consumeRemoteUnlock() && !setup) {
            finish();
            return;
        }
        ScrollView sv = new ScrollView(this);
        sv.setBackgroundColor(Color.WHITE);
        box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        int pad = dp(24);
        box.setPadding(pad, pad, pad, pad);
        sv.addView(box);
        setContentView(sv);
        if (setup) buildSetup(); else buildSettings();
    }

    // ---- first run ----------------------------------------------------------------------------

    private void buildSetup() {
        title("RSR Kiosk — first setup");
        note("Device owner (full lock): " + (Policy.isOwner(this) ? "YES" : "NO — screen pinning only"));
        EditText name = field("Tablet name (e.g. Carmen kiosk)", prefs.name(), InputType.TYPE_CLASS_TEXT);
        EditText p1 = field("Exit passcode (6 to 10 digits)", "", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        EditText p2 = field("Repeat passcode", "", InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        button("Save and start kiosk", v -> {
            String a = p1.getText().toString(), c = p2.getText().toString();
            if (name.getText().toString().trim().isEmpty()) { toast("Enter the tablet name"); return; }
            if (!a.matches("\\d{6,10}")) { toast("Passcode must be 6 to 10 digits"); return; }
            if (!a.equals(c)) { toast("Passcodes do not match"); return; }
            prefs.setName(name.getText().toString().trim());
            prefs.setPasscode(a);
            Core.get(this).reportEvent("setup done");
            Core.get(this).beatSoon();
            finish();
        });
    }

    // ---- settings -----------------------------------------------------------------------------

    private void buildSettings() {
        Core core = Core.get(this);
        title("RSR Kiosk settings");
        note("Tablet: " + prefs.name() + "\nApp build: " + Updater.currentVersion(this)
                + "\nFull lock (device owner): " + (Policy.isOwner(this) ? "YES" : "NO")
                + "\nOffice link: " + prefs.lastBeatStatus()
                + "\nDevice ID: " + prefs.deviceId()
                + (prefs.inMaintenance() ? "\n\nMAINTENANCE IS ON (kiosk unlocked)" : ""));

        section("Tablet");
        EditText name = field("Tablet name", prefs.name(), InputType.TYPE_CLASS_TEXT);
        EditText url = field("Kiosk page address", prefs.url(), InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);

        section("Screen schedule");
        CheckBox sched = new CheckBox(this);
        sched.setText("Turn screen off at night");
        sched.setTextSize(18);
        sched.setChecked(prefs.scheduleEnabled());
        box.addView(sched);
        EditText on = field("Screen ON time (HH:MM)", prefs.onTime(), InputType.TYPE_CLASS_DATETIME | InputType.TYPE_DATETIME_VARIATION_TIME);
        EditText off = field("Screen OFF time (HH:MM)", prefs.offTime(), InputType.TYPE_CLASS_DATETIME | InputType.TYPE_DATETIME_VARIATION_TIME);

        button("Save", v -> {
            String u = url.getText().toString().trim();
            if (!u.startsWith("https://seafordprojects-bit.github.io/")) { toast("Address must be an RSR page (https://seafordprojects-bit.github.io/...)"); return; }
            if (Core.minutes(on.getText().toString()) < 0 || Core.minutes(off.getText().toString()) < 0) { toast("Time must be like 05:30"); return; }
            boolean urlChanged = !u.equals(prefs.url());
            prefs.setName(name.getText().toString().trim());
            prefs.setUrl(u);
            core.applyScheduleArg(sched.isChecked() ? on.getText().toString().trim() + "-" + off.getText().toString().trim() : "off");
            core.beatSoon();
            toast("Saved");
            if (urlChanged) startActivity(new Intent(this, KioskActivity.class).putExtra("reload_url", true).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
            finish();
        });

        section("Page");
        button("Reload page", v -> { reloadKiosk(false); finish(); });
        button("Full reload (clear old version)", v -> { reloadKiosk(true); finish(); });

        section("App");
        button("Check for app update now", v -> {
            StringBuilder out = new StringBuilder();
            toast("Checking...");
            core.updateNow(() -> toast(out.toString()), out);
        });

        section("Maintenance");
        if (prefs.inMaintenance()) {
            button("End maintenance now (lock kiosk)", v -> { core.endMaintenance(); finish(); });
        }
        button("Open Wi-Fi / Android settings (unlocks 10 min)", v -> confirm(
                "Kiosk will be unlocked for 10 minutes, then it locks again by itself. Continue?", () -> {
                    core.startMaintenance();
                    try { stopLockTask(); } catch (Exception ignored) { }
                    startActivity(new Intent(Settings.ACTION_WIFI_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK));
                    finish();
                }));
        button("Change exit passcode", v -> changePasscode());
        button("Restart tablet", v -> confirm("Restart the tablet now?", () -> {
            if (!Policy.reboot(this)) toast("Restart needs full lock (device owner)");
        }));

        section("Danger");
        Button rm = button("Remove full lock (before selling / replacing tablet)", v -> confirm(
                "This removes the kiosk lock completely. To lock again you need a factory reset + USB setup. Continue?",
                () -> confirm("Are you really sure?", () -> {
                    try { stopLockTask(); } catch (Exception ignored) { }
                    Policy.removeDeviceOwner(this);
                    toast("Full lock removed. You can now uninstall the app.");
                    finish();
                })));
        rm.setTextColor(Color.RED);

        button("Close", v -> finish());
    }

    private void reloadKiosk(boolean hard) {
        Core.get(this).reportEvent(hard ? "full reload (settings)" : "reload (settings)");
        // KioskActivity is the Host; ask it through the same path the office uses.
        startActivity(new Intent(this, KioskActivity.class).addFlags(Intent.FLAG_ACTIVITY_REORDER_TO_FRONT));
        ui.postDelayed(() -> Core.get(this).reloadViaHost(hard), 300);
    }

    private void changePasscode() {
        LinearLayout l = new LinearLayout(this);
        l.setOrientation(LinearLayout.VERTICAL);
        EditText a = new EditText(this), c = new EditText(this);
        a.setHint("New passcode (6-10 digits)");
        c.setHint("Repeat new passcode");
        a.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        c.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        l.addView(a);
        l.addView(c);
        new AlertDialog.Builder(this).setTitle("Change passcode").setView(l)
                .setPositiveButton("Save", (d, w) -> {
                    String x = a.getText().toString();
                    if (!x.matches("\\d{6,10}")) { toast("Passcode must be 6 to 10 digits"); return; }
                    if (!x.equals(c.getText().toString())) { toast("Passcodes do not match"); return; }
                    prefs.setPasscode(x);
                    toast("Passcode changed");
                })
                .setNegativeButton("Cancel", null).show();
    }

    // ---- small UI helpers ---------------------------------------------------------------------

    private void title(String t) {
        TextView v = new TextView(this);
        v.setText(t);
        v.setTextSize(26);
        v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setTextColor(0xFF0E2A47);
        v.setPadding(0, 0, 0, dp(12));
        box.addView(v);
    }

    private void section(String t) {
        TextView v = new TextView(this);
        v.setText(t.toUpperCase());
        v.setTextSize(14);
        v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setTextColor(0xFF667788);
        v.setPadding(0, dp(24), 0, dp(6));
        box.addView(v);
    }

    private void note(String t) {
        TextView v = new TextView(this);
        v.setText(t);
        v.setTextSize(16);
        v.setTextColor(0xFF333333);
        v.setBackgroundColor(0xFFF1F4F8);
        v.setPadding(dp(12), dp(12), dp(12), dp(12));
        box.addView(v);
    }

    private EditText field(String label, String value, int type) {
        TextView l = new TextView(this);
        l.setText(label);
        l.setTextSize(15);
        l.setTextColor(0xFF333333);
        l.setPadding(0, dp(10), 0, 0);
        box.addView(l);
        EditText e = new EditText(this);
        e.setText(value);
        e.setInputType(type);
        e.setTextSize(20);
        e.setSingleLine(true);
        box.addView(e, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return e;
    }

    private Button button(String text, View.OnClickListener l) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextSize(18);
        b.setAllCaps(false);
        b.setMinHeight(dp(56));
        b.setOnClickListener(l);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lp.topMargin = dp(8);
        box.addView(b, lp);
        return b;
    }

    private void confirm(String msg, Runnable yes) {
        new AlertDialog.Builder(this).setMessage(msg).setPositiveButton("Yes", (d, w) -> yes.run()).setNegativeButton("No", null).show();
    }

    private void toast(String t) {
        Toast.makeText(this, t, Toast.LENGTH_LONG).show();
    }

    private int dp(int v) {
        return Math.round(v * getResources().getDisplayMetrics().density);
    }

    // Close by itself after 3 minutes without a touch, so settings is never left open for workers.
    @Override
    protected void onResume() {
        super.onResume();
        if (!setup) ui.postDelayed(idleClose, IDLE_CLOSE_MS);
    }

    @Override
    protected void onPause() {
        super.onPause();
        ui.removeCallbacks(idleClose);
    }

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        if (!setup) {
            ui.removeCallbacks(idleClose);
            ui.postDelayed(idleClose, IDLE_CLOSE_MS);
        }
        return super.dispatchTouchEvent(ev);
    }

    @Override
    public void onBackPressed() {
        if (!setup) super.onBackPressed();   // first setup cannot be skipped
    }
}

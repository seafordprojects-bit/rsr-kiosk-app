package ph.rsr.kiosk;

import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import org.json.JSONObject;

import java.lang.ref.WeakReference;
import java.util.Calendar;

/**
 * Background brain of the app (one per process):
 *  - heartbeat to Supabase every 60 s (battery, charging, screen, version) and picks up remote commands
 *  - screen on/off schedule
 *  - ends maintenance mode after 10 minutes
 *  - nightly update check
 */
final class Core {
    private static final String TAG = "RSRCore";
    private static Core instance;

    /** What the kiosk screen offers to the core. */
    interface Host {
        void reloadPage(boolean hard);
        void openSettingsFromRemote();
        void applyScreenFlag(boolean keepOn);
        String pageUrl();
        boolean pageOk();
    }

    private final Context ctx;
    private final Prefs prefs;
    private final Handler bg;
    private final Handler main = new Handler(Looper.getMainLooper());
    private WeakReference<Host> host = new WeakReference<>(null);
    private volatile String pendingEvent = "started";
    private Boolean lastOnHours = null;
    /** Last time a worker touched the screen (elapsedRealtime). Restart/update wait for a quiet moment. */
    private volatile long lastTouch = 0;

    void touched() { lastTouch = android.os.SystemClock.elapsedRealtime(); }

    /**
     * Wait (on the background thread) until nobody has touched the screen for 20 s, at most 3 minutes.
     * Then wait 10 s more so the page has written its last punch to storage before the app stops.
     */
    private void waitForQuiet() {
        long start = android.os.SystemClock.elapsedRealtime();
        while (android.os.SystemClock.elapsedRealtime() - lastTouch < 20_000
                && android.os.SystemClock.elapsedRealtime() - start < 180_000) {
            try { Thread.sleep(2000); } catch (InterruptedException e) { return; }
        }
        try { Thread.sleep(10_000); } catch (InterruptedException ignored) { }
    }

    static synchronized Core get(Context c) {
        if (instance == null) instance = new Core(c.getApplicationContext());
        return instance;
    }

    private Core(Context c) {
        ctx = c;
        prefs = new Prefs(c);
        HandlerThread t = new HandlerThread("rsr-core");
        t.start();
        bg = new Handler(t.getLooper());
    }

    void start() {
        bg.removeCallbacksAndMessages(null);
        bg.post(this::loop);
        scheduleNextAlarm();
    }

    void setHost(Host h) { host = new WeakReference<>(h); }

    void reportEvent(String e) { pendingEvent = e; }

    void reloadViaHost(boolean hard) {
        main.post(() -> { Host h = host.get(); if (h != null) h.reloadPage(hard); });
    }

    /** Send a heartbeat now (e.g. right after settings change). */
    void beatSoon() { bg.post(this::beat); }

    private void loop() {
        try {
            beat();
            checkMaintenanceExpiry();
            checkScheduleTransition();
            nightlyUpdateCheck();
        } catch (Throwable t) {
            Log.w(TAG, "loop", t);
        }
        bg.postDelayed(this::loop, Config.BEAT_MS);
    }

    // ---- heartbeat + remote commands ----------------------------------------------------------

    private void beat() {
        try {
            JSONObject p = new JSONObject();
            p.put("device_id", prefs.deviceId());
            p.put("name", prefs.name());
            p.put("kiosk_device_id", prefs.pageDeviceId());
            p.put("app_version", Updater.currentVersion(ctx));
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b != null) {
                int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                int plug = b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
                if (lvl >= 0 && sc > 0) p.put("battery", Math.round(lvl * 100f / sc));
                p.put("charging", plug != 0);
            }
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            p.put("screen_on", pm != null && pm.isInteractive());
            p.put("device_owner", Policy.isOwner(ctx));
            p.put("maintenance", prefs.inMaintenance());
            p.put("sched_on", prefs.scheduleEnabled() ? prefs.onTime() : "");
            p.put("sched_off", prefs.scheduleEnabled() ? prefs.offTime() : "");
            Host h = host.get();
            if (h != null) {
                p.put("page_url", h.pageUrl());
                p.put("page_ok", h.pageOk());
            }
            p.put("model", Build.MANUFACTURER + " " + Build.MODEL + " / Android " + Build.VERSION.RELEASE);
            String ev = pendingEvent;
            if (ev != null) p.put("event", ev);

            String body = new JSONObject().put("p", p).toString();
            String resp = Net.rpc("kiosk_app_beat", body);
            if (ev != null && ev.equals(pendingEvent)) pendingEvent = null;
            prefs.setLastBeatStatus("ok " + android.text.format.DateFormat.format("HH:mm", System.currentTimeMillis()));

            JSONObject r = resp.trim().startsWith("{") ? new JSONObject(resp) : new JSONObject();
            long cmdId = r.optLong("cmd_id", 0);
            String cmd = r.optString("cmd", "");
            if (cmdId > prefs.lastCmdDone() && !cmd.isEmpty()) {
                // Mark done BEFORE running, so a restart command can never loop after the reboot.
                prefs.setLastCmdDone(cmdId);
                ack(cmdId, "started");
                runCommand(cmd, r.optString("arg", ""), cmdId);
            }
        } catch (Exception e) {
            prefs.setLastBeatStatus("offline (" + e.getClass().getSimpleName() + ")");
        }
    }

    private void ack(long id, String result) {
        try {
            JSONObject b = new JSONObject().put("p_device", prefs.deviceId()).put("p_cmd_id", id).put("p_result", result);
            Net.rpc("kiosk_app_ack", b.toString());
        } catch (Exception e) {
            Log.w(TAG, "ack", e);
        }
    }

    private void runCommand(String cmd, String arg, long id) {
        Log.i(TAG, "command " + cmd + " " + arg);
        switch (cmd) {
            case "reload":
                main.post(() -> { Host h = host.get(); if (h != null) h.reloadPage(false); });
                ack(id, "done");
                break;
            case "hard_reload":
                main.post(() -> { Host h = host.get(); if (h != null) h.reloadPage(true); });
                ack(id, "done");
                break;
            case "restart":
                if (!Policy.isOwner(ctx)) { ack(id, "failed: not device owner"); break; }
                ack(id, "restarting (waits for no punching)");
                waitForQuiet();
                Policy.reboot(ctx);
                break;
            case "update":
                waitForQuiet();
                ack(id, Updater.checkAndInstall(ctx));
                break;
            case "screen_on":
                wakeScreen();
                ack(id, "done");
                break;
            case "screen_off":
                main.post(() -> { Host h = host.get(); if (h != null) h.applyScreenFlag(false); });
                main.postDelayed(() -> Policy.screenOffNow(ctx), 500);
                ack(id, "done");
                break;
            case "open_settings":
                prefs.grantRemoteUnlock();
                wakeScreen();
                main.post(() -> { Host h = host.get(); if (h != null) h.openSettingsFromRemote(); });
                ack(id, "done");
                break;
            case "schedule":
                ack(id, applyScheduleArg(arg));
                break;
            default:
                ack(id, "unknown command");
        }
    }

    /** arg "05:30-22:30" sets the schedule; "off" = screen always on. */
    synchronized String applyScheduleArg(String arg) {
        if ("off".equals(arg)) {
            prefs.setSchedule(prefs.onTime(), prefs.offTime(), false);
        } else {
            String[] p = arg.split("-");
            if (p.length != 2 || minutes(p[0]) < 0 || minutes(p[1]) < 0) return "bad schedule";
            prefs.setSchedule(p[0].trim(), p[1].trim(), true);
        }
        lastOnHours = null;   // re-apply right away
        scheduleNextAlarm();
        checkScheduleTransition();
        return "schedule " + (prefs.scheduleEnabled() ? prefs.onTime() + "-" + prefs.offTime() : "off");
    }

    // ---- screen schedule ----------------------------------------------------------------------

    /** True when the screen should stay on (inside the schedule, or schedule turned off). */
    boolean isOnHours() {
        if (!prefs.scheduleEnabled()) return true;
        int on = minutes(prefs.onTime()), off = minutes(prefs.offTime());
        if (on < 0 || off < 0 || on == off) return true;
        Calendar c = Calendar.getInstance();
        int now = c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
        return on < off ? (now >= on && now < off) : (now >= on || now < off);
    }

    /** Called by the alarm and by the 60 s loop. Acts only when on-hours flips, never repeatedly. */
    synchronized void checkScheduleTransition() {
        boolean onHours = isOnHours();
        if (lastOnHours != null && lastOnHours == onHours) return;
        boolean first = lastOnHours == null;
        lastOnHours = onHours;
        main.post(() -> { Host h = host.get(); if (h != null) h.applyScreenFlag(onHours); });
        if (onHours) {
            if (!first) wakeScreen();
        } else if (!first) {
            // Scheduled screen off. A worker can still wake it with the power button for late OT.
            main.postDelayed(() -> Policy.screenOffNow(ctx), 1000);
            // Good quiet moment for an update check.
            bg.postDelayed(this::nightlyUpdateCheck, 60_000);
        }
    }

    void scheduleNextAlarm() {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 7, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        am.cancel(pi);
        if (!prefs.scheduleEnabled()) return;
        long next = Math.min(nextAt(prefs.onTime()), nextAt(prefs.offTime()));
        if (next <= 0) return;
        // Inexact-but-idle-safe: may fire a few minutes late in deep sleep. The ON time defaults to 5:30,
        // well before the 8:00 time-in, and the 60 s loop also catches the change while awake.
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
    }

    private static long nextAt(String hhmm) {
        int m = minutes(hhmm);
        if (m < 0) return Long.MAX_VALUE;
        Calendar c = Calendar.getInstance();
        c.set(Calendar.HOUR_OF_DAY, m / 60);
        c.set(Calendar.MINUTE, m % 60);
        c.set(Calendar.SECOND, 5);
        c.set(Calendar.MILLISECOND, 0);
        if (c.getTimeInMillis() <= System.currentTimeMillis() + 1000) c.add(Calendar.DAY_OF_MONTH, 1);
        return c.getTimeInMillis();
    }

    static int minutes(String hhmm) {
        try {
            String[] p = hhmm.trim().split(":");
            int h = Integer.parseInt(p[0]), m = Integer.parseInt(p[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
            return h * 60 + m;
        } catch (Exception e) {
            return -1;
        }
    }

    @SuppressWarnings("deprecation")
    void wakeScreen() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            PowerManager.WakeLock wl = pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                    | PowerManager.ACQUIRE_CAUSES_WAKEUP | PowerManager.ON_AFTER_RELEASE, "rsr:wake");
            wl.acquire(5000);
        } catch (Exception e) {
            Log.w(TAG, "wake", e);
        }
        bringToFront();
    }

    void bringToFront() {
        main.post(() -> {
            try {
                Intent i = new Intent(ctx, KioskActivity.class);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                ctx.startActivity(i);
            } catch (Exception e) {
                Log.w(TAG, "front", e);
            }
        });
    }

    // ---- maintenance + updates ----------------------------------------------------------------

    void startMaintenance() {
        long until = System.currentTimeMillis() + Config.MAINTENANCE_MS;
        prefs.setMaintenanceUntil(until);
        Policy.relaxForMaintenance(ctx);
        reportEvent("maintenance opened");
        bg.postDelayed(this::checkMaintenanceExpiry, Config.MAINTENANCE_MS + 2000);
        // Also an alarm: relocks even if the app process was closed during maintenance.
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am != null) {
            Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(ScheduleReceiver.ACTION_MAINT_END);
            PendingIntent pi = PendingIntent.getBroadcast(ctx, 8, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, until + 2000, pi);
        }
    }

    /** Alarm path: end maintenance if its time has passed. */
    void maintenanceAlarm() {
        bg.post(this::checkMaintenanceExpiry);
    }

    /** Alarm path for the screen schedule: alarms only fire at ON/OFF times, so act on the current state. */
    void scheduleAlarm() {
        boolean onHours = isOnHours();
        synchronized (this) { lastOnHours = onHours; }
        main.post(() -> { Host h = host.get(); if (h != null) h.applyScreenFlag(onHours); });
        if (onHours) wakeScreen();
        else main.postDelayed(() -> Policy.screenOffNow(ctx), 1000);
        scheduleNextAlarm();
    }

    void endMaintenance() {
        prefs.setMaintenanceUntil(0);
        Policy.applyKioskPolicies(ctx);
        bringToFront();
    }

    private void checkMaintenanceExpiry() {
        long until = prefs.maintenanceUntil();
        if (until > 0 && System.currentTimeMillis() >= until) {
            reportEvent("maintenance ended (auto)");
            endMaintenance();
        }
    }

    private void nightlyUpdateCheck() {
        Calendar c = Calendar.getInstance();
        int h = c.get(Calendar.HOUR_OF_DAY);
        boolean quiet = h >= 23 || h < 4 || !isOnHours();
        if (!quiet) return;
        if (System.currentTimeMillis() - prefs.lastUpdateCheck() < 20 * 3600_000L) return;
        prefs.setLastUpdateCheck(System.currentTimeMillis());
        String r = Updater.checkAndInstall(ctx);
        if (r.startsWith("installing")) reportEvent(r);
    }

    void updateNow(Runnable done, StringBuilder out) {
        bg.post(() -> {
            out.append(Updater.checkAndInstall(ctx));
            main.post(done);
        });
    }
}

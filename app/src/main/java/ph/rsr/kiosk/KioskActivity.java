package ph.rsr.kiosk;

import android.app.Activity;
import android.app.ActivityManager;
import android.app.AlertDialog;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowInsetsController;
import android.view.WindowManager;
import android.webkit.PermissionRequest;
import android.webkit.RenderProcessGoneDetail;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.TextView;

/**
 * The kiosk screen: one full-screen WebView showing the RSR kiosk page, locked in place.
 * Recovers by itself from: no internet (retry), a crashed page (rebuild), a frozen page (reload).
 */
public class KioskActivity extends Activity implements Core.Host {
    private static final String TAG = "RSRKiosk";

    private FrameLayout root;
    private WebView web;
    private TextView overlay;
    private Prefs prefs;
    private final Handler ui = new Handler(Looper.getMainLooper());

    private volatile boolean mainFrameError = false;
    private volatile String lastUrl = "";      // read by the background heartbeat; WebView itself is main-thread only
    private boolean loading = false;
    private long hangAskedAt = 0;
    private long lastRebuild = 0;
    private PermissionRequest pendingCamRequest;
    private long lastTouchAt = SystemClock.elapsedRealtime();
    private boolean backlightLow = false;
    /** The kiosk page blacks itself out after 6 min without a touch (5 min dim + 60 s). Shortly after
     *  that the app turns the real backlight down too: the page is black, so nobody sees a difference,
     *  but the screen light was the biggest battery user. The next touch brings it back. */
    private static final long BACKLIGHT_LOW_AFTER_MS = 6 * 60_000L + 15_000L;
    private int cornerTaps = 0;
    private long firstCornerTap = 0;
    private ConnectivityManager.NetworkCallback netCb;
    private AlertDialog passDialog;

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        prefs = new Prefs(this);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED | WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON);

        root = new FrameLayout(this);
        root.setBackgroundColor(Color.BLACK);
        overlay = new TextView(this);
        overlay.setTextColor(Color.WHITE);
        overlay.setTextSize(22);
        overlay.setGravity(Gravity.CENTER);
        overlay.setPadding(48, 48, 48, 48);
        overlay.setBackgroundColor(0xEE0E2A47);
        overlay.setVisibility(View.GONE);
        setContentView(root);
        buildWebView();
        root.addView(overlay, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        Core.get(this).setHost(this);
        watchNetwork();
        ui.postDelayed(hangCheck, Config.HANG_CHECK_MS);
        ui.postDelayed(backlightCheck, 30_000);

        if (!prefs.hasPasscode()) {
            // First run: set the exit passcode and tablet name before anything else.
            startActivity(new Intent(this, SettingsActivity.class).putExtra(SettingsActivity.EXTRA_SETUP, true));
        }
        web.loadUrl(prefs.url());
    }

    @SuppressWarnings("SetJavaScriptEnabled")
    private void buildWebView() {
        if (web != null) {
            root.removeView(web);
            try { web.destroy(); } catch (Exception ignored) { }
        }
        web = new WebView(this);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);          // localStorage: offline punches, PIN memory, device id
        s.setDatabaseEnabled(true);
        s.setMediaPlaybackRequiresUserGesture(false);   // camera preview + beeps start without a tap
        s.setCacheMode(WebSettings.LOAD_DEFAULT);
        s.setAllowFileAccess(false);
        s.setAllowContentAccess(false);
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setTextZoom(100);
        s.setSupportMultipleWindows(false);
        s.setJavaScriptCanOpenWindowsAutomatically(false);
        s.setUserAgentString(s.getUserAgentString() + " RSRKiosk/" + Updater.currentVersion(this));
        web.setOverScrollMode(View.OVER_SCROLL_NEVER);
        // No copy/paste pop-up on long-press. The page still gets the touches (its 2 s title long-press works).
        web.setOnLongClickListener(v -> true);
        web.setLongClickable(false);
        web.setHapticFeedbackEnabled(false);

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView v, WebResourceRequest r) {
                return !allowed(r.getUrl());   // block every site that is not RSR's
            }

            @Override
            public void onPageStarted(WebView v, String url, android.graphics.Bitmap f) {
                mainFrameError = false;
                loading = true;
                hangAskedAt = 0;
                if (backlightLow) setBacklightLow(false);   // a fresh page is never left on a dark screen   // a navigation drops a pending hang check; never blame the new page for it
                if (url != null) lastUrl = url;
            }

            @Override
            public void onPageFinished(WebView v, String url) {
                loading = false;
                hangAskedAt = 0;
                if (url != null) lastUrl = url;
                if (!mainFrameError) {
                    overlay.setVisibility(View.GONE);
                    readPageDeviceId();
                }
            }

            @Override
            public void onReceivedError(WebView v, WebResourceRequest r, WebResourceError e) {
                if (!r.isForMainFrame()) return;
                mainFrameError = true;
                loading = false;
                showOverlay("Walay internet / dili ma-abli ang kiosk.\nMosulay pag-usab...\n\n(" + e.getDescription() + ")");
                ui.removeCallbacks(retry);
                ui.postDelayed(retry, Config.RETRY_MS);
            }

            @Override
            public boolean onRenderProcessGone(WebView v, RenderProcessGoneDetail d) {
                // The page engine crashed: rebuild the WebView instead of letting Android kill the app.
                Log.w(TAG, "renderer gone, crash=" + d.didCrash());
                if (v != web) return true;   // an old WebView we already replaced
                // Take the dead WebView out right away so nothing touches it again.
                root.removeView(v);
                try { v.destroy(); } catch (Exception ignored) { }
                web = null;
                Core.get(KioskActivity.this).reportEvent("page crashed, rebuilt");
                // At most one rebuild every 10 s, so repeated out-of-memory kills cannot loop fast.
                long wait = Math.max(0, 10_000 - (SystemClock.elapsedRealtime() - lastRebuild));
                ui.postDelayed(() -> {
                    if (web != null || isFinishing()) return;
                    lastRebuild = SystemClock.elapsedRealtime();
                    buildWebView();
                    root.bringChildToFront(overlay);
                    web.loadUrl(prefs.url());
                }, wait);
                return true;
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(PermissionRequest req) {
                // Camera (and mic) only, and only for RSR's own page.
                if (!allowed(req.getOrigin())) { req.deny(); return; }
                // Without full lock the CAMERA permission is not pre-granted: ask Android first.
                if (checkSelfPermission(android.Manifest.permission.CAMERA) != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                    pendingCamRequest = req;
                    requestPermissions(new String[]{android.Manifest.permission.CAMERA, android.Manifest.permission.RECORD_AUDIO}, 41);
                    return;
                }
                grantMedia(req);
            }
        });

        root.addView(web, 0, new FrameLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
    }

    /** Camera (and mic) only. */
    private static void grantMedia(PermissionRequest req) {
        java.util.ArrayList<String> ok = new java.util.ArrayList<>();
        for (String r : req.getResources()) {
            if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(r) || PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(r)) ok.add(r);
        }
        if (ok.isEmpty()) req.deny(); else req.grant(ok.toArray(new String[0]));
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] perms, int[] results) {
        super.onRequestPermissionsResult(code, perms, results);
        PermissionRequest req = pendingCamRequest;
        pendingCamRequest = null;
        if (code != 41 || req == null) return;
        boolean cam = checkSelfPermission(android.Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED;
        if (cam) grantMedia(req); else req.deny();
    }

    private static boolean allowed(Uri u) {
        if (u == null || !"https".equals(u.getScheme())) return false;
        String h = u.getHost();
        for (String a : Config.ALLOWED_HOSTS) if (a.equalsIgnoreCase(h)) return true;
        return false;
    }

    private final Runnable retry = () -> {
        if (mainFrameError && web != null) web.loadUrl(prefs.url());
    };

    /** Every minute ask the page for "1". No answer in 30 s = frozen page → reload. */
    private final Runnable hangCheck = new Runnable() {
        @Override
        public void run() {
            if (web != null && !mainFrameError && !loading) {
                if (hangAskedAt > 0 && SystemClock.elapsedRealtime() - hangAskedAt > Config.HANG_TIMEOUT_MS) {
                    Log.w(TAG, "page not answering, reloading");
                    Core.get(KioskActivity.this).reportEvent("page froze, reloaded");
                    hangAskedAt = 0;
                    web.reload();
                } else if (hangAskedAt == 0) {
                    hangAskedAt = SystemClock.elapsedRealtime();
                    web.evaluateJavascript("1", v -> hangAskedAt = 0);
                }
            }
            ui.postDelayed(this, Config.HANG_TIMEOUT_MS);
        }
    };

    private final Runnable backlightCheck = new Runnable() {
        @Override
        public void run() {
            if (!backlightLow && SystemClock.elapsedRealtime() - lastTouchAt > BACKLIGHT_LOW_AFTER_MS) setBacklightLow(true);
            ui.postDelayed(this, 30_000);
        }
    };

    private void setBacklightLow(boolean low) {
        backlightLow = low;
        WindowManager.LayoutParams lp = getWindow().getAttributes();
        lp.screenBrightness = low ? 0.01f : WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE;
        getWindow().setAttributes(lp);
    }

    private void readPageDeviceId() {
        web.evaluateJavascript("(function(){try{return localStorage.getItem('rsr_device_id')||''}catch(e){return ''}})()", v -> {
            if (v == null) return;
            String id = v.replace("\"", "").trim();
            if (!id.isEmpty() && !"null".equals(id) && !id.equals(prefs.pageDeviceId())) {
                prefs.setPageDeviceId(id);
                Core.get(this).beatSoon();
            }
        });
    }

    private void watchNetwork() {
        ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
        if (cm == null) return;
        netCb = new ConnectivityManager.NetworkCallback() {
            @Override
            public void onAvailable(Network n) {
                // Internet is back: only reload if the page had failed. A working (offline) page is never interrupted.
                ui.postDelayed(() -> { if (mainFrameError) retry.run(); }, 3000);
            }
        };
        try { cm.registerDefaultNetworkCallback(netCb); } catch (Exception e) { Log.w(TAG, "netcb", e); }
    }

    private void showOverlay(String text) {
        overlay.setText(text);
        overlay.setVisibility(View.VISIBLE);
        root.bringChildToFront(overlay);
    }

    // ---- lock + full screen ------------------------------------------------------------------

    @Override
    protected void onResume() {
        super.onResume();
        Core core = Core.get(this);
        core.setHost(this);
        KeepAlive.start(this);   // in front = always allowed; restarts it if Android ever stopped it
        applyScreenFlag(true);   // the app decides when the screen goes off (Core.checkScheduleTransition)
        hideBars();
        if (!prefs.inMaintenance()) startLock();
        if (web != null) web.onResume();
    }

    @Override
    protected void onPause() {
        super.onPause();
        // Keep the page running (heartbeat, sync queue) even if something covers it briefly.
    }

    private void startLock() {
        try {
            ActivityManager am = (ActivityManager) getSystemService(Context.ACTIVITY_SERVICE);
            if (am != null && am.getLockTaskModeState() == ActivityManager.LOCK_TASK_MODE_NONE) {
                Policy.applyKioskPolicies(this);
                startLockTask();   // device owner: full lock. Otherwise Android's screen pinning.
            }
        } catch (Exception e) {
            Log.w(TAG, "lock", e);
        }
    }

    void stopLock() {
        try { stopLockTask(); } catch (Exception e) { Log.w(TAG, "unlock", e); }
    }

    @SuppressWarnings("deprecation")
    private void hideBars() {
        if (Build.VERSION.SDK_INT >= 30) {
            WindowInsetsController c = getWindow().getInsetsController();
            if (c != null) {
                c.hide(WindowInsets.Type.statusBars() | WindowInsets.Type.navigationBars());
                c.setSystemBarsBehavior(WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE);
            }
        } else {
            getWindow().getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                    | View.SYSTEM_UI_FLAG_FULLSCREEN | View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN | View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                    | View.SYSTEM_UI_FLAG_LAYOUT_STABLE);
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) hideBars();
    }

    @Override
    public void onBackPressed() {
        // Back does nothing in the kiosk.
    }

    @Override
    public boolean onKeyDown(int code, KeyEvent e) {
        if (code == KeyEvent.KEYCODE_BACK) return true;
        return super.onKeyDown(code, e);
    }

    // ---- hidden settings: tap the TOP-RIGHT corner 5 times within 3 seconds ------------------

    @Override
    public boolean dispatchTouchEvent(MotionEvent ev) {
        Core.get(this).touched();
        lastTouchAt = SystemClock.elapsedRealtime();
        if (backlightLow) setBacklightLow(false);
        if (ev.getActionMasked() == MotionEvent.ACTION_DOWN) {
            float zone = 90 * getResources().getDisplayMetrics().density;
            if (ev.getX() > root.getWidth() - zone && ev.getY() < zone) {
                long now = SystemClock.elapsedRealtime();
                if (now - firstCornerTap > 3000) { firstCornerTap = now; cornerTaps = 0; }
                if (++cornerTaps >= 5) { cornerTaps = 0; askPasscode(); }
            } else {
                cornerTaps = 0;
            }
        }
        return super.dispatchTouchEvent(ev);   // the page still receives the tap
    }

    private void askPasscode() {
        if (passDialog != null && passDialog.isShowing()) return;
        if (prefs.passcodeLocked()) {
            new AlertDialog.Builder(this).setMessage("Too many wrong tries. Wait 5 minutes.").setPositiveButton("OK", null).show();
            return;
        }
        EditText in = new EditText(this);
        in.setInputType(InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_VARIATION_PASSWORD);
        in.setHint("Passcode");
        passDialog = new AlertDialog.Builder(this)
                .setTitle("RSR Kiosk settings")
                .setView(in)
                .setPositiveButton("Open", (d, w) -> {
                    if (prefs.checkPasscode(in.getText().toString())) {
                        prefs.passcodeOk();
                        startActivity(new Intent(this, SettingsActivity.class));
                    } else {
                        prefs.passcodeWrong();
                    }
                })
                .setNegativeButton("Cancel", null)
                .create();
        passDialog.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_VISIBLE);
        passDialog.show();
        // Close by itself after 30 s so it is never left on screen for workers.
        ui.postDelayed(() -> { if (passDialog != null && passDialog.isShowing()) passDialog.dismiss(); }, 30_000);
    }

    // ---- Core.Host ----------------------------------------------------------------------------

    @Override
    public void reloadPage(boolean hard) {
        if (web == null) return;
        String url = prefs.url();
        if (hard && url.contains("/kiosk/")) {
            // The kiosk's own reset page: clears the old cached app (refuses when offline). Punches are never touched.
            web.loadUrl(Uri.parse(url).buildUpon().path(Uri.parse(url).getPath().replaceAll("[^/]*$", "") + "reset.html").clearQuery().build().toString());
        } else if (hard) {
            web.clearCache(true);
            web.loadUrl(url);
        } else {
            web.reload();
        }
    }

    @Override
    public void openSettingsFromRemote() {
        if (prefs.consumeRemoteUnlock()) {
            prefs.grantRemoteUnlock();   // SettingsActivity consumes it
            startActivity(new Intent(this, SettingsActivity.class).putExtra(SettingsActivity.EXTRA_REMOTE, true));
        }
    }

    @Override
    public void applyScreenFlag(boolean keepOn) {
        if (keepOn) getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
        else getWindow().clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    }

    @Override
    public String pageUrl() {
        return lastUrl;   // safe from the background thread
    }

    @Override
    public void pageBusy(java.util.function.Consumer<Boolean> answer) {
        if (web == null || mainFrameError) { answer.accept(false); return; }
        // Same check the kiosk page itself uses before applying its own updates (kiosk/index.html):
        // an employee selected, or any dialog open = a worker is mid-punch.
        web.evaluateJavascript("(function(){try{if(typeof curEmp!=='undefined'&&curEmp)return true;"
                + "if(typeof pin!=='undefined'&&pin)return true;"
                + "if(document.querySelector('.modal-bg.show'))return true;}catch(e){}return false;})()",
                v -> answer.accept("true".equals(v)));
    }

    @Override
    public void wakeAndBrighten() {
        lastTouchAt = SystemClock.elapsedRealtime();   // the 6-minute dim timer starts again, like a touch
        Core.get(this).touched();   // and the night / evening idle screen-off counts from now, not from the last real touch
        if (backlightLow) setBacklightLow(false);
        if (web == null || mainFrameError) return;
        // kiosk/index.html's own black screen, lifted ONLY when it is black (nobody can be mid-punch behind it).
        // An awake page just restarts its dim timer: its wakeScreen() re-checks the camera, which must never
        // run under a worker taking a punch photo. Guarded so an older page is not an error.
        web.evaluateJavascript("(function(){try{if(typeof screenBlack!=='undefined'&&screenBlack){"
                + "if(typeof wakeScreen==='function')wakeScreen();}"
                + "else if(typeof resetDimTimer==='function')resetDimTimer();}catch(e){}})()", null);
    }

    @Override
    public void nudgePage() {
        if (web == null || mainFrameError) return;
        // Functions of the RSR kiosk page (kiosk/index.html). Each is guarded inside the page
        // (already syncing / offline = it returns), and missing ones are skipped.
        web.evaluateJavascript("(function(){try{if(typeof syncFlush==='function')syncFlush();}catch(e){}"
                + "try{if(typeof flushOfflinePunches==='function')flushOfflinePunches();}catch(e){}"
                + "setTimeout(function(){try{if(typeof sendHeartbeat==='function')sendHeartbeat();}catch(e){}},15000);"
                + "return 1;})()", null);
    }

    @Override
    public boolean pageOk() {
        return !mainFrameError;
    }

    /** Settings asks for a fresh page after the address changed. */
    void loadConfiguredUrl() {
        if (web != null) web.loadUrl(prefs.url());
    }

    @Override
    protected void onNewIntent(Intent i) {
        super.onNewIntent(i);
        if (i != null && i.getBooleanExtra("reload_url", false)) loadConfiguredUrl();
    }

    @Override
    protected void onDestroy() {
        ui.removeCallbacksAndMessages(null);
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null && netCb != null) cm.unregisterNetworkCallback(netCb);
        } catch (Exception ignored) { }
        if (web != null) web.destroy();
        super.onDestroy();
    }
}

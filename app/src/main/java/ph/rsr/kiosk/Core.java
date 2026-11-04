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
import android.net.wifi.WifiManager;
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
        /** Ask the kiosk page to sync now (punch queues + its own heartbeat). Main thread. */
        void nudgePage();
        /** Is a worker in the middle of a punch (employee selected / dialog open)? Main thread; answers async. */
        void pageBusy(java.util.function.Consumer<Boolean> answer);
    }

    private final Context ctx;
    private final Prefs prefs;
    private final NetState net;
    private final Handler bg;
    private final Handler main = new Handler(Looper.getMainLooper());
    private WeakReference<Host> host = new WeakReference<>(null);
    private volatile String pendingEvent = "started";
    private Boolean lastOnHours = null;
    /** Last time a worker touched the screen (elapsedRealtime). Restart/update wait for a quiet moment. */
    private volatile long lastTouch = 0;

    void touched() { lastTouch = android.os.SystemClock.elapsedRealtime(); }

    // ---- punch safety --------------------------------------------------------------------------
    // Owner rule: never block, delay or lose a punch. Anything that stops or reloads the kiosk page
    // (reload, restart, app update, screen off) first checks that nobody is using the kiosk.

    private long idleMs() { return android.os.SystemClock.elapsedRealtime() - lastTouch; }

    /** Now inside a punch rush (Config.RUSH)? */
    static boolean inRush() {
        int now = nowMin();
        for (String[] r : Config.RUSH) if (now >= minutes(r[0]) && now < minutes(r[1])) return true;
        return false;
    }

    static int nowMin() {
        Calendar c = Calendar.getInstance();
        return c.get(Calendar.HOUR_OF_DAY) * 60 + c.get(Calendar.MINUTE);
    }

    static boolean between(int now, String from, String to) {
        int a = minutes(from), b = minutes(to);
        return a <= b ? (now >= a && now < b) : (now >= a || now < b);
    }

    /** Asks the page (background thread; waits up to 3 s). No page = not busy; no answer = busy (safe side).
     *  Must never run on the main thread (the answer comes on the main thread): there it says busy. */
    private boolean pageBusyNow() {
        if (Looper.myLooper() == Looper.getMainLooper()) return true;
        Host h = host.get();
        if (h == null || !h.pageOk()) return false;
        java.util.concurrent.CountDownLatch l = new java.util.concurrent.CountDownLatch(1);
        final boolean[] busy = {true};
        main.post(() -> {
            Host hh = host.get();
            if (hh == null) { l.countDown(); return; }
            hh.pageBusy(b -> { busy[0] = Boolean.TRUE.equals(b); l.countDown(); });
        });
        try { l.await(3, java.util.concurrent.TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
        return busy[0];
    }

    /** Safe to interrupt the kiosk right now: no touch for idleSec, nobody mid-punch. */
    private boolean safeNow(int idleSec) {
        return idleMs() >= idleSec * 1000L && !pageBusyNow();
    }

    /** Background thread: wait until safe (checked every 5 s), at most maxSec. */
    private boolean waitUntilSafe(int idleSec, int maxSec) {
        long end = android.os.SystemClock.elapsedRealtime() + maxSec * 1000L;
        while (true) {
            if (safeNow(idleSec)) return true;
            if (android.os.SystemClock.elapsedRealtime() > end) return false;
            try { Thread.sleep(5000); } catch (InterruptedException e) { return false; }
        }
    }

    static synchronized Core get(Context c) {
        if (instance == null) instance = new Core(c.getApplicationContext());
        return instance;
    }

    private Core(Context c) {
        ctx = c;
        prefs = new Prefs(c);
        net = new NetState(c);
        HandlerThread t = new HandlerThread("rsr-core");
        t.start();
        bg = new Handler(t.getLooper());
    }

    // ---- wake before the roll-call reports ----------------------------------------------------

    /** Next report wake time, as an exact alarm (allowed while idle). Safe to call any time. */
    void scheduleReportAlarm() {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(ScheduleReceiver.ACTION_REPORT_WAKE);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 9, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        long next = Long.MAX_VALUE;
        for (String t : Config.REPORT_WAKE_TIMES) next = Math.min(next, nextAt(t));
        if (next == Long.MAX_VALUE) return;
        boolean exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms();
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
    }

    /** Alarm fired: wake the screen, keep the CPU up for 90 s, push waiting punches, send heartbeats. */
    void reportWake() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            PowerManager.WakeLock cpu = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:report");
            cpu.acquire(90_000);
        } catch (Exception e) {
            Log.w(TAG, "report wakelock", e);
        }
        wakeScreen();
        main.postDelayed(() -> { Host h = host.get(); if (h != null) { if (!h.pageOk()) h.reloadPage(false); else h.nudgePage(); } }, 3000);
        // a second push 30 s later, after Wi-Fi has had time to reconnect from sleep
        main.postDelayed(() -> { Host h = host.get(); if (h != null) h.nudgePage(); }, 33_000);
        bg.postDelayed(this::beat, 5000);
        scheduleReportAlarm();
    }

    void start() {
        bg.removeCallbacksAndMessages(null);
        watchPower();
        bg.post(this::loop);
        scheduleNextAlarm();
        scheduleReportAlarm();
        scheduleUpdateAlarm();
    }

    /** 01:00 every night: wake the processor for the update check (the tablet sleeps at night). */
    void scheduleUpdateAlarm() {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(ScheduleReceiver.ACTION_UPDATE);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 10, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, nextAt("01:00"), pi);
    }

    void updateAlarm() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:update").acquire(5 * 60_000L);
        } catch (Exception ignored) { }
        bg.postDelayed(this::nightlyUpdateCheck, 20_000);   // give Wi-Fi time to wake
        scheduleUpdateAlarm();
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
            applyAwake();
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
            p.put("token", prefs.token());
            p.put("name", prefs.name());
            p.put("kiosk_device_id", prefs.pageDeviceId());
            p.put("app_version", Updater.currentVersion(ctx));
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b != null) {
                int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                int plug = b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0);
                if (lvl >= 0 && sc > 0) p.put("battery", Math.round(lvl * 100f / sc));
                p.put("charging", plug != 0);   // plugged in
                // what the battery is really doing: a weak charger can be plugged in and still lose charge
                int st = b.getIntExtra(BatteryManager.EXTRA_STATUS, -1);
                p.put("charge_state", st == BatteryManager.BATTERY_STATUS_CHARGING ? "charging"
                        : st == BatteryManager.BATTERY_STATUS_FULL ? "full"
                        : st == BatteryManager.BATTERY_STATUS_DISCHARGING ? "discharging"
                        : st == BatteryManager.BATTERY_STATUS_NOT_CHARGING ? "not_charging" : "unknown");
                int temp = b.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE);   // tenths of a degree C
                if (temp != Integer.MIN_VALUE && temp > -200 && temp < 1000) p.put("battery_temp", temp / 10.0);
            }
            net.addTo(p);
            JSONObject outage = net.pendingOutage();
            if (outage != null) p.put("outage", outage);
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
            String resp;
            try {
                resp = Net.rpc("kiosk_app_beat", body);
            } catch (Exception e) {
                net.beatFailed();
                throw e;
            }
            net.beatOk();
            if (ev != null && ev.equals(pendingEvent)) pendingEvent = null;

            JSONObject r = resp.trim().startsWith("{") ? new JSONObject(resp) : new JSONObject();
            if ("token".equals(r.optString("error"))) {
                prefs.setLastBeatStatus("REJECTED by server - press Forget tablet on the Tablets page");
                return;
            }
            prefs.setLastBeatStatus("ok " + android.text.format.DateFormat.format("HH:mm", System.currentTimeMillis()));
            String tok = r.optString("token", "");
            if (tok.matches("[0-9a-f-]{36}") && !tok.equals(prefs.token())) prefs.setToken(tok);
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
            JSONObject b = new JSONObject().put("p_device", prefs.deviceId()).put("p_token", prefs.token())
                    .put("p_cmd_id", id).put("p_result", result);
            Net.rpc("kiosk_app_ack", b.toString());
        } catch (Exception e) {
            Log.w(TAG, "ack", e);
        }
    }

    private void runCommand(String cmd, String arg, long id) {
        Log.i(TAG, "command " + cmd + " " + arg);
        switch (cmd) {
            case "reload":
            case "hard_reload": {
                // A page that is not loading cannot be punched on anyway: reload at once.
                Host h0 = host.get();
                boolean broken = h0 != null && !h0.pageOk();
                if (!broken && inRush()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!broken && !waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                final boolean hard = cmd.equals("hard_reload");
                main.post(() -> { Host h = host.get(); if (h != null) h.reloadPage(hard); });
                ack(id, "done");
                break;
            }
            case "restart":
                if (!Policy.isOwner(ctx)) { ack(id, "failed: not device owner"); break; }
                if (inRush()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                ack(id, "restarting");
                Policy.reboot(ctx);
                break;
            case "update":
                if (inRush()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                ack(id, Updater.checkAndInstall(ctx, () -> !inRush() && safeNow(30)));
                break;
            case "screen_on":
                wakeScreen();
                ack(id, "done");
                break;
            case "screen_off":
                if (inRush()) { ack(id, "refused: punch rush time"); break; }
                if (!waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min"); break; }
                screenOff("office");
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
        bg.post(this::checkScheduleTransition);   // background thread: it may ask the page
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

    /**
     * Screen rules, checked every minute while the tablet is awake (and by the ON/OFF alarms):
     *  - ON time: wake the screen.
     *  - Inside the schedule before EVENING_IDLE_FROM (9 PM): the screen stays on (the page blacks out
     *    by itself and the app lowers the backlight).
     *  - Inside the schedule from 9 PM: off after 15 min without a touch (overtime may end 9, 10 or 12).
     *  - Outside the schedule: a screen woken by the power button goes off 2 min after the last touch.
     *  Never while a worker is mid-punch.
     */
    void checkScheduleTransition() {
        boolean onHours, changed;
        synchronized (this) {
            onHours = isOnHours();
            changed = lastOnHours != null && lastOnHours != onHours;
            lastOnHours = onHours;
        }
        if (changed && onHours) { wakeScreen(); return; }
        // Maintenance: the office is in Android settings, where touches do not reach the kiosk's idle timer.
        // Never turn the screen off under them (2026-11-04).
        if (prefs.inMaintenance()) return;
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        if (pm == null || !pm.isInteractive()) return;
        int limitMin;
        if (!onHours) limitMin = Config.NIGHT_IDLE_MIN;
        else if (inEvening()) limitMin = Config.EVENING_IDLE_MIN;
        else return;
        if (idleMs() >= limitMin * 60_000L && !pageBusyNow()) {
            synchronized (this) { if (isOnHours() != onHours) return; }   // an ON alarm came in meanwhile
            screenOff(onHours ? "evening idle" : "after hours");
        }
    }

    /** From 9 PM until the OFF time (OFF may be after midnight). Never during the day. */
    private boolean inEvening() {
        if (!prefs.scheduleEnabled()) return false;
        int now = nowMin(), from = minutes(Config.EVENING_IDLE_FROM), on = minutes(prefs.onTime()), off = minutes(prefs.offTime());
        if (from < 0 || on < 0 || off < 0) return false;
        if (off > on) return now >= from && now < off;   // OFF the same day (e.g. 22:30)
        return now >= from || now < off;                 // OFF after midnight (e.g. 00:15)
    }

    /** Turn the screen off now and tell the office it was on purpose (not a dead or offline tablet). */
    private void screenOff(String why) {
        Log.i(TAG, "screen off: " + why);
        try {   // keep the processor awake until the screen_on=false report has gone out
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:screenoff").acquire(20_000L);
        } catch (Exception ignored) { }
        bg.post(this::beat);                                   // last report says screen_on=true...
        main.postDelayed(() -> Policy.screenOffNow(ctx), 1500);
        bg.postDelayed(this::beat, 4000);                      // ...this one says screen_on=false
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
        // Exact, so the screen is on before the first 7:00 punch even after a night of deep sleep.
        boolean exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms();
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
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

    // ---- stay reachable with the screen off (see Awake) ----------------------------------------

    private Awake awake;
    private boolean powerWatched;

    private synchronized Awake awake() {
        if (awake == null) awake = buildAwake();
        return awake;
    }

    @SuppressWarnings("deprecation")
    private Awake buildAwake() {
        Awake.Lock none = new Awake.Lock() {
            public void acquire() { }
            public void release() { }
            public boolean held() { return false; }
        };
        Awake.Lock cpu = none, wifi = none, screen = none;
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null) {
                cpu = wakeLock(pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:net"));
                screen = wakeLock(pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                        | PowerManager.ON_AFTER_RELEASE, "rsr:maint"));
            }
        } catch (Exception e) { Log.w(TAG, "wakelock", e); }
        try {
            WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null) {
                final WifiManager.WifiLock w = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "rsr:wifi");
                w.setReferenceCounted(false);
                wifi = new Awake.Lock() {
                    public void acquire() { w.acquire(); }
                    public void release() { w.release(); }
                    public boolean held() { return w.isHeld(); }
                };
            }
        } catch (Exception e) { Log.w(TAG, "wifilock", e); }
        return new Awake(cpu, wifi, screen);
    }

    private static Awake.Lock wakeLock(final PowerManager.WakeLock l) {
        l.setReferenceCounted(false);
        return new Awake.Lock() {
            public void acquire() { l.acquire(); }
            public void release() { l.release(); }
            public boolean held() { return l.isHeld(); }
        };
    }

    /** Charger connected (the "charging" flag in the heartbeat is the same reading). */
    private boolean plugged() {
        try {
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            return b != null && b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
        } catch (Exception e) {
            return false;
        }
    }

    void applyAwake() {
        try { awake().apply(plugged(), prefs.inMaintenance()); } catch (Throwable t) { Log.w(TAG, "awake", t); }
    }

    /** Plug / unplug: re-apply at once (an unplugged tablet asleep would otherwise wait for its next wake). */
    private void watchPower() {
        synchronized (this) {
            if (powerWatched) return;
            powerWatched = true;
        }
        try {
            IntentFilter f = new IntentFilter(Intent.ACTION_POWER_CONNECTED);
            f.addAction(Intent.ACTION_POWER_DISCONNECTED);
            ctx.registerReceiver(new android.content.BroadcastReceiver() {
                @Override
                public void onReceive(Context c, Intent i) { bg.post(Core.this::applyAwake); }
            }, f);
        } catch (Exception e) { Log.w(TAG, "power watch", e); }
    }

    // ---- maintenance + updates ----------------------------------------------------------------

    void startMaintenance() {
        long until = System.currentTimeMillis() + Config.MAINTENANCE_MS;
        prefs.setMaintenanceUntil(until);
        applyAwake();   // screen stays on for the 10 minutes (Android's own timeout must not cut the tablet off)
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

    /** Alarm path for the screen schedule (ON / OFF time). The same punch-safe rules as the minute check. */
    void scheduleAlarm() {
        boolean onHours = isOnHours();
        if (onHours) {
            synchronized (this) { lastOnHours = true; }
            wakeScreen();
        } else {
            try {
                PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
                pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:sched").acquire(4 * 60_000L);
            } catch (Exception ignored) { }
            // keep checking each minute for a few minutes, so a worker mid-punch at OFF time is not cut off
            for (int k = 0; k < 4; k++) bg.postDelayed(this::checkScheduleTransition, k * 60_000L);
        }
        scheduleNextAlarm();
    }

    void endMaintenance() {
        prefs.setMaintenanceUntil(0);
        applyAwake();
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

    /** Once a day, only 00:30 - 04:30 and only when nobody is using the kiosk (never mid-punch). */
    private void nightlyUpdateCheck() {
        if (!between(nowMin(), Config.UPDATE_FROM, Config.UPDATE_TO)) return;
        if (System.currentTimeMillis() - prefs.lastUpdateCheck() < 20 * 3600_000L) return;
        if (!safeNow(10 * 60)) return;
        String r = Updater.checkAndInstall(ctx, () -> between(nowMin(), Config.UPDATE_FROM, Config.UPDATE_TO) && safeNow(10 * 60));
        // only a real outcome counts as tonight's check; postponed / no internet tries again later tonight
        if (r.startsWith("installing") || r.startsWith("up to date") || r.startsWith("no release")) {
            prefs.setLastUpdateCheck(System.currentTimeMillis());
        }
        if (r.startsWith("installing")) reportEvent(r);
    }

    void updateNow(Runnable done, StringBuilder out) {
        bg.post(() -> {
            out.append(Updater.checkAndInstall(ctx));
            main.post(done);
        });
    }
}

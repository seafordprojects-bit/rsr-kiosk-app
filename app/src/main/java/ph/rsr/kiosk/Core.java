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

import org.json.JSONArray;
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
        /** Office pressed Screen on: undim the backlight and lift the page's black screen. Main thread. */
        void wakeAndBrighten();
        /** The kiosk page's version stamp ("" if not read yet). Any thread. */
        String pageVersion();
        /** The page's last error ("" if none) and when (ms). Any thread. */
        String pageError();
        long pageErrorAt();
        /** Capture the kiosk screen (camera hidden). Main thread; answers a base64 JPEG or null. */
        void takeScreenshot(java.util.function.Consumer<String> done);
        /** Is a worker in the middle of a punch (employee selected / dialog open)? Main thread; answers async. */
        void pageBusy(java.util.function.Consumer<Boolean> answer);
        /** Build-6 office "Retry stuck punches": un-stick rejected punches the page still has, then sync. Main thread. */
        void retryPunches(java.util.function.Consumer<String> done);
        /** Build-6 stronger wake: ask Android to turn the screen on for the kiosk window itself. Main thread. */
        void turnScreenOnNow();
        /** Holiday sleep: pause the kiosk page (timers, sync) / run it again. Main thread. */
        void setPaused(boolean paused);
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

    void touched() {
        lastTouch = android.os.SystemClock.elapsedRealtime();
        long now = System.currentTimeMillis();
        if (now - lastTouchSaved > 60_000) { lastTouchSaved = now; prefs.setLastTouchWall(now); }
        if (prefs.sleeping()) bg.post(() -> exitSleep("screen touched"));
    }
    private long lastTouchSaved = 0;

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

    /** Punch-rush protection blocks office commands only on a kiosk tablet (build-14, owner 2026-11-14).
     *  A roll-call phone has no kiosk punches, so Update / Reload / Full reload / Restart are never
     *  refused on it for "punch rush time". Tablets are unchanged. Pure decision in Mode (tested). */
    private boolean rushBlocks() { return Mode.rushBlocks(inRush(), prefs.phone()); }

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
        // Roll-call phone: no kiosk punches to push, and waking a phone on battery 6x a day wastes it.
        if (prefs.phone()) { am.cancel(pi); return; }
        long next = Long.MAX_VALUE;
        for (String t : Config.REPORT_WAKE_TIMES) next = Math.min(next, nextAt(t));
        if (next == Long.MAX_VALUE) return;
        boolean exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms();
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
    }

    /** Alarm fired: wake the screen, keep the CPU up for 90 s, push waiting punches, send heartbeats.
     *  (Review 2026-11-12: kept as it was. In the day the screen is already on with the backlight at 1% and the
     *  window brightness wins over this wake lock, so it does not light the tablet; and it still brings the kiosk
     *  to the front when Android has dropped it, before the roll-call push.) */
    void reportWake() {
        if (prefs.sleeping()) { scheduleReportAlarm(); return; }   // holiday sleep: no report pushes
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
        // build-7: read the yard WiFi modem at this report time (the CPU is already up; no extra wake-up)
        bg.postDelayed(() -> modemRead(true), 40_000);
        bg.postDelayed(this::beat, 60_000);
        scheduleReportAlarm();
    }

    // ---- build-7: yard WiFi modem load (PLDT prepaid; owner 2026-11-17) -----------------------------
    /** Never on the roll-call phone; never in a punch rush, within 60 s of a touch, or on battery at 20% or less. */
    void modemRead(boolean force) {
        if (prefs.phone()) return;
        ModemRead.request(ctx, force, () -> !inRush() && idleMs() >= 60_000
                && !(batteryPct() >= 0 && batteryPct() <= 20 && !plugged()));
    }

    void start() {
        KeepAlive.start(ctx);   // foreground class: never frozen, network kept (device owner may start it any time)
        bg.removeCallbacksAndMessages(null);
        watchPower();
        if (!rawPlugged() && PowerLog.unpluggedSince(ctx) == 0) PowerLog.setUnpluggedSince(ctx, System.currentTimeMillis());
        if (rawPlugged()) PowerLog.setUnpluggedSince(ctx, 0L);
        bg.post(this::loop);
        scheduleNextAlarm();
        scheduleReportAlarm();
        scheduleUpdateAlarm();
        scheduleCheckin();
        watchCalls();
    }

    // ---- build-6: a phone call to the tablet's SIM wakes the kiosk (owner 2026-11-16) -------------
    // Backup when "Screen on" cannot reach the tablet (Wi-Fi down, deep sleep): call the SIM number. Owner's test
    // 2026-11-16: the full lock already keeps the call silent with no call screen, and Android lights the screen.
    // Here the kiosk page is also brought back (black idle screen lifted, brightness restored), the idle screen-off
    // counts from the call, and the office is told. The caller's number is never read or stored. Any caller works
    // (a spam call only lights the screen for a few minutes). Phone mode: not used.
    private long lastCallWake = 0;

    private void watchCalls() {
        try {
            ctx.registerReceiver(new android.content.BroadcastReceiver() {
                @Override
                public void onReceive(Context c, Intent i) {
                    if (!android.telephony.TelephonyManager.EXTRA_STATE_RINGING.equals(
                            i.getStringExtra(android.telephony.TelephonyManager.EXTRA_STATE))) return;
                    callWake();
                }
            }, new IntentFilter(android.telephony.TelephonyManager.ACTION_PHONE_STATE_CHANGED));
        } catch (Exception e) {
            Log.w(TAG, "watch calls", e);
        }
    }

    private void callWake() {
        if (prefs.phone()) return;
        if (prefs.sleeping()) bg.post(() -> exitSleep("phone call"));
        long now = System.currentTimeMillis();
        // owner test 2026-11-16: a 2nd / 3rd call soon after the first stayed black (the old 60 s guard skipped it).
        // Every call now wakes and lifts the black page; only the office report is limited (one per 15 s).
        touched();
        if (prefs.inMaintenance()) wakeScreenOnly(); else wakeScreenChecked();
        // the kiosk window may only be back on screen a moment later: lift the black page / dim backlight again
        for (long d : new long[]{2000, 5000}) {
            main.postDelayed(() -> { Host h = host.get(); if (h != null) h.wakeAndBrighten(); }, d);
        }
        if (now - lastCallWake < 15_000) return;
        lastCallWake = now;
        reportEvent("screen woken by phone call");
        beatSoon();
    }

    // ---- build-6: hourly check-in while the screen is off on battery ----------------------------
    // On the charger the tablet stays reachable (Awake). On battery with the screen off (Carmen at night, generator
    // off) it falls into deep sleep and the office's commands wait until morning (found 2026-11-04). Every hour an
    // alarm wakes it for about 45 s: report, pick up a command, send waiting telco texts. Phone: never (battery).

    void scheduleCheckin() {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(ScheduleReceiver.ACTION_CHECKIN);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, 11, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        if (prefs.phone()) { am.cancel(pi); return; }
        long next = System.currentTimeMillis() + Config.CHECKIN_MS;
        boolean exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms();
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, next, pi);
    }

    void checkinAlarm() {
        scheduleCheckin();
        if (prefs.phone() || prefs.sleeping()) return;   // holiday sleep: its own 12-hour report instead
        PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
        boolean asleep = pm != null && !pm.isInteractive();
        if (!asleep || plugged()) return;   // screen on or on the charger: the normal 1-minute loop is running
        if (batteryPct() >= 0 && batteryPct() <= 20) return;   // low battery: keep it for the morning punches
        final PowerManager.WakeLock wl;
        try {
            wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:checkin");
            wl.setReferenceCounted(false);
            wl.acquire(45_000L);
        } catch (Exception e) {
            return;
        }
        bg.postDelayed(this::checkSleepTriggers, 2_000);   // power-cut saver: generator never came / long brownout
        bg.postDelayed(this::beat, 12_000);         // Wi-Fi reconnects from sleep first
        bg.postDelayed(this::sendTexts, 14_000);
        bg.postDelayed(() -> {                      // second try (and picks up a command sent meanwhile), then sleep again
            beat();
            try { if (wl.isHeld()) wl.release(); } catch (Exception ignored) { }
        }, 32_000);
    }

    private int batteryPct() {
        try {
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b == null) return -1;
            int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            return lvl >= 0 && sc > 0 ? Math.round(lvl * 100f / sc) : -1;
        } catch (Exception e) {
            return -1;
        }
    }

    // ---- build-6: telco texts to the office ------------------------------------------------------

    void sendTextsSoon() { bg.post(this::sendTexts); }

    /**
     * A telco text just arrived (owner 2026-11-16: a sign-in code must reach the Tablets page at once, not at the next
     * hourly check-in). Keep the processor awake ~50 s - NOT the screen - and send right away, then again at 10 / 25 /
     * 45 s in case the Wi-Fi is still waking up from sleep. The app's foreground service keeps the network allowed in
     * deep sleep. A few texts a month: no real battery cost. The hourly check-in is not changed.
     */
    private Handler textH;

    private synchronized Handler textHandler() {
        if (textH == null) {
            HandlerThread t = new HandlerThread("rsr-texts");
            t.start();
            textH = new Handler(t.getLooper());
        }
        return textH;
    }

    void textArrived() {
        final PowerManager.WakeLock wl;
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:text");
            wl.setReferenceCounted(false);
            wl.acquire(55_000L);
        } catch (Exception e) {
            sendTextsSoon();
            return;
        }
        // own thread: the main background thread may be busy (waiting for a quiet moment, an update check)
        Handler tx = textHandler();
        tx.post(this::sendTexts);
        tx.postDelayed(this::sendTexts, 10_000);
        tx.postDelayed(this::sendTexts, 25_000);
        tx.postDelayed(() -> {
            sendTexts();
            try { if (wl.isHeld()) wl.release(); } catch (Exception ignored) { }
        }, 45_000);
    }

    private void sendTexts() {
        for (int k = 0; k < 10; k++) {
            org.json.JSONArray q = TextQueue.list(ctx);
            if (q.length() == 0) return;
            try {
                JSONObject t = q.getJSONObject(0);
                String body = t.optString("body", "");
                long at = t.optLong("at", System.currentTimeMillis());
                JSONObject b = new JSONObject().put("p_device", prefs.deviceId()).put("p_token", prefs.token())
                        .put("p_sender", t.optString("from", "")).put("p_body", body).put("p_at", isoUtc(at));
                String resp = Net.rpc("kiosk_app_sms_put", b.toString());
                JSONObject r = resp.trim().startsWith("{") ? new JSONObject(resp) : new JSONObject();
                String err = r.optString("error", "");
                if (err.equals("token")) return;                                    // keep; try again later
                TextQueue.removeFirst(ctx, at, body);   // sent, or refused for good (empty / over 40 a day = spam)
            } catch (Exception e) {
                return;   // offline: kept on the tablet, sent with a later report
            }
        }
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
        if (prefs.sleeping()) {   // holiday sleep: nothing but "is it time / is the power back?"
            try {
                if (rawPlugged()) exitSleep("power back");
                else if (System.currentTimeMillis() >= prefs.sleepUntil()) exitSleep("wake time");
            } catch (Throwable t) { Log.w(TAG, "sleep loop", t); }
            bg.postDelayed(this::loop, Config.BEAT_MS);
            return;
        }
        try {
            checkSleepTriggers();
            applyAwake();
            beat();
            checkMaintenanceExpiry();
            checkScheduleTransition();
            nightlyUpdateCheck();
            modemRead(false);
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
                BatteryHealth.addTo(ctx, b, p);   // owner 2026-11-18: battery wear (replace before it fails)
            }
            net.addTo(p);
            SimWatch.addTo(ctx, p);   // build-6: connection type, SIM, mobile data used
            JSONObject modem = ModemRead.pending();   // build-7: the yard modem's counter, when a new read is waiting
            if (modem != null) p.put("modem", modem);
            String modemErr = ModemRead.lastError();
            if (modemErr != null) p.put("modem_err", modemErr);
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
                if (!h.pageVersion().isEmpty()) p.put("page_version", h.pageVersion());
                if (h.pageErrorAt() > 0) {
                    p.put("page_error", h.pageError());
                    p.put("page_error_at", isoUtc(h.pageErrorAt()));
                }
            }
            p.put("model", Build.MANUFACTURER + " " + Build.MODEL + " / Android " + Build.VERSION.RELEASE);
            String ev = pendingEvent;
            if (ev != null) p.put("event", ev);
            JSONArray power = PowerLog.list(ctx);   // owner 2026-11-19: power log (cuts and returns, even offline)
            if (power.length() > 50) { JSONArray f = new JSONArray(); for (int i = 0; i < 50; i++) f.put(power.get(i)); power = f; }
            if (power.length() > 0) p.put("power_events", power);
            if (prefs.sleeping()) p.put("deep_sleep", new JSONObject().put("reason", prefs.sleepReason())
                    .put("until", isoUtc(prefs.sleepUntil())));

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
            if (TextQueue.list(ctx).length() > 0) bg.post(this::sendTexts);   // texts that waited for the network

            JSONObject r = resp.trim().startsWith("{") ? new JSONObject(resp) : new JSONObject();
            if ("token".equals(r.optString("error"))) {
                prefs.setLastBeatStatus("REJECTED by server - press Forget tablet on the Tablets page");
                return;
            }
            if (modem != null) ModemRead.sent(modem);   // only once the server accepted this tablet's report
            if (power.length() > 0) PowerLog.sent(ctx, power);
            readSleepPlan(r);
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

    private static String isoUtc(long t) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return f.format(new java.util.Date(t));
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
        Log.i(TAG, "command " + cmd + ("set_wifi".equals(cmd) ? "" : " " + arg));   // never the Wi-Fi password
        switch (cmd) {
            case "reload":
            case "hard_reload": {
                // A page that is not loading cannot be punched on anyway: reload at once.
                Host h0 = host.get();
                boolean broken = h0 != null && !h0.pageOk();
                if (!broken && rushBlocks()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!broken && !waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                final boolean hard = cmd.equals("hard_reload");
                main.post(() -> { Host h = host.get(); if (h != null) h.reloadPage(hard); });
                ack(id, "done");
                break;
            }
            case "restart":
                if (!Policy.isOwner(ctx)) { ack(id, "failed: not device owner"); break; }
                if (rushBlocks()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                ack(id, "restarting");
                Policy.reboot(ctx);
                break;
            case "update":
                if (rushBlocks()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!waitUntilSafe(60, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                ack(id, Updater.checkAndInstall(ctx, () -> !rushBlocks() && safeNow(30)));
                break;
            case "screen_on":
                if (prefs.sleeping()) exitSleep("office Screen on");
                touched();   // at once: the night / evening idle screen-off counts from this press
                if (prefs.inMaintenance()) wakeScreenOnly(); else wakeScreenChecked();
                // The display may already be on but dimmed to 1% with the page black (idle saver): lift both.
                main.postDelayed(() -> { Host h = host.get(); if (h != null) h.wakeAndBrighten(); }, 500);
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
            case "screenshot": {
                if (prefs.inMaintenance()) { ack(id, "refused: settings are open (maintenance)"); break; }
                // never while a worker is mid-punch: wait for 20 s without a touch, at most 2 min
                if (!waitUntilSafe(20, 60)) { ack(id, "refused: kiosk in use - send again later"); break; }
                if (prefs.inMaintenance()) { ack(id, "refused: settings are open (maintenance)"); break; }   // opened while waiting
                if (host.get() == null) { ack(id, "failed: kiosk screen not running"); break; }
                wakeScreen();   // PixelCopy needs the screen on and the kiosk in front
                final String[] pic = {null};
                final java.util.concurrent.CountDownLatch l = new java.util.concurrent.CountDownLatch(1);
                main.postDelayed(() -> {
                    Host hh = host.get();
                    if (hh == null) { l.countDown(); return; }
                    hh.takeScreenshot(b -> { pic[0] = b; l.countDown(); });
                }, 1500);
                try { l.await(20, java.util.concurrent.TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
                if (KioskActivity.SHOT_BUSY.equals(pic[0])) { ack(id, "refused: kiosk in use - send again later"); break; }
                if (pic[0] == null) { ack(id, "failed: could not capture the screen"); break; }
                try {
                    JSONObject b = new JSONObject().put("p_device", prefs.deviceId()).put("p_token", prefs.token()).put("p_jpeg", pic[0]);
                    String resp = Net.rpc("kiosk_app_shot_put", b.toString());
                    JSONObject r = resp.trim().startsWith("{") ? new JSONObject(resp) : new JSONObject();
                    ack(id, r.optBoolean("ok") ? "done" : "failed: " + r.optString("error", "upload"));
                } catch (Exception e) {
                    ack(id, "failed: upload (" + e.getClass().getSimpleName() + ")");
                }
                break;
            }
            case "retry_punches": {
                // never under a worker's hands: wait for 10 s without a touch and nobody mid-punch (at most 2 min)
                if (!waitUntilSafe(10, 120)) { ack(id, "refused: kiosk in use - send again later"); break; }
                if (host.get() == null) { ack(id, "failed: kiosk screen not running"); break; }
                final String[] res = {null};
                final java.util.concurrent.CountDownLatch l = new java.util.concurrent.CountDownLatch(1);
                main.post(() -> {
                    Host hh = host.get();
                    if (hh == null) { l.countDown(); return; }
                    hh.retryPunches(v -> { res[0] = v; l.countDown(); });
                });
                try { l.await(10, java.util.concurrent.TimeUnit.SECONDS); } catch (InterruptedException ignored) { }
                ack(id, res[0] == null ? "failed: page did not answer" : res[0]);
                break;
            }
            case "set_wifi": {
                // switching Wi-Fi drops the network for a few seconds (punches are saved on the tablet anyway):
                // still never in a punch rush or under a worker's hands
                if (rushBlocks()) { ack(id, "refused: punch rush time - send again later"); break; }
                if (!waitUntilSafe(30, 300)) { ack(id, "refused: kiosk in use for 5 min - send again later"); break; }
                ack(id, WifiSetter.apply(ctx, arg));
                break;
            }
            case "read_modem":
                // office button: read the yard modem at the next quiet moment (never in a rush / under a worker's hands)
                if (inRush()) { ack(id, "refused: punch rush time - send again later"); break; }
                modemRead(true);
                ack(id, "reading the modem - result in about 1 minute");
                bg.postDelayed(this::beat, 20_000);
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
        if (prefs.sleeping()) return;
        boolean onHours, changed;
        synchronized (this) {
            onHours = isOnHours();
            changed = lastOnHours != null && lastOnHours != onHours;
            lastOnHours = onHours;
        }
        if (changed && onHours) {
            if (prefs.inMaintenance()) wakeScreenOnly(); else wakeScreenChecked();
            return;
        }
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

    /** Light the screen without bringing the kiosk to the front (maintenance: office is in Android settings). */
    @SuppressWarnings("deprecation")
    private void wakeScreenOnly() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm.newWakeLock(PowerManager.SCREEN_BRIGHT_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP
                    | PowerManager.ON_AFTER_RELEASE, "rsr:wake").acquire(5000);
        } catch (Exception e) {
            Log.w(TAG, "wake", e);
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

    /**
     * Build-6 (06:45 screen-on failed 2026-11-04 although "Turn screen on" was allowed): wake the screen, then
     * CHECK it really came on. If not: a second, stronger way (the kiosk window itself asks Android to turn the
     * screen on). Still off: tell the office ("screen on failed"), so it is seen on the Tablets page / Telegram.
     * Also lifts the page's black idle screen, so the first worker sees the keypad.
     */
    void wakeScreenChecked() {
        try {   // keep the processor up for the checks below even if the screen stays off
            PowerManager pm0 = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm0.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:wakecheck").acquire(15_000L);
        } catch (Exception ignored) { }
        wakeScreen();
        main.postDelayed(() -> { Host h = host.get(); if (h != null) h.wakeAndBrighten(); }, 800);
        bg.postDelayed(() -> {
            if (screenIsOn()) return;
            Log.w(TAG, "screen did not come on: second try");
            wakeScreenStrong();
            bg.postDelayed(() -> {
                if (screenIsOn()) { reportEvent("screen on needed a second try"); }
                else { reportEvent("screen on failed"); }
                beat();
            }, 4000);
        }, 4000);
    }

    private boolean screenIsOn() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            return pm != null && pm.isInteractive();
        } catch (Exception e) {
            return true;   // unknown: do not report a failure we cannot see
        }
    }

    @SuppressWarnings("deprecation")
    private void wakeScreenStrong() {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm.newWakeLock(PowerManager.FULL_WAKE_LOCK | PowerManager.ACQUIRE_CAUSES_WAKEUP
                    | PowerManager.ON_AFTER_RELEASE, "rsr:wake2").acquire(8000);
        } catch (Exception e) {
            Log.w(TAG, "wake2", e);
        }
        main.post(() -> {
            try {
                Host h = host.get();
                if (h != null) h.turnScreenOnNow();
                Intent i = new Intent(ctx, KioskActivity.class).putExtra(KioskActivity.EXTRA_WAKE, true);
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_REORDER_TO_FRONT);
                ctx.startActivity(i);
            } catch (Exception e) {
                Log.w(TAG, "front2", e);
            }
        });
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

    // No timeout on purpose: applyAwake() re-checks every minute and on every plug / unplug.
    @SuppressWarnings("deprecation")
    @android.annotation.SuppressLint("WakelockTimeout")
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

    /** On a charger that really keeps up (see Awake.onCharger). Unknown = no (safe side for the battery). */
    private boolean plugged() {
        try {
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (b == null) return false;
            int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            int pct = lvl >= 0 && sc > 0 ? Math.round(lvl * 100f / sc) : -1;
            int temp = b.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, 0);   // tenths of a degree C
            return Awake.onCharger(b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0),
                    b.getIntExtra(BatteryManager.EXTRA_STATUS, -1), pct, temp / 10.0);
        } catch (Exception e) {
            return false;
        }
    }

    private final Object awakeGate = new Object();

    /** Any thread. Inputs are read and applied under one lock, so two threads never apply out of order. */
    void applyAwake() {
        synchronized (awakeGate) {
            try { awake().apply(plugged(), prefs.inMaintenance()); } catch (Exception e) { Log.w(TAG, "awake", e); }
        }
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
            f.addAction(Intent.ACTION_SCREEN_ON);
            f.addAction(Intent.ACTION_SHUTDOWN);
            android.content.BroadcastReceiver r = new android.content.BroadcastReceiver() {
                // Right here, not on the background thread: that one can be busy for minutes (update, reload wait).
                @Override
                public void onReceive(Context c, Intent i) {
                    String a = i.getAction();
                    if (Intent.ACTION_SCREEN_ON.equals(a)) {   // power button / anyone: a sleeping kiosk wakes at once
                        if (prefs.sleeping() && System.currentTimeMillis() > ownScreenOnUntil) bg.post(() -> exitSleep("screen turned on"));
                        return;
                    }
                    if (Intent.ACTION_SHUTDOWN.equals(a)) { PowerLog.add(ctx, "shutdown", batteryPct()); return; }
                    boolean on = Intent.ACTION_POWER_CONNECTED.equals(a);
                    PowerLog.add(ctx, on ? "on" : "off", batteryPct());   // power log (owner 2026-11-19)
                    PowerLog.setUnpluggedSince(ctx, on ? 0L : System.currentTimeMillis());
                    applyAwake();
                    if (on && prefs.sleeping()) bg.post(() -> exitSleep("power back"));
                }
            };
            if (Build.VERSION.SDK_INT >= 33) ctx.registerReceiver(r, f, Context.RECEIVER_NOT_EXPORTED);
            else ctx.registerReceiver(r, f);
        } catch (Exception e) { Log.w(TAG, "power watch", e); }
    }

    // ---- holiday sleep / power-cut saver (owner 2026-11-18/19) ---------------------------------------
    // A powered-off tablet cannot be turned on remotely, so the kiosk sleeps DEEPLY instead: screen off, Wi-Fi off,
    // page paused, no check-ins, a short report every 12 hours, and it wakes by itself at 7:00 (or the plan's end).
    // Rules: SleepRules. Any touch, the power button, a phone call, the office Screen on or the charger wakes it.

    private volatile long ownScreenOnUntil = 0;   // our own screen-on (wake at 7:00) is not "someone pressed power"

    /** Charger connected at all (any power coming in), unlike plugged() which also checks it keeps up. */
    private boolean rawPlugged() {
        try {
            Intent b = ctx.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            return b != null && b.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0;
        } catch (Exception e) {
            return false;
        }
    }

    /** Background thread. The planned holiday, or the power-cut saver: go to sleep now? Never in maintenance or on the phone. */
    void checkSleepTriggers() {
        try {
            if (prefs.phone() || prefs.inMaintenance() || prefs.sleeping()) return;
            long now = System.currentTimeMillis();
            if (SleepRules.inPlan(now, prefs.planFrom(), prefs.planUntil())) { enterSleep("holiday", prefs.planUntil()); return; }
            long off = PowerLog.unpluggedSince(ctx);
            int unMin = rawPlugged() || off <= 0 ? -1 : (int) Math.min(Integer.MAX_VALUE, (now - off) / 60_000L);
            int idleMin = (int) Math.min(Integer.MAX_VALUE, idleMs() / 60_000L);
            java.util.Calendar c = java.util.Calendar.getInstance();
            int nowMin = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE);
            c.set(java.util.Calendar.HOUR_OF_DAY, 0); c.set(java.util.Calendar.MINUTE, 0); c.set(java.util.Calendar.SECOND, 0);
            boolean touchedToday = Math.max(prefs.lastTouchWall(), lastTouchSaved) >= c.getTimeInMillis() || idleMin < nowMin;
            if (SleepRules.saverNow(prefs.powerWindows(), prefs.scheduleEnabled(), prefs.onTime(), prefs.offTime(),
                    nowMin, unMin, idleMin, touchedToday)) {
                enterSleep("power cut", SleepRules.nextWake(now));
            }
        } catch (Throwable t) {
            Log.w(TAG, "sleep check", t);
        }
    }

    /** Background thread. Push waiting punches, tell the office, then sleep. Not while a worker is mid-punch. */
    private void enterSleep(String reason, long until) {
        if (prefs.sleeping() || until <= System.currentTimeMillis()) return;
        if (inRush() || pageBusyNow() || idleMs() < 60_000) return;   // try again at the next check
        int b = batteryPct();
        main.post(() -> { Host h = host.get(); if (h != null) h.nudgePage(); });   // last push of waiting punches
        reportEvent("deep sleep (" + reason + ") until " + new java.text.SimpleDateFormat("MMM d h:mm a", java.util.Locale.US)
                .format(new java.util.Date(until)) + (b >= 0 ? ", battery " + b + "%" : ""));
        try { Thread.sleep(15_000); } catch (InterruptedException ignored) { }
        if (idleMs() < 15_000 || rawPlugged()) return;   // someone came / power came back meanwhile
        beat();                                          // the office sees it before Wi-Fi goes off
        prefs.setSleep(until, reason);
        main.post(() -> { Host h = host.get(); if (h != null) h.setPaused(true); });
        main.postDelayed(() -> Policy.screenOffNow(ctx), 500);
        setWifi(false);
        cancelSleepAlarm(11, ScheduleReceiver.ACTION_CHECKIN);
        setSleepAlarm(21, ScheduleReceiver.ACTION_SLEEP_WAKE, until);
        setSleepAlarm(22, ScheduleReceiver.ACTION_SLEEP_REPORT, Math.min(until, System.currentTimeMillis() + SleepRules.REPORT_EVERY_MS));
    }

    /** Background thread. Wake up: Wi-Fi back, page running, screen on (in its hours), office told. */
    void exitSleep(String why) {
        if (!prefs.sleeping()) return;
        String reason = prefs.sleepReason();
        boolean timeUp = "wake time".equals(why);
        prefs.setSleep(0, "");
        cancelSleepAlarm(21, ScheduleReceiver.ACTION_SLEEP_WAKE);
        cancelSleepAlarm(22, ScheduleReceiver.ACTION_SLEEP_REPORT);
        setWifi(true);
        main.post(() -> { Host h = host.get(); if (h != null) h.setPaused(false); });
        if (isOnHours() && !"screen turned on".equals(why) && !"screen touched".equals(why)) {
            ownScreenOnUntil = System.currentTimeMillis() + 10_000;
            wakeScreenChecked();
        }
        scheduleCheckin();
        scheduleReportAlarm();
        scheduleNextAlarm();
        if (timeUp && "power cut".equals(reason) && !rawPlugged()) {   // 10:00: still no power and nobody? sleep again
            prefs.setWokeAt(System.currentTimeMillis());
            long at = SleepRules.nextAt(System.currentTimeMillis(), SleepRules.RECHECK_AT);
            if (at - System.currentTimeMillis() < 12 * 3600_000L) setSleepAlarm(23, ScheduleReceiver.ACTION_SLEEP_RECHECK, at);
        }
        int b = batteryPct();
        reportEvent("woke from deep sleep (" + why + ")" + (b >= 0 ? ", battery " + b + "%" : ""));
        bg.postDelayed(this::beat, 25_000);   // after Wi-Fi reconnects
        bg.postDelayed(this::beat, 50_000);
    }

    void sleepWakeAlarm() { bg.post(() -> { if (prefs.sleeping()) exitSleep("wake time"); }); }

    /** Every 12 hours while sleeping: Wi-Fi on for about 1.5 min, report "still alive, battery N%", pick up a command. */
    void sleepReportAlarm() {
        if (!prefs.sleeping()) return;
        long next = Math.min(prefs.sleepUntil(), System.currentTimeMillis() + SleepRules.REPORT_EVERY_MS);
        setSleepAlarm(22, ScheduleReceiver.ACTION_SLEEP_REPORT, next);
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "rsr:sleepreport").acquire(100_000L);
        } catch (Exception ignored) { }
        setWifi(true);
        bg.postDelayed(this::beat, 40_000);
        bg.postDelayed(this::beat, 70_000);
        bg.postDelayed(() -> { if (prefs.sleeping()) setWifi(false); }, 90_000);
    }

    /** 10:00 after a 7:00 power-cut wake: still no power and nobody touched it since -> sleep until the next 7:00. */
    void sleepRecheckAlarm() {
        bg.post(() -> {
            long woke = prefs.wokeAt();
            prefs.setWokeAt(0);
            if (woke <= 0 || prefs.sleeping()) return;
            boolean touched = Math.max(prefs.lastTouchWall(), lastTouchSaved) >= woke || idleMs() < System.currentTimeMillis() - woke;
            if (SleepRules.sleepAgainAt10(rawPlugged(), touched)) enterSleep("power cut", SleepRules.nextWake(System.currentTimeMillis()));
        });
    }

    void sleepPlanAlarm() { bg.post(this::checkSleepTriggers); }

    /** After a restart: alarms are gone. Still sleeping -> keep sleeping (or wake if its time passed). */
    void afterBoot() {
        if (!prefs.sleeping()) return;
        if (System.currentTimeMillis() >= prefs.sleepUntil() || rawPlugged()) { bg.post(() -> exitSleep(rawPlugged() ? "power back" : "wake time")); return; }
        setSleepAlarm(21, ScheduleReceiver.ACTION_SLEEP_WAKE, prefs.sleepUntil());
        setSleepAlarm(22, ScheduleReceiver.ACTION_SLEEP_REPORT, Math.min(prefs.sleepUntil(), System.currentTimeMillis() + SleepRules.REPORT_EVERY_MS));
        main.post(() -> { Host h = host.get(); if (h != null) h.setPaused(true); });
        setWifi(false);
    }

    /** The beat answer carries the owner's plan and the generator hours. A cancelled plan wakes a holiday sleep. */
    private void readSleepPlan(JSONObject r) {
        if (r.has("power_windows")) prefs.setPowerWindows(r.optString("power_windows", ""));
        if (!r.has("sleep_from")) return;
        long from = parseIso(r.optString("sleep_from", "")), until = parseIso(r.optString("sleep_until", ""));
        if (from != prefs.planFrom() || until != prefs.planUntil()) {
            prefs.setPlan(from, until);
            if (from > System.currentTimeMillis()) setSleepAlarm(24, ScheduleReceiver.ACTION_SLEEP_PLAN, from);
            else cancelSleepAlarm(24, ScheduleReceiver.ACTION_SLEEP_PLAN);
            if (prefs.sleeping() && "holiday".equals(prefs.sleepReason())) {
                if (until <= System.currentTimeMillis()) bg.post(() -> exitSleep("plan cancelled"));
                else if (until != prefs.sleepUntil()) {
                    prefs.setSleep(until, "holiday");
                    setSleepAlarm(21, ScheduleReceiver.ACTION_SLEEP_WAKE, until);
                }
            }
        }
    }

    private static long parseIso(String s) {
        if (s == null || s.isEmpty() || "null".equals(s)) return 0L;
        try {
            java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US);
            f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
            return f.parse(s).getTime();
        } catch (Exception e) {
            return 0L;
        }
    }

    @SuppressWarnings("deprecation")
    private void setWifi(boolean on) {
        try {   // device owner may still switch Wi-Fi (Android 10+ refuses this to normal apps)
            android.net.wifi.WifiManager wm = (android.net.wifi.WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm != null && wm.isWifiEnabled() != on) wm.setWifiEnabled(on);
        } catch (Exception e) {
            Log.w(TAG, "wifi " + on, e);
        }
    }

    private void setSleepAlarm(int code, String action, long at) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(action);
        PendingIntent pi = PendingIntent.getBroadcast(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        boolean exact = Build.VERSION.SDK_INT < 31 || am.canScheduleExactAlarms();
        if (exact) am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi);
        else am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pi);
    }

    private void cancelSleepAlarm(int code, String action) {
        AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;
        Intent i = new Intent(ctx, ScheduleReceiver.class).setAction(action);
        am.cancel(PendingIntent.getBroadcast(ctx, code, i, PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE));
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
            if (prefs.inMaintenance()) wakeScreenOnly(); else wakeScreenChecked();
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
        touched();   // touches in Android settings never reached the kiosk: do not go black a minute later at night
        applyAwake();
        Policy.applyKioskPolicies(ctx);
        bringToFront();
    }

    private void checkMaintenanceExpiry() {
        long until = prefs.maintenanceUntil();
        long now = System.currentTimeMillis();
        // also when the clock was set backwards: maintenance never lasts longer than 10 minutes from "now"
        if (until > 0 && (now >= until || until - now > Config.MAINTENANCE_MS + 60_000L)) {
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

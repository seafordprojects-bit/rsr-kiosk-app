package ph.rsr.kiosk;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;

/**
 * Plain-Java test (no Android needed). Run from the repo root:
 *   javac -d .scratch/t app/src/main/java/ph/rsr/kiosk/Awake.java test/AwakeTest.java && java -cp .scratch/t ph.rsr.kiosk.AwakeTest
 *
 * Failure it guards (2026-11-04, Mandaue tablet): with the screen off the tablet slept, Wi-Fi dropped,
 * the panel showed OFFLINE and the office's "Screen on" never arrived. During maintenance the screen
 * went dark on Android's own timeout, which is how it started.
 */
public class AwakeTest {
    static int fails = 0, passes = 0;

    static void ok(boolean c, String what) {
        if (c) { passes++; System.out.println("  ok   " + what); }
        else { fails++; System.out.println("  FAIL " + what); }
    }

    /** A lock that counts acquire/release and refuses to be released when not held (like Android does). */
    static final class FakeLock implements Awake.Lock {
        boolean held; int acquires, releases; final List<String> log;
        final String name;
        FakeLock(String n, List<String> log) { name = n; this.log = log; }
        public void acquire() { if (held) throw new IllegalStateException(name + " acquired twice"); held = true; acquires++; log.add("+" + name); }
        public void release() { if (!held) throw new IllegalStateException(name + " released while not held"); held = false; releases++; log.add("-" + name); }
        public boolean held() { return held; }
    }

    public static void main(String[] a) throws Exception {
        List<String> log = new ArrayList<>();
        FakeLock cpu = new FakeLock("cpu", log), wifi = new FakeLock("wifi", log), screen = new FakeLock("screen", log);
        Awake aw = new Awake(cpu, wifi, screen);

        System.out.println("Awake rules");
        aw.apply(false, false);
        ok(!cpu.held && !wifi.held && !screen.held, "on battery, no maintenance: nothing held (battery is never drained by us)");

        aw.apply(true, false);
        ok(cpu.held && wifi.held, "plugged in: processor and Wi-Fi kept awake (heartbeat + commands keep arriving with the screen off)");
        ok(!screen.held, "plugged in: the screen is NOT forced on (night schedule still turns it off)");

        aw.apply(true, false); aw.apply(true, false);
        ok(cpu.acquires == 1 && wifi.acquires == 1, "applied every minute: each lock taken only once (no stacking)");

        aw.apply(false, false);
        ok(!cpu.held && !wifi.held, "unplugged (Carmen generator off): locks released, battery not drained");

        aw.apply(false, true);
        ok(cpu.held && wifi.held && screen.held, "maintenance on battery: screen, processor and Wi-Fi stay on for the 10 minutes");

        aw.apply(true, true);
        ok(cpu.acquires == 2 && screen.acquires == 1, "maintenance + plugged in: nothing taken twice");

        aw.apply(true, false);
        ok(!screen.held && cpu.held && wifi.held, "maintenance ends while plugged in: screen lock released, network stays awake");

        aw.apply(false, false);
        ok(!cpu.held && !wifi.held && !screen.held, "everything released at the end");
        ok(cpu.acquires == cpu.releases && wifi.acquires == wifi.releases && screen.acquires == screen.releases,
                "every acquire has its release (no leaked lock)");

        // A lock call that throws (Android refusing) must not stop the other locks.
        List<String> log2 = new ArrayList<>();
        Awake.Lock bad = new Awake.Lock() {
            public void acquire() { throw new SecurityException("refused"); }
            public void release() { throw new SecurityException("refused"); }
            public boolean held() { return false; }
        };
        FakeLock w2 = new FakeLock("wifi", log2), s2 = new FakeLock("screen", log2);
        Awake aw2 = new Awake(bad, w2, s2);
        boolean threw = false;
        try { aw2.apply(true, true); } catch (Throwable t) { threw = true; }
        ok(!threw && w2.held && s2.held, "a refused lock never crashes the kiosk and never blocks the others");

        System.out.println("On the charger = really charging (review 2026-11-04: a weak charger or PC port is plugged but losing charge)");
        int AC = 1, CHARGING = 2, DISCHARGING = 3, NOT_CHARGING = 4, FULL = 5;
        ok(Awake.onCharger(AC, CHARGING, 80, 35), "plugged and charging: keep awake");
        ok(Awake.onCharger(AC, FULL, 100, 35), "plugged and full: keep awake");
        ok(Awake.onCharger(AC, NOT_CHARGING, 85, 35), "plugged, held at 85% by Samsung battery protection: keep awake");
        ok(!Awake.onCharger(0, DISCHARGING, 90, 35), "not plugged: never");
        ok(!Awake.onCharger(AC, DISCHARGING, 40, 35), "plugged but losing charge below 50% (weak charger): let it sleep");
        ok(Awake.onCharger(AC, DISCHARGING, 70, 35), "plugged, losing a little at 70%: still awake (above 50%)");
        ok(!Awake.onCharger(AC, CHARGING, 25, 35), "below 30%: always let it sleep, even if it says charging");
        ok(!Awake.onCharger(AC, CHARGING, 80, 43), "battery 43 C or hotter: let it cool down");
        ok(Awake.onCharger(AC, CHARGING, 80, 42.9), "42.9 C: still fine (boundary)");
        ok(Awake.onCharger(AC, CHARGING, 30, 35), "exactly 30%: still fine (boundary)");
        ok(!Awake.onCharger(AC, CHARGING, -1, 35), "unknown battery level: let it sleep (safe side)");

        System.out.println("Wiring in Core.java (source check: fails loudly if a method is missing)");
        String core = Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/Core.java"));
        ok(body(core, "private void loop()").contains("applyAwake()"), "loop() re-applies the locks every minute");
        ok(body(core, "void startMaintenance()").contains("applyAwake()"), "startMaintenance() takes the screen lock at once");
        ok(body(core, "void endMaintenance()").contains("applyAwake()"), "endMaintenance() releases the screen lock at once");
        ok(body(core, "void start()").contains("ACTION_POWER_CONNECTED") || body(core, "private void watchPower()").contains("ACTION_POWER_CONNECTED"),
                "plugging / unplugging the charger re-applies at once");
        String sched = body(core, "void checkScheduleTransition()");
        int guard = sched.indexOf("if (prefs.inMaintenance()) return;"), off = sched.indexOf("screenOff(");
        ok(guard >= 0 && off > guard, "the night / evening idle screen-off is skipped during maintenance, and the guard comes BEFORE screenOff");
        ok(body(core, "void endMaintenance()").contains("touched()"),
                "ending maintenance counts as a touch (the screen does not go black a minute later at night)");
        ok(body(core, "private void checkMaintenanceExpiry()").contains("Config.MAINTENANCE_MS"),
                "a clock set backwards cannot stretch maintenance past 10 minutes");
        ok(body(core, "void applyAwake()").contains("synchronized"),
                "applyAwake reads its inputs and applies under one lock (no out-of-order apply between threads)");
        String boot = Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/BootReceiver.java"));
        int clear = boot.indexOf("setMaintenanceUntil(0)"), app = boot.indexOf("applyAwake()", Math.max(clear, 0));
        ok(clear >= 0 && app > clear, "after a reboot during maintenance the screen lock is released at once");

        System.out.println("Remote Screen on really lights the kiosk (2026-11-04 12:28: panel said Screen On, tablet looked off)");
        String cmd = core.substring(core.indexOf("case \"screen_on\":"));
        cmd = cmd.substring(0, cmd.indexOf("break;"));
        ok(cmd.contains("wakeAndBrighten()"), "screen_on command wakes the page, not only the display");
        String act = Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/KioskActivity.java"));
        String wb = body(act, "public void wakeAndBrighten()");
        ok(wb.contains("setBacklightLow(false)"), "it turns the dimmed backlight (1%) back up");
        ok(wb.contains("lastTouchAt"), "it restarts the 6-minute dim timer (otherwise it dims again within 30 s)");
        ok(wb.contains("wakeScreen()") && wb.contains("typeof wakeScreen"), "it lifts the page's own black screen (kiosk/index.html wakeScreen), guarded if missing");
        String js = wb.substring(Math.max(0, wb.indexOf("evaluateJavascript")));   // the script, not the comments
        ok(js.indexOf("screenBlack") >= 0 && js.indexOf("screenBlack") < js.indexOf("wakeScreen()"),
                "the page is woken ONLY when it is black (an awake page may be mid-punch: its camera check must not run)");
        ok(cmd.indexOf("touched()") >= 0 && cmd.indexOf("touched()") < cmd.indexOf("wakeScreen"),
                "the press counts as a touch at once, before anything else (no half-second gap for the night screen-off)");
        ok(cmd.contains("wakeScreenOnly()"), "during maintenance Screen on does not pull the kiosk over Android settings");
        ok(!body(core, "void reportWake()").contains("wakeAndBrighten"), "roll-call report wakes do NOT light the page (only push punches)");

        System.out.println("Kiosk runs as a foreground service (2026-11-04: offline every time the kiosk was not the front app)");
        String man = Files.readString(Path.of("app/src/main/AndroidManifest.xml"));
        ok(man.contains("android.permission.FOREGROUND_SERVICE\"") && man.contains("android.permission.FOREGROUND_SERVICE_SPECIAL_USE"),
                "manifest asks for the foreground-service permissions (Android 14 needs the typed one)");
        ok(man.contains("android:name=\".KeepAlive\"") && man.contains("android:foregroundServiceType=\"specialUse\"")
                && man.contains("PROPERTY_SPECIAL_USE_FGS_SUBTYPE"), "manifest declares KeepAlive as a specialUse foreground service");
        String ka = Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/KeepAlive.java"));
        ok(ka.contains("startForeground(") && ka.contains("FOREGROUND_SERVICE_TYPE_SPECIAL_USE"), "the service goes to the foreground with its type");
        ok(ka.contains("START_STICKY"), "Android restarts it if it is ever killed");
        ok(body(ka, "static void start(").contains("catch"), "a refused start never crashes the kiosk");
        String st = body(ka, "static void start(");
        ok(st.contains("running") && st.indexOf("running") < st.indexOf("startForegroundService"),
                "already running: no new start (each start re-arms Android's 10 s must-go-foreground timer)");
        ok(st.contains("keepAliveFailedAt") && st.indexOf("keepAliveFailedAt") < st.indexOf("startForegroundService"),
                "after a failed go-foreground it is not started again for a day (no crash loop on a live kiosk)");
        String gf = body(ka, "private void goForeground()");
        ok(gf.contains("setKeepAliveFailedAt") && gf.indexOf("setKeepAliveFailedAt") < gf.lastIndexOf("startForeground("),
                "a failure is saved BEFORE the plain fallback notification is tried");
        ok(!ka.contains("getApplicationInfo().icon"), "small icon is a one-colour system icon, not the colour launcher icon");
        ok(body(core, "void start()").contains("KeepAlive.start("), "started with the app (every process start)");
        ok(body(act, "protected void onResume()").contains("KeepAlive.start("), "started again whenever the kiosk is in front (always allowed)");
        ok(Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/BootReceiver.java")).contains("KeepAlive.start("), "started after a restart / app update");

        System.out.println(fails == 0 ? "ALL " + passes + " PASSED" : fails + " FAILED, " + passes + " passed");
        if (fails > 0) System.exit(1);
    }

    /** Text of one method, from its signature to its matching brace. Throws when the method is not there. */
    static String body(String src, String sig) {
        int i = src.indexOf(sig);
        if (i < 0) throw new AssertionError("method not found in Core.java: " + sig);
        int b = src.indexOf('{', i), depth = 0;
        for (int k = b; k < src.length(); k++) {
            char c = src.charAt(k);
            if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return src.substring(b, k + 1);
        }
        throw new AssertionError("unbalanced braces after " + sig);
    }
}

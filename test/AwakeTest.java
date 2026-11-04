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

        System.out.println("Wiring in Core.java (source check: fails loudly if a method is missing)");
        String core = Files.readString(Path.of("app/src/main/java/ph/rsr/kiosk/Core.java"));
        ok(body(core, "private void loop()").contains("applyAwake()"), "loop() re-applies the locks every minute");
        ok(body(core, "void startMaintenance()").contains("applyAwake()"), "startMaintenance() takes the screen lock at once");
        ok(body(core, "void endMaintenance()").contains("applyAwake()"), "endMaintenance() releases the screen lock at once");
        ok(body(core, "void start()").contains("ACTION_POWER_CONNECTED") || body(core, "private void watchPower()").contains("ACTION_POWER_CONNECTED"),
                "plugging / unplugging the charger re-applies at once");
        ok(body(core, "void checkScheduleTransition()").contains("prefs.inMaintenance()"),
                "the night / evening idle screen-off is skipped during maintenance (office is using Android settings)");

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

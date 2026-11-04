package ph.rsr.kiosk;

/**
 * Keeps the tablet reachable when its screen is off (2026-11-04, Mandaue: screen off -> tablet slept,
 * Wi-Fi dropped, panel OFFLINE, the office's "Screen on" never arrived).
 *
 *  - Plugged in: processor + Wi-Fi stay awake, so the heartbeat and remote commands keep working with
 *    the screen off (night schedule, maintenance). The screen itself is NOT forced on.
 *  - On battery (Carmen with the generator off): nothing is held, so the battery is never drained by us.
 *  - Maintenance (10 min, office in Android settings): screen, processor and Wi-Fi stay on even on battery,
 *    so Android's own screen timeout cannot cut the tablet off mid-fix.
 *
 * Pure Java (no Android imports) so test/AwakeTest.java runs without a phone. Core wires real locks in.
 * apply() is safe to call every minute: a lock is taken once and released once.
 */
final class Awake {
    interface Lock { void acquire(); void release(); boolean held(); }

    private final Lock cpu, wifi, screen;

    Awake(Lock cpu, Lock wifi, Lock screen) {
        this.cpu = cpu;
        this.wifi = wifi;
        this.screen = screen;
    }

    synchronized void apply(boolean plugged, boolean maintenance) {
        boolean net = plugged || maintenance;
        set(cpu, net);
        set(wifi, net);
        set(screen, maintenance);
    }

    /** A lock Android refuses must never crash the kiosk or stop the other locks. */
    private static void set(Lock l, boolean on) {
        try {
            if (on && !l.held()) l.acquire();
            else if (!on && l.held()) l.release();
        } catch (Throwable ignored) { }
    }
}

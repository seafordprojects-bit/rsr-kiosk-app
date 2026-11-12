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

    /**
     * Counts as "on the charger" only when the charger really keeps up (review 2026-11-04): a weak charger,
     * bad cable or PC port can be plugged in and still lose charge, and then the locks would drain it.
     * plugged / status are BatteryManager values (status 2 = charging, 4 = not charging, 5 = full).
     */
    static boolean onCharger(int plugged, int status, int levelPct, double tempC) {
        if (plugged == 0 || levelPct < 30 || tempC >= 43) return false;
        boolean keepingUp = status == 2 || status == 5 || status == 4;   // 4: held at 85% by battery protection
        return keepingUp || levelPct >= 50;
    }

    /** The kiosk page (kiosk/index.html v2026-11-12b) dims after 2 min without a touch and goes black at 5 min
     *  (owner 2026-11-12). Keep in step with DIM_AFTER_MS + BLACK_AFTER_MS there. */
    static final long PAGE_BLACK_AFTER_MS = 5 * 60_000L;
    /** The app turns the real backlight down 15 s after the page is black: nobody sees a difference, and the
     *  screen light is the biggest battery user. The next touch brings it back. */
    static final long BACKLIGHT_LOW_AFTER_MS = PAGE_BLACK_AFTER_MS + 15_000L;

    /**
     * A report wake (8 and 2 min before the 10:01, 3:00 and 7:10 roll-call reports) must push the waiting punches.
     * It lights the screen ONLY when that is the one way to get Wi-Fi back: screen off AND on battery (deep sleep).
     * On the charger the CPU + Wi-Fi locks keep the page running, and a screen that is on (dimmed in the day) already
     * has Wi-Fi - so the screen stays dark (owner 2026-11-12: "the kiosk keeps on waking").
     */
    static boolean reportNeedsScreen(boolean screenOn, boolean onCharger) {
        return !screenOn && !onCharger;
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
        } catch (RuntimeException e) {
            System.err.println("RSRAwake lock refused: " + e);
        }
    }
}

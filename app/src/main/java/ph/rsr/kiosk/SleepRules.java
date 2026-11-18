package ph.rsr.kiosk;

/**
 * Holiday sleep (owner 2026-11-18/19): when the yard has no power for days, the kiosk tablet must still be alive when
 * the workers come back. A powered-off tablet cannot be turned on remotely, so instead it goes into DEEP SLEEP
 * (screen off, Wi-Fi off, page paused, no check-ins; a short report every 12 hours) and wakes by itself at 7:00.
 *
 * Plain Java (tested by test/SleepRulesTest.java). Minutes are minutes of the day, 0..1439, Manila time.
 *
 * Power-cut saver (no one has to plan it):
 *  - GRID tablet (no generator hours, e.g. Mandaue): off the charger for 2 hours, outside the screen schedule, and
 *    nobody touched the screen for 2 hours.
 *    Example: brownout 22:00 -> 00:00 deep sleep; power back 03:00 -> awake at once; still out -> awake at 7:00.
 *  - GENERATOR tablet (Carmen): being on battery at night is NORMAL (generator off after 9 PM), so it never sleeps
 *    for that. It sleeps only when the generator should have been running for 2 hours and the tablet got no power,
 *    and nobody used the kiosk today. Example: Dec 25, generator never starts at 8:00 -> 10:00 deep sleep.
 *    Generator breaks on a workday with workers there: they punched in -> it never sleeps that day.
 *  - After the 7:00 wake from a power-cut sleep: still no power and nobody touched it by 10:00 -> sleep again until
 *    the next 7:00 (a no-work day). Anyone punching keeps it awake.
 * Never while a worker is using it; any touch, the power button or the charger wakes it at once (Core).
 */
final class SleepRules {
    private SleepRules() { }

    static final int SAVER_AFTER_MIN = 120;     // 2 hours (owner 2026-11-18)
    static final String WAKE_AT = "07:00";      // owner 2026-11-18
    static final String RECHECK_AT = "10:00";   // still no power + untouched since 7:00 -> sleep again
    static final long REPORT_EVERY_MS = 12 * 3600_000L;   // owner 2026-11-18: a "still alive" report every 12 h

    /** "HH:MM" -> minutes of the day, -1 if not a time (same as Core.minutes; here so the tests need no Android). */
    static int hm(String hhmm) {
        try {
            String[] p = hhmm.trim().split(":");
            int h = Integer.parseInt(p[0]), m = Integer.parseInt(p[1]);
            if (h < 0 || h > 23 || m < 0 || m > 59) return -1;
            return h * 60 + m;
        } catch (Exception e) {
            return -1;
        }
    }

    /** "08:00-11:30,13:00-16:30,18:00-21:00+24:00" -> is minute m inside a generator window? (+24:00 = overtime
     *  may run until midnight: not counted as a window the generator MUST run.) */
    static boolean inWindows(String windows, int m) {
        if (windows == null || windows.trim().isEmpty()) return false;
        for (String w : windows.split(",")) {
            String x = w.trim();
            int plus = x.indexOf('+');
            if (plus >= 0) x = x.substring(0, plus);
            String[] ab = x.split("-");
            if (ab.length != 2) continue;
            int a = hm(ab[0]), b = hm(ab[1]);
            if (a < 0 || b < 0) continue;
            if (a < b ? (m >= a && m < b) : (m >= a || m < b)) return true;
        }
        return false;
    }

    /** Minutes of generator time between fromMin and nowMin over the last `spanMin` minutes (walks minute by minute
     *  back from now; span capped at 2 days). dayStart = minute-of-day of `now`. */
    static int windowMinutes(String windows, int nowMin, int spanMin) {
        int n = 0, span = Math.min(Math.max(spanMin, 0), 2880);
        for (int k = 1; k <= span; k++) {
            int m = ((nowMin - k) % 1440 + 1440) % 1440;
            if (inWindows(windows, m)) n++;
        }
        return n;
    }

    /** Is m inside the screen schedule (on..off, off may be after midnight)? No schedule = always inside. */
    static boolean inSchedule(boolean enabled, String on, String off, int m) {
        if (!enabled) return true;
        int a = hm(on), b = hm(off);
        if (a < 0 || b < 0 || a == b) return true;
        return a < b ? (m >= a && m < b) : (m >= a || m < b);
    }

    /**
     * Power-cut saver: should the tablet go into deep sleep now?
     * @param nowMin        minute of the day now
     * @param unpluggedMin  minutes since the charger was lost (-1 = on the charger)
     * @param idleMin       minutes since the last touch on the screen
     * @param touchedToday  someone used the kiosk since 00:00 today
     */
    static boolean saverNow(String windows, boolean schedOn, String on, String off, int nowMin,
                            int unpluggedMin, int idleMin, boolean touchedToday) {
        if (unpluggedMin < SAVER_AFTER_MIN) return false;
        boolean generator = windows != null && !windows.trim().isEmpty();
        if (generator) {
            if (touchedToday) return false;
            return windowMinutes(windows, nowMin, unpluggedMin) >= SAVER_AFTER_MIN;
        }
        if (idleMin < SAVER_AFTER_MIN) return false;
        // grid: only outside the screen schedule (a daytime brownout with workers is handled by the alerts)
        return !inSchedule(schedOn, on, off, nowMin);
    }

    /** After the 7:00 wake from a power-cut sleep: at 10:00, still no power and untouched since the wake -> sleep. */
    static boolean sleepAgainAt10(boolean onCharger, boolean touchedSinceWake) {
        return !onCharger && !touchedSinceWake;
    }

    /** Next 7:00 strictly after now (ms), on the device clock (Manila). */
    static long nextWake(long nowMs) {
        return nextAt(nowMs, WAKE_AT);
    }

    static long nextAt(long nowMs, String hhmm) {
        int m = hm(hhmm);
        java.util.Calendar c = java.util.Calendar.getInstance();
        c.setTimeInMillis(nowMs);
        c.set(java.util.Calendar.HOUR_OF_DAY, m / 60);
        c.set(java.util.Calendar.MINUTE, m % 60);
        c.set(java.util.Calendar.SECOND, 0);
        c.set(java.util.Calendar.MILLISECOND, 0);
        if (c.getTimeInMillis() <= nowMs) c.add(java.util.Calendar.DAY_OF_MONTH, 1);
        return c.getTimeInMillis();
    }

    /** Owner's planned holiday sleep [from, until): sleep now? (until must be after from, at most 31 days) */
    static boolean inPlan(long nowMs, long fromMs, long untilMs) {
        if (fromMs <= 0 || untilMs <= fromMs || untilMs - fromMs > 31L * 86400_000L) return false;
        return nowMs >= fromMs && nowMs < untilMs;
    }
}

package ph.rsr.kiosk;

/** Plain-Java test of the holiday-sleep / power-cut saver rules with the owner's situations (2026-11-19). */
public class SleepRulesTest {
    static int pass, fail;
    static void ok(boolean c, String m) { if (c) pass++; else { fail++; System.out.println("FAIL " + m); } }
    static int t(String hhmm) { return SleepRules.hm(hhmm); }

    public static void main(String[] a) {
        String GEN = "08:00-11:30,13:00-16:30,18:00-21:00+24:00";   // Carmen
        ok(SleepRules.inWindows(GEN, t("08:00")) && SleepRules.inWindows(GEN, t("20:59")) && !SleepRules.inWindows(GEN, t("12:00")), "generator windows");
        ok(!SleepRules.inWindows(GEN, t("22:00")), "+24:00 overtime is not a must-run window");
        ok(!SleepRules.inWindows("", t("09:00")) && !SleepRules.inWindows(null, t("09:00")), "no generator hours");
        // Situation A (Carmen, normal workday): generator off 21:00, on battery all night -> never sleeps
        ok(!SleepRules.saverNow(GEN, true, "06:45", "00:15", t("23:00"), 120, 120, true), "A: 23:00 after a workday: no sleep");
        ok(!SleepRules.saverNow(GEN, true, "06:45", "00:15", t("06:00"), 540, 540, false), "A: 06:00 next morning (9 h on battery, generator not due yet): no sleep");
        // Situation B (no-work day): unplugged since 21:00, generator due 08:00, nobody touches -> 10:00 sleep
        ok(!SleepRules.saverNow(GEN, true, "06:45", "00:15", t("09:59"), 779, 779, false), "B: 09:59 = 119 generator minutes: not yet");
        ok(SleepRules.saverNow(GEN, true, "06:45", "00:15", t("10:00"), 780, 780, false), "B: 10:00 = 2 generator hours with no power: deep sleep");
        // Situation C (generator broken, workers punched this morning): never sleeps that day
        ok(!SleepRules.saverNow(GEN, true, "06:45", "00:15", t("11:00"), 840, 150, true), "C: workers used it today: no sleep");
        // Situation D (overtime until midnight): charger on -> unplugged -1
        ok(!SleepRules.saverNow(GEN, true, "06:45", "00:15", t("23:30"), -1, 300, true), "D: on the generator: no sleep");
        // Mandaue (grid), schedule 06:45-00:15
        ok(!SleepRules.saverNow("", true, "06:45", "00:15", t("23:00"), 120, 120, true), "grid: 23:00 is still inside the schedule: no sleep");
        ok(SleepRules.saverNow("", true, "06:45", "00:15", t("02:00"), 120, 120, true), "grid: brownout 00:00 -> 02:00 outside the schedule, untouched: deep sleep");
        ok(!SleepRules.saverNow("", true, "06:45", "00:15", t("02:00"), 119, 300, false), "grid: 1 h 59 min unplugged: not yet");
        ok(!SleepRules.saverNow("", true, "06:45", "00:15", t("02:00"), 200, 30, false), "grid: someone touched it 30 min ago: no sleep");
        ok(!SleepRules.saverNow("", true, "06:45", "00:15", t("10:00"), 300, 300, false), "grid: daytime brownout (inside the schedule): no sleep");
        ok(SleepRules.saverNow("", true, "05:30", "22:30", t("23:00"), 150, 150, true), "grid: schedule 05:30-22:30, 23:00 brownout 2.5 h: deep sleep");
        // after the 7:00 wake
        ok(SleepRules.sleepAgainAt10(false, false), "10:00, no power, untouched since 7:00: sleep again");
        ok(!SleepRules.sleepAgainAt10(false, true), "10:00, someone punched: stay awake");
        ok(!SleepRules.sleepAgainAt10(true, false), "10:00, power back: stay awake");
        // next 7:00
        java.util.Calendar c = java.util.Calendar.getInstance();
        c.set(2026, 11, 25, 10, 0, 0); c.set(java.util.Calendar.MILLISECOND, 0);
        java.util.Calendar w = java.util.Calendar.getInstance(); w.setTimeInMillis(SleepRules.nextWake(c.getTimeInMillis()));
        ok(w.get(java.util.Calendar.DAY_OF_MONTH) == 26 && w.get(java.util.Calendar.HOUR_OF_DAY) == 7 && w.get(java.util.Calendar.MINUTE) == 0, "10:00 Dec 25 -> wake 7:00 Dec 26");
        c.set(2026, 11, 26, 2, 0, 0);
        w.setTimeInMillis(SleepRules.nextWake(c.getTimeInMillis()));
        ok(w.get(java.util.Calendar.DAY_OF_MONTH) == 26 && w.get(java.util.Calendar.HOUR_OF_DAY) == 7, "02:00 -> wake 7:00 the same morning");
        // planned holiday
        long now = 1_000_000_000_000L, h = 3600_000L;
        ok(SleepRules.inPlan(now, now - h, now + 80 * h), "inside the planned holiday: sleep");
        ok(!SleepRules.inPlan(now, now + h, now + 80 * h), "before the plan starts: awake");
        ok(!SleepRules.inPlan(now, now - 80 * h, now - h), "after the plan: awake");
        ok(!SleepRules.inPlan(now, now - h, now - 2 * h) && !SleepRules.inPlan(now, 0, now + h), "bad plan (end before start / none): awake");
        ok(!SleepRules.inPlan(now, now - h, now + 40L * 24 * h), "plan over 31 days refused");
        ok(SleepRules.windowMinutes(GEN, t("10:00"), 13 * 60) == 120, "13 h back from 10:00 = 2 h of generator time (08-10)");
        System.out.println(pass + " passed, " + fail + " failed");
        if (fail > 0) System.exit(1);
    }
}

package ph.rsr.kiosk;

/**
 * Plain-Java test (no Android needed). Run from the repo root:
 *   javac -d .scratch/t app/src/main/java/ph/rsr/kiosk/Mode.java test/ModeTest.java && java -cp .scratch/t ph.rsr.kiosk.ModeTest
 *
 * Roll-call phone (owner 2026-11-08/11-12): the Wi-Fi-only Motorola runs the same RSR app, locked to the
 * Job Monitoring roll-call page. It is carried around on battery, so it must NOT behave like a kiosk
 * tablet (screen kept on all day, report wake-ups, screen schedule). The mode comes from the page address
 * the office already sets, so the kiosk tablets can never switch into it by accident.
 */
public class ModeTest {
    static int fails = 0, passes = 0;
    static void ok(boolean c, String what) {
        if (c) { passes++; System.out.println("  ok   " + what); }
        else { fails++; System.out.println("  FAIL " + what); }
    }

    public static void main(String[] a) {
        String base = "https://seafordprojects-bit.github.io/rsr-engineering";
        ok(Mode.isPhoneUrl(base + "/monitoring/roll-call.html?site=Carmen"), "roll-call page = phone");
        ok(Mode.isPhoneUrl(base + "/monitoring/index.html"), "Job Monitoring menu (locked phone menu) = phone");
        ok(Mode.isPhoneUrl(base + "/monitoring/borrow.html?site=Carmen"), "tool borrow on the yard phone = phone");
        ok(!Mode.isPhoneUrl(base + "/kiosk/"), "kiosk page = tablet");
        ok(!Mode.isPhoneUrl(base + "/kiosk/?site=Mandaue"), "Mandaue kiosk = tablet");
        ok(!Mode.isPhoneUrl(base + "/kiosk/?x=/monitoring/"), "'/monitoring/' only in the query does not count");
        ok(!Mode.isPhoneUrl(null), "no address = tablet (safe default)");
        ok(!Mode.isPhoneUrl(""), "empty address = tablet");
        ok(!Mode.isPhoneUrl("https://evil.example/monitoring/roll-call.html"), "other site never = phone");
        ok(!Mode.isPhoneUrl("https://seafordprojects-bit.github.io/monitoring/x.html"), "no repo folder = tablet (same as the server rule)");
        String rc = base + "/monitoring/roll-call.html?site=Carmen";
        ok(Mode.phoneBlocks(rc, base + "/index.html"), "phone: main RSR menu is blocked (back to roll-call)");
        ok(Mode.phoneBlocks(rc, base + "/coordinator/index.html"), "phone: coordinator page is blocked");
        ok(!Mode.phoneBlocks(rc, base + "/monitoring/index.html"), "phone: Job Monitoring menu allowed");
        ok(!Mode.phoneBlocks(rc, base + "/monitoring/borrow.html?site=Carmen"), "phone: tool borrow allowed");
        ok(!Mode.phoneBlocks(base + "/kiosk/", base + "/index.html"), "tablet: nothing extra is blocked");
        ok(!Mode.phoneBlocks(rc, null), "no target = not blocked here (host check handles it)");
        ok(Mode.PHONE_SCREEN_TIMEOUT_MS == 60_000, "phone screen turns off after 1 min without a touch");
        System.out.println(passes + " passed, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}

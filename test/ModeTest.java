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
        // Job photos (owner 2026-11-14): the roll-call phone may also open the phone's own Camera and Gallery
        // (and the photo picker) so the in-charge takes and checks photos, then uploads them in roll-call.
        java.util.List<String> media = java.util.Arrays.asList("com.motorola.camera5", "com.google.android.apps.photos");
        String[] ph = Mode.lockPackages("ph.rsr.kiosk", true, media);
        ok(java.util.Arrays.asList(ph).equals(java.util.Arrays.asList("ph.rsr.kiosk", "com.motorola.camera5")),
                "phone: RSR app + its camera app only (review: no Google Photos - Share/Lens/sign-in escape the lock)");
        for (String bad : new String[]{"com.google.android.apps.photos", "com.google.android.apps.nbu.files", "com.google.android.apps.docs",
                "com.google.android.documentsui", "com.android.settings", "com.android.vending", "com.android.chrome", "android", "", null}) {
            ok(Mode.lockPackages("ph.rsr.kiosk", true, java.util.Collections.singletonList(bad)).length == 1, "phone never lets in: " + bad);
        }
        ok(Mode.lockPackages("ph.rsr.kiosk", true, java.util.Arrays.asList("a.cam", "b.other", "c.more")).length == 2,
                "phone: never more than RSR + one camera app");
        String[] tab = Mode.lockPackages("ph.rsr.kiosk", false, media);
        ok(tab.length == 1 && tab[0].equals("ph.rsr.kiosk"), "tablet: still only the RSR app");
        ok(Mode.lockPackages("ph.rsr.kiosk", true, null).length == 1, "phone with no camera/gallery found: only the RSR app");
        ok(Mode.phoneHomeButton(true) && !Mode.phoneHomeButton(false), "Home button only on the phone (it brings back RSR)");
        ok(Mode.PHONE_SCREEN_TIMEOUT_MS == 60_000, "phone screen turns off after 1 min without a touch");

        // build-14: punch-rush protection is for kiosk tablets only; the roll-call phone has no punches.
        ok(Mode.rushBlocks(true,  false), "TABLET during rush: office command refused (protected)");
        ok(!Mode.rushBlocks(false, false), "TABLET outside rush: command allowed");
        ok(!Mode.rushBlocks(true,  true),  "PHONE during rush: command NOT refused (no punches)");
        ok(!Mode.rushBlocks(false, true),  "PHONE outside rush: command allowed");

        System.out.println(passes + " passed, " + fails + " failed");
        if (fails > 0) System.exit(1);
    }
}

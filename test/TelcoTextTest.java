package ph.rsr.kiosk;

/** Plain-Java test: which texts on the tablet's SIM may leave the tablet (telco only, never a person). */
public class TelcoTextTest {
    static int pass, fail;
    static void ok(boolean c, String m) { if (c) pass++; else { fail++; System.out.println("FAIL " + m); } }

    public static void main(String[] a) {
        ok(TelcoText.isTelcoSender("DITO"), "DITO name");
        ok(TelcoText.isTelcoSender("GOMO"), "GOMO name");
        ok(TelcoText.isTelcoSender("Globe"), "Globe name");
        ok(TelcoText.isTelcoSender("GOMOph"), "GOMO with suffix");
        ok(TelcoText.isTelcoSender("8080"), "short code 4 digits");
        ok(TelcoText.isTelcoSender("2600"), "short code");
        ok(TelcoText.isTelcoSender("211"), "3-digit short code");
        ok(!TelcoText.isTelcoSender("225666"), "6-digit code: not a telco short code");
        ok(!TelcoText.isTelcoSender("GCash"), "GCash: never");
        ok(!TelcoText.isTelcoSender("BDO"), "bank: never");
        ok(!TelcoText.isTelcoSender("SHOPEE"), "shop: never");
        ok(TelcoText.isTelcoSender("DITO Telecom"), "DITO with more words");
        ok(TelcoText.isTelcoSender("TM"), "TM");
        ok(!TelcoText.isTelcoSender("ATMOS"), "TM inside a word: no");
        ok("Missed call from 09********* at 3PM".equals(TelcoText.maskNumbers("Missed call from 09171234567 at 3PM")), "number masked");
        ok("P50 from 09*********".equals(TelcoText.maskNumbers("P50 from +639171234567")), "+63 number masked");
        ok("25GB valid 30 days".equals(TelcoText.maskNumbers("25GB valid 30 days")), "normal text unchanged");
        ok(!TelcoText.isTelcoSender("09171234567"), "PH mobile 09.. = person");
        ok(!TelcoText.isTelcoSender("+639171234567"), "PH mobile +639.. = person");
        ok(!TelcoText.isTelcoSender("+63 917 123 4567"), "spaced mobile = person");
        ok(!TelcoText.isTelcoSender("0917-123-4567"), "dashed mobile = person");
        ok(!TelcoText.isTelcoSender("3456789"), "7-digit landline = person");
        ok(!TelcoText.isTelcoSender("(032) 345-6789"), "landline with brackets = person");
        ok(!TelcoText.isTelcoSender(""), "empty");
        ok(!TelcoText.isTelcoSender(null), "null");
        ok(!TelcoText.isTelcoSender("   "), "blank");
        ok("x".repeat(1000).equals(TelcoText.clip("x".repeat(5000))), "text clipped to 1000");
        ok("".equals(TelcoText.clip(null)), "null text = empty");
        System.out.println(pass + " passed, " + fail + " failed");
        if (fail > 0) System.exit(1);
    }
}

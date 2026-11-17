package ph.rsr.kiosk;

/** Plain-Java test: reading the yard modem's numbers (real answers from the owner's H153-381, 2026-11-17). */
public class ModemXmlTest {
    static int pass, fail;
    static void ok(boolean c, String m) { if (c) pass++; else { fail++; System.out.println("FAIL " + m); } }

    static final String TRAFFIC = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<response>\n<CurrentConnectTime>3560</CurrentConnectTime>\n"
            + "<CurrentUpload>28300178</CurrentUpload>\n<CurrentDownload>18993985</CurrentDownload>\n<CurrentDownloadRate>7781</CurrentDownloadRate>\n"
            + "<CurrentUploadRate>2543</CurrentUploadRate>\n<TotalUpload>28305285</TotalUpload>\n<TotalDownload>19013986</TotalDownload>\n"
            + "<TotalConnectTime>21580</TotalConnectTime>\n<showtraffic>1</showtraffic>\n</response>\n";
    static final String MONTH = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<response>\n<CurrentMonthDownload>20203196</CurrentMonthDownload>\n"
            + "<CurrentMonthUpload>29078827</CurrentMonthUpload>\n<MonthDuration>21982</MonthDuration>\n<MonthLastClearTime>2026-11-17</MonthLastClearTime>\n"
            + "<CurrentDayUsed>49282023</CurrentDayUsed>\n<CurrentDayDuration>21982</CurrentDayDuration>\n</response>\n";
    static final String SMS = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<response>\n\t<LocalUnread>12</LocalUnread>\n\t<LocalInbox>12</LocalInbox>\n"
            + "\t<LocalOutbox>0</LocalOutbox>\n\t<LocalMax>500</LocalMax>\n</response>";
    static final String ERR = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><error><code>100003</code><message></message></error>";

    public static void main(String[] a) {
        ModemXml.Reading r = ModemXml.parse(TRAFFIC, MONTH, SMS);
        ok(r != null, "real answer read");
        ok(r.totalBytes == 28305285L + 19013986L, "total = upload + download (47,319,271 bytes)");
        ok(r.totalSecs == 21580, "total connect time");
        ok(r.dayBytes == 49282023L, "used today");
        ok(r.monthBytes == 20203196L + 29078827L, "month = down + up");
        ok("2026-11-17".equals(r.monthClear), "month cleared date");
        ok(r.inbox == 12, "texts in the modem inbox");
        ok(ModemXml.parse(ERR, MONTH, SMS) == null, "login-needed error = no reading");
        ok(ModemXml.parse("<html>router</html>", null, null) == null, "another router's page = no reading");
        ok(ModemXml.parse(null, null, null) == null, "no answer = no reading");
        r = ModemXml.parse(TRAFFIC, ERR, ERR);
        ok(r != null && r.dayBytes == -1 && r.monthBytes == -1 && r.inbox == -1, "month / texts locked: total still read");
        r = ModemXml.parse(TRAFFIC, null, null);
        ok(r != null && r.inbox == -1 && "".equals(r.monthClear), "only traffic answered");
        ok(ModemXml.num("<TotalUpload>-5</TotalUpload>", "TotalUpload") == -1, "negative number refused");
        ok(ModemXml.num("<TotalUpload>12a</TotalUpload>", "TotalUpload") == -1, "not a number refused");
        ok(ModemXml.num("<TotalUpload>1234567890123456</TotalUpload>", "TotalUpload") == -1, "16 digits refused");
        ok(ModemXml.parse("<response><TotalUpload>5</TotalUpload></response>", null, null) == null, "download missing = no reading");
        ok(ModemXml.parse(TRAFFIC, "<MonthLastClearTime>2026-11-17<script></MonthLastClearTime>", null).monthClear.isEmpty(), "odd date refused");
        ok(ModemXml.allowedHost("192.168.1.1") && !ModemXml.allowedHost("example.com") && !ModemXml.allowedHost("192.168.1.10"), "only modem addresses");
        long t = 1_000_000_000L;
        ok(ModemXml.due(t, 0, false), "first read: due");
        ok(!ModemXml.due(t + 29 * 60_000L, t, false), "29 min later: not due");
        ok(ModemXml.due(t + 30 * 60_000L, t, false), "30 min later: due");
        ok(ModemXml.due(t + 60_000L, t, true), "forced (report time / office): due");
        ok(ModemXml.due(t - 60_000L, t, false), "clock moved back: due");
        System.out.println(pass + " passed, " + fail + " failed");
        if (fail > 0) System.exit(1);
    }
}

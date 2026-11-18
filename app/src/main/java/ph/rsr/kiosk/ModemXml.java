package ph.rsr.kiosk;

/**
 * Build-7 (owner 2026-11-17): the yard WiFi modem (PLDT Home WiFi prepaid, Huawei H153-381 "HiLink") shows its own
 * data counter. These pages answer WITHOUT a login (owner's test 2026-11-17):
 *   /api/monitoring/traffic-statistics  TotalUpload + TotalDownload (bytes), TotalConnectTime (s) - "Total Volume"
 *   /api/monitoring/month_statistics    CurrentDayUsed, CurrentMonthDownload + Upload, MonthLastClearTime
 *   /api/sms/sms-count                  LocalInbox (number of texts in the modem; only a count, never the text)
 * Plain Java (tested by test/ModemXmlTest.java): picks the numbers out of those small XML answers.
 * An error answer (&lt;error&gt;&lt;code&gt;100003&lt;/code&gt; = login needed) or anything else gives null.
 */
final class ModemXml {
    private ModemXml() { }

    static final class Reading {
        long totalBytes, totalSecs = -1, dayBytes = -1, monthBytes = -1;
        int inbox = -1;
        String monthClear = "";
        /** owner 2026-11-19: modem SIM - "ok" / "missing" (SimStatus 1 = good SIM), "" = the modem did not say. */
        String sim = "";
        /** modem's mobile connection: "connected" (901) / "disconnected" / "" = unknown. */
        String conn = "";
    }

    /** Whole number inside &lt;name&gt;...&lt;/name&gt; (digits only, at most 15), else -1. */
    static long num(String xml, String name) {
        String v = text(xml, name);
        if (v == null || !v.matches("[0-9]{1,15}")) return -1;
        return Long.parseLong(v);
    }

    static String text(String xml, String name) {
        if (xml == null) return null;
        int a = xml.indexOf("<" + name + ">");
        if (a < 0) return null;
        a += name.length() + 2;
        int b = xml.indexOf("</" + name + ">", a);
        if (b < 0 || b - a > 64) return null;
        return xml.substring(a, b).trim();
    }

    /** As parse(traffic, month, sms), plus /api/monitoring/status (may be null or a login error: then unknown). */
    static Reading parse(String traffic, String month, String sms, String status) {
        Reading r = parse(traffic, month, sms);
        if (r == null || status == null || status.contains("<error>")) return r;
        long sim = num(status, "SimStatus");
        if (sim >= 0) r.sim = sim == 1 ? "ok" : "missing";
        long cs = num(status, "ConnectionStatus");
        if (cs >= 0) r.conn = cs == 901 ? "connected" : "disconnected";
        return r;
    }

    /** traffic is required; month and sms may be null (not answered). Null when traffic is not a modem answer. */
    static Reading parse(String traffic, String month, String sms) {
        if (traffic == null || traffic.contains("<error>")) return null;
        long up = num(traffic, "TotalUpload"), down = num(traffic, "TotalDownload");
        if (up < 0 || down < 0) return null;
        Reading r = new Reading();
        r.totalBytes = up + down;
        r.totalSecs = num(traffic, "TotalConnectTime");
        if (month != null && !month.contains("<error>")) {
            r.dayBytes = num(month, "CurrentDayUsed");
            long mu = num(month, "CurrentMonthUpload"), md = num(month, "CurrentMonthDownload");
            if (mu >= 0 && md >= 0) r.monthBytes = mu + md;
            String c = text(month, "MonthLastClearTime");
            if (c != null && c.matches("20[0-9]{2}-[0-9]{2}-[0-9]{2}")) r.monthClear = c;
        }
        if (sms != null && !sms.contains("<error>")) {
            long n = num(sms, "LocalInbox");
            if (n >= 0 && n <= 100000) r.inbox = (int) n;
        }
        return r;
    }

    /** Only the modem's own addresses may be read in plain http (res/xml/network_security_config.xml). */
    static final String[] HOSTS = { "192.168.1.1", "192.168.8.1", "192.168.0.1", "192.168.254.254" };

    static boolean allowedHost(String h) {
        for (String x : HOSTS) if (x.equals(h)) return true;
        return false;
    }

    /** Throttle: a normal read at most every READ_EVERY_MS; a forced read (report time, office button) any time. */
    static final long READ_EVERY_MS = 30 * 60_000L;

    static boolean due(long now, long lastAt, boolean force) {
        return force || lastAt <= 0 || now - lastAt >= READ_EVERY_MS || now < lastAt;
    }
}

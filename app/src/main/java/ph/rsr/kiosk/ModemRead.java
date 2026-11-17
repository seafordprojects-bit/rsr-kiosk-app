package ph.rsr.kiosk;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.RouteInfo;
import android.util.Log;

import org.json.JSONObject;

import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.URL;
import java.util.function.BooleanSupplier;

/**
 * Build-7 (owner 2026-11-17): reads the yard WiFi modem's data counter so the office knows how much prepaid load is
 * left (the modem SIM cannot be linked to the Smart app). No password: the counter pages answer without a login.
 *
 * Kiosk rules unchanged: NO new wake-up and no screen-on. A read only happens while the app is already awake
 *  - normally at most every 30 min (from the 1-minute loop),
 *  - forced at the roll-call report wake-ups (before 10:01, 3:00, 7:10) and when the office presses "Read modem",
 * and never in a punch rush, never within 60 s of a touch on the screen, never on battery at 20% or less.
 * It runs on its own thread with 3-second timeouts, so it can never hold up a punch, a sync or a report; a slow or
 * failed read is simply dropped. The request goes over the Wi-Fi network itself (also when the Wi-Fi has no internet
 * and the tablet is on its SIM), only to the modem's own address. The result rides on the next heartbeat.
 */
final class ModemRead {
    private ModemRead() { }

    private static final String TAG = "RSRModem";
    private static final Object LOCK = new Object();
    private static long lastAt = 0;
    private static boolean running = false;
    private static JSONObject pending = null;   // waiting for the next heartbeat
    private static String lastError = null;     // short reason, shown on the Tablets page
    private static Thread worker;

    /** quiet: no rush, nobody at the screen, battery OK. Forced reads wait for quiet up to 3 min. */
    static void request(Context ctx, boolean force, BooleanSupplier quiet) {
        synchronized (LOCK) {
            if (running || !ModemXml.due(System.currentTimeMillis(), lastAt, force)) return;
            if (!force && !quiet.getAsBoolean()) return;   // not now: the 1-minute loop asks again (no thread started)
            running = true;
        }
        final Context app = ctx.getApplicationContext();
        worker = new Thread(() -> {
            try {
                long end = System.currentTimeMillis() + (force ? 180_000L : 0);
                while (!quiet.getAsBoolean()) {
                    if (System.currentTimeMillis() >= end) {   // not now; the next chance comes by itself
                        if (force) setError("skipped: kiosk busy or punch rush - try again later");
                        return;
                    }
                    Thread.sleep(10_000);
                }
                readNow(app);
            } catch (Throwable t) {
                Log.w(TAG, "read", t);
            } finally {
                synchronized (LOCK) { running = false; }
            }
        }, "rsr-modem");
        worker.setDaemon(true);
        worker.start();
    }

    private static void readNow(Context ctx) {
        long now = System.currentTimeMillis();
        synchronized (LOCK) { lastAt = now; }
        Network wifi = wifiNetwork(ctx);
        if (wifi == null) { setError("not on Wi-Fi"); return; }
        String gw = gateway(ctx, wifi);
        String[] hosts = gw != null && ModemXml.allowedHost(gw) && !"192.168.1.1".equals(gw)
                ? new String[]{ gw, "192.168.1.1" } : new String[]{ "192.168.1.1" };
        for (String h : hosts) {
            String traffic = get(wifi, h, "/api/monitoring/traffic-statistics");
            ModemXml.Reading r = ModemXml.parse(traffic, null, null);
            if (r == null) continue;
            r = ModemXml.parse(traffic, get(wifi, h, "/api/monitoring/month_statistics"), get(wifi, h, "/api/sms/sms-count"));
            if (r == null) continue;
            try {
                JSONObject m = new JSONObject();
                m.put("at", iso(now));
                m.put("host", h);
                m.put("total_bytes", r.totalBytes);
                if (r.totalSecs >= 0) m.put("total_secs", r.totalSecs);
                if (r.dayBytes >= 0) m.put("day_bytes", r.dayBytes);
                if (r.monthBytes >= 0) m.put("month_bytes", r.monthBytes);
                if (!r.monthClear.isEmpty()) m.put("month_clear", r.monthClear);
                if (r.inbox >= 0) m.put("inbox", r.inbox);
                synchronized (LOCK) { pending = m; lastError = null; }
            } catch (Exception e) {
                setError("read failed");
            }
            return;
        }
        setError(gw == null ? "no modem found" : "Wi-Fi router is not the PLDT modem");
    }

    private static void setError(String e) { synchronized (LOCK) { lastError = e; } }

    /** The reading to send with this heartbeat (null = nothing new). */
    static JSONObject pending() { synchronized (LOCK) { return pending; } }

    /** The heartbeat carrying m reached the server. */
    static void sent(JSONObject m) { synchronized (LOCK) { if (pending == m) pending = null; } }

    static String lastError() { synchronized (LOCK) { return lastError; } }

    private static Network wifiNetwork(Context ctx) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return null;
            for (Network n : cm.getAllNetworks()) {
                NetworkCapabilities c = cm.getNetworkCapabilities(n);
                if (c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) return n;
            }
        } catch (Throwable ignored) { }
        return null;
    }

    private static String gateway(Context ctx, Network n) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            LinkProperties lp = cm == null ? null : cm.getLinkProperties(n);
            if (lp == null) return null;
            for (RouteInfo r : lp.getRoutes()) {
                InetAddress g = r.getGateway();
                if (r.isDefaultRoute() && g instanceof Inet4Address && !g.isAnyLocalAddress()) return g.getHostAddress();
            }
        } catch (Throwable ignored) { }
        return null;
    }

    /** Small GET over the Wi-Fi network; null on any problem. Answers above 16 KB are cut (they are ~1 KB). */
    private static String get(Network wifi, String host, String path) {
        HttpURLConnection c = null;
        try {
            c = (HttpURLConnection) wifi.openConnection(new URL("http://" + host + path));
            c.setConnectTimeout(3000);
            c.setReadTimeout(3000);
            c.setInstanceFollowRedirects(false);
            c.setUseCaches(false);
            c.setRequestProperty("X-Requested-With", "XMLHttpRequest");
            if (c.getResponseCode() != 200) return null;
            try (InputStream in = c.getInputStream()) {
                byte[] buf = new byte[16384];
                int len = 0, k;
                while (len < buf.length && (k = in.read(buf, len, buf.length - len)) > 0) len += k;
                return new String(buf, 0, len, java.nio.charset.StandardCharsets.UTF_8);
            }
        } catch (Throwable t) {
            return null;
        } finally {
            if (c != null) c.disconnect();
        }
    }

    private static String iso(long t) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", java.util.Locale.US);
        f.setTimeZone(java.util.TimeZone.getTimeZone("UTC"));
        return f.format(new java.util.Date(t));
    }
}

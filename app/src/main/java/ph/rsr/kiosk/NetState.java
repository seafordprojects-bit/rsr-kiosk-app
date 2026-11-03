package ph.rsr.kiosk;

import android.content.Context;
import android.content.SharedPreferences;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiManager;

import org.json.JSONObject;

/**
 * What the tablet's connection looks like right now, and a record of the last outage.
 *
 * An outage is measured by the heartbeat itself: it starts at the first heartbeat that could not reach
 * the server and ends at the next one that did. While it lasts we keep the WORST reason seen
 * (Wi-Fi off > no internet > server not reachable). The record is saved, so it survives an app
 * restart or a reboot, and is sent with the first good heartbeat: "no Wi-Fi from 2:10 to 2:35 PM".
 */
final class NetState {
    static final String WIFI_OFF = "Wi-Fi off / not connected";
    static final String NO_INTERNET = "Wi-Fi connected but no internet";
    static final String SERVER = "internet OK but server not reachable";

    private final Context ctx;
    private final SharedPreferences sp;

    NetState(Context c) {
        ctx = c.getApplicationContext();
        sp = ctx.getSharedPreferences("rsr_net", Context.MODE_PRIVATE);
    }

    /** Current state for the heartbeat: wifi (bool), wifi_signal (0-4), internet (bool). */
    @SuppressWarnings("deprecation")
    void addTo(JSONObject p) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            Network n = cm == null ? null : cm.getActiveNetwork();
            NetworkCapabilities c = n == null ? null : cm.getNetworkCapabilities(n);
            boolean wifi = c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
            p.put("wifi", wifi);
            p.put("internet", c != null && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
            if (wifi) {
                WifiManager wm = (WifiManager) ctx.getSystemService(Context.WIFI_SERVICE);
                if (wm != null && wm.getConnectionInfo() != null) {
                    p.put("wifi_signal", WifiManager.calculateSignalLevel(wm.getConnectionInfo().getRssi(), 5));
                }
            }
        } catch (Exception ignored) { }
    }

    /** Why the server can't be reached right now. */
    String reasonNow() {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            Network n = cm == null ? null : cm.getActiveNetwork();
            NetworkCapabilities c = n == null ? null : cm.getNetworkCapabilities(n);
            if (c == null) return WIFI_OFF;
            if (!c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return NO_INTERNET;
            return SERVER;
        } catch (Exception e) {
            return SERVER;
        }
    }

    private static int rank(String r) {
        return WIFI_OFF.equals(r) ? 3 : NO_INTERNET.equals(r) ? 2 : 1;
    }

    /**
     * A heartbeat failed: start or extend the outage record. Not while the screen is off or the tablet
     * is in Android's deep sleep (night schedule): Android then blocks the app's network on purpose,
     * which is not a Wi-Fi problem and must not show up as a fake outage every morning.
     */
    void beatFailed() {
        try {
            android.os.PowerManager pm = (android.os.PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null && (!pm.isInteractive() || pm.isDeviceIdleMode())) return;
        } catch (Exception ignored) { }
        long now = System.currentTimeMillis();
        String reason = reasonNow();
        SharedPreferences.Editor e = sp.edit();
        if (!sp.contains("off_from")) e.putLong("off_from", now);
        if (rank(reason) >= rank(sp.getString("off_reason", ""))) e.putString("off_reason", reason);
        e.putLong("off_last_fail", now);
        e.commit();   // background thread: commit so a reboot right after cannot lose or resurrect it
    }

    /**
     * A heartbeat is about to be sent. If an outage is on record, it is returned to include in this
     * heartbeat (from, to, minutes, reason). Short blips under 2 minutes are dropped quietly.
     */
    JSONObject pendingOutage() {
        if (!sp.contains("off_from")) return null;
        long from = sp.getLong("off_from", 0), to = System.currentTimeMillis();
        if (to - from < 2 * 60_000L) return null;   // a blip under 2 min is not reported (beatOk clears it)
        try {
            return new JSONObject()
                    .put("from", iso(from)).put("to", iso(to))
                    .put("minutes", (to - from) / 60_000L)
                    .put("reason", sp.getString("off_reason", SERVER));
        } catch (Exception e) {
            return null;
        }
    }

    /** The heartbeat reached the server: the outage (if any) has been reported, clear it. */
    void beatOk() {
        if (sp.contains("off_from")) sp.edit().remove("off_from").remove("off_reason").remove("off_last_fail").commit();
    }

    private static String iso(long t) {
        java.text.SimpleDateFormat f = new java.text.SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ssXXX", java.util.Locale.US);
        return f.format(new java.util.Date(t));
    }
}

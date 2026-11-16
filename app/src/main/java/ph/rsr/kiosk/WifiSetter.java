package ph.rsr.kiosk;

import android.content.Context;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiManager;

import org.json.JSONObject;

/**
 * Build-6: office "Set Wi-Fi" (Tablets page, admin passcode). Adds the yard's Wi-Fi to the tablet and, if asked,
 * switches to it now. Only a device owner app may add networks on Android 10+. The password is used here and not
 * kept by the app (Android keeps the network like any saved Wi-Fi). "Switch now" is checked for 45 s; if the new Wi-Fi
 * does not give internet, the old networks are switched back on (review 2026-11-16).
 */
final class WifiSetter {
    private WifiSetter() { }

    @SuppressWarnings("deprecation")
    private static boolean onWifiWithInternet(Context ctx, WifiManager wm, int id) {
        try {
            android.net.ConnectivityManager cm = (android.net.ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            android.net.NetworkCapabilities c = cm == null ? null : cm.getNetworkCapabilities(cm.getActiveNetwork());
            if (c == null || !c.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI)
                    || !c.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_VALIDATED)) return false;
            android.net.wifi.WifiInfo wi = wm.getConnectionInfo();
            return wi == null || wi.getNetworkId() == -1 || wi.getNetworkId() == id;   // id unreadable: trust "validated Wi-Fi"
        } catch (Exception e) {
            return false;
        }
    }

    @SuppressWarnings("deprecation")
    static String apply(Context ctx, String arg) {
        try {
            if (!Policy.isOwner(ctx)) return "failed: needs full lock (device owner)";
            JSONObject a = new JSONObject(arg);
            String ssid = a.optString("ssid", "").trim();
            String pass = a.optString("pass", "");
            boolean sw = a.optBoolean("switch", true);
            if (ssid.isEmpty() || ssid.length() > 32 || ssid.contains("\"")) return "failed: bad Wi-Fi name";
            if (!pass.isEmpty() && (pass.length() < 8 || pass.length() > 63 || pass.contains("\""))) return "failed: bad password";
            WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
            if (wm == null) return "failed: no Wi-Fi";
            if (!wm.isWifiEnabled()) wm.setWifiEnabled(true);   // allowed for a device owner
            WifiConfiguration w = new WifiConfiguration();
            w.SSID = "\"" + ssid + "\"";
            if (pass.isEmpty()) {
                w.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.NONE);
            } else {
                w.preSharedKey = "\"" + pass + "\"";
                w.allowedKeyManagement.set(WifiConfiguration.KeyMgmt.WPA_PSK);
            }
            // saved networks before (needs location permission, granted by the full lock): to give them back if the
            // new Wi-Fi does not work (wrong password, out of range) - the tablet must never be left without Wi-Fi
            java.util.List<WifiConfiguration> before = null;
            try { before = wm.getConfiguredNetworks(); } catch (Exception ignored) { }
            int id = -1;
            if (before != null) {   // the same name saved before (old password): update it instead of adding a second one
                for (WifiConfiguration c : before) {
                    if (w.SSID.equals(c.SSID)) { w.networkId = c.networkId; id = wm.updateNetwork(w); break; }
                }
            }
            if (id < 0) id = wm.addNetwork(w);
            if (id < 0) return "failed: Android refused the network";
            if (!sw) {
                wm.enableNetwork(id, false);
                return "done: saved " + ssid + " (used when the current Wi-Fi is gone)";
            }
            wm.enableNetwork(id, true);
            // up to 45 s: is the tablet on THIS Wi-Fi, with internet?
            for (int k = 0; k < 9; k++) {
                try { Thread.sleep(5000); } catch (InterruptedException e) { break; }
                if (onWifiWithInternet(ctx, wm, id)) return "done: connected to " + ssid;
            }
            // did not work: switch the old networks back on, and leave the new one saved but off
            try { wm.disableNetwork(id); } catch (Exception ignored) { }
            if (before != null) for (WifiConfiguration c : before) if (c.networkId != id) wm.enableNetwork(c.networkId, false);
            wm.reconnect();
            return "failed: could not connect to " + ssid + " (wrong password or too far?) - back on the old Wi-Fi"
                    + (before == null ? " if it is in range" : "");
        } catch (Exception e) {
            return "failed: " + e.getClass().getSimpleName();
        }
    }
}

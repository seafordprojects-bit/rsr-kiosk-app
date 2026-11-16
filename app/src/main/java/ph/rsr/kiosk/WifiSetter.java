package ph.rsr.kiosk;

import android.content.Context;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiManager;

import org.json.JSONObject;

/**
 * Build-6: office "Set Wi-Fi" (Tablets page, admin passcode). Adds the yard's Wi-Fi to the tablet and, if asked,
 * switches to it now. Only a device owner app may add networks on Android 10+. The password is used here and not
 * kept by the app (Android keeps the network like any saved Wi-Fi).
 */
final class WifiSetter {
    private WifiSetter() { }

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
            int id = -1;
            // the same name saved before (old password): update it instead of adding a second one
            try {
                for (WifiConfiguration c : wm.getConfiguredNetworks()) {
                    if (w.SSID.equals(c.SSID)) { w.networkId = c.networkId; id = wm.updateNetwork(w); break; }
                }
            } catch (Exception ignored) { }
            if (id < 0) id = wm.addNetwork(w);
            if (id < 0) return "failed: Android refused the network";
            wm.enableNetwork(id, sw);
            return "done: " + (sw ? "switching to " : "saved ") + ssid;
        } catch (Exception e) {
            return "failed: " + e.getClass().getSimpleName();
        }
    }
}

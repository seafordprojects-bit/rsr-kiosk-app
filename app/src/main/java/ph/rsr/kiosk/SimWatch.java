package ph.rsr.kiosk;

import android.Manifest;
import android.app.usage.NetworkStats;
import android.app.usage.NetworkStatsManager;
import android.content.Context;
import android.content.pm.PackageManager;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.PowerManager;
import android.telephony.SignalStrength;
import android.telephony.TelephonyManager;

import org.json.JSONObject;

import java.util.Calendar;

/**
 * Build-6 (2026-11-16): what the office needs to watch the tablet's SIM and connection.
 *  - net_type: wifi / mobile / none (Wi-Fi downtime is measured on the server from this)
 *  - mobile_ok: mobile data really works (the SIM's data network is validated); left out when Android
 *    has no mobile network up to check (then nothing is known)
 *  - sim_operator / sim_state / mobile_signal
 *  - sms_ok: the app may read incoming telco texts (load / expiry), see SmsReceiver
 *  - mobile_days: mobile data used today and the 2 days before, from Android's own counter (device owner
 *    may read it). Read at most every 15 min (cheap, but no need every minute).
 *  - battery_unrestricted: Samsung battery "Unrestricted" for this app (needed for night check-ins)
 * Nothing here can block the kiosk: every read is guarded.
 */
final class SimWatch {
    private SimWatch() { }

    private static long lastDaysAt = 0;
    private static JSONObject lastDays = null;

    static void addTo(Context ctx, JSONObject p) {
        try {
            ConnectivityManager cm = (ConnectivityManager) ctx.getSystemService(Context.CONNECTIVITY_SERVICE);
            Network act = cm == null ? null : cm.getActiveNetwork();
            NetworkCapabilities ac = act == null ? null : cm.getNetworkCapabilities(act);
            String type = ac == null ? "none"
                    : ac.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ? "wifi"
                    : ac.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ? "mobile" : "none";
            p.put("net_type", type);
            // mobile data works? Only when Android has the SIM's data network up (on mobile, or kept up beside Wi-Fi)
            if (cm != null) {
                for (Network n : cm.getAllNetworks()) {
                    NetworkCapabilities c = cm.getNetworkCapabilities(n);
                    if (c != null && c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)
                            && c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)) {
                        p.put("mobile_ok", c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED));
                        break;
                    }
                }
            }
        } catch (Throwable ignored) { }
        try {
            TelephonyManager tm = (TelephonyManager) ctx.getSystemService(Context.TELEPHONY_SERVICE);
            if (tm != null) {
                int st = tm.getSimState();
                p.put("sim_state", st == TelephonyManager.SIM_STATE_READY ? "ready"
                        : st == TelephonyManager.SIM_STATE_ABSENT ? "absent"
                        : (st == TelephonyManager.SIM_STATE_PIN_REQUIRED || st == TelephonyManager.SIM_STATE_PUK_REQUIRED
                           || st == TelephonyManager.SIM_STATE_NETWORK_LOCKED) ? "locked" : "unknown");
                // the SIM's own name only when it is ready (the network name changes with the network: no false
                // "SIM CHANGED"); empty = unknown, the server keeps the last known name (owner 2026-11-19)
                String op = st == TelephonyManager.SIM_STATE_READY ? tm.getSimOperatorName() : null;
                if (op == null || op.trim().isEmpty()) op = st == TelephonyManager.SIM_STATE_READY ? tm.getNetworkOperatorName() : "";
                p.put("sim_operator", op == null ? "" : op.trim());
                // a new SIM gets a new subscription number from Android; the same SIM keeps its own (swap check)
                if (st == TelephonyManager.SIM_STATE_READY) try {
                    int sub = android.telephony.SubscriptionManager.getDefaultDataSubscriptionId();
                    if (sub >= 0) p.put("sim_sub", sub);
                } catch (Throwable ignored) { }
                if (st == TelephonyManager.SIM_STATE_READY && android.os.Build.VERSION.SDK_INT >= 28) {
                    try {
                        SignalStrength ss = tm.getSignalStrength();
                        if (ss != null) p.put("mobile_signal", Math.max(0, Math.min(4, ss.getLevel())));
                    } catch (Throwable ignored) { }
                }
            }
        } catch (Throwable ignored) { }
        try {
            // granted AND really allowed: Android can show a restricted permission as granted while its app-op
            // still blocks the texts (app not allow-listed by its installer) - then the office must know
            boolean perm = ctx.checkSelfPermission(Manifest.permission.RECEIVE_SMS) == PackageManager.PERMISSION_GRANTED;
            boolean op = true;
            if (android.os.Build.VERSION.SDK_INT >= 29) try {
                android.app.AppOpsManager ao = (android.app.AppOpsManager) ctx.getSystemService(Context.APP_OPS_SERVICE);
                if (ao != null) op = ao.unsafeCheckOpNoThrow("android:receive_sms", android.os.Process.myUid(), ctx.getPackageName())
                        == android.app.AppOpsManager.MODE_ALLOWED;
            } catch (Throwable ignored) { }
            p.put("sms_ok", perm && op);
        } catch (Throwable ignored) { }
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm != null) p.put("battery_unrestricted", pm.isIgnoringBatteryOptimizations(ctx.getPackageName()));
        } catch (Throwable ignored) { }
        try {
            JSONObject d = mobileDays(ctx);
            if (d != null && d.length() > 0) p.put("mobile_days", d);
        } catch (Throwable ignored) { }
    }

    /** {"2026-11-16": bytes, ...} for today and the 2 days before. Cached 15 min. */
    private static synchronized JSONObject mobileDays(Context ctx) {
        long now = System.currentTimeMillis();
        if (now - lastDaysAt < 15 * 60_000L) return lastDays;   // also a failed read waits 15 min
        lastDaysAt = now;
        try {
            NetworkStatsManager ns = (NetworkStatsManager) ctx.getSystemService(Context.NETWORK_STATS_SERVICE);
            if (ns == null) return lastDays = null;
            JSONObject out = new JSONObject();
            Calendar c = Calendar.getInstance();
            c.set(Calendar.HOUR_OF_DAY, 0); c.set(Calendar.MINUTE, 0); c.set(Calendar.SECOND, 0); c.set(Calendar.MILLISECOND, 0);
            for (int k = 0; k < 3; k++) {
                long from = c.getTimeInMillis();
                long to = k == 0 ? now : from + 24 * 3600_000L;
                NetworkStats.Bucket b = ns.querySummaryForDevice(ConnectivityManager.TYPE_MOBILE, null, from, to);
                if (b != null) {
                    String day = String.format(java.util.Locale.US, "%04d-%02d-%02d",
                            c.get(Calendar.YEAR), c.get(Calendar.MONTH) + 1, c.get(Calendar.DAY_OF_MONTH));
                    out.put(day, Math.max(0L, b.getRxBytes() + b.getTxBytes()));
                }
                c.add(Calendar.DAY_OF_MONTH, -1);
            }
            return lastDays = out;
        } catch (Exception e) {
            return lastDays = null;   // not allowed (not device owner) or no counter: just not reported
        }
    }
}

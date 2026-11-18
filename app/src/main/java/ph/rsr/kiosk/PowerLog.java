package ph.rsr.kiosk;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Power log (owner 2026-11-19: "log the tablet with no power, a table with what time the power is cut off").
 * The tablet notes the moment its charger loses power and gets it back, and when it shuts down / starts again,
 * even with no internet. The notes ride on the next heartbeat; the server builds the table (kiosk_app_power_log).
 * Kept across restarts; at most 100 waiting (oldest dropped first).
 */
final class PowerLog {
    private PowerLog() { }
    private static final String SP = "rsr_power", KEY = "q";

    private static SharedPreferences sp(Context c) { return c.getApplicationContext().getSharedPreferences(SP, Context.MODE_PRIVATE); }

    /** kind: "off" (charger lost power), "on" (power back), "shutdown", "boot". batt: % or -1. */
    static synchronized void add(Context c, String kind, int batt) {
        try {
            JSONArray q = list(c);
            long at = System.currentTimeMillis();
            if (q.length() > 0) {   // Android may send the same plug event twice: keep one
                JSONObject l = q.getJSONObject(q.length() - 1);
                if (kind.equals(l.optString("kind")) && at - l.optLong("at") < 5_000) return;
            }
            JSONObject e = new JSONObject().put("kind", kind).put("at", at);
            if (batt >= 0) e.put("batt", batt);
            q.put(e);
            while (q.length() > 100) q.remove(0);
            sp(c).edit().putString(KEY, q.toString()).commit();
        } catch (Exception ignored) { }
    }

    static synchronized JSONArray list(Context c) {
        try { return new JSONArray(sp(c).getString(KEY, "[]")); } catch (Exception e) { return new JSONArray(); }
    }

    /** The heartbeat that carried the first n notes reached the server: drop them. */
    static synchronized void sent(Context c, JSONArray carried) {
        try {
            JSONArray q = list(c), keep = new JSONArray();
            java.util.HashSet<String> done = new java.util.HashSet<>();
            for (int i = 0; i < carried.length(); i++) {
                JSONObject e = carried.getJSONObject(i);
                done.add(e.optString("kind") + e.optLong("at"));
            }
            for (int i = 0; i < q.length(); i++) {
                JSONObject e = q.getJSONObject(i);
                if (!done.contains(e.optString("kind") + e.optLong("at"))) keep.put(e);
            }
            sp(c).edit().putString(KEY, keep.toString()).commit();
        } catch (Exception ignored) { }
    }

    /** Wall-clock time the charger was lost and not back since (0 = on the charger / unknown). */
    static long unpluggedSince(Context c) { return sp(c).getLong("off_since", 0L); }
    static void setUnpluggedSince(Context c, long t) { sp(c).edit().putLong("off_since", t).commit(); }
}

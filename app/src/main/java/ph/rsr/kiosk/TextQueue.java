package ph.rsr.kiosk;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

/** Telco texts waiting to reach the office (kept across restarts; at most 30, the oldest dropped first). */
final class TextQueue {
    private TextQueue() { }
    private static final String SP = "rsr_texts", KEY = "q";

    private static SharedPreferences sp(Context c) { return c.getApplicationContext().getSharedPreferences(SP, Context.MODE_PRIVATE); }

    static synchronized void add(Context c, String from, String body, long at) {
        try {
            JSONArray q = list(c);
            q.put(new JSONObject().put("from", from).put("body", body).put("at", at));
            while (q.length() > 30) q.remove(0);
            sp(c).edit().putString(KEY, q.toString()).commit();
        } catch (Exception ignored) { }
    }

    static synchronized JSONArray list(Context c) {
        try { return new JSONArray(sp(c).getString(KEY, "[]")); } catch (Exception e) { return new JSONArray(); }
    }

    /** Remove the first entry if it is still the same one (sent). */
    static synchronized void removeFirst(Context c, long at, String body) {
        try {
            JSONArray q = list(c);
            if (q.length() == 0) return;
            JSONObject f = q.getJSONObject(0);
            if (f.optLong("at") == at && body.equals(f.optString("body"))) {
                q.remove(0);
                sp(c).edit().putString(KEY, q.toString()).commit();
            }
        } catch (Exception ignored) { }
    }
}

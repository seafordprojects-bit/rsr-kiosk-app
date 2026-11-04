package ph.rsr.kiosk;

import android.annotation.SuppressLint;
import android.content.Context;
import android.content.SharedPreferences;
import android.provider.Settings;

import java.security.SecureRandom;
import java.security.spec.KeySpec;

import javax.crypto.SecretKeyFactory;
import javax.crypto.spec.PBEKeySpec;

/** Small wrapper over SharedPreferences. The exit passcode is stored only as a salted PBKDF2 hash. */
final class Prefs {
    private final SharedPreferences sp;
    private final Context ctx;

    Prefs(Context c) {
        ctx = c.getApplicationContext();
        sp = ctx.getSharedPreferences("rsr_kiosk", Context.MODE_PRIVATE);
    }

    String url() { return sp.getString("url", Config.DEFAULT_URL); }
    void setUrl(String u) { sp.edit().putString("url", u).apply(); }

    String name() { return sp.getString("name", ""); }
    void setName(String n) { sp.edit().putString("name", n).apply(); }

    String onTime() { return sp.getString("on", Config.DEFAULT_ON); }
    String offTime() { return sp.getString("off", Config.DEFAULT_OFF); }
    boolean scheduleEnabled() { return sp.getBoolean("sched", true); }
    void setSchedule(String on, String off, boolean enabled) {
        sp.edit().putString("on", on).putString("off", off).putBoolean("sched", enabled).apply();
    }

    /** The kiosk page's own device id (localStorage rsr_device_id), so the office can match both heartbeats. */
    String pageDeviceId() { return sp.getString("page_dev", ""); }
    void setPageDeviceId(String id) { sp.edit().putString("page_dev", id).apply(); }

    /** Secret the server gave this tablet on its first report; proves later reports really come from it. */
    String token() { return sp.getString("srv_token", ""); }
    void setToken(String t) { sp.edit().putString("srv_token", t).commit(); }

    long lastCmdDone() { return sp.getLong("cmd_done", 0L); }
    void setLastCmdDone(long id) { sp.edit().putLong("cmd_done", id).commit(); }

    /** Last time KeepAlive could not go to the foreground (0 = never). Saved at once: the system may crash us next. */
    long keepAliveFailedAt() { return sp.getLong("ka_failed", 0L); }
    void setKeepAliveFailedAt(long t) { sp.edit().putLong("ka_failed", t).commit(); }

    long maintenanceUntil() { return sp.getLong("maint_until", 0L); }
    void setMaintenanceUntil(long t) { sp.edit().putLong("maint_until", t).commit(); }
    boolean inMaintenance() { return System.currentTimeMillis() < maintenanceUntil(); }

    long lastUpdateCheck() { return sp.getLong("upd_check", 0L); }
    void setLastUpdateCheck(long t) { sp.edit().putLong("upd_check", t).apply(); }

    String lastBeatStatus() { return sp.getString("beat_status", "not yet"); }
    void setLastBeatStatus(String s) { sp.edit().putString("beat_status", s).apply(); }

    /** Stable id for this tablet: "app-" + ANDROID_ID (survives app updates, changes only on factory reset). */
    @SuppressLint("HardwareIds")
    String deviceId() {
        String id = sp.getString("dev_id", null);
        if (id == null) {
            String a = Settings.Secure.getString(ctx.getContentResolver(), Settings.Secure.ANDROID_ID);
            if (a == null || a.isEmpty()) a = Long.toHexString(new SecureRandom().nextLong());
            id = "app-" + a;
            sp.edit().putString("dev_id", id).apply();
        }
        return id;
    }

    // ---- exit passcode -------------------------------------------------------------------------

    boolean hasPasscode() { return sp.contains("pc_hash"); }

    void setPasscode(String code) {
        byte[] salt = new byte[16];
        new SecureRandom().nextBytes(salt);
        sp.edit().putString("pc_salt", hex(salt)).putString("pc_hash", hex(pbkdf2(code, salt))).commit();
    }

    boolean checkPasscode(String code) {
        String salt = sp.getString("pc_salt", null), hash = sp.getString("pc_hash", null);
        if (salt == null || hash == null || code == null) return false;
        String got = hex(pbkdf2(code, unhex(salt)));
        // constant-time compare
        if (got.length() != hash.length()) return false;
        int diff = 0;
        for (int i = 0; i < got.length(); i++) diff |= got.charAt(i) ^ hash.charAt(i);
        return diff == 0;
    }

    /** Wrong-passcode throttle: after 5 wrong tries, wait 5 minutes. */
    boolean passcodeLocked() { return System.currentTimeMillis() < sp.getLong("pc_lock", 0L); }
    void passcodeWrong() {
        int n = sp.getInt("pc_fails", 0) + 1;
        SharedPreferences.Editor e = sp.edit().putInt("pc_fails", n);
        if (n >= 5) e.putInt("pc_fails", 0).putLong("pc_lock", System.currentTimeMillis() + 5 * 60_000L);
        e.apply();
    }
    void passcodeOk() { sp.edit().putInt("pc_fails", 0).remove("pc_lock").apply(); }

    /** Office sent "open settings" remotely: allow ONE settings open without the passcode within 10 minutes. */
    void grantRemoteUnlock() { sp.edit().putLong("remote_unlock", System.currentTimeMillis() + 10 * 60_000L).commit(); }
    boolean consumeRemoteUnlock() {
        boolean ok = System.currentTimeMillis() < sp.getLong("remote_unlock", 0L);
        sp.edit().remove("remote_unlock").commit();
        return ok;
    }

    private static byte[] pbkdf2(String code, byte[] salt) {
        try {
            KeySpec spec = new PBEKeySpec(code.toCharArray(), salt, 20000, 256);
            return SecretKeyFactory.getInstance("PBKDF2WithHmacSHA1").generateSecret(spec).getEncoded();
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
    }

    private static String hex(byte[] b) {
        StringBuilder s = new StringBuilder();
        for (byte x : b) s.append(String.format("%02x", x & 0xff));
        return s.toString();
    }

    private static byte[] unhex(String h) {
        byte[] b = new byte[h.length() / 2];
        for (int i = 0; i < b.length; i++) b[i] = (byte) Integer.parseInt(h.substring(i * 2, i * 2 + 2), 16);
        return b;
    }
}

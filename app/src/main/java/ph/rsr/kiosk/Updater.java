package ph.rsr.kiosk;

import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageInstaller;
import android.os.Build;
import android.util.Log;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;

/**
 * Self-update from this repo's latest GitHub Release. Device owner = silent install (nothing to tap).
 * Android itself refuses an APK not signed with the same key, so only our own builds can ever install.
 */
final class Updater {
    private static final String TAG = "RSRUpdate";
    private Updater() {}

    static long currentVersion(Context c) {
        try {
            PackageInfo p = c.getPackageManager().getPackageInfo(c.getPackageName(), 0);
            return Build.VERSION.SDK_INT >= 28 ? p.getLongVersionCode() : p.versionCode;
        } catch (Exception e) {
            return 0;
        }
    }

    /** Asked right before the install starts (the app stops while installing). */
    interface Gate { boolean ok(); }

    static String checkAndInstall(Context c) { return checkAndInstall(c, () -> true); }

    /** Runs on the background thread. Returns a short result line for the office/settings screen. */
    static String checkAndInstall(Context c, Gate gate) {
        try {
            JSONObject rel = new JSONObject(Net.get(Config.RELEASES_LATEST));
            String tag = rel.optString("tag_name", "");
            if (!tag.startsWith("build-")) return "no release";
            long latest = Long.parseLong(tag.substring(6).trim());
            long mine = currentVersion(c);
            if (latest <= mine) return "up to date (build " + mine + ")";

            String url = null;
            JSONArray assets = rel.optJSONArray("assets");
            for (int i = 0; assets != null && i < assets.length(); i++) {
                JSONObject a = assets.getJSONObject(i);
                if (Config.APK_ASSET_NAME.equals(a.optString("name"))) url = a.optString("browser_download_url");
            }
            if (url == null || !url.startsWith("https://github.com/seafordprojects-bit/rsr-kiosk-app/")) return "apk missing in release";

            if (!install(c, url, gate)) return "update postponed: kiosk in use";
            return "installing build " + latest;
        } catch (Exception e) {
            Log.w(TAG, "update failed", e);
            return "update failed: " + e.getMessage();
        }
    }

    private static boolean install(Context c, String url, Gate gate) throws Exception {
        PackageInstaller pi = c.getPackageManager().getPackageInstaller();
        PackageInstaller.SessionParams params = new PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL);
        params.setAppPackageName(c.getPackageName());
        if (Build.VERSION.SDK_INT >= 31) params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED);
        int id = pi.createSession(params);
        PackageInstaller.Session s = pi.openSession(id);
        HttpURLConnection conn = Net.openDownload(url);
        try (InputStream in = conn.getInputStream(); OutputStream out = s.openWrite("rsr-kiosk.apk", 0, -1)) {
            byte[] buf = new byte[65536];
            int n;
            while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            s.fsync(out);
        } catch (Exception e) {
            s.abandon();
            throw e;
        } finally {
            conn.disconnect();
        }
        // Downloading takes a while: check again that nobody is punching right before the app stops.
        if (!gate.ok()) { s.abandon(); return false; }
        Intent i = new Intent(c, InstallReceiver.class);
        int flags = PendingIntent.FLAG_UPDATE_CURRENT | (Build.VERSION.SDK_INT >= 31 ? PendingIntent.FLAG_MUTABLE : 0);
        PendingIntent p = PendingIntent.getBroadcast(c, id, i, flags);
        s.commit(p.getIntentSender());
        s.close();
        return true;
    }
}

package ph.rsr.kiosk;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.provider.MediaStore;
import android.util.Log;

import java.util.ArrayList;
import java.util.List;

/**
 * Roll-call phone job photos (owner 2026-11-14). EXACT allow-list, decided after review: only the phone's own
 * built-in CAMERA app may run inside the lock (photos are saved to the phone). Google Photos / Files / Drive are
 * NOT allowed: they open Share, Lens, Google sign-in, browsers. Checking and choosing photos is done in Android's
 * own photo picker (full-screen preview, no share), opened from roll-call; it runs inside the RSR task and needs
 * no allow-list entry. The manifest's <queries> makes the camera visible on Android 11+.
 */
final class MediaApps {
    private static final String TAG = "RSRMedia";
    private MediaApps() {}

    /** Package of the phone's default built-in camera app, or none. Never the app chooser ("android"). */
    static List<String> find(Context c) {
        List<String> out = new ArrayList<>();
        try {
            ResolveInfo r = c.getPackageManager().resolveActivity(camera(),
                    PackageManager.MATCH_DEFAULT_ONLY | PackageManager.MATCH_SYSTEM_ONLY);
            ActivityInfo a = r == null ? null : r.activityInfo;
            ApplicationInfo ai = a == null ? null : a.applicationInfo;
            if (a != null && ai != null && !"android".equals(a.packageName)
                    && (ai.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0) {
                out.add(a.packageName);
            }
        } catch (Exception e) { Log.w(TAG, "camera", e); }
        return out;
    }

    /** The phone's camera app, opened normally: photos are saved on the phone. */
    static Intent camera() { return new Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA); }

    /** Check / choose photos for roll-call (<input type=file>). Android 13+: the system photo picker. */
    static Intent picker(boolean multiple) {
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            Intent i = new Intent(MediaStore.ACTION_PICK_IMAGES);
            if (multiple) i.putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX, 20);
            return i;
        }
        Intent i = new Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE);
        if (multiple) i.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        return i;
    }
}

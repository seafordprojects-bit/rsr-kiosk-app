package ph.rsr.kiosk;

import android.content.Context;
import android.content.Intent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.content.pm.ResolveInfo;
import android.provider.MediaStore;
import android.util.Log;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

/**
 * Roll-call phone job photos (owner 2026-11-14): finds the phone's OWN camera, gallery and photo-picker apps
 * (system apps only — never something installed later) so Policy can let them run inside the lock.
 * The manifest's <queries> block makes these intents visible on Android 11+.
 */
final class MediaApps {
    private static final String TAG = "RSRMedia";
    private MediaApps() {}

    static List<String> find(Context c) {
        LinkedHashSet<String> out = new LinkedHashSet<>();
        PackageManager pm = c.getPackageManager();
        for (Intent i : intents()) {
            try {
                for (ResolveInfo r : pm.queryIntentActivities(i, PackageManager.MATCH_SYSTEM_ONLY)) {
                    if (r.activityInfo == null) continue;
                    ApplicationInfo a = r.activityInfo.applicationInfo;
                    if (a != null && (a.flags & (ApplicationInfo.FLAG_SYSTEM | ApplicationInfo.FLAG_UPDATED_SYSTEM_APP)) != 0) {
                        out.add(r.activityInfo.packageName);
                    }
                }
            } catch (Exception e) { Log.w(TAG, "query", e); }
        }
        return new ArrayList<>(out);
    }

    /** The phone's camera app, opened normally: photos are saved to the gallery. */
    static Intent camera() { return new Intent(MediaStore.INTENT_ACTION_STILL_IMAGE_CAMERA); }

    /** The phone's gallery, to check the photos. */
    static Intent gallery() {
        return Intent.makeMainSelectorActivity(Intent.ACTION_MAIN, Intent.CATEGORY_APP_GALLERY);
    }

    /** Pick one or more photos for roll-call (<input type=file>). Android 13+: the system photo picker. */
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

    private static List<Intent> intents() {
        List<Intent> l = new ArrayList<>();
        l.add(camera());
        l.add(new Intent(MediaStore.ACTION_IMAGE_CAPTURE));
        l.add(new Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_APP_GALLERY));
        l.add(new Intent(Intent.ACTION_VIEW).setDataAndType(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, "image/*"));
        l.add(picker(true));
        l.add(new Intent(Intent.ACTION_GET_CONTENT).setType("image/*").addCategory(Intent.CATEGORY_OPENABLE));
        return l;
    }
}

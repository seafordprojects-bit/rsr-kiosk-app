package ph.rsr.kiosk;

import android.Manifest;
import android.app.admin.DevicePolicyManager;
import android.app.admin.SystemUpdatePolicy;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.UserManager;
import android.util.Log;

/**
 * Everything that needs device-owner rights. Every call is wrapped so a policy the tablet refuses
 * never crashes the kiosk. Without device owner the app still runs, using normal screen pinning.
 */
final class Policy {
    private static final String TAG = "RSRPolicy";
    private static final String[] RESTRICTIONS = {
            UserManager.DISALLOW_SAFE_BOOT,
            UserManager.DISALLOW_ADD_USER,
            UserManager.DISALLOW_USB_FILE_TRANSFER,
            UserManager.DISALLOW_MOUNT_PHYSICAL_MEDIA,
    };

    private Policy() {}

    static DevicePolicyManager dpm(Context c) {
        return (DevicePolicyManager) c.getSystemService(Context.DEVICE_POLICY_SERVICE);
    }

    static ComponentName admin(Context c) {
        return new ComponentName(c, AdminReceiver.class);
    }

    static boolean isOwner(Context c) {
        try { return dpm(c).isDeviceOwnerApp(c.getPackageName()); } catch (Exception e) { return false; }
    }

    /** Full lock: called on every start. Safe to repeat. */
    static void applyKioskPolicies(Context c) {
        if (!isOwner(c)) return;
        DevicePolicyManager d = dpm(c);
        ComponentName a = admin(c);
        run("lockTaskPackages", () -> d.setLockTaskPackages(a, new String[]{c.getPackageName()}));
        // NONE = no Home, no Recents, no notifications, no power menu while locked.
        run("lockTaskFeatures", () -> d.setLockTaskFeatures(a, DevicePolicyManager.LOCK_TASK_FEATURE_NONE));
        run("home", () -> setAsHome(c, d, a));
        run("keyguard", () -> d.setKeyguardDisabled(a, true));
        run("statusbar", () -> d.setStatusBarDisabled(a, true));
        for (String r : RESTRICTIONS) run(r, () -> d.addUserRestriction(a, r));
        // Camera (punch photos) + mic (some camera stacks need it) granted without a prompt.
        run("perm cam", () -> d.setPermissionGrantState(a, c.getPackageName(), Manifest.permission.CAMERA,
                DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED));
        run("perm mic", () -> d.setPermissionGrantState(a, c.getPackageName(), Manifest.permission.RECORD_AUDIO,
                DevicePolicyManager.PERMISSION_GRANT_STATE_GRANTED));
        // System updates only 00:30 - 04:30 so Samsung never restarts the tablet during work or overtime.
        run("updates", () -> d.setSystemUpdatePolicy(a, SystemUpdatePolicy.createWindowedInstallPolicy(30, 4 * 60 + 30)));
    }

    /** Roll-call phone (Mode): screen off after 1 min without a touch, so the battery lasts the day in the
     *  yard. Only with device owner (Android 9+); otherwise the phone keeps its own timeout. Safe to repeat. */
    static void applyPhoneScreenTimeout(Context c) {
        if (!isOwner(c) || android.os.Build.VERSION.SDK_INT < 28) return;
        run("phone screen timeout", () -> dpm(c).setSystemSetting(admin(c),
                android.provider.Settings.System.SCREEN_OFF_TIMEOUT, String.valueOf(Mode.PHONE_SCREEN_TIMEOUT_MS)));
    }

    /** Maintenance: let the office use the tablet normally for a while (Wi-Fi, Settings). */
    static void relaxForMaintenance(Context c) {
        if (!isOwner(c)) return;
        DevicePolicyManager d = dpm(c);
        ComponentName a = admin(c);
        run("statusbar off", () -> d.setStatusBarDisabled(a, false));
        // HOME stays pointed at the kiosk: pressing Home during maintenance returns to the kiosk.
    }

    /** Decommission: remove every restriction, then give up device owner. Only from Settings with passcode. */
    static void removeDeviceOwner(Context c) {
        if (!isOwner(c)) return;
        DevicePolicyManager d = dpm(c);
        ComponentName a = admin(c);
        relaxForMaintenance(c);
        run("keyguard off", () -> d.setKeyguardDisabled(a, false));
        run("home clear", () -> d.clearPackagePersistentPreferredActivities(a, c.getPackageName()));
        for (String r : RESTRICTIONS) run("clear " + r, () -> d.clearUserRestriction(a, r));
        run("updates clear", () -> d.setSystemUpdatePolicy(a, null));
        run("lockTaskPackages clear", () -> d.setLockTaskPackages(a, new String[]{}));
        run("clearOwner", () -> d.clearDeviceOwnerApp(c.getPackageName()));
    }

    static boolean reboot(Context c) {
        if (!isOwner(c)) return false;
        try { dpm(c).reboot(admin(c)); return true; } catch (Exception e) { Log.w(TAG, "reboot", e); return false; }
    }

    static void screenOffNow(Context c) {
        try { dpm(c).lockNow(); } catch (Exception e) { Log.w(TAG, "lockNow", e); }
    }

    private static void setAsHome(Context c, DevicePolicyManager d, ComponentName a) {
        IntentFilter f = new IntentFilter(Intent.ACTION_MAIN);
        f.addCategory(Intent.CATEGORY_HOME);
        f.addCategory(Intent.CATEGORY_DEFAULT);
        d.addPersistentPreferredActivity(a, f, new ComponentName(c, KioskActivity.class));
    }

    private interface Step { void go() throws Exception; }

    private static void run(String what, Step r) {
        try { r.go(); } catch (Throwable t) { Log.w(TAG, what + " failed", t); }
    }
}

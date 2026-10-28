package ph.rsr.kiosk;

import android.app.admin.DeviceAdminReceiver;
import android.content.Context;
import android.content.Intent;

/** Device-owner receiver. Set once with: adb shell dpm set-device-owner ph.rsr.kiosk/.AdminReceiver */
public class AdminReceiver extends DeviceAdminReceiver {
    @Override
    public void onEnabled(Context c, Intent i) {
        Policy.applyKioskPolicies(c);
    }
}

package ph.rsr.kiosk;

import android.app.Activity;
import android.content.Intent;
import android.os.Bundle;

/**
 * QR setup (Android 10+, required from Android 12): during the phone's first setup, Android asks the RSR app
 * which kind of management it wants. Answer: fully managed device (= device owner, the same full lock that
 * "adb shell dpm set-device-owner" gives). Added 2026-11-12 for the roll-call phone; adb setup still works.
 */
public class ProvisioningModeActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        Intent r = new Intent();
        r.putExtra("android.app.extra.PROVISIONING_MODE", 1);   // DevicePolicyManager.PROVISIONING_MODE_FULLY_MANAGED_DEVICE
        setResult(RESULT_OK, r);
        finish();
    }
}

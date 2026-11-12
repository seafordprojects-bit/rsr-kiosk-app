package ph.rsr.kiosk;

import android.app.Activity;
import android.os.Bundle;
import android.os.PersistableBundle;

/**
 * QR setup, last step: Android hands over the extras from the QR code. Only one is used: "rsr_url", the page
 * the device should show (an RSR page only). The roll-call phone's QR carries the roll-call address, so the
 * phone starts straight in phone mode (Mode). Everything else (name, exit passcode) is asked on first start.
 */
public class PolicyComplianceActivity extends Activity {
    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        try {
            PersistableBundle extras = getIntent().getParcelableExtra("android.app.extra.PROVISIONING_ADMIN_EXTRAS_BUNDLE");
            String u = extras == null ? null : extras.getString("rsr_url");
            if (u != null && u.trim().startsWith("https://seafordprojects-bit.github.io/")) new Prefs(this).setUrl(u.trim());
        } catch (Exception ignored) { }
        setResult(RESULT_OK);
        finish();
    }
}

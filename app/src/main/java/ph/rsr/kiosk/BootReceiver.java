package ph.rsr.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** After a restart or an app update: open the kiosk again. (As HOME app it usually opens anyway.) */
public class BootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context c, Intent i) {
        String a = i.getAction();
        Core core = Core.get(c);
        if (Intent.ACTION_MY_PACKAGE_REPLACED.equals(a)) {
            core.reportEvent("updated to build " + Updater.currentVersion(c));
        } else {
            core.reportEvent("tablet restarted");
            // A restart always ends maintenance: the tablet comes back locked.
            new Prefs(c).setMaintenanceUntil(0);
        }
        Policy.applyKioskPolicies(c);
        core.scheduleNextAlarm();
        core.scheduleReportAlarm();
        core.bringToFront();
    }
}

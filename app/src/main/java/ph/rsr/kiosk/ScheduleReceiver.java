package ph.rsr.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Screen on/off alarm, and the maintenance-end alarm. */
public class ScheduleReceiver extends BroadcastReceiver {
    static final String ACTION_MAINT_END = "ph.rsr.kiosk.MAINT_END";
    static final String ACTION_REPORT_WAKE = "ph.rsr.kiosk.REPORT_WAKE";
    static final String ACTION_UPDATE = "ph.rsr.kiosk.UPDATE";

    @Override
    public void onReceive(Context c, Intent i) {
        Core core = Core.get(c);
        if (ACTION_MAINT_END.equals(i.getAction())) core.maintenanceAlarm();
        else if (ACTION_REPORT_WAKE.equals(i.getAction())) core.reportWake();
        else if (ACTION_UPDATE.equals(i.getAction())) core.updateAlarm();
        else core.scheduleAlarm();
    }
}

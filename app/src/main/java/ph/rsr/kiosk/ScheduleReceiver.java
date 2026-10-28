package ph.rsr.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Screen on/off alarm, and the maintenance-end alarm. */
public class ScheduleReceiver extends BroadcastReceiver {
    static final String ACTION_MAINT_END = "ph.rsr.kiosk.MAINT_END";

    @Override
    public void onReceive(Context c, Intent i) {
        Core core = Core.get(c);
        if (ACTION_MAINT_END.equals(i.getAction())) core.maintenanceAlarm();
        else core.scheduleAlarm();
    }
}

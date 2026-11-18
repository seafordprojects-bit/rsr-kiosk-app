package ph.rsr.kiosk;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Screen on/off alarm, and the maintenance-end alarm. */
public class ScheduleReceiver extends BroadcastReceiver {
    static final String ACTION_MAINT_END = "ph.rsr.kiosk.MAINT_END";
    static final String ACTION_REPORT_WAKE = "ph.rsr.kiosk.REPORT_WAKE";
    static final String ACTION_UPDATE = "ph.rsr.kiosk.UPDATE";
    static final String ACTION_CHECKIN = "ph.rsr.kiosk.CHECKIN";
    static final String ACTION_SLEEP_WAKE = "ph.rsr.kiosk.SLEEP_WAKE";       // holiday sleep: 7:00 / plan end
    static final String ACTION_SLEEP_REPORT = "ph.rsr.kiosk.SLEEP_REPORT";   // holiday sleep: 12-hour report
    static final String ACTION_SLEEP_RECHECK = "ph.rsr.kiosk.SLEEP_RECHECK"; // 10:00: still no power, untouched?
    static final String ACTION_SLEEP_PLAN = "ph.rsr.kiosk.SLEEP_PLAN";       // planned holiday sleep starts

    @Override
    public void onReceive(Context c, Intent i) {
        Core core = Core.get(c);
        if (ACTION_MAINT_END.equals(i.getAction())) core.maintenanceAlarm();
        else if (ACTION_REPORT_WAKE.equals(i.getAction())) core.reportWake();
        else if (ACTION_UPDATE.equals(i.getAction())) core.updateAlarm();
        else if (ACTION_CHECKIN.equals(i.getAction())) core.checkinAlarm();
        else if (ACTION_SLEEP_WAKE.equals(i.getAction())) core.sleepWakeAlarm();
        else if (ACTION_SLEEP_REPORT.equals(i.getAction())) core.sleepReportAlarm();
        else if (ACTION_SLEEP_RECHECK.equals(i.getAction())) core.sleepRecheckAlarm();
        else if (ACTION_SLEEP_PLAN.equals(i.getAction())) core.sleepPlanAlarm();
        else core.scheduleAlarm();
    }
}

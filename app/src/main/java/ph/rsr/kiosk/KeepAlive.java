package ph.rsr.kiosk;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;

/**
 * Keeps the RSR Kiosk process in the foreground class, like Fully Kiosk does.
 *
 * Failure it fixes (Mandaue, 2026-11-04): every time the kiosk was not the front app (maintenance in
 * Android settings, screen off) Android froze the app and cut its network. The heartbeat stopped, the
 * panel showed OFFLINE "Wi-Fi off", and commands (Screen on) waited, while the phone on the same Wi-Fi
 * was fine. A foreground service is never frozen and keeps its network.
 *
 * It does no work of its own: Core still does the heartbeat. The notification it must show is hidden
 * by the full lock (status bar disabled); during maintenance it reads "RSR Kiosk is running".
 */
public class KeepAlive extends Service {
    private static final String TAG = "RSRKeepAlive";
    private static final String CHANNEL = "rsr_keepalive";
    private static final int ID = 41;

    /** Safe to call any time, from anywhere: a start Android refuses is logged, never a crash. */
    static void start(Context c) {
        try {
            Intent i = new Intent(c, KeepAlive.class);
            if (Build.VERSION.SDK_INT >= 26) c.startForegroundService(i); else c.startService(i);
        } catch (Exception e) {
            Log.w(TAG, "start refused", e);
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        goForeground();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        goForeground();   // every start must reach startForeground within a few seconds
        return START_STICKY;
    }

    private void goForeground() {
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null && nm.getNotificationChannel(CHANNEL) == null) {
                NotificationChannel ch = new NotificationChannel(CHANNEL, "RSR Kiosk running", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                nm.createNotificationChannel(ch);
            }
            Notification n = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(getApplicationInfo().icon)
                    .setContentTitle("RSR Kiosk is running")
                    .setOngoing(true)
                    .build();
            if (Build.VERSION.SDK_INT >= 34) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            else startForeground(ID, n);
        } catch (Exception e) {
            Log.w(TAG, "foreground refused", e);
        }
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

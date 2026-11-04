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

    /** True once the service is in the foreground; cleared when Android stops it. */
    static volatile boolean running;
    private static final long RETRY_AFTER_FAIL_MS = 24 * 3600_000L;

    /** Safe to call any time, from anywhere: a start Android refuses is logged, never a crash. */
    static void start(Context c) {
        // Each start re-arms Android's "go foreground within 10 s" timer: never start what already runs.
        if (running) return;
        try {
            // It once failed to go foreground: Android then crashes the app, and the kiosk would relaunch and
            // crash again every few seconds. Stay off for a day instead (the kiosk works as before without it).
            long failed = new Prefs(c).keepAliveFailedAt();
            if (failed > 0 && System.currentTimeMillis() - failed < RETRY_AFTER_FAIL_MS) return;
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
        // No "already running" shortcut here: a start that slipped in must still be answered with startForeground
        // (calling it again on a running service is harmless, skipping it would let Android crash the app).
        try {
            NotificationManager nm = (NotificationManager) getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm != null && nm.getNotificationChannel(CHANNEL) == null) {
                NotificationChannel ch = new NotificationChannel(CHANNEL, "RSR Kiosk running", NotificationManager.IMPORTANCE_MIN);
                ch.setShowBadge(false);
                nm.createNotificationChannel(ch);
            }
            Notification n = new Notification.Builder(this, CHANNEL)
                    .setSmallIcon(android.R.drawable.stat_notify_sync)   // one-colour system icon
                    .setContentTitle("RSR Kiosk is running")
                    .setOngoing(true)
                    .build();
            if (Build.VERSION.SDK_INT >= 34) startForeground(ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE);
            else startForeground(ID, n);
            running = true;
        } catch (Exception e) {
            Log.w(TAG, "foreground refused", e);
            new Prefs(this).setKeepAliveFailedAt(System.currentTimeMillis());   // before anything else can fail
            try {   // last try with the plainest notification, so Android has no reason to crash the app
                Notification plain = new Notification.Builder(this, CHANNEL)
                        .setSmallIcon(android.R.drawable.stat_notify_sync).build();
                startForeground(ID, plain);
                running = true;
            } catch (Exception e2) {
                Log.w(TAG, "plain foreground refused too", e2);
                stopSelf();
            }
        }
    }

    @Override
    public void onDestroy() {
        running = false;
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}

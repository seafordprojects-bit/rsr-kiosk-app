package ph.rsr.kiosk;

import android.app.Application;

public class App extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        // During maintenance (kiosk unlocked for Wi-Fi etc.) do not re-lock just because the process restarted.
        if (!new Prefs(this).inMaintenance()) Policy.applyKioskPolicies(this);
        Core.get(this).start();
    }
}

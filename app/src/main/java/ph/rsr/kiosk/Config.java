package ph.rsr.kiosk;

/** Fixed settings for the RSR-only kiosk. Nothing secret lives here (the anon key is already public in the kiosk page). */
final class Config {
    private Config() {}

    /** Page the tablet shows by default. Can be changed in Settings (passcode). */
    static final String DEFAULT_URL = "https://seafordprojects-bit.github.io/rsr-engineering/kiosk/";

    /** Only pages on these hosts may open in the kiosk. Anything else is blocked. */
    static final String[] ALLOWED_HOSTS = { "seafordprojects-bit.github.io" };

    /** Same Supabase project as the kiosk/payroll (free tier). Used only for the tablet heartbeat + remote commands. */
    static final String SUPABASE_URL = "https://wpmcbjrisuyjvobvzaus.supabase.co";
    static final String SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6IndwbWNianJpc3V5anZvYnZ6YXVzIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Nzc4NjU3ODQsImV4cCI6MjA5MzQ0MTc4NH0.EGyUnXmVkUrsEteKICMRSOXURxYXPOaKUs8EYCpw6_0";

    /** Self-update source: the latest GitHub Release of this repo, asset "rsr-kiosk.apk", tag "build-<versionCode>". */
    static final String RELEASES_LATEST = "https://api.github.com/repos/seafordprojects-bit/rsr-kiosk-app/releases/latest";
    static final String APK_ASSET_NAME = "rsr-kiosk.apk";

    /** Heartbeat + command poll every 60 s. Two tablets = ~2,900 small calls a day, far inside the free tier. */
    static final long BEAT_MS = 60_000L;

    /** Hang check: the page must answer a tiny script within this time, else it is reloaded. */
    static final long HANG_CHECK_MS = 60_000L;
    static final long HANG_TIMEOUT_MS = 30_000L;

    /** Page failed to load (no internet AND nothing cached): retry this often. */
    static final long RETRY_MS = 15_000L;

    /** Maintenance (kiosk unlocked to fix Wi-Fi etc.) ends by itself after this long. */
    static final long MAINTENANCE_MS = 10 * 60_000L;

    /** Default screen schedule (Manila time on the tablet). After the 10 PM OT cut-off. */
    static final String DEFAULT_ON = "05:30";
    static final String DEFAULT_OFF = "22:30";
}

package ph.rsr.kiosk;

/**
 * Roll-call PHONE mode (owner 2026-11-08 / 11-12). The Wi-Fi-only Motorola roll-call phone runs this same
 * app, locked to a Job Monitoring page (roll-call). It is carried around on battery, so unlike a kiosk tablet:
 *  - the screen is NOT kept on; Android turns it off after PHONE_SCREEN_TIMEOUT_MS without a touch,
 *  - no screen schedule and no wake-ups before the 10:01 / 3:00 / 7:10 kiosk reports,
 *  - the server sends no OFFLINE / NOT CHARGING alerts for it (it is offline in the yard by design),
 *    only battery LOW 20% and CRITICAL 10% (supabase/kiosk-app.sql, kiosk_app_is_phone).
 * The mode follows the page address the office already sets in Settings, so a kiosk tablet
 * (address .../kiosk/) can never switch into it by accident. Pure Java: tested in test/ModeTest.java.
 */
final class Mode {
    private Mode() {}

    static final long PHONE_SCREEN_TIMEOUT_MS = 60_000L;

    /** Punch-rush protection (Config.RUSH) blocks office commands only on a kiosk tablet
     *  (build-14, owner 2026-11-14). A roll-call phone has no kiosk punches, so Update / Reload /
     *  Full reload / Restart are never refused on it for "punch rush time". Tablets are unchanged. */
    static boolean rushBlocks(boolean inRush, boolean phone) { return inRush && !phone; }

    /** Roll-call phone (owner 2026-11-12): only Job Monitoring pages may open; any other RSR page (main menu,
     *  coordinator, issuance) is refused and the phone goes back to its saved page. Tablets: never. */
    static boolean phoneBlocks(String savedUrl, String target) {
        return target != null && isPhoneUrl(savedUrl) && !isPhoneUrl(target);
    }

    /** Never let these out of the lock, even if one handles a camera/gallery intent. */
    private static final java.util.Set<String> NEVER = new java.util.HashSet<>(java.util.Arrays.asList(
            "com.android.settings", "com.android.vending", "com.android.chrome", "com.google.android.googlequicksearchbox",
            "com.android.packageinstaller", "com.google.android.packageinstaller", "com.android.systemui",
            "com.google.android.apps.photos", "com.google.android.apps.nbu.files", "com.google.android.apps.docs",
            "com.google.android.documentsui", "com.android.documentsui"));

    /** Apps allowed in the lock. Tablet: only RSR. Roll-call phone (owner 2026-11-14, job before/after photos):
     *  RSR + the phone's own built-in camera app (MediaApps). At most 2 apps; anything on NEVER is dropped. */
    static String[] lockPackages(String self, boolean phone, java.util.Collection<String> media) {
        java.util.LinkedHashSet<String> out = new java.util.LinkedHashSet<>();
        out.add(self);
        if (phone && media != null) for (String p : media) {
            if (out.size() >= 2) break;
            if (p != null && !p.trim().isEmpty() && !NEVER.contains(p.trim()) && !"android".equals(p.trim())) out.add(p.trim());
        }
        return out.toArray(new String[0]);
    }

    /** Roll-call phone: the Home button works and always brings back the RSR app (it is the phone's Home),
     *  so the in-charge can never get stuck in the Camera or Gallery. Tablets: no Home button. */
    static boolean phoneHomeButton(boolean phone) { return phone; }

    /** True for an RSR Job Monitoring page (path contains /monitoring/). Query and #hash are ignored. */
    static boolean isPhoneUrl(String url) {
        if (url == null) return false;
        String u = url.trim().toLowerCase(java.util.Locale.ROOT);
        String prefix = "https://seafordprojects-bit.github.io/";
        if (!u.startsWith(prefix)) return false;
        int cut = u.length();
        int q = u.indexOf('?'), h = u.indexOf('#');
        if (q >= 0) cut = Math.min(cut, q);
        if (h >= 0) cut = Math.min(cut, h);
        // path after the host must be "<folder>/.../monitoring/..." (same rule as SQL kiosk_app_is_phone)
        return u.substring(prefix.length() - 1, cut).indexOf("/monitoring/") > 0;
    }
}

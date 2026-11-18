package ph.rsr.kiosk;

import android.content.Context;
import android.content.Intent;
import android.os.BatteryManager;
import android.os.Build;

import org.json.JSONObject;

/**
 * Owner 2026-11-18: "add battery life percentage and warn me if the battery needs replacement".
 * Android gives apps no direct "battery health %", so the tablet reports what it can, and the server works it out:
 *  - batt_full_mah: how much a FULL charge holds today = charge left now (CHARGE_COUNTER, micro-amp-hours) / level %.
 *    Only read between 30% and 95% (most accurate there); the server averages many readings.
 *  - batt_design_mah: what it held when new (Galaxy Tab A9 = 5100 mAh; else Android's own power profile if readable).
 *  - batt_health: Android's own verdict (good / overheat / dead / over_voltage / failure / cold).
 *  - batt_cycles: full charge cycles (Android 14+, when the tablet reports it).
 * Every read is guarded: nothing here can break the heartbeat.
 */
final class BatteryHealth {
    private BatteryHealth() { }

    static void addTo(Context ctx, Intent b, JSONObject p) {
        try {
            int h = b.getIntExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_UNKNOWN);
            String hs = h == BatteryManager.BATTERY_HEALTH_GOOD ? "good"
                    : h == BatteryManager.BATTERY_HEALTH_OVERHEAT ? "overheat"
                    : h == BatteryManager.BATTERY_HEALTH_DEAD ? "dead"
                    : h == BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE ? "over_voltage"
                    : h == BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE ? "failure"
                    : h == BatteryManager.BATTERY_HEALTH_COLD ? "cold" : null;
            if (hs != null) p.put("batt_health", hs);
        } catch (Throwable ignored) { }
        try {
            int c = b.getIntExtra("android.os.extra.CYCLE_COUNT", -1);   // BatteryManager.EXTRA_CYCLE_COUNT (API 34)
            if (c >= 0 && c < 100000) p.put("batt_cycles", c);
        } catch (Throwable ignored) { }
        try {
            int lvl = b.getIntExtra(BatteryManager.EXTRA_LEVEL, -1), sc = b.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
            int pct = lvl >= 0 && sc > 0 ? Math.round(lvl * 100f / sc) : -1;
            BatteryManager bm = (BatteryManager) ctx.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null && pct >= 30 && pct <= 95) {
                int uah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
                if (uah > 0 && uah != Integer.MIN_VALUE) {
                    long full = Math.round(uah / 1000.0 * 100.0 / pct);
                    if (full >= 500 && full <= 30000) p.put("batt_full_mah", full);
                }
            }
        } catch (Throwable ignored) { }
        try {
            int d = designMah(ctx);
            if (d > 0) p.put("batt_design_mah", d);
        } catch (Throwable ignored) { }
    }

    private static int design = 0;

    /** Capacity when new, mAh (0 = unknown). Galaxy Tab A9 (SM-X110 / X115 / X117) = 5100 mAh. */
    static int designMah(Context ctx) {
        if (design != 0) return design;
        String m = Build.MODEL == null ? "" : Build.MODEL.toUpperCase(java.util.Locale.US);
        if (m.startsWith("SM-X11")) return design = 5100;
        try {   // Android's power profile (hidden but usually readable); any failure = unknown
            Class<?> c = Class.forName("com.android.internal.os.PowerProfile");
            Object pp = c.getConstructor(Context.class).newInstance(ctx);
            double v = (double) c.getMethod("getBatteryCapacity").invoke(pp);
            if (v >= 500 && v <= 30000) return design = (int) Math.round(v);
        } catch (Throwable ignored) { }
        return design = -1;
    }
}

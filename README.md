# RSR Kiosk app

RSR-only Android kiosk browser for the Galaxy Tab kiosks. Replaces Fully Kiosk Browser.

- Locks the tablet to the RSR kiosk page (Android device owner + lock task): no Home, Back, Recents, notifications or power menu.
- Starts on boot, keeps the screen on in work hours, turns it off at night (schedule).
- Camera allowed for the punch photo; every non-RSR site is blocked.
- Recovers by itself: retries when the page cannot load, rebuilds a crashed page, reloads a frozen page.
  Offline punching keeps working because the kiosk page's own offline mode is untouched.
- Heartbeat every 60 s to Supabase (battery, charging, screen, build). Remote commands from the
  **RSR Tablets** page: reload, full reload, update, screen on/off, schedule, open settings, restart.
- Telegram (RSR Kiosk Alerts): NOT CHARGING after 5 min with battery % (reminder every 30 min, 2 h at night), battery drop 50/30/20/10%, charging again, tablet restarted, app updated.
- Self-update from the latest GitHub Release, silent install.

| Path | What |
|---|---|
| `app/` | Android app (Java, no libraries) |
| `.github/workflows/build.yml` | Builds the signed APK and publishes a Release on every app change |
| `supabase/kiosk-app.sql` | Tables, RPCs, Telegram watcher (run once; rollback file beside it; test in `test-kiosk-app.mjs`) |
| `tablets.html` | Office page to watch and control the tablets (admin passcode) |
| `docs/SETUP.md` | Tablet setup, step by step |

Package `ph.rsr.kiosk`. Device owner: `adb shell dpm set-device-owner ph.rsr.kiosk/.AdminReceiver`.

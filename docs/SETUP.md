# RSR Kiosk app: tablet setup (full lock)

One time per tablet, about 20 minutes. You need: the tablet, its USB cable, and the laptop.

## 0. Before you start (important)

The setup needs a **factory reset**, which erases everything on the tablet, including punches that have
not synced yet.

1. Do it when no one needs to punch (for example Sunday, or after the evening punches).
2. Make sure the tablet is **online** and the RSR Admin dashboard shows **no stuck/unsynced punches** for that yard.
3. Keep the logbook ready in case setup takes longer.

## 1. Get the app

On the laptop open `https://github.com/seafordprojects-bit/rsr-kiosk-app/releases`, then download
**rsr-kiosk.apk** from the newest build.

## 2. Install adb on the laptop (once)

1. Download **SDK Platform-Tools for Windows** from `https://developer.android.com/tools/releases/platform-tools`.
2. Unzip it to `C:\platform-tools`.
3. Copy `rsr-kiosk.apk` into `C:\platform-tools`.

## 3. Reset the tablet

1. Tablet: **Settings > General management > Reset > Factory data reset**.
2. In the welcome setup: connect to the yard **Wi-Fi**.
3. **Skip** the Google account and **skip** the Samsung account. No account must be added, otherwise step 5 fails.

## 3b. Protect the battery (important for a tablet that is plugged in all day)

1. **Settings > Battery > More battery settings > Protect battery: ON** (on some versions:
   **Settings > Battery > Battery protection > Maximum 85%**).
2. The tablet then stops charging at 85%. A battery kept at 100% all day in yard heat can swell within months.
3. Use a proper 10-15 W charger and keep the tablet out of direct sun and with some air around it.
   The app sends a Telegram alert if the battery reaches 45 C.

## 4. Turn on USB debugging

1. **Settings > About tablet > Software information**. Tap **Build number** 7 times until it says
   "Developer mode has been turned on".
2. **Settings > Developer options > USB debugging**: ON.
3. Connect the USB cable to the laptop. On the tablet tap **Allow** on the "Allow USB debugging?" pop-up
   (tick "Always allow from this computer").

## 5. Install and lock (on the laptop, PowerShell)

```powershell
cd C:\platform-tools
.\adb devices
.\adb install rsr-kiosk.apk
.\adb shell dpm set-device-owner ph.rsr.kiosk/.AdminReceiver
```

Expected: `adb devices` lists one device, install says `Success`, and the last line says
`Success: Device owner set to package ph.rsr.kiosk`.

If it says *"there are already some accounts on the device"*, an account was added in step 3. Go to
**Settings > Accounts and backup > Manage accounts**, remove every account, then run the last line again.

## 6. First start

1. Open **RSR Kiosk** on the tablet.
2. Enter the tablet name (for example `Carmen kiosk`) and an **exit passcode** (6 to 10 digits). Keep it in a safe place.
3. The kiosk page opens, locked. Allow nothing else; the camera is already allowed.
4. Unplug the USB cable. Then turn USB debugging OFF: hidden settings (step 8) > **Open Wi-Fi / Android settings**
   > back to main Settings > **Developer options > USB debugging OFF**. Press Home to return to the kiosk.

## 7. Check (visual confirmation)

- Home, Back and Recents buttons do nothing. The notification bar does not pull down.
- Press the power button twice. The tablet goes back to the kiosk, no lock screen.
- Punch with a test PIN. The photo is taken.
- On your phone open **RSR Tablets** (`https://seafordprojects-bit.github.io/rsr-kiosk-app/tablets.html`),
  enter the admin passcode, and see the tablet **Online** with its battery.

## 7b. Carmen only (generator power)

On the RSR Tablets page, for **Carmen kiosk**:
1. **Set schedule**: already `06:45-00:15` by default (screen on 15 min before the first 7:00 AM punch; from 9 PM the
   screen turns off after 15 min without a touch, latest 00:15; the power button always wakes it).
2. **Generator hours** -> `08:00-11:30,13:00-16:30,18:00-21:00+24:00`.
   `+24:00` means overtime MAY run until 24:00: from 9 PM the tablet on battery is normal (no "not charging"
   alerts), you are only warned if the battery may run out before 8 AM.

Then "not charging" alerts only come while the generator should be running (a real charger/cable problem).
During breaks and at night you get a message only if the battery may run out before the generator is back.
Mandaue (grid power): leave Generator hours empty.

## 8. Hidden settings on the tablet

Tap the **top-right corner 5 times quickly** (within 3 seconds), then enter the exit passcode.

| Button | What it does |
|---|---|
| Reload page / Full reload | Same as Fully's reload. Full reload clears the old cached kiosk version; punches are kept. |
| Check for app update now | Downloads and installs the newest build. |
| Open Wi-Fi / Android settings | Unlocks the tablet for **10 minutes**, then it locks again by itself (or on restart). |
| Screen schedule | Screen ON / OFF times (default 05:30 to 22:30). At night a worker can still press the power button to wake it. |
| Change exit passcode | |
| Restart tablet | |
| Remove full lock | Only before selling or replacing the tablet. |

Forgot the exit passcode: on the RSR Tablets page press **Open settings** for that tablet. The tablet opens
settings once, without the passcode, within about 1 minute.

## 8b. Replacing or resetting a tablet

Each tablet gets a secret from the server on its first start. After a factory reset or reinstall it has a new secret,
so first press **Forget tablet** for it on the RSR Tablets page; it registers again within a minute.

## 9. Updates

- **Kiosk page changes (rsr-engineering):** nothing to do. The tablet shows the new page like before.
- **App changes:** a new build appears in Releases by itself. Tablets install it between 00:30 and 04:30 when nobody
  is using the kiosk, or press **Update app** on the RSR Tablets page. Update, restart and reload are refused during
  punch rushes (6:50-8:15, 11:50-1:10, 4:50-6:10) and wait until nobody is mid-punch. No tapping on the tablet.

## 10. Roll-call phone (Motorola moto g power XT2515V, Wi-Fi only) - 2026-11-12

The yard roll-call phone runs the same RSR app, locked to the roll-call page. The app sees the roll-call
address and switches to **phone mode** by itself:
- the screen turns off after **1 minute** without a touch (battery lasts the day); the power button wakes it straight into roll-call, no lock screen;
- no screen schedule and no 10:01 / 3:00 / 7:10 wake-ups (those are for the kiosk tablets);
- Telegram (RSR Kiosk Alerts) only for **battery LOW 20%** and **CRITICAL 10%** (plus HOT 45 C / weak charger), sent when the phone is on Wi-Fi.
  No OFFLINE or NOT CHARGING alerts: it is offline in the yard on purpose. "Not synced by 7:30 PM" and
  "not seen 2 days" come from the roll-call page itself.
- On the RSR Tablets page it shows as **"roll-call phone"**, grey (not red) when it is away from Wi-Fi.

### Before you start
1. On office Wi-Fi open roll-call on the Motorola and check the bar says **All sent ✓** (nothing waiting). The reset erases the phone.
2. Do it after the last roll-call of the day.

### Steps (same as sections 2-6, Motorola menus)
1. **Reset**: Settings > System > Reset options > **Erase all data (factory reset)**.
2. Welcome setup: connect to the **office Wi-Fi**; **skip** the Google account (and any Verizon / Motorola account screens). No account may be added.
3. **USB debugging**: Settings > About phone > tap **Build number** 7 times; Settings > System > Developer options > **USB debugging ON**; plug into the laptop, tap **Allow**.
4. On the laptop (PowerShell, `C:\platform-tools`), same as section 5:
   ```powershell
   .\adb devices
   .\adb install rsr-kiosk.apk
   .\adb shell dpm set-device-owner ph.rsr.kiosk/.AdminReceiver
   ```
   Expected last line: `Success: Device owner set to package ph.rsr.kiosk`.
5. Open **RSR Kiosk**. Name: `Carmen roll-call phone`. Exit passcode: 6-10 digits (keep it safe).
6. Open the hidden settings (tap the **top-right corner 5 times** quickly; on roll-call this may also open the Menu - that is fine), enter the exit passcode, and set
   **Kiosk page address** to
   `https://seafordprojects-bit.github.io/rsr-engineering/monitoring/roll-call.html?site=Carmen` and press **Save**.
7. On the PC: **Admin > Settings > Roll-call phones > reset Carmen** (the reset gave the phone a new ID, so the old registration must go first).
8. Roll-call opens on the phone. Sign in (carmen@ account) and type the **roll-call passcode** on office Wi-Fi. The phone becomes the Carmen roll-call phone again.
9. Unplug the cable; turn USB debugging OFF (hidden settings > Open Wi-Fi / Android settings > Developer options).

If this Motorola ran RSR Kiosk before (a second setup), press **Forget tablet** for it on the RSR Tablets page first (section 8b).

### Check (visual confirmation)
- Home, Back and Recents do nothing; the notification bar does not pull down.
- Leave it 1 minute: the screen turns off. Press power: roll-call is back, no lock screen.
- Roll-call shows **v2026-11-10a** and **All sent ✓**. Turn Wi-Fi off: it still opens and taps wait; Wi-Fi on: they send.
- RSR Tablets page: **Carmen roll-call phone - roll-call phone - Online**, with its battery %.

## Signing key (keep safe)

All builds are signed with one key. GitHub has it locked (secret `KEYSTORE_PASSWORD`). Keep the backup
`rsr-kiosk-signing-key.zip` on the NAS / Google Drive. If the key is lost, tablets cannot update anymore
and each must be reset and set up again.

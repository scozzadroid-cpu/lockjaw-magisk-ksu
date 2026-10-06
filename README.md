# 🔒 Lockjaw — anti-forensic USB lockdown for Magisk / KernelSU

**Lockjaw** clamps your phone shut the moment it locks. It is a **Magisk / KernelSU module**
that hardens a locked Android phone against physical data extraction (forensic tools such as
Cellebrite / GrayKey, malicious USB devices, ADB).

- 🔌 **USB lockdown while locked** — charging only, gadget soft-disconnected, OTG devices not authorized
- 🔁 **Inactivity reboot** — reboots to BFU after N hours without an unlock
- 🎛️ **Armed on demand** — installed disarmed; one tap on Action arms it (e.g. before a border
  crossing or a protest), another tap disarms it. Live status in the module description
- 🔋 **Battery friendly** — event driven, no wakelocks, no tight polling

> ⚠️ **Status: beta.** Lock/unlock detection is verified on a real device; USB cable tests
> (PC, charger, OTG) are in progress.

## Features

Every feature can be toggled in `/data/adb/physical_hardening/config`.

### a) USB lockdown while the screen is locked
When the screen locks:
- **`USB_LOCK`** — USB functions are set to charging only (`svc usb setFunctions`).
- **`USB_SOFT_DISCONNECT`** — the USB device controller is logically disconnected
  (`/sys/class/udc/*/soft_connect`): a PC does not see the phone at all, not even over ADB.
  Charging is not affected.
- **`USB_BLOCK_OTG`** — USB devices plugged *into* the phone (host/OTG mode) are not
  authorized (`usbcore.authorized_default=0`), so no driver (UVC, USB audio, HID, storage)
  binds to them. This is the attack surface used in the Cellebrite exploit chain documented by
  Amnesty International (CVE-2024-53104, CVE-2024-53197, CVE-2024-50302), especially relevant
  on devices running an unpatched kernel. OTG is blocked as soon as the module starts at boot,
  before Android finishes booting.
- **`ADB_LOCK`** — ADB (USB and wireless debugging) is turned off while locked, only if it was on.
  An `adb shell` session ends when the phone locks.

The soft-disconnect is applied only after the USB gadget has settled, because the USB HAL
re-binds the controller when functions change, and a re-bind turns the connection back on.
It is re-checked on every event and on every cable plug/unplug (`battery_status`).

On unlock, the previous state is restored. As with GrapheneOS and Android 16 Advanced Protection,
an accessory plugged in while locked works only after you unlock and replug it.

### b) Inactivity reboot
- **`INACTIVITY_REBOOT` / `INACTIVITY_HOURS`** (default 18 h): if the phone is not unlocked
  for N hours it reboots. After a reboot the file-based encryption (FBE) keys are not in memory
  until you enter your PIN (BFU state).
- Time is measured with the system clock, not by counting sleep cycles.
- **`WAKE_ALARM`**: the deadline is also programmed into the RTC (`/sys/class/rtc/rtc0/wakealarm`),
  so the phone wakes up and reboots on time even in deep sleep (for example in a Faraday bag, with
  no network and no other wake-ups). On every wake-up the module only compares the clock with
  the deadline and does a full check once it has passed.
- Since April 2025 Google Play services also reboots phones locked for 72 h. Lockjaw's shorter,
  configurable threshold is independent of it.
- **Never** reboots in BFU state (`sys.user.0.ce_available`), so no reboot loops;
  **never** during a phone call; never with less than 10 minutes of uptime.
- `INACTIVITY_TEST_MINUTES` is for testing only (set it back to 0).

## Action button and live description
- The module is installed **disarmed**: nothing is locked down and nothing reboots.
- The **Action** button (Magisk 28+ / KernelSU) arms or disarms it. The state persists across
  reboots, including the inactivity reboot: an armed phone comes back armed (and in BFU).
- The module description shows the current state, for example:
  `🟢 ARMED [USB+OTG+ADB, reboot 18h] 🔒 locked, USB data OFF, reboot after 28/09 19:40`

## How it works
- Lock/unlock is detected through **events** (`logcat -b events`: `screen_toggled`,
  `wm_set_keyguard_shown`, `battery_status`), used only as a wake-up trigger; the real state is always read from
  `dumpsys trust` (`deviceLocked`). If the state is uncertain, USB stays locked.
- Fallback check every `CHECK_INTERVAL` seconds (default 300).
- Nothing in `/system` is modified.

### Battery
Measured: the listener process uses ~10 ms of CPU per minute and ~2.7 MB of RAM.
It does not prevent deep sleep and never wakes the phone by itself.

## Installation
1. Download the zip from the *Releases* page.
2. Install it from Magisk / KernelSU → Modules → Install from storage.
3. Reboot. The config is created on first boot and **kept** across updates.

Requirements: Magisk 20.4+ (Action button: Magisk 28+) or KernelSU; an Android kernel exposing
`/sys/class/udc` and `usbcore` (the installer warns if they are missing).

## Configuration
```ini
USB_LOCK=1               # charging-only USB while locked
USB_BLOCK_OTG=1          # OTG devices not authorized while locked
USB_SOFT_DISCONNECT=1    # USB controller disconnected from the PC while locked
ADB_LOCK=1               # ADB off while locked, restored on unlock
INACTIVITY_REBOOT=1
INACTIVITY_HOURS=18
INACTIVITY_TEST_MINUTES=0
WAKE_ALARM=1             # RTC alarm so the reboot happens on time in deep sleep
CHECK_INTERVAL=300
```
Changes are picked up on the next event, no reboot needed (`WAKE_ALARM` and the escape hatch:
press Action twice).

### Escape hatch (broken screen)
`ESCAPE_PRESSES` / `ESCAPE_SECONDS` (off by default): pressing the power key that many times
within that many seconds disarms the module and vibrates, so USB and ADB come back (for example to
control the phone with scrcpy from an already authorized PC). Pick your own values on the device
(10-60 presses, 2-30 seconds); they live only in your local config, not in this repository.
Only the power key input device is read, never the touchscreen.

> ⚠️ Turn off **Emergency SOS** first (Settings → Safety & emergency → Emergency SOS, or the
> Personal Safety app on Pixel): from Android 12 five quick power presses start an emergency call.
Configs from older versions get the new keys appended automatically. Set `USB_BLOCK_OTG=0` if you use
USB-C headphones or other accessories plugged in while the phone is locked.

## Disabling and troubleshooting
| Method | How |
|---|---|
| Action button | Magisk/KernelSU → module → Action (disarm) |
| Escape hatch | power key sequence configured in `ESCAPE_PRESSES` / `ESCAPE_SECONDS` |
| Kill switch | `touch /data/adb/physical_hardening/disable` (on the next event the service stops and restores USB) |
| Safe mode | Boot into safe mode → Magisk disables all modules on the next boot |
| ADB (if authorized) | `adb shell su -c magisk --remove-modules` |
| Recovery with /data access | create `/data/adb/modules/physical_hardening/disable` |
| Uninstall | remove the module: `uninstall.sh` restores USB and deletes `/data/adb/physical_hardening` |

Short rotating log (64 KB, no personal data): `/data/adb/physical_hardening/log`.

Manual test without starting the service:
```sh
su -c sh /data/adb/modules/physical_hardening/service.sh test status   # show state
su -c sh /data/adb/modules/physical_hardening/service.sh test lock     # apply USB lockdown
su -c sh /data/adb/modules/physical_hardening/service.sh test unlock   # restore
```

## Keywords
magisk module · kernelsu module · ksu · root · android hardening · android security ·
anti-forensics · anti forensic · cellebrite · cellebrite ufed · graykey · forensic extraction ·
usb restricted mode · usb lockdown · usb data block · otg block · usb host · adb hardening ·
bfu · afu · before first unlock · inactivity reboot · auto reboot · lockdown mode ·
file-based encryption · fbe · CVE-2024-53104 · CVE-2024-53197 · CVE-2024-50302 ·
privacy · physical access

## License
[GPL-3.0](LICENSE) © scozzadroid-cpu

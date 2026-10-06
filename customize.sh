#!/system/bin/sh
# Lockjaw (physical_hardening) - installer
ui_print "- Lockjaw: anti-forensic USB lockdown"
[ -d /sys/class/udc ] || ui_print "! /sys/class/udc missing: USB data lockdown will not be available"
[ -w /sys/module/usbcore/parameters/authorized_default ] || ui_print "! usbcore.authorized_default not writable: OTG blocking will not be available"
ls /sys/class/rtc/rtc*/wakealarm >/dev/null 2>&1 || ui_print "! no RTC wakealarm: the inactivity reboot may be late while the phone is in deep sleep"
D=/data/adb/physical_hardening
if [ -f "$D/config" ]; then
  ui_print "- Existing configuration and armed/disarmed state kept"
else
  # first install: start DISARMED, the user arms it with the Action button
  mkdir -p "$D" && chmod 700 "$D" && touch "$D/disable"
  ui_print "- Installed DISARMED. Configuration created on first boot: $D/config"
fi
ui_print "- Action button: arm / disarm (the state survives reboots)"
set_perm_recursive "$MODPATH" 0 0 0755 0644

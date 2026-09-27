#!/system/bin/sh
# Lockjaw (physical_hardening) - installer
ui_print "- Lockjaw: anti-forensic USB lockdown"
[ -d /sys/class/udc ] || ui_print "! /sys/class/udc missing: USB data lockdown will not be available"
[ -w /sys/module/usbcore/parameters/authorized_default ] || ui_print "! usbcore.authorized_default not writable: OTG blocking will not be available"
if [ -f /data/adb/physical_hardening/config ]; then
  ui_print "- Existing configuration kept: /data/adb/physical_hardening/config"
else
  ui_print "- Configuration will be created on first boot: /data/adb/physical_hardening/config"
fi
ui_print "- Action button: enable/disable the module"
set_perm_recursive "$MODPATH" 0 0 0755 0644

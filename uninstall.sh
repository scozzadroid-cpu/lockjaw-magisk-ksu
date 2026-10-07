#!/system/bin/sh
# Lockjaw (physical_hardening) - uninstall.sh: stop the service, restore USB, remove data
PATH=/system/bin:/system/xbin:$PATH
D=/data/adb/physical_hardening
RUN=$D/run

touch "$D/disable" 2>/dev/null
for f in logcat_pid pid; do
    [ -f "$RUN/$f" ] && kill "$(cat "$RUN/$f")" 2>/dev/null
done

# restore USB (safe even if it was not locked)
for u in /sys/class/udc/*; do
    case "$u" in *dummy*) continue ;; esac
    [ -e "$u/soft_connect" ] && echo connect > "$u/soft_connect" 2>/dev/null
done
echo -1 > /sys/module/usbcore/parameters/authorized_default 2>/dev/null
for b in /sys/bus/usb/devices/usb*; do [ -e "$b/authorized_default" ] && echo 1 > "$b/authorized_default" 2>/dev/null; done
for r in /sys/class/rtc/rtc*; do [ -w "$r/wakealarm" ] && { echo 0 > "$r/wakealarm" 2>/dev/null; break; }; done

# ADB was turned off by the module while locked: adb_enabled is persistent, so turn it
# back on. Removal usually runs during boot, before the settings service exists.
if [ -f "$RUN/adb_off" ]; then
    if [ "$(getprop sys.boot_completed)" = "1" ]; then
        settings put global adb_enabled 1 >/dev/null 2>&1
    else
        (until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
         settings put global adb_enabled 1 >/dev/null 2>&1) </dev/null >/dev/null 2>&1 &
    fi
fi

rm -rf "$D"

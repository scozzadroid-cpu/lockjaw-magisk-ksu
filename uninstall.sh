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

rm -rf "$D"

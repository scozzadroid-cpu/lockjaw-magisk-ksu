#!/system/bin/sh
# Lockjaw (physical_hardening) - action.sh (Magisk/KernelSU "Action" button): arm/disarm the module
MODDIR=${0%/*}
D=/data/adb/physical_hardening
if [ -f "$D/disable" ]; then
    echo "- State: DISARMED -> arming..."
    if sh "$MODDIR/service.sh" on; then
        echo "- ARMED: USB locked down while the screen is locked, inactivity reboot enabled."
        echo "  It stays armed across reboots until you press Action again."
    else
        echo "! Start not confirmed: check $D/log"
    fi
else
    echo "- State: ARMED -> disarming..."
    sh "$MODDIR/service.sh" off
    echo "- DISARMED: USB restored, no automatic reboot."
    echo "  It stays disarmed across reboots until you press Action again."
fi
sed -n 's/^description=/- /p' "$MODDIR/module.prop"

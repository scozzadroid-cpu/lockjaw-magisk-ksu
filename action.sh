#!/system/bin/sh
# Lockjaw (physical_hardening) - action.sh (Magisk/KernelSU "Action" button): enable/disable the module
MODDIR=${0%/*}
D=/data/adb/physical_hardening
if [ -f "$D/disable" ]; then
    echo "- State: DISABLED -> enabling..."
    if sh "$MODDIR/service.sh" on; then
        echo "- Module ACTIVE: USB locked down while the screen is locked, inactivity reboot enabled."
    else
        echo "! Start not confirmed: check $D/log"
    fi
else
    echo "- State: ACTIVE -> disabling..."
    sh "$MODDIR/service.sh" off
    echo "- Module DISABLED: USB restored, no automatic reboot."
    echo "  It stays disabled across reboots until you press Action again."
fi
sed -n 's/^description=/- /p' "$MODDIR/module.prop"

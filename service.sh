#!/system/bin/sh
# Lockjaw (physical_hardening) - service.sh
# a) USB data + host/OTG disabled while the screen is locked, restored on unlock
# b) reboot if the phone is not unlocked for N hours (never in BFU, never during a call)
#
# Detection: logcat events (events buffer) are used ONLY as a wake-up trigger;
# the real state is always read from `dumpsys trust` (deviceLocked, user 0).

PATH=/system/bin:/system/xbin:$PATH
MODDIR=${0%/*}
PROP=$MODDIR/module.prop
D=/data/adb/physical_hardening
CFG=$D/config
LOG=$D/log
RUN=$D/run
# first real gadget controller (skips dummy_udc)
UDC=""
for u in /sys/class/udc/*; do case "$u" in *dummy*) continue ;; esac; UDC=$u; break; done
AUTH=/sys/module/usbcore/parameters/authorized_default

mkdir -p "$RUN"
chmod 700 "$D"

# ---------- rotating log (max ~64 KB, 1 history file) ----------
log() {
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        mv -f "$LOG" "$LOG.1"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ---------- dynamic description (this module's own module.prop only) ----------
set_desc() {
    [ -f "$PROP" ] || return
    grep -qxF "description=$*" "$PROP" && return
    { grep -v '^description=' "$PROP"; echo "description=$*"; } > "$PROP.tmp" && mv -f "$PROP.tmp" "$PROP"
}

hm() { date -d "@$1" '+%d/%m %H:%M' 2>/dev/null; }

update_desc() {
    if [ -f "$D/disable" ]; then
        set_desc "🔴 DISABLED - press Action to enable. USB lockdown and inactivity reboot are off."
        return
    fi
    feat=""
    [ "$USB_LOCK" = 1 ] && feat="USB" || feat="USB off"
    [ "$USB_BLOCK_OTG" = 1 ] && feat="$feat+OTG"
    if [ "$INACTIVITY_REBOOT" = 1 ]; then
        if [ "$INACTIVITY_TEST_MINUTES" -gt 0 ] 2>/dev/null; then r="reboot ${INACTIVITY_TEST_MINUTES}min (TEST)"; else r="reboot ${INACTIVITY_HOURS}h"; fi
    else
        r="reboot off"
    fi
    last=$(cat "$RUN/last_unlock" 2>/dev/null)
    if [ -f "$RUN/usb_locked" ] || [ "$1" = locked ]; then
        stato="🔒 locked"
        [ "$USB_LOCK" = 1 ] && stato="$stato, USB data OFF"
        if [ "$INACTIVITY_REBOOT" = 1 ] && [ -n "$last" ]; then
            stato="$stato, reboot after $(hm $((last + LIMIT)))"
        fi
    else
        stato="🔓 unlocked, USB normal"
    fi
    [ "$(getprop sys.user.0.ce_available)" = "true" ] || stato="⏳ BFU (not unlocked since boot)"
    set_desc "🟢 ACTIVE [$feat, $r] $stato. Action = disable."
}

# ---------- configuration ----------
write_default_cfg() {
    cat > "$CFG" <<'EOF'
# Lockjaw (physical_hardening) - configuration (1=on, 0=off)
# Changes are re-read on every event/check, no reboot needed.

# a) Charging-only USB while the screen is locked
USB_LOCK=1
# a) Host/OTG: USB devices plugged in while locked are NOT authorized
#    (no UVC/audio/HID/storage driver binds). Side effect: USB accessories
#    (USB-C DAC headphones, flash drives, keyboards) plugged in while locked do not
#    work until you unlock and replug them. Already connected ones keep working.
USB_BLOCK_OTG=1
# a) Soft-disconnect the USB gadget (D+ pull-up) while locked: a PC does not see
#    the phone at all, not even over ADB. Charging is not affected.
USB_SOFT_DISCONNECT=1

# b) Inactivity reboot
INACTIVITY_REBOOT=1
INACTIVITY_HOURS=18
# Testing only: if > 0 it overrides INACTIVITY_HOURS (in minutes). Set back to 0.
INACTIVITY_TEST_MINUTES=0

# Fallback periodic check interval, in seconds of awake time (min 60)
CHECK_INTERVAL=300
EOF
    chmod 600 "$CFG"
}

load_cfg() {
    USB_LOCK=1; USB_BLOCK_OTG=1; USB_SOFT_DISCONNECT=1
    INACTIVITY_REBOOT=1; INACTIVITY_HOURS=18; INACTIVITY_TEST_MINUTES=0
    CHECK_INTERVAL=300
    [ -f "$CFG" ] || write_default_cfg
    # only KEY=number lines are read (no code is executed from the file)
    eval "$(grep -E '^[A-Z_]+=[0-9]+[[:space:]]*$' "$CFG")"
    [ "$CHECK_INTERVAL" -lt 60 ] 2>/dev/null && CHECK_INTERVAL=60
    [ "$INACTIVITY_HOURS" -lt 1 ] 2>/dev/null && INACTIVITY_HOURS=1
    if [ "$INACTIVITY_TEST_MINUTES" -gt 0 ] 2>/dev/null; then
        LIMIT=$((INACTIVITY_TEST_MINUTES * 60))
    else
        LIMIT=$((INACTIVITY_HOURS * 3600))
    fi
}

# ---------- device state ----------
# 0 = locked, 1 = unlocked, 2 = unknown (treated as locked for USB)
lock_state() {
    l=$(dumpsys trust 2>/dev/null | grep -E '\(id=0,' | grep -oE 'deviceLocked=[01]' | head -1)
    case "$l" in
        deviceLocked=1) return 0 ;;
        deviceLocked=0) return 1 ;;
        *) return 2 ;;
    esac
}

screen_on() {
    dumpsys power 2>/dev/null | grep -q 'mWakefulness=Awake'
}

in_call() {
    dumpsys telephony.registry 2>/dev/null | grep -E 'mCallState=[12]' >/dev/null
}

usb_functions() {
    svc usb getFunctions 2>/dev/null | tail -n 1 | tr -d '\r'
}

# real USB host buses (skips the internal dummy_hcd)
host_buses() {
    for b in /sys/bus/usb/devices/usb*; do
        [ -e "$b/authorized_default" ] || continue
        case "$(readlink -f "$b")" in *dummy_hcd*) continue ;; esac
        echo "$b"
    done
}

# ---------- a) USB ----------
apply_lock() {
    [ "$USB_LOCK" = 1 ] || return
    [ -f "$RUN/usb_locked" ] && return
    f=$(usb_functions)
    case "$f" in mtp|ptp|rndis|midi|ncm|none|"") ;; *) f=none ;; esac
    echo "$f" > "$RUN/usb_prev"
    svc usb setFunctions "" >/dev/null 2>&1
    if [ "$USB_BLOCK_OTG" = 1 ] && [ -w "$AUTH" ]; then
        cat "$AUTH" > "$RUN/auth_prev"
        echo 0 > "$AUTH"
        for b in $(host_buses); do echo 0 > "$b/authorized_default"; done
    fi
    if [ "$USB_SOFT_DISCONNECT" = 1 ] && [ -e "$UDC/soft_connect" ]; then
        echo disconnect > "$UDC/soft_connect" 2>/dev/null
        touch "$RUN/udc_off"
    fi
    touch "$RUN/usb_locked"
    log "LOCK usb: functions=charging otg_auth=$(cat "$AUTH" 2>/dev/null) udc=$([ -f "$RUN/udc_off" ] && echo off || echo on) (before: $f)"
}

restore_usb() {
    [ -f "$RUN/usb_locked" ] || return
    if [ -f "$RUN/udc_off" ]; then
        echo connect > "$UDC/soft_connect" 2>/dev/null
        rm -f "$RUN/udc_off"
    fi
    if [ -f "$RUN/auth_prev" ]; then
        a=$(cat "$RUN/auth_prev"); case "$a" in -1|0|1|2) ;; *) a=-1 ;; esac
        echo "$a" > "$AUTH"
        for b in $(host_buses); do echo 1 > "$b/authorized_default"; done
        rm -f "$RUN/auth_prev"
    fi
    f=$(cat "$RUN/usb_prev" 2>/dev/null)
    case "$f" in mtp|ptp|rndis|midi|ncm) svc usb setFunctions "$f" >/dev/null 2>&1 ;; esac
    rm -f "$RUN/usb_locked" "$RUN/usb_prev"
    log "UNLOCK usb: restored otg_auth=$(cat "$AUTH" 2>/dev/null) functions=${f:-charging}"
}

# ---------- b) inactivity reboot ----------
# last_unlock = last moment (system clock) the phone was seen unlocked
mark_unlocked() { date +%s > "$RUN/last_unlock"; }

check_inactivity() {
    [ "$INACTIVITY_REBOOT" = 1 ] || return
    # never in BFU state (before first unlock): prevents reboot loops
    [ "$(getprop sys.user.0.ce_available)" = "true" ] || return
    now=$(date +%s)
    last=$(cat "$RUN/last_unlock" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) mark_unlocked; return ;; esac
    # clock went backwards: restart counting from now
    [ "$now" -lt "$last" ] && { mark_unlocked; return; }
    [ $((now - last)) -ge "$LIMIT" ] || return
    # re-check the real state right before acting
    lock_state; [ $? -eq 0 ] || return
    # minimum uptime 10 minutes (extra protection against loops)
    up=$(cut -d. -f1 /proc/uptime); [ "$up" -ge 600 ] || return
    if in_call; then
        log "INACTIVITY: threshold reached but a call is active, postponing"
        return
    fi
    log "INACTIVITY: no unlock for $(( (now - last) / 60 )) min (limit $((LIMIT / 60))), rebooting"
    rm -f "$RUN/last_unlock"
    sync
    svc power reboot inactivity >/dev/null 2>&1
    sleep 30
    reboot
}

# ---------- reconcile (called by events and timer) ----------
reconcile() {
    if [ -f "$D/disable" ]; then
        restore_usb
        update_desc
        log "kill switch present: stopping"
        return 9
    fi
    # avoid concurrent runs (events + timer)
    mkdir "$RUN/lk" 2>/dev/null || return 0
    load_cfg
    lock_state; s=$?
    if [ $s -eq 1 ]; then
        mark_unlocked
        restore_usb
        update_desc
    else
        apply_lock
        [ "$USB_LOCK" = 1 ] || restore_usb
        update_desc locked
        check_inactivity
    fi
    rmdir "$RUN/lk" 2>/dev/null
    return 0
}

# ---------- on / off (used by action.sh) ----------
svc_running() { [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; }

ctl_off() {
    touch "$D/disable"
    kill "$(cat "$RUN/logcat_pid" 2>/dev/null)" 2>/dev/null
    i=0; while svc_running && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
    svc_running && kill "$(cat "$RUN/pid")" 2>/dev/null
    rmdir "$RUN/lk" 2>/dev/null
    restore_usb
    update_desc
    log "DISABLED manually (Action)"
}

ctl_on() {
    rm -f "$D/disable"
    rmdir "$RUN/lk" 2>/dev/null
    log "ENABLED manually (Action)"
    setsid sh "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 &
    i=0; while ! svc_running && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
    svc_running
}

# ---------- control and manual test modes (do not start the service) ----------
# sh service.sh test lock|unlock|status|inactivity
case "$1" in
    on)  ctl_on; exit $? ;;
    off) ctl_off; exit 0 ;;
    toggle) if [ -f "$D/disable" ]; then ctl_on; exit $?; else ctl_off; exit 0; fi ;;
esac

if [ "$1" = "test" ]; then
    load_cfg
    case "$2" in
        lock)   apply_lock ;;
        unlock) restore_usb ;;
        inactivity) check_inactivity ;;
    esac
    lock_state; s=$?
    echo "deviceLocked=$([ $s -eq 0 ] && echo 1 || echo 0) (code $s) screen=$(screen_on && echo on || echo off) call=$(in_call && echo yes || echo no)"
    echo "ce_available=$(getprop sys.user.0.ce_available) usb_functions=$(usb_functions) authorized_default=$(cat "$AUTH")"
    for b in $(host_buses); do echo "  $b authorized_default=$(cat "$b/authorized_default")"; done
    echo "service=$(svc_running && echo running || echo stopped) disable=$([ -f "$D/disable" ] && echo yes || echo no)"
    echo "usb_locked=$([ -f "$RUN/usb_locked" ] && echo yes || echo no) last_unlock=$(cat "$RUN/last_unlock" 2>/dev/null) now=$(date +%s) limit_s=$LIMIT"
    exit 0
fi

# ---------- startup ----------
if [ -f "$D/disable" ]; then update_desc; exit 0; fi
set_desc "⏳ Starting: waiting for sys.boot_completed..."
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
if [ -f "$D/disable" ]; then update_desc; exit 0; fi

# single instance
if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then exit 0; fi
echo $$ > "$RUN/pid"

# runtime state from the previous boot is stale (the kernel starts with defaults)
rm -f "$RUN/usb_locked" "$RUN/usb_prev" "$RUN/auth_prev" "$RUN/udc_off" "$RUN/last_unlock"
rmdir "$RUN/lk" 2>/dev/null
load_cfg
log "start v1.0 (BFU=$([ "$(getprop sys.user.0.ce_available)" = true ] && echo no || echo yes))"
reconcile

# fallback timer (awake seconds; it pauses in deep sleep, but every
# wake-up - cable, power key, notification - still generates an event)
(
    while :; do
        sleep "$CHECK_INTERVAL"
        if ! reconcile; then
            kill "$(cat "$RUN/logcat_pid" 2>/dev/null)" 2>/dev/null
            exit 0
        fi
    done
) &
TIMER=$!

# event loop: wakes only on screen on/off and keyguard changes.
# If logcat exits (e.g. logd restart) it is restarted.
FIFO=$RUN/events
while [ ! -f "$D/disable" ]; do
    rm -f "$FIFO"; mkfifo -m 600 "$FIFO"
    logcat -b events -T 1 -s wm_set_keyguard_shown:I screen_toggled:I > "$FIFO" 2>/dev/null &
    echo $! > "$RUN/logcat_pid"
    while read -r line; do
        case "$line" in
            *wm_set_keyguard_shown*|*screen_toggled*)
                sleep 1
                reconcile || { kill "$(cat "$RUN/logcat_pid")" 2>/dev/null; break; }
                # keyguard hidden but state still "locked": re-check after 2 s
                case "$line" in
                    *wm_set_keyguard_shown*\[0,0,*)
                        if [ -f "$RUN/usb_locked" ]; then sleep 2; reconcile; fi ;;
                esac
                ;;
        esac
    done < "$FIFO"
    [ -f "$D/disable" ] || { log "logcat exited, restarting listener"; sleep 10; }
done

kill "$TIMER" 2>/dev/null
kill "$(cat "$RUN/logcat_pid" 2>/dev/null)" 2>/dev/null
rm -f "$RUN/pid" "$RUN/logcat_pid" "$FIFO"

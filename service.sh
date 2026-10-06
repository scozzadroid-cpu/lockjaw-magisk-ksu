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
for u in /sys/class/udc/*; do case "$u" in *dummy*) continue ;; esac; [ -e "$u" ] && { UDC=$u; break; }; done
AUTH=/sys/module/usbcore/parameters/authorized_default
# RTC able to wake the device from deep sleep (used for the inactivity deadline)
RTC=""
for r in /sys/class/rtc/rtc*; do [ -w "$r/wakealarm" ] && { RTC=$r; break; }; done
VER=$(sed -n 's/^version=//p' "$PROP" 2>/dev/null)

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
    [ "$ADB_LOCK" = 1 ] && feat="$feat+ADB"
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
# a) Turn off ADB (USB and wireless debugging) while locked, restored on unlock.
#    Only acts if ADB was enabled. Note: an adb shell session ends when the phone locks.
ADB_LOCK=1

# b) Inactivity reboot
INACTIVITY_REBOOT=1
INACTIVITY_HOURS=18
# Testing only: if > 0 it overrides INACTIVITY_HOURS (in minutes). Set back to 0.
INACTIVITY_TEST_MINUTES=0
# b) Program the RTC alarm so the deadline is honored even in deep sleep
#    (e.g. phone left untouched with no network). Applied on the next start.
WAKE_ALARM=1

# Fallback periodic check interval, in seconds of awake time (min 60)
CHECK_INTERVAL=300
EOF
    chmod 600 "$CFG"
}

load_cfg() {
    USB_LOCK=1; USB_BLOCK_OTG=1; USB_SOFT_DISCONNECT=1; ADB_LOCK=1
    INACTIVITY_REBOOT=1; INACTIVITY_HOURS=18; INACTIVITY_TEST_MINUTES=0; WAKE_ALARM=1
    CHECK_INTERVAL=300
    [ -f "$CFG" ] || write_default_cfg
    # configs created by older versions: add the new keys with their defaults
    grep -q '^ADB_LOCK=' "$CFG" || printf '\n# a) Turn off ADB (USB and wireless debugging) while locked, restored on unlock\nADB_LOCK=1\n' >> "$CFG"
    grep -q '^WAKE_ALARM=' "$CFG" || printf '\n# b) RTC alarm so the inactivity deadline is honored in deep sleep\nWAKE_ALARM=1\n' >> "$CFG"
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
# Gadget reconfiguration (setFunctions, adb toggle) is asynchronous: the USB HAL
# unbinds and re-binds the UDC, and a re-bind turns the D+ pull-up back on.
# So the soft-disconnect is applied only after the gadget has settled, and it is
# re-checked on every reconcile and on every cable plug event.
wait_usb_settled() {
    i=0
    while [ $i -lt 6 ]; do
        sleep 1
        st=$(getprop sys.usb.state); cf=$(getprop sys.usb.config)
        [ -n "$st" ] && [ "$st" = "$cf" ] && [ $i -ge 1 ] && return
        i=$((i+1))
    done
}

# true if a host can currently see the gadget (pull-up on)
udc_visible() {
    case "$(cat "$UDC/state" 2>/dev/null)" in
        "not attached"|"") return 1 ;;
        *) return 0 ;;
    esac
}

udc_disconnect() {
    [ "$USB_SOFT_DISCONNECT" = 1 ] && [ -n "$UDC" ] && [ -e "$UDC/soft_connect" ] || return
    # already applied and nobody re-enabled it: nothing to do (avoids kernel log noise)
    [ -f "$RUN/udc_off" ] && ! udc_visible && return
    if echo disconnect > "$UDC/soft_connect" 2>/dev/null; then
        [ -f "$RUN/udc_off" ] && log "UDC re-connected by the system, disconnected again"
        touch "$RUN/udc_off"
    else
        # no gadget bound at this moment (HAL reconfiguring): retry once
        sleep 2
        echo disconnect > "$UDC/soft_connect" 2>/dev/null && touch "$RUN/udc_off"
    fi
}

otg_block() {
    [ "$USB_BLOCK_OTG" = 1 ] && [ -w "$AUTH" ] || return
    if [ ! -f "$RUN/auth_prev" ]; then
        a=$(cat "$AUTH" 2>/dev/null); case "$a" in -1|0|1|2) ;; *) a=-1 ;; esac
        echo "$a" > "$RUN/auth_prev"
    fi
    # the module parameter covers buses created later (dwc3 creates the xHCI
    # host only when an OTG device is attached); existing buses are set directly
    echo 0 > "$AUTH" 2>/dev/null
    for b in $(host_buses); do echo 0 > "$b/authorized_default" 2>/dev/null; done
}

apply_lock() {
    [ "$USB_LOCK" = 1 ] || return
    otg_block
    if [ ! -f "$RUN/usb_locked" ]; then
        f=$(usb_functions)
        case "$f" in mtp|ptp|rndis|midi|ncm|none|"") ;; *) f=none ;; esac
        echo "$f" > "$RUN/usb_prev"
        if [ "$ADB_LOCK" = 1 ] && [ "$(settings get global adb_enabled 2>/dev/null)" = 1 ]; then
            settings put global adb_enabled 0 >/dev/null 2>&1
            touch "$RUN/adb_off"
        fi
        svc usb setFunctions "" >/dev/null 2>&1
        touch "$RUN/usb_locked"
        [ "$USB_SOFT_DISCONNECT" = 1 ] && [ -n "$UDC" ] && wait_usb_settled
        udc_disconnect
        log "LOCK usb: functions=charging otg_auth=$(cat "$AUTH" 2>/dev/null) udc=$([ -f "$RUN/udc_off" ] && echo off || echo on) adb=$([ -f "$RUN/adb_off" ] && echo off || echo unchanged) (before: $f)"
    else
        udc_disconnect
    fi
}

restore_usb() {
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
    if [ -f "$RUN/adb_off" ]; then
        settings put global adb_enabled 1 >/dev/null 2>&1
        rm -f "$RUN/adb_off"
    fi
    [ -f "$RUN/usb_locked" ] || return
    f=$(cat "$RUN/usb_prev" 2>/dev/null)
    case "$f" in mtp|ptp|rndis|midi|ncm) svc usb setFunctions "$f" >/dev/null 2>&1 ;; esac
    rm -f "$RUN/usb_locked" "$RUN/usb_prev"
    log "UNLOCK usb: restored otg_auth=$(cat "$AUTH" 2>/dev/null) functions=${f:-charging}"
}

# ---------- b) inactivity reboot ----------
# last_unlock = last moment (system clock) the phone was seen unlocked
mark_unlocked() { date +%s > "$RUN/last_unlock"; }

# RTC wake alarm at the given epoch (system clock); no argument = cancel.
# The RTC is written with a relative value, so its own time base does not matter.
arm_wake() {
    [ "$WAKE_ALARM" = 1 ] && [ -n "$RTC" ] || return
    if [ -z "$1" ]; then
        [ -f "$RUN/alarm" ] || return
        echo 0 > "$RTC/wakealarm" 2>/dev/null
        rm -f "$RUN/alarm"
        return
    fi
    [ "$(cat "$RUN/alarm" 2>/dev/null)" = "$1" ] && return
    rel=$(( $1 - $(date +%s) )); [ $rel -lt 60 ] && rel=60
    echo 0 > "$RTC/wakealarm" 2>/dev/null
    if echo "+$rel" > "$RTC/wakealarm" 2>/dev/null; then
        echo "$1" > "$RUN/alarm"
    else
        log "RTC wake alarm not accepted by $RTC, relying on natural wake-ups"
        RTC=""
    fi
}

check_inactivity() {
    if [ "$INACTIVITY_REBOOT" != 1 ] || [ "$(getprop sys.user.0.ce_available)" != "true" ]; then
        # never in BFU state (before first unlock): prevents reboot loops
        rm -f "$RUN/deadline"; arm_wake
        return
    fi
    now=$(date +%s)
    last=$(cat "$RUN/last_unlock" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) mark_unlocked; last=$now ;; esac
    # clock went backwards: restart counting from now
    [ "$now" -lt "$last" ] && { mark_unlocked; last=$now; }
    echo $((last + LIMIT)) > "$RUN/deadline"
    if [ $((now - last)) -lt "$LIMIT" ]; then
        arm_wake $((last + LIMIT + 5))
        return
    fi
    # threshold reached: if anything below postpones the reboot, try again in 10 min
    echo $((now + 600)) > "$RUN/deadline"
    arm_wake $((now + 600))
    # re-check the real state right before acting
    lock_state; [ $? -eq 0 ] || return
    # minimum uptime 10 minutes (extra protection against loops)
    up=$(cut -d. -f1 /proc/uptime); [ "$up" -ge 600 ] || return
    if in_call; then
        log "INACTIVITY: threshold reached but a call is active, postponing"
        return
    fi
    log "INACTIVITY: no unlock for $(( (now - last) / 60 )) min (limit $((LIMIT / 60))), rebooting"
    rm -f "$RUN/last_unlock" "$RUN/deadline"
    arm_wake
    sync
    svc power reboot inactivity >/dev/null 2>&1
    sleep 30
    reboot
}

# ---------- reconcile (called by events and timer) ----------
# Waits for a concurrent run instead of skipping it, so an unlock event is never
# lost while the timer (or another event) is reconciling.
take_lock() {
    i=0
    until mkdir "$RUN/lk" 2>/dev/null; do
        i=$((i+1)); [ $i -ge 20 ] && return 1
        t=$(stat -c %Y "$RUN/lk" 2>/dev/null) || { sleep 1; continue; }
        # stale lock left by a killed run
        if [ $(( $(date +%s) - t )) -gt 60 ] || [ $(( t - $(date +%s) )) -gt 60 ]; then
            rmdir "$RUN/lk" 2>/dev/null; continue
        fi
        sleep 1
    done
}

reconcile() {
    if [ -f "$D/disable" ]; then
        restore_usb
        rm -f "$RUN/deadline"; arm_wake
        update_desc
        log "kill switch present: stopping"
        return 9
    fi
    take_lock || return 0
    load_cfg
    lock_state; s=$?
    if [ $s -eq 1 ]; then
        mark_unlocked
        restore_usb
        rm -f "$RUN/deadline"; arm_wake
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

stop_listeners() {
    for p in logcat_pid dmesg_pid; do
        kill "$(cat "$RUN/$p" 2>/dev/null)" 2>/dev/null
    done
}

ctl_off() {
    touch "$D/disable"
    stop_listeners
    i=0; while svc_running && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
    svc_running && kill "$(cat "$RUN/pid")" 2>/dev/null
    rmdir "$RUN/lk" 2>/dev/null
    load_cfg
    restore_usb
    rm -f "$RUN/deadline"; arm_wake
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
    echo "udc=${UDC:-none} udc_state=$(cat "$UDC/state" 2>/dev/null) adb_enabled=$(settings get global adb_enabled 2>/dev/null)"
    echo "rtc=${RTC:-none} wakealarm=$(cat "$RTC/wakealarm" 2>/dev/null) deadline=$(cat "$RUN/deadline" 2>/dev/null)"
    echo "service=$(svc_running && echo running || echo stopped) disable=$([ -f "$D/disable" ] && echo yes || echo no)"
    echo "usb_locked=$([ -f "$RUN/usb_locked" ] && echo yes || echo no) last_unlock=$(cat "$RUN/last_unlock" 2>/dev/null) now=$(date +%s) limit_s=$LIMIT"
    exit 0
fi

# ---------- startup ----------
if [ -f "$D/disable" ]; then update_desc; exit 0; fi

# single instance
if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then exit 0; fi
echo $$ > "$RUN/pid"

# runtime state from the previous boot is stale (the kernel starts with defaults).
# adb_off is kept: adb_enabled is a persistent setting and must still be restored.
rm -f "$RUN/usb_locked" "$RUN/usb_prev" "$RUN/auth_prev" "$RUN/udc_off" "$RUN/last_unlock" \
      "$RUN/deadline" "$RUN/alarm"
rmdir "$RUN/lk" 2>/dev/null
load_cfg
# a leftover RTC alarm from the previous boot is not ours any more
[ "$WAKE_ALARM" = 1 ] && [ -n "$RTC" ] && echo 0 > "$RTC/wakealarm" 2>/dev/null
# the device is locked (BFU) during boot: block OTG right away, before Android is up
[ "$USB_LOCK" = 1 ] && otg_block

set_desc "⏳ Starting: waiting for sys.boot_completed..."
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
if [ -f "$D/disable" ]; then load_cfg; restore_usb; update_desc; rm -f "$RUN/pid"; exit 0; fi

log "start ${VER:-v?} (BFU=$([ "$(getprop sys.user.0.ce_available)" = true ] && echo no || echo yes) rtc=${RTC:-none} udc=${UDC:-none})"
reconcile

# fallback timer (awake seconds; it pauses in deep sleep, but every
# wake-up - cable, power key, notification - still generates an event)
(
    while :; do
        sleep "$CHECK_INTERVAL"
        if ! reconcile; then
            stop_listeners
            exit 0
        fi
    done
) &
TIMER=$!

# resume watcher: the kernel prints "PM: suspend exit" on every wake-up from deep
# sleep, including the RTC alarm armed for the inactivity deadline. Only a cheap
# deadline comparison runs here; a full reconcile happens only once it has passed.
WATCHER=""
if [ "$INACTIVITY_REBOOT" = 1 ] && [ "$WAKE_ALARM" = 1 ]; then
    (
        KFIFO=$RUN/kmsg
        while [ ! -f "$D/disable" ]; do
            rm -f "$KFIFO"; mkfifo -m 600 "$KFIFO"
            dmesg -w > "$KFIFO" 2>/dev/null &
            echo $! > "$RUN/dmesg_pid"
            n=0
            while read -r line; do
                n=1
                case "$line" in
                    *"PM: suspend exit"*)
                        dl=$(cat "$RUN/deadline" 2>/dev/null)
                        case "$dl" in ''|*[!0-9]*) continue ;; esac
                        [ "$(date +%s)" -ge "$dl" ] || continue
                        # keep the CPU awake while checking, or it may suspend again mid-run
                        echo lockjaw > /sys/power/wake_lock 2>/dev/null
                        reconcile
                        echo lockjaw > /sys/power/wake_unlock 2>/dev/null
                        ;;
                esac
            done < "$KFIFO"
            if [ $n = 0 ] && [ ! -f "$D/disable" ]; then
                log "dmesg -w not usable, resume watcher off (timer and events still active)"
                break
            fi
            [ -f "$D/disable" ] || sleep 30
        done
        rm -f "$KFIFO" "$RUN/dmesg_pid"
    ) &
    WATCHER=$!
fi

# event loop: wakes only on screen on/off, keyguard changes and charger plug/unplug
# (battery_status). If logcat exits (e.g. logd restart) it is restarted.
FIFO=$RUN/events
while [ ! -f "$D/disable" ]; do
    rm -f "$FIFO"; mkfifo -m 600 "$FIFO"
    logcat -b events -T 1 -s wm_set_keyguard_shown:I screen_toggled:I battery_status:I > "$FIFO" 2>/dev/null &
    echo $! > "$RUN/logcat_pid"
    while read -r line; do
        case "$line" in
            *wm_set_keyguard_shown*|*screen_toggled*|*battery_status*)
                sleep 1
                reconcile || { stop_listeners; break; }
                case "$line" in
                    # keyguard hidden but state still "locked": re-check after 2 s
                    *wm_set_keyguard_shown*\[0,0,*)
                        if [ -f "$RUN/usb_locked" ]; then sleep 2; reconcile; fi ;;
                    # cable plugged while locked: the HAL may re-bind the gadget late
                    *battery_status*)
                        if [ -f "$RUN/usb_locked" ]; then sleep 3; reconcile; fi ;;
                esac
                ;;
        esac
    done < "$FIFO"
    [ -f "$D/disable" ] || { log "logcat exited, restarting listener"; sleep 10; }
done

kill "$TIMER" $WATCHER 2>/dev/null
stop_listeners
rm -f "$RUN/pid" "$RUN/logcat_pid" "$RUN/dmesg_pid" "$FIFO" "$RUN/kmsg"

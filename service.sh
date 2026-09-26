#!/system/bin/sh
# physical_hardening - service.sh
# a) USB dati + host/OTG disattivati a schermo bloccato, ripristino allo sblocco
# b) riavvio se il telefono non viene sbloccato per N ore (mai in BFU, mai in chiamata)
#
# Rilevamento: eventi logcat (buffer events) usati SOLO come "sveglia";
# lo stato reale viene sempre letto da `dumpsys trust` (deviceLocked, user 0).

PATH=/system/bin:/system/xbin:$PATH
MODDIR=${0%/*}
PROP=$MODDIR/module.prop
D=/data/adb/physical_hardening
CFG=$D/config
LOG=$D/log
RUN=$D/run
# primo controller gadget reale (esclude dummy_udc)
UDC=""
for u in /sys/class/udc/*; do case "$u" in *dummy*) continue ;; esac; UDC=$u; break; done
AUTH=/sys/module/usbcore/parameters/authorized_default

mkdir -p "$RUN"
chmod 700 "$D"

# ---------- log a rotazione (max ~64 KB, 1 file di storico) ----------
log() {
    if [ -f "$LOG" ] && [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -gt 65536 ]; then
        mv -f "$LOG" "$LOG.1"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

# ---------- descrizione dinamica (solo il module.prop di questo modulo) ----------
set_desc() {
    [ -f "$PROP" ] || return
    grep -qxF "description=$*" "$PROP" && return
    { grep -v '^description=' "$PROP"; echo "description=$*"; } > "$PROP.tmp" && mv -f "$PROP.tmp" "$PROP"
}

hm() { date -d "@$1" '+%d/%m %H:%M' 2>/dev/null; }

update_desc() {
    if [ -f "$D/disable" ]; then
        set_desc "🔴 DISATTIVATO - premi Azione per riattivare. USB e riavvio per inattivita' non protetti."
        return
    fi
    feat=""
    [ "$USB_LOCK" = 1 ] && feat="USB" || feat="USB off"
    [ "$USB_BLOCK_OTG" = 1 ] && feat="$feat+OTG"
    if [ "$INACTIVITY_REBOOT" = 1 ]; then
        if [ "$INACTIVITY_TEST_MINUTES" -gt 0 ] 2>/dev/null; then r="riavvio ${INACTIVITY_TEST_MINUTES}min (TEST)"; else r="riavvio ${INACTIVITY_HOURS}h"; fi
    else
        r="riavvio off"
    fi
    last=$(cat "$RUN/last_unlock" 2>/dev/null)
    if [ -f "$RUN/usb_locked" ] || [ "$1" = locked ]; then
        stato="🔒 bloccato"
        [ "$USB_LOCK" = 1 ] && stato="$stato, USB dati OFF"
        if [ "$INACTIVITY_REBOOT" = 1 ] && [ -n "$last" ]; then
            stato="$stato, riavvio dal $(hm $((last + LIMIT)))"
        fi
    else
        stato="🔓 sbloccato, USB normale"
    fi
    [ "$(getprop sys.user.0.ce_available)" = "true" ] || stato="⏳ BFU (mai sbloccato dal boot)"
    set_desc "🟢 ATTIVO [$feat, $r] $stato. Azione = disattiva."
}

# ---------- configurazione ----------
write_default_cfg() {
    cat > "$CFG" <<'EOF'
# physical_hardening - configurazione (1=attivo, 0=disattivo)
# Le modifiche vengono rilette ad ogni evento/controllo, senza riavvio.

# a) Blocco USB a schermo bloccato
USB_LOCK=1
# a) Host/OTG: i dispositivi USB collegati a schermo bloccato NON vengono autorizzati
#    (nessun driver UVC/audio/HID/storage si aggancia). Effetto collaterale: accessori
#    USB (cuffie USB-C con DAC, chiavette, tastiere) collegati a schermo bloccato non
#    funzionano finche' non sblocchi e li ricolleghi. Quelli gia' collegati restano attivi.
USB_BLOCK_OTG=1
# a) Stacca il gadget USB (pull-up D+) a schermo bloccato: il PC non vede il telefono
#    neanche per ADB. La ricarica non e' influenzata.
USB_SOFT_DISCONNECT=1

# b) Riavvio per inattivita'
INACTIVITY_REBOOT=1
INACTIVITY_HOURS=18
# Solo per test: se > 0 sostituisce INACTIVITY_HOURS (in minuti). Rimettere a 0.
INACTIVITY_TEST_MINUTES=0

# Intervallo del controllo periodico di riserva, in secondi di veglia (min 60)
CHECK_INTERVAL=300
EOF
    chmod 600 "$CFG"
}

load_cfg() {
    USB_LOCK=1; USB_BLOCK_OTG=1; USB_SOFT_DISCONNECT=1
    INACTIVITY_REBOOT=1; INACTIVITY_HOURS=18; INACTIVITY_TEST_MINUTES=0
    CHECK_INTERVAL=300
    [ -f "$CFG" ] || write_default_cfg
    # legge solo righe CHIAVE=numero (nessun codice eseguito dal file)
    eval "$(grep -E '^[A-Z_]+=[0-9]+[[:space:]]*$' "$CFG")"
    [ "$CHECK_INTERVAL" -lt 60 ] 2>/dev/null && CHECK_INTERVAL=60
    [ "$INACTIVITY_HOURS" -lt 1 ] 2>/dev/null && INACTIVITY_HOURS=1
    if [ "$INACTIVITY_TEST_MINUTES" -gt 0 ] 2>/dev/null; then
        LIMIT=$((INACTIVITY_TEST_MINUTES * 60))
    else
        LIMIT=$((INACTIVITY_HOURS * 3600))
    fi
}

# ---------- stato del dispositivo ----------
# 0 = bloccato, 1 = sbloccato, 2 = sconosciuto (trattato come bloccato per l'USB)
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

# bus USB host reali (esclude il dummy_hcd interno)
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
    log "LOCK usb: funzioni=charging otg_auth=$(cat "$AUTH" 2>/dev/null) udc=$([ -f "$RUN/udc_off" ] && echo off || echo on) (prima: $f)"
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
    log "UNLOCK usb: ripristinato otg_auth=$(cat "$AUTH" 2>/dev/null) funzioni=${f:-charging}"
}

# ---------- b) riavvio per inattivita' ----------
# last_unlock = ultimo istante (orologio di sistema) in cui il telefono e' stato visto sbloccato
mark_unlocked() { date +%s > "$RUN/last_unlock"; }

check_inactivity() {
    [ "$INACTIVITY_REBOOT" = 1 ] || return
    # mai in stato BFU (prima del primo sblocco): evita riavvii a catena
    [ "$(getprop sys.user.0.ce_available)" = "true" ] || return
    now=$(date +%s)
    last=$(cat "$RUN/last_unlock" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) mark_unlocked; return ;; esac
    # orologio tornato indietro: riparte da ora
    [ "$now" -lt "$last" ] && { mark_unlocked; return; }
    [ $((now - last)) -ge "$LIMIT" ] || return
    # ricontrolla lo stato reale subito prima di agire
    lock_state; [ $? -eq 0 ] || return
    # uptime minimo 10 minuti (protezione extra contro cicli)
    up=$(cut -d. -f1 /proc/uptime); [ "$up" -ge 600 ] || return
    if in_call; then
        log "INATTIVITA': soglia superata ma chiamata attiva, rinvio"
        return
    fi
    log "INATTIVITA': nessuno sblocco da $(( (now - last) / 60 )) min (limite $((LIMIT / 60))), riavvio"
    rm -f "$RUN/last_unlock"
    sync
    svc power reboot inactivity >/dev/null 2>&1
    sleep 30
    reboot
}

# ---------- riconciliazione (chiamata da eventi e timer) ----------
reconcile() {
    if [ -f "$D/disable" ]; then
        restore_usb
        update_desc
        log "kill switch presente: stop"
        return 9
    fi
    # evita esecuzioni concorrenti (eventi + timer)
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

# ---------- accensione / spegnimento (usato da action.sh) ----------
svc_running() { [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; }

ctl_off() {
    touch "$D/disable"
    kill "$(cat "$RUN/logcat_pid" 2>/dev/null)" 2>/dev/null
    i=0; while svc_running && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
    svc_running && kill "$(cat "$RUN/pid")" 2>/dev/null
    rmdir "$RUN/lk" 2>/dev/null
    restore_usb
    update_desc
    log "DISATTIVATO manualmente (Azione)"
}

ctl_on() {
    rm -f "$D/disable"
    rmdir "$RUN/lk" 2>/dev/null
    log "RIATTIVATO manualmente (Azione)"
    setsid sh "$MODDIR/service.sh" </dev/null >/dev/null 2>&1 &
    i=0; while ! svc_running && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
    svc_running
}

# ---------- modalita' test manuale (non avvia il servizio) ----------
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
    echo "deviceLocked=$([ $s -eq 0 ] && echo 1 || echo 0) (codice $s) schermo=$(screen_on && echo on || echo off) chiamata=$(in_call && echo si || echo no)"
    echo "ce_available=$(getprop sys.user.0.ce_available) funzioni_usb=$(usb_functions) authorized_default=$(cat "$AUTH")"
    for b in $(host_buses); do echo "  $b authorized_default=$(cat "$b/authorized_default")"; done
    echo "servizio=$(svc_running && echo attivo || echo fermo) disable=$([ -f "$D/disable" ] && echo si || echo no)"
    echo "usb_locked=$([ -f "$RUN/usb_locked" ] && echo si || echo no) last_unlock=$(cat "$RUN/last_unlock" 2>/dev/null) ora=$(date +%s) limite_s=$LIMIT"
    exit 0
fi

# ---------- avvio ----------
if [ -f "$D/disable" ]; then update_desc; exit 0; fi
set_desc "⏳ In avvio: attendo sys.boot_completed..."
until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
if [ -f "$D/disable" ]; then update_desc; exit 0; fi

# istanza singola
if [ -f "$RUN/pid" ] && kill -0 "$(cat "$RUN/pid")" 2>/dev/null; then exit 0; fi
echo $$ > "$RUN/pid"

# stato runtime del boot precedente non piu' valido (il kernel riparte con i default)
rm -f "$RUN/usb_locked" "$RUN/usb_prev" "$RUN/auth_prev" "$RUN/udc_off" "$RUN/last_unlock"
rmdir "$RUN/lk" 2>/dev/null
load_cfg
log "avvio v1.0 (BFU=$([ "$(getprop sys.user.0.ce_available)" = true ] && echo no || echo si))"
reconcile

# timer di riserva (secondi di veglia; in deep sleep si ferma ma
# ogni risveglio - cavo, tasto, notifica - genera comunque un evento)
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

# ciclo a eventi: si sveglia solo su accensione/spegnimento schermo e keyguard.
# Se logcat termina (es. riavvio di logd) viene rilanciato.
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
                # keyguard nascosto ma stato ancora "bloccato": ricontrolla dopo 2 s
                case "$line" in
                    *wm_set_keyguard_shown*\[0,0,*)
                        if [ -f "$RUN/usb_locked" ]; then sleep 2; reconcile; fi ;;
                esac
                ;;
        esac
    done < "$FIFO"
    [ -f "$D/disable" ] || { log "logcat terminato, riavvio ascolto"; sleep 10; }
done

kill "$TIMER" 2>/dev/null
kill "$(cat "$RUN/logcat_pid" 2>/dev/null)" 2>/dev/null
rm -f "$RUN/pid" "$RUN/logcat_pid" "$FIFO"

#!/system/bin/sh
# physical_hardening - action.sh (tasto "Azione" in Magisk): attiva/disattiva il modulo
MODDIR=${0%/*}
D=/data/adb/physical_hardening
if [ -f "$D/disable" ]; then
    echo "- Stato: DISATTIVATO -> riattivo..."
    if sh "$MODDIR/service.sh" on; then
        echo "- Modulo ATTIVO: USB bloccata a schermo bloccato, riavvio per inattivita' abilitato."
    else
        echo "! Avvio non confermato: controlla $D/log"
    fi
else
    echo "- Stato: ATTIVO -> disattivo..."
    sh "$MODDIR/service.sh" off
    echo "- Modulo DISATTIVATO: USB ripristinata, nessun riavvio automatico."
    echo "  Resta disattivato anche dopo il riavvio finche' non premi di nuovo Azione."
fi
sed -n 's/^description=/- /p' "$MODDIR/module.prop"

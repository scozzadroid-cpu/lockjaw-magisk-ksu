#!/system/bin/sh
# physical_hardening - installazione
ui_print "- Physical Hardening"
[ -d /sys/class/udc ] || ui_print "! /sys/class/udc assente: il blocco USB dati non sara' disponibile"
[ -w /sys/module/usbcore/parameters/authorized_default ] || ui_print "! usbcore.authorized_default non scrivibile: blocco OTG non disponibile"
if [ -f /data/adb/physical_hardening/config ]; then
  ui_print "- Configurazione esistente mantenuta: /data/adb/physical_hardening/config"
else
  ui_print "- Configurazione creata al primo avvio: /data/adb/physical_hardening/config"
fi
ui_print "- Tasto Azione: attiva/disattiva il modulo"
set_perm_recursive "$MODPATH" 0 0 0755 0644

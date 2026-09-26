# 🔒 Lockjaw — anti-forensic USB lockdown per Magisk / KernelSU

**Lockjaw** serra il telefono appena si blocca: modulo **Magisk / KernelSU** contro l'estrazione di dati con accesso fisico al telefono bloccato
(strumenti forensi tipo Cellebrite/GrayKey, attacchi via USB e ADB).

> **English:** Lockjaw is a Magisk/KernelSU module that disables USB data and USB host (OTG) device
> authorization while the screen is locked, and reboots the phone after N hours without
> an unlock (pushing it back to BFU state). Toggle with the module **Action** button.

> ⚠️ **Stato: beta.** Rilevamento blocco/sblocco verificato su dispositivo reale; i test con
> cavo USB (PC, caricatore, OTG) sono ancora in corso. Usalo sapendo cosa fa.

## Funzioni

Ogni funzione si attiva/disattiva da `/data/adb/physical_hardening/config`.

### a) USB bloccata a schermo bloccato
Al blocco dello schermo:
- **`USB_LOCK`** — funzioni USB impostate su "solo ricarica" (`svc usb setFunctions`).
- **`USB_SOFT_DISCONNECT`** — il controller USB si "stacca" logicamente dal PC
  (`/sys/class/udc/*/soft_connect`): il PC non vede il telefono, nemmeno via ADB.
  La ricarica non è influenzata.
- **`USB_BLOCK_OTG`** — i dispositivi USB collegati *al* telefono (modalità host/OTG) non
  vengono autorizzati (`usbcore.authorized_default=0`): nessun driver (UVC, audio USB, HID,
  storage) si aggancia. È il vettore usato nella catena Cellebrite documentata da Amnesty
  International (CVE-2024-53104, CVE-2024-53197, CVE-2024-50302), utile soprattutto su
  kernel non aggiornati.

Allo sblocco lo stato precedente viene ripristinato.

### b) Riavvio per inattività
- **`INACTIVITY_REBOOT` / `INACTIVITY_HOURS`** (default 18 h): se il telefono non viene
  sbloccato per N ore, viene riavviato. Dopo il riavvio le chiavi di cifratura (FBE) non sono
  in memoria finché non inserisci il PIN (stato BFU).
- Il tempo è misurato con l'orologio di sistema, non contando i cicli di attesa.
- **Mai** riavvio in stato BFU (`sys.user.0.ce_available`), quindi niente riavvii a catena;
  **mai** durante una chiamata; mai con meno di 10 minuti di uptime.
- `INACTIVITY_TEST_MINUTES` serve solo per provarlo (rimettere a 0).

## Tasto Azione e descrizione dinamica
- Il tasto **Azione** (Magisk 28+ / KernelSU) attiva o disattiva il modulo. Lo stato
  disattivato persiste ai riavvii.
- La descrizione del modulo mostra lo stato attuale, ad esempio:
  `🟢 ATTIVO [USB+OTG, riavvio 18h] 🔒 bloccato, USB dati OFF, riavvio dal 28/09 19:40`

## Come funziona
- Blocco/sblocco rilevati a **eventi** (`logcat -b events`: `screen_toggled`,
  `wm_set_keyguard_shown`), usati solo come "sveglia"; lo stato reale è sempre letto da
  `dumpsys trust` (`deviceLocked`). Se lo stato è incerto, l'USB resta bloccata.
- Controllo di riserva ogni `CHECK_INTERVAL` secondi (default 300).
- Nessun file di `/system` modificato, nessun wakelock.

### Batteria
Misurato: il processo in ascolto usa ~10 ms di CPU al minuto e ~2,7 MB di RAM.
Non impedisce il sonno profondo e non sveglia il telefono da solo.

## Installazione
1. Scarica lo zip dalla pagina *Releases* (o crea uno zip del contenuto del repository).
2. Installa da Magisk / KernelSU → Moduli → Installa da archivio.
3. Riavvia. Il config viene creato al primo avvio e **mantenuto** negli aggiornamenti.

Requisiti: Magisk 20.4+ (tasto Azione: Magisk 28+) oppure KernelSU; Android con
`/sys/class/udc` e `usbcore` (il modulo avvisa in installazione se mancano).

## Disattivazione e problemi
| Metodo | Come |
|---|---|
| Tasto Azione | Magisk/KernelSU → modulo → Azione |
| Kill switch | `touch /data/adb/physical_hardening/disable` (al primo evento il servizio si ferma e ripristina l'USB) |
| Modalità provvisoria | Avvio in safe mode → Magisk disabilita tutti i moduli al boot successivo |
| ADB (se autorizzato) | `adb shell su -c magisk --remove-modules` |
| Recovery con accesso a /data | crea `/data/adb/modules/physical_hardening/disable` |
| Disinstallazione | rimuovi il modulo: `uninstall.sh` ripristina l'USB e cancella `/data/adb/physical_hardening` |

Log sintetico a rotazione (64 KB, nessun dato personale): `/data/adb/physical_hardening/log`.

Test manuale senza avviare il servizio:
```sh
su -c sh /data/adb/modules/physical_hardening/service.sh test status   # stato
su -c sh /data/adb/modules/physical_hardening/service.sh test lock     # applica blocco USB
su -c sh /data/adb/modules/physical_hardening/service.sh test unlock   # ripristina
```

## Cosa NON copre
- **Bootloader sbloccato**: chi ha il telefono può avviare un'immagine modificata. Nessun
  modulo può compensarlo.
- **Finestra di boot**: prima di `sys.boot_completed` il modulo non è ancora attivo
  (l'USB ha il comportamento di default del sistema).
- **Enumerazione USB di base**: con OTG bloccato il kernel legge comunque i descrittori del
  dispositivo; sono bloccati i driver, non il core USB.
- **Riavvio per inattività in sonno profondo**: il controllo avviene al primo risveglio dopo
  la soglia (cavo collegato, tasto, notifiche, risvegli periodici del sistema), non al
  secondo esatto.
- Attacchi hardware (chip-off, glitching), exploit del bootloader/baseband, Bluetooth/Wi-Fi/NFC.
- Non sostituisce: PIN/password lungo, aggiornamenti di sicurezza, Lockdown.

## Opzioni del config
```ini
USB_LOCK=1               # solo ricarica a schermo bloccato
USB_BLOCK_OTG=1          # dispositivi OTG non autorizzati a schermo bloccato
USB_SOFT_DISCONNECT=1    # controller USB staccato dal PC a schermo bloccato
INACTIVITY_REBOOT=1
INACTIVITY_HOURS=18
INACTIVITY_TEST_MINUTES=0
CHECK_INTERVAL=300
```
Le modifiche sono lette ad ogni evento, senza riavvio. `USB_BLOCK_OTG=0` se usi cuffie
USB-C o altri accessori collegati a schermo bloccato.

## Parole chiave
magisk module · kernelsu module · ksu · root · android hardening · android security ·
anti-forensics · anti forensic · cellebrite · cellebrite ufed · graykey · forensic extraction ·
usb restricted mode · usb lockdown · usb data block · otg block · usb host · adb hardening ·
bfu · afu · before first unlock · inactivity reboot · auto reboot · lockdown mode ·
file-based encryption · fbe · CVE-2024-53104 · CVE-2024-53197 · CVE-2024-50302 ·
privacy · physical access · protezione usb · schermo bloccato · riavvio per inattività

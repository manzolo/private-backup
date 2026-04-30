# PrivateBackup

Script Bash per il backup di file e cartelle private, con supporto a:

- backup remoti via **SSH + tar** (nessun `rsync` richiesto sul remoto)
- **cifratura GPG AES256** con password chiesta a runtime
- **restore selettivo** (file singoli, cartelle, host remoti specifici)
- **upload su Google Drive** tramite rclone
- interfaccia TUI con `dialog` (fallback testuale automatico)

---

## Installazione

```bash
# Clona il repository
git clone https://github.com/<tuo-utente>/private-backup.git
cd private-backup

# Rendi lo script eseguibile
chmod +x private_backup.sh

# Crea la directory di configurazione e copia l'esempio
mkdir -p ~/.config/privatebackup
cp private_backup.conf.example ~/.config/privatebackup/private_backup.conf

# Modifica il config con i tuoi percorsi e host
$EDITOR ~/.config/privatebackup/private_backup.conf
```

## Dipendenze

| Tool | Uso | Obbligatorio |
|------|-----|:---:|
| `tar` | creazione e estrazione archivi | ✅ |
| `sha256sum` | verifica integrità | ✅ |
| `ssh` | accesso agli host remoti | solo con remoti |
| `gpg` | cifratura/decifratura AES256 | solo se `BACKUP_ENCRYPT=true` |
| `rclone` | upload su Google Drive | solo per upload |
| `dialog` | interfaccia TUI | no (fallback testuale) |

---

## Avvio

```bash
bash private_backup.sh
```

Menu principale:

```
1) Backup
2) Restore
3) Upload su Google Drive (rclone)
4) Backup + Upload
5) Scompatta archivio
6) Visualizza snapshot dimensioni cartelle
7) Esplora backup
0) Esci
```

---

## Configurazione

Il file di configurazione si trova in `~/.config/privatebackup/private_backup.conf`. Vedi [`private_backup.conf.example`](private_backup.conf.example) per un template commentato.

### File e cartelle locali

```bash
BACKUP_ITEMS=(
    "${HOME}/.ssh"
    "${HOME}/.gnupg"
    "${HOME}/.config/myapp"
    "${HOME}/.bashrc"
)
```

### Ricerca automatica di sottocartelle

Trova ricorsivamente tutte le sottocartelle con un dato nome sotto una directory base. Utile per includere automaticamente nuove cartelle senza modificare il config.

```bash
BACKUP_FIND_DIRS=(
    "${HOME}/projects:.env"   # include tutte le dir ".env" dentro ~/projects
)
```

### Backup da host remoti via SSH

Non richiede `rsync` sul remoto — basta che siano disponibili `ssh` e `tar`.

```bash
SSH_KEY="${HOME}/.ssh/id_rsa"

BACKUP_REMOTE_ITEMS=(
    "root@server1.lan:/root/.env"
    "root@server1.lan:/root/myapp"
    "user@server2.lan:/etc/myconfig"
    # Formato: "user@host:/percorso/assoluto"
    # Funziona sia con file singoli che con directory intere
)
```

I file remoti vengono scaricati in una staging dir locale (`.remote_stage/`) e inclusi nell'archivio finale con la struttura originale dei percorsi preservata.

### Cifratura GPG

```bash
BACKUP_ENCRYPT=true   # false per disabilitare
```

Quando abilitata, la password viene chiesta a runtime (due volte per conferma) e **non viene mai salvata su disco**. L'archivio prodotto ha estensione `.tar.gz.gpg`.

### Destinazione e remote rclone

```bash
BACKUP_DEST_DIR="${HOME}/backups/private"
RCLONE_REMOTE_PATH="gdrive:Backup/private"
```

---

## Funzionalità

### 1 — Backup

1. Scarica i file da tutti gli host in `BACKUP_REMOTE_ITEMS` via `ssh + tar`
2. Aggiunge le directory trovate tramite `BACKUP_FIND_DIRS`
3. Crea un archivio compresso con timestamp:
   ```
   ~/backups/private/<hostname>_private_<timestamp>.tar.gz.gpg
   ~/backups/private/<hostname>_private_<timestamp>.tar.gz.gpg.sha256
   ```
4. Cifra con GPG AES256 se `BACKUP_ENCRYPT=true`
5. Calcola e salva il checksum SHA256
6. Elimina automaticamente gli archivi locali oltre i 7 più recenti

Percorsi inesistenti vengono saltati silenziosamente (con avviso a fine backup).

### 2 — Restore

#### Restore completo o selettivo

Con `dialog` puoi navigare il contenuto dell'archivio in modo gerarchico:

- `Apri` — entra nella cartella o mostra l'anteprima di un file
- `Segna` — aggiunge o rimuove file/cartelle dalla selezione
- `Fine` — conferma la selezione per il restore

Nel fallback testuale è disponibile l'elenco numerato classico con selezione manuale (es. `3`, `1,4,7`, `2-5`, `1-3,7`).

#### Destinazione restore locale

| Opzione | Destinazione | Note |
|---------|-------------|------|
| Posizione originale | `/` | Richiede conferma. Usa `sudo` se necessario |
| Cartella anteprima | `~/backups/private/restore/` | Sicura, per ispezionare prima di sovrascrivere |

#### Restore remoto

Se l'archivio contiene file scaricati da host remoti, viene proposto il ripristino sugli host originali. È possibile scegliere un singolo host o tutti.

```
Host disponibili per il ripristino:
   1) server1.lan                    (12 file)
   2) server2.lan                    (47 file)
   a) Tutti gli host
   0) Annulla
```

Il ripristino avviene tramite `tar | ssh`, senza richiedere rsync sul remoto.

### 3 — Upload su Google Drive

Carica l'archivio scelto su Google Drive tramite rclone. Sul remote viene mantenuto **sempre lo stesso file** (il precedente viene sovrascritto):

```
gdrive:Backup/private/<hostname>_private.tar.gz.gpg
gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256
```

Verifica dei file presenti sul remote:
```bash
rclone ls gdrive:Backup/private
```

### 4 — Backup + Upload

Esegue backup locale e upload in sequenza con un solo comando.

### 5 — Scompatta archivio

Decifra (se necessario) ed estrae un archivio scelto in una sottocartella dedicata dentro `~/backups/private/`. Utile per ispezionare il contenuto o estrarre file specifici manualmente.

### 7 — Esplora backup

Apre un archivio in sola lettura e permette di navigarlo con `dialog`:

- vista ad albero con navigazione su/giù nelle cartelle
- anteprima diretta dei file testuali
- riepilogo tipo/dimensione per file binari

---

## Restore da Google Drive

```bash
# Scarica l'archivio
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg ~/backups/private/
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256 ~/backups/private/

# Verifica integrità
sha256sum -c ~/backups/private/<hostname>_private.tar.gz.gpg.sha256

# Avvia lo script e scegli Restore (opzione 2)
bash private_backup.sh
```

---

## Note tecniche

- **Nessun rsync sul remoto**: il pull usa `ssh + tar` (pipeline `ssh host "tar -czf - -C / path"` → `tar -xzf -`), quindi basta che sul remoto siano presenti `ssh` e `tar`
- **Struttura percorsi preservata**: un file `/root/.env` da `server1.lan` finisce in `.remote_stage/server1.lan/root/.env` e viene ripristinato in `/root/.env` sull'host originale
- **Socket GPG ignorati**: `tar --warning=no-file-ignored` evita errori su file socket (`S.gpg-agent.*`) presenti nelle directory GPG
- **Permessi file remoti**: dopo il pull viene eseguito `chmod -R u+rwX` sulla staging dir per rendere leggibili e cancellabili file estratti con permessi restrittivi di root
- **Password con caratteri speciali**: la password viene passata a GPG tramite file descriptor (`--passphrase-fd 3`) con `--pinentry-mode loopback`, gestendo correttamente caratteri come `!`, `?`, `$`, ecc.

---

## Licenza

MIT

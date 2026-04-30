# PrivateBackup

[Italiano](#italiano) | [English](#english)

---

## Italiano

Script Bash per il backup di file e cartelle private, con supporto a:

- backup remoti via **SSH + tar** (nessun `rsync` richiesto sul remoto)
- **cifratura GPG AES256** con password chiesta a runtime
- **restore selettivo** di file, cartelle e host remoti
- **upload su Google Drive** tramite `rclone`
- interfaccia TUI con `dialog` e fallback testuale automatico

### Installazione

```bash
git clone https://github.com/manzolo/private-backup.git
cd private-backup

chmod +x private_backup.sh

mkdir -p ~/.config/manzolo
cp private_backup.conf.example ~/.config/manzolo/private_backup.conf

$EDITOR ~/.config/manzolo/private_backup.conf
```

### Dipendenze

| Tool | Uso | Obbligatorio |
|------|-----|:---:|
| `tar` | creazione ed estrazione archivi | `yes` |
| `sha256sum` | verifica integrita | `yes` |
| `ssh` | accesso agli host remoti | solo con remoti |
| `gpg` | cifratura/decifratura AES256 | solo se `BACKUP_ENCRYPT=true` |
| `rclone` | upload cloud | solo per upload |
| `dialog` | TUI | no |

### Avvio

```bash
bash private_backup.sh
```

Menu principale:

```text
1) Backup
2) Restore
3) Upload su Google Drive (rclone)
4) Backup + Upload
5) Scompatta archivio
6) Visualizza snapshot dimensioni cartelle
7) Esplora backup
0) Esci
```

### Configurazione

Il file di configurazione si trova in `~/.config/manzolo/private_backup.conf`. Vedi [`private_backup.conf.example`](private_backup.conf.example).

File e cartelle locali:

```bash
BACKUP_ITEMS=(
    "${HOME}/.ssh"
    "${HOME}/.gnupg"
    "${HOME}/.config/myapp"
    "${HOME}/.bashrc"
)
```

Ricerca automatica di sottocartelle:

```bash
BACKUP_FIND_DIRS=(
    "${HOME}/projects:.env"
)
```

Backup remoti via SSH:

```bash
SSH_KEY="${HOME}/.ssh/id_rsa"

BACKUP_REMOTE_ITEMS=(
    "root@server1.lan:/root/.env"
    "root@server1.lan:/root/myapp"
    "user@server2.lan:/etc/myconfig"
)
```

I file remoti vengono scaricati in `.remote_stage/` e inclusi nell'archivio mantenendo la struttura dei percorsi.

Recupero automatico file Docker remoti:

```bash
BACKUP_REMOTE_DOCKER_HOSTS=(
    "root@server1.lan"
    "root@server2.lan"
)

BACKUP_REMOTE_DOCKER_SEARCH_DIRS="/root /home /opt /srv /var/www"
```

Controllo compose locali non tracciati:

```bash
COMPOSE_WATCH_DIRS=(
    "${HOME}/projects"
    "${HOME}/docker"
)
```

Cifratura:

```bash
BACKUP_ENCRYPT=true
```

Destinazione e remote `rclone`:

```bash
BACKUP_DEST_DIR="${HOME}/backups/private"
RCLONE_REMOTE_PATH="gdrive:Backup/private"
```

### Funzionalita

`1. Backup`

1. Scarica i file da `BACKUP_REMOTE_ITEMS` via `ssh + tar`
2. Aggiunge le directory trovate tramite `BACKUP_FIND_DIRS`
3. Crea un archivio con timestamp
4. Cifra con GPG se `BACKUP_ENCRYPT=true`
5. Genera checksum SHA256
6. Mantiene solo gli ultimi 7 archivi locali

I percorsi inesistenti vengono saltati con avviso finale.

`2. Restore`

- Navigazione gerarchica con `dialog`
- Selezione manuale nel fallback testuale
- Ripristino in posizione originale oppure in `~/backups/private/restore/`
- Ripristino remoto via `tar | ssh` sugli host originali

`3. Upload su Google Drive`

Mantiene sempre lo stesso nome file sul remote:

```text
gdrive:Backup/private/<hostname>_private.tar.gz.gpg
gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256
```

Verifica:

```bash
rclone ls gdrive:Backup/private
```

`4. Backup + Upload`

Esegue backup locale e upload in sequenza.

`5. Scompatta archivio`

Estrae un archivio scelto in una sottocartella dedicata dentro `~/backups/private/`.

`6. Snapshot cartelle`

Genera `~/backups/private/folder_snapshot.html` con:

- albero locale/remoto
- dimensioni aggregate
- ricerca per nome o percorso completo
- risultati separati tra cartelle e file
- anteprima dei file testuali piccoli

Se c'e un display grafico disponibile, il file viene aperto automaticamente nel browser.

`7. Esplora backup`

Permette di navigare un archivio in sola lettura con anteprima file testuali e riepilogo dei file binari.

### Restore da Google Drive

```bash
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg ~/backups/private/
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256 ~/backups/private/

sha256sum -c ~/backups/private/<hostname>_private.tar.gz.gpg.sha256

bash private_backup.sh
```

### Note tecniche

- Nessun `rsync` sul remoto: il pull usa `ssh + tar`
- Struttura percorsi preservata per file remoti e restore remoto
- `BACKUP_REMOTE_DOCKER_HOSTS` cerca `.env`, `docker-compose*` e directory `.secrets` via `find`
- `COMPOSE_WATCH_DIRS` avvisa sui file compose locali non inclusi in `BACKUP_ITEMS`
- `tar --warning=no-file-ignored` evita errori sui socket GPG
- `chmod -R u+rwX` rende gestibili i file remoti estratti con permessi restrittivi
- la password GPG passa via file descriptor con `--pinentry-mode loopback`

### Licenza

MIT

---

## English

Bash script for backing up private files and folders, with support for:

- remote backups via **SSH + tar** with no `rsync` required on the remote host
- **AES256 GPG encryption** with password prompt at runtime
- **selective restore** of files, folders, and remote hosts
- **Google Drive upload** through `rclone`
- `dialog`-based TUI with automatic plain-text fallback

### Installation

```bash
git clone https://github.com/manzolo/private-backup.git
cd private-backup

chmod +x private_backup.sh

mkdir -p ~/.config/manzolo
cp private_backup.conf.example ~/.config/manzolo/private_backup.conf

$EDITOR ~/.config/manzolo/private_backup.conf
```

### Dependencies

| Tool | Purpose | Required |
|------|---------|:---:|
| `tar` | create and extract archives | `yes` |
| `sha256sum` | integrity verification | `yes` |
| `ssh` | access remote hosts | only for remote backups |
| `gpg` | AES256 encryption/decryption | only if `BACKUP_ENCRYPT=true` |
| `rclone` | cloud upload | only for uploads |
| `dialog` | TUI interface | no |

### Run

```bash
bash private_backup.sh
```

Main menu:

```text
1) Backup
2) Restore
3) Upload su Google Drive (rclone)
4) Backup + Upload
5) Scompatta archivio
6) Visualizza snapshot dimensioni cartelle
7) Esplora backup
0) Esci
```

### Configuration

The config file is located at `~/.config/manzolo/private_backup.conf`. See [`private_backup.conf.example`](private_backup.conf.example).

Local files and folders:

```bash
BACKUP_ITEMS=(
    "${HOME}/.ssh"
    "${HOME}/.gnupg"
    "${HOME}/.config/myapp"
    "${HOME}/.bashrc"
)
```

Automatic subfolder discovery:

```bash
BACKUP_FIND_DIRS=(
    "${HOME}/projects:.env"
)
```

Remote backups over SSH:

```bash
SSH_KEY="${HOME}/.ssh/id_rsa"

BACKUP_REMOTE_ITEMS=(
    "root@server1.lan:/root/.env"
    "root@server1.lan:/root/myapp"
    "user@server2.lan:/etc/myconfig"
)
```

Remote files are downloaded into `.remote_stage/` and packed while preserving their original path layout.

Automatic remote Docker file discovery:

```bash
BACKUP_REMOTE_DOCKER_HOSTS=(
    "root@server1.lan"
    "root@server2.lan"
)

BACKUP_REMOTE_DOCKER_SEARCH_DIRS="/root /home /opt /srv /var/www"
```

Warn about untracked local compose files:

```bash
COMPOSE_WATCH_DIRS=(
    "${HOME}/projects"
    "${HOME}/docker"
)
```

Encryption:

```bash
BACKUP_ENCRYPT=true
```

Destination and `rclone` remote:

```bash
BACKUP_DEST_DIR="${HOME}/backups/private"
RCLONE_REMOTE_PATH="gdrive:Backup/private"
```

### Features

`1. Backup`

1. Pulls files from `BACKUP_REMOTE_ITEMS` via `ssh + tar`
2. Adds directories discovered through `BACKUP_FIND_DIRS`
3. Creates a timestamped archive
4. Encrypts it with GPG if `BACKUP_ENCRYPT=true`
5. Generates a SHA256 checksum
6. Keeps only the latest 7 local archives

Missing paths are skipped and reported at the end.

`2. Restore`

- Hierarchical archive browsing with `dialog`
- Manual selection in text fallback mode
- Restore to original location or to `~/backups/private/restore/`
- Remote restore back to the original hosts via `tar | ssh`

`3. Google Drive Upload`

The remote always keeps a stable filename:

```text
gdrive:Backup/private/<hostname>_private.tar.gz.gpg
gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256
```

Check remote files:

```bash
rclone ls gdrive:Backup/private
```

`4. Backup + Upload`

Runs a local backup and uploads it immediately after.

`5. Extract Archive`

Decrypts if needed and extracts the selected archive into a dedicated folder inside `~/backups/private/`.

`6. Folder Snapshot`

Generates `~/backups/private/folder_snapshot.html` with:

- local and remote tree view
- aggregated sizes
- search by filename or full path
- separate folder/file result groups
- preview for small text files

If a graphical display is available, the HTML file is opened automatically in the browser.

`7. Browse Backup`

Opens an archive in read-only mode and lets you inspect text files or view a size/type summary for binary files.

### Restore from Google Drive

```bash
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg ~/backups/private/
rclone copy gdrive:Backup/private/<hostname>_private.tar.gz.gpg.sha256 ~/backups/private/

sha256sum -c ~/backups/private/<hostname>_private.tar.gz.gpg.sha256

bash private_backup.sh
```

### Technical notes

- No remote `rsync`: pull operations use `ssh + tar`
- Remote path structure is preserved for both backup and restore
- `BACKUP_REMOTE_DOCKER_HOSTS` discovers `.env`, `docker-compose*`, and `.secrets` directories via `find`
- `COMPOSE_WATCH_DIRS` warns about local compose files missing from `BACKUP_ITEMS`
- `tar --warning=no-file-ignored` avoids GPG socket errors
- `chmod -R u+rwX` makes extracted remote files manageable even with restrictive permissions
- the GPG password is passed through a file descriptor with `--pinentry-mode loopback`

### License

MIT

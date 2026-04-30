#!/usr/bin/env bash

# ============================================================
# private_backup.sh - Backup, restore e upload su Google Drive
# di file e cartelle private dell'utente
# Configurazione: ~/.config/manzolo/private_backup.conf
# ============================================================

# Caricamento configurazione
CONFIG_FILE="${HOME}/.config/manzolo/private_backup.conf"
DIALOG_BIN="$(command -v dialog 2>/dev/null || true)"

if [ ! -f "${CONFIG_FILE}" ]; then
    echo "❌ File di configurazione non trovato: ${CONFIG_FILE}"
    echo "   Crea il file con BACKUP_ITEMS, BACKUP_DEST_DIR e RCLONE_REMOTE_PATH."
    exit 1
fi

source "${CONFIG_FILE}"

# Variabili derivate dalla configurazione
HOSTNAME_SHORT="$(hostname)"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DEST_DIR}/${HOSTNAME_SHORT}_private_${TIMESTAMP}.tar.gz"
CHECKSUM_FILE="${BACKUP_FILE}.sha256"
LOG_FILE="${BACKUP_DEST_DIR}/private_backup.log"
RESTORE_PREVIEW_DIR="${BACKUP_DEST_DIR}/restore"
REMOTE_STAGE_DIR="${BACKUP_DEST_DIR}/.remote_stage"
# Nome fisso su Google Drive: sovrascrive sempre lo stesso file
# Se la cifratura è attiva l'estensione diventa .tar.gz.gpg
if [[ "${BACKUP_ENCRYPT:-false}" == "true" ]]; then
    REMOTE_ARCHIVE="${RCLONE_REMOTE_PATH}/${HOSTNAME_SHORT}_private.tar.gz.gpg"
    REMOTE_CHECKSUM="${RCLONE_REMOTE_PATH}/${HOSTNAME_SHORT}_private.tar.gz.gpg.sha256"
else
    REMOTE_ARCHIVE="${RCLONE_REMOTE_PATH}/${HOSTNAME_SHORT}_private.tar.gz"
    REMOTE_CHECKSUM="${RCLONE_REMOTE_PATH}/${HOSTNAME_SHORT}_private.tar.gz.sha256"
fi

# Creazione della directory di backup e del log, se non esistono
mkdir -p "${BACKUP_DEST_DIR}"
touch "${LOG_FILE}"

# Variabili TUI
USE_DIALOG=false
if [ -n "${DIALOG_BIN}" ] && [ -t 0 ] && [ -t 1 ]; then
    USE_DIALOG=true
fi

DIALOG_RESULT=""
SELECTED_BACKUP_FILE=""
PREPARED_WORK_ARCHIVE=""
PREPARED_TMP_FILE=""

cleanup_dialog_screen() {
    [ "${USE_DIALOG}" = true ] && clear
}

trap cleanup_dialog_screen EXIT

start_operation_screen() {
    clear
}

close_dialog_overlay() {
    [ "${USE_DIALOG}" = true ] && clear
}

dialog_msgbox() {
    local text="$1"
    local height="${2:-12}"
    local width="${3:-80}"
    if [ "${USE_DIALOG}" = true ]; then
        clear
        "${DIALOG_BIN}" --backtitle "PrivateBackup" --title "PrivateBackup" \
            --msgbox "$text" "$height" "$width"
    else
        echo "$text"
    fi
}

dialog_infobox() {
    local text="$1"
    local height="${2:-8}"
    local width="${3:-80}"
    if [ "${USE_DIALOG}" = true ]; then
        clear
        "${DIALOG_BIN}" --backtitle "PrivateBackup" --title "PrivateBackup" \
            --infobox "$text" "$height" "$width"
    else
        echo "$text"
    fi
}

dialog_menu() {
    local title="$1"
    local text="$2"
    local height="$3"
    local width="$4"
    local menu_height="$5"
    shift 5
    if [ "${USE_DIALOG}" = true ]; then
        local tmp_output
        tmp_output="$(mktemp /tmp/private_dialog_XXXXXX)" || return 1
        clear
        "${DIALOG_BIN}" --output-fd 3 --backtitle "PrivateBackup" --title "$title" \
            --menu "$text" "$height" "$width" "$menu_height" "$@" 3>"$tmp_output"
        local status=$?
        DIALOG_RESULT=""
        if [ $status -eq 0 ] || [ $status -eq 2 ] || [ $status -eq 3 ]; then
            DIALOG_RESULT="$(cat "$tmp_output")"
        fi
        rm -f "$tmp_output"
        return $status
    fi
    return 1
}

dialog_yesno() {
    local text="$1"
    local height="${2:-12}"
    local width="${3:-80}"
    if [ "${USE_DIALOG}" = true ]; then
        clear
        "${DIALOG_BIN}" --backtitle "PrivateBackup" --title "Conferma" \
            --yesno "$text" "$height" "$width"
        return $?
    fi
    read -r -p "${text} (s/n): " CONFIRM
    [[ "${CONFIRM,,}" == "s" ]]
}

dialog_inputbox() {
    local title="$1"
    local text="$2"
    local height="${3:-12}"
    local width="${4:-80}"
    local initial="${5:-}"
    if [ "${USE_DIALOG}" = true ]; then
        local tmp_output
        tmp_output="$(mktemp /tmp/private_dialog_XXXXXX)" || return 1
        clear
        "${DIALOG_BIN}" --output-fd 3 --backtitle "PrivateBackup" --title "$title" \
            --inputbox "$text" "$height" "$width" "$initial" 3>"$tmp_output"
        local status=$?
        DIALOG_RESULT=""
        if [ $status -eq 0 ]; then
            DIALOG_RESULT="$(cat "$tmp_output")"
        fi
        rm -f "$tmp_output"
        return $status
    fi
    read -r -p "${text}: " REPLY
    DIALOG_RESULT="$REPLY"
}

dialog_passwordbox() {
    local title="$1"
    local text="$2"
    local height="${3:-12}"
    local width="${4:-70}"
    if [ "${USE_DIALOG}" = true ]; then
        local tmp_output
        tmp_output="$(mktemp /tmp/private_dialog_XXXXXX)" || return 1
        clear
        "${DIALOG_BIN}" --output-fd 3 --insecure --backtitle "PrivateBackup" --title "$title" \
            --passwordbox "$text" "$height" "$width" 3>"$tmp_output"
        local status=$?
        DIALOG_RESULT=""
        if [ $status -eq 0 ]; then
            DIALOG_RESULT="$(cat "$tmp_output")"
        fi
        rm -f "$tmp_output"
        return $status
    fi
    read -r -s -p "${text}: " REPLY
    echo ""
    DIALOG_RESULT="$REPLY"
}

show_text_file() {
    local title="$1"
    local file="$2"
    local height="${3:-22}"
    local width="${4:-100}"
    if [ "${USE_DIALOG}" = true ]; then
        clear
        "${DIALOG_BIN}" --backtitle "PrivateBackup" --title "$title" \
            --textbox "$file" "$height" "$width"
    else
        cat "$file"
    fi
}

_pause_if_needed() {
    local text="${1:-Premi invio per continuare.}"
    read -r -n 1 -s -p "$text" _
    echo ""
}

show_error() {
    local text="$1"
    if [ "${USE_DIALOG}" = true ]; then
        dialog_msgbox "$text" 10 80
    else
        echo "$text"
    fi
}

_gpg_tmp_home() {
    local dir
    dir="$(mktemp -d /tmp/private_backup_gnupg_XXXXXX)" || return 1
    chmod 700 "$dir" 2>/dev/null || true
    printf '%s\n' "$dir"
}

gpg_decrypt_to_file() {
    local archive="$1"
    local output_file="$2"
    local tmp_home

    dialog_infobox "Decifratura archivio in corso...\n\n$(basename "$archive")" 8 70
    tmp_home="$(_gpg_tmp_home)" || return 1
    GNUPGHOME="$tmp_home" gpg --no-options --homedir "$tmp_home" \
        --decrypt --batch --pinentry-mode loopback --yes \
        --passphrase-fd 3 \
        --output "$output_file" "$archive" 2>>"${LOG_FILE}" \
        3< <(printf '%s' "$BACKUP_PASSWORD")
    local status=$?
    rm -rf "$tmp_home"
    close_dialog_overlay
    return $status
}

gpg_encrypt_file() {
    local input_file="$1"
    local output_file="$2"
    local tmp_home

    dialog_infobox "Cifratura archivio in corso...\n\n$(basename "$input_file")" 8 70
    tmp_home="$(_gpg_tmp_home)" || return 1
    GNUPGHOME="$tmp_home" gpg --no-options --homedir "$tmp_home" \
        --symmetric --cipher-algo AES256 --batch --pinentry-mode loopback \
        --passphrase-fd 3 \
        --output "$output_file" "$input_file" 2>>"${LOG_FILE}" \
        3< <(printf '%s' "$BACKUP_PASSWORD")
    local status=$?
    rm -rf "$tmp_home"
    close_dialog_overlay
    return $status
}

gpg_decrypt_to_stdout() {
    local archive="$1"
    local tmp_home

    # UI redirected to /dev/tty: this function runs inside a pipeline,
    # so anything on stdout would corrupt the decrypted stream.
    dialog_infobox "Verifica archivio in corso...\n\n$(basename "$archive")" 8 70 >/dev/tty 2>/dev/tty
    tmp_home="$(_gpg_tmp_home)" || return 1
    GNUPGHOME="$tmp_home" gpg --no-options --homedir "$tmp_home" \
        --decrypt --batch --pinentry-mode loopback --yes \
        --passphrase-fd 3 \
        "$archive" 2>>"${LOG_FILE}" \
        3< <(printf '%s' "$BACKUP_PASSWORD")
    local status=$?
    rm -rf "$tmp_home"
    close_dialog_overlay >/dev/tty 2>/dev/tty
    return $status
}

# ============================================================
# Funzione: chiedi_password
# Chiede la password una volta sola e la memorizza in BACKUP_PASSWORD
# ============================================================
chiedi_password() {
    # chiedi_password          → chiede due volte (backup/cifratura)
    # chiedi_password decrypt  → chiede una volta sola (restore/decifratura)
    [ -n "${BACKUP_PASSWORD:-}" ] && return 0
    local mode="${1:-}"
    if [ "$mode" = "decrypt" ]; then
        dialog_passwordbox "Password archivio" "Inserisci la password dell'archivio" || exit 1
        BACKUP_PASSWORD="$DIALOG_RESULT"
        if [ -z "$BACKUP_PASSWORD" ]; then
            echo "❌ Password non inserita."
            exit 1
        fi
        close_dialog_overlay
        return 0
    fi
    local password_confirm
    while true; do
        dialog_passwordbox "Cifratura backup" "Inserisci la password di cifratura" || exit 1
        BACKUP_PASSWORD="$DIALOG_RESULT"
        if [ -z "$BACKUP_PASSWORD" ]; then
            echo "❌ Password non inserita."
            exit 1
        fi
        dialog_passwordbox "Conferma password" "Ripeti la password di cifratura" || exit 1
        password_confirm="$DIALOG_RESULT"
        if [ "$BACKUP_PASSWORD" = "$password_confirm" ]; then
            close_dialog_overlay
            break
        fi
        show_error "❌ Le password non coincidono.\n\nRiprova."
    done
}

# ============================================================
# Funzione: recupera_remoti
# Scarica via SSH+tar i file da BACKUP_REMOTE_ITEMS nella staging dir locale
# (non richiede rsync sul host remoto, solo tar e ssh)
# ============================================================
recupera_remoti() {
    [[ -z "${BACKUP_REMOTE_ITEMS+x}" || ${#BACKUP_REMOTE_ITEMS[@]} -eq 0 ]] && return 0
    local ssh_opts=(-n -o ConnectTimeout=5 -o IdentitiesOnly=yes \
                    -i "${SSH_KEY:-${HOME}/.ssh/id_rsa}" \
                    -o StrictHostKeyChecking=no)
    local skipped=0

    # -n assicura che SSH non consumi lo stdin dello script (es. la password GPG)
    chmod -R u+rwX "${REMOTE_STAGE_DIR}" 2>/dev/null
    rm -rf "${REMOTE_STAGE_DIR}"
    echo "Recupero file da host remoti..."
    echo "$(date): Avvio recupero file remoti" >>"${LOG_FILE}"

    for item in "${BACKUP_REMOTE_ITEMS[@]}"; do
        local userhost="${item%%:*}"
        local remotepath="${item##*:}"
        local hostname="${userhost##*@}"
        local stagedir="${REMOTE_STAGE_DIR}/${hostname}"

        mkdir -p "$stagedir"
        echo "$userhost" > "${stagedir}/.userhost"

        # tar sul remoto crea l'archivio con percorso relativo a /,
        # tar locale lo estrae in stagedir mantenendo la struttura originale
        local rel_path="${remotepath#/}"
        ssh "${ssh_opts[@]}" "$userhost" \
            "tar -czf - -C / '${rel_path}'" 2>>"${LOG_FILE}" | \
            tar -xzf - -C "${stagedir}/" >>"${LOG_FILE}" 2>&1

        if [ "${PIPESTATUS[0]}" -eq 0 ]; then
            echo "  ✅ ${userhost}:${remotepath}"
        else
            echo "  ❗ Non raggiungibile: ${userhost}:${remotepath}"
            ((skipped++))
        fi
    done

    if [ -d "${REMOTE_STAGE_DIR}" ] && [ "$(ls -A "${REMOTE_STAGE_DIR}" 2>/dev/null)" ]; then
        # Garantisce che i file estratti da root remoto siano leggibili e cancellabili localmente
        chmod -R u+rwX "${REMOTE_STAGE_DIR}" 2>/dev/null
        VALID_INCLUDE_PATHS+=("${REMOTE_STAGE_DIR}")
        echo "$(date): Recupero remoto completato" >>"${LOG_FILE}"
    fi

    [ "$skipped" -gt 0 ] && echo "❗ ${skipped} item non raggiungibili (saltati nel backup)."
}

# ============================================================
# Funzione: _fmt_bytes (helper)
# Converte byte in formato leggibile (KiB/MiB/GiB)
# ============================================================
_fmt_bytes() {
    local b="${1:-0}"
    numfmt --to=iec-i --suffix=B "$b" 2>/dev/null || \
        awk -v b="$b" 'BEGIN{
            if (b>=1073741824)      printf "%.1f GiB", b/1073741824
            else if (b>=1048576)    printf "%.1f MiB", b/1048576
            else if (b>=1024)       printf "%.1f KiB", b/1024
            else                    printf "%d B",     b
        }'
}

# ============================================================
# Helper: escape minimo per valori stringa JSON
# ============================================================
_json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r//g'
}

# Legge e codifica in base64 un file testo <= 32KB; stampa nulla se binario o troppo grande
_read_text_content() {
    local fpath="$1" bytes="$2"
    [ -f "$fpath" ] && [ "${bytes:-0}" -le 32768 ] && [ "${bytes:-0}" -gt 0 ] || return
    [ "$(file -b --mime-encoding "$fpath" 2>/dev/null)" = "binary" ] && return
    base64 -w0 "$fpath" 2>/dev/null
}

# ============================================================
# Funzione: snapshot_cartelle
# Genera folder_snapshot.html: albero interattivo (stile Baobab)
# con le dimensioni di tutti i percorsi inclusi nel backup.
# Sovrascritta ad ogni backup.
# ============================================================
snapshot_cartelle() {
    local snapshot_file="${BACKUP_DEST_DIR}/folder_snapshot.html"
    local date_str archive_name total_bytes total_bytes_fmt
    local roots_json="" entries path_esc label_esc root_bytes is_dir bytes fpath fp_esc
    local path host_dir hostname userhost item rel

    date_str=$(date '+%d/%m/%Y %H:%M:%S')
    archive_name=$(basename "${BACKUP_FILE}")
    total_bytes=0

    # --- Percorsi locali ---
    for path in "${VALID_INCLUDE_PATHS[@]}"; do
        [[ "$path" == "${REMOTE_STAGE_DIR}"* ]] && continue
        [ -e "$path" ] || continue
        entries=""
        root_bytes=0
        while IFS=$'\t' read -r bytes fpath; do
            [ -n "$fpath" ] || continue
            bytes="${bytes:-0}"
            fp_esc="$(_json_escape "$fpath")"
            is_dir=0; [ -d "$fpath" ] && is_dir=1
            _cf=""; [ "$is_dir" -eq 0 ] && { _ct="$(_read_text_content "$fpath" "$bytes")"; [ -n "$_ct" ] && _cf=",\"c\":\"${_ct}\""; }
            entries+="{\"b\":${bytes},\"p\":\"${fp_esc}\",\"d\":${is_dir}${_cf}},"
            [ "$fpath" = "$path" ] && root_bytes="$bytes"
        done < <(du -ab --max-depth=5 "$path" 2>/dev/null | head -n 8000)
        entries="${entries%,}"
        label_esc="$(_json_escape "[locale] $path")"
        path_esc="$(_json_escape "$path")"
        roots_json+="{\"label\":\"${label_esc}\",\"root\":\"${path_esc}\",\"entries\":[${entries}]},"
        (( total_bytes += root_bytes )) || true
    done

    # --- Percorsi remoti ---
    if [ -d "${REMOTE_STAGE_DIR}" ]; then
        while IFS= read -r host_dir; do
            hostname=$(basename "$host_dir")
            userhost=$(cat "${host_dir}/.userhost" 2>/dev/null || echo "?@${hostname}")
            while IFS= read -r item; do
                [ -e "$item" ] || continue
                rel="/${item#${host_dir}/}"
                entries=""
                root_bytes=0
                while IFS=$'\t' read -r bytes fpath; do
                    [ -n "$fpath" ] || continue
                    bytes="${bytes:-0}"
                    fp_esc="$(_json_escape "$fpath")"
                    is_dir=0; [ -d "$fpath" ] && is_dir=1
                    _cf=""; [ "$is_dir" -eq 0 ] && { _ct="$(_read_text_content "$fpath" "$bytes")"; [ -n "$_ct" ] && _cf=",\"c\":\"${_ct}\""; }
                    entries+="{\"b\":${bytes},\"p\":\"${fp_esc}\",\"d\":${is_dir}${_cf}},"
                    [ "$fpath" = "$item" ] && root_bytes="$bytes"
                done < <(du -ab --max-depth=5 "$item" 2>/dev/null | head -n 8000)
                entries="${entries%,}"
                label_esc="$(_json_escape "[${userhost}] ${rel}")"
                path_esc="$(_json_escape "$item")"
                roots_json+="{\"label\":\"${label_esc}\",\"root\":\"${path_esc}\",\"entries\":[${entries}]},"
                (( total_bytes += root_bytes )) || true
            done < <(find "$host_dir" -mindepth 1 -maxdepth 1 -not -name '.userhost' 2>/dev/null | sort)
        done < <(find "${REMOTE_STAGE_DIR}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    fi

    roots_json="[${roots_json%,}]"
    total_bytes_fmt="$(_fmt_bytes "$total_bytes")"

    {
        cat << 'HTMLEOF'
<!DOCTYPE html>
<html lang="it">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Folder Snapshot &mdash; PrivateBackup</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#0d1117;color:#e6edf3;font-family:'Courier New',Consolas,monospace;font-size:14px;padding:24px;min-height:100vh}
.hdr{background:#161b22;border:1px solid #30363d;border-radius:10px;padding:20px 24px;margin-bottom:20px}
.hdr h1{color:#58a6ff;font-size:1.15em;margin-bottom:10px;letter-spacing:.02em}
.hdr .m{color:#8b949e;font-size:.9em;margin-top:4px}
.hdr .tot{color:#3fb950;font-weight:bold;margin-top:10px;font-size:1em}
.src{background:#161b22;border:1px solid #30363d;border-radius:10px;margin-bottom:14px;overflow:hidden}
.src-hdr{background:#21262d;padding:10px 16px;font-weight:bold;color:#79c0ff;border-bottom:1px solid #30363d;font-size:.88em;letter-spacing:.03em}
.tree{padding:4px 0}
.nr{display:flex;align-items:center;padding:2px 0;gap:6px;cursor:default;user-select:none;border-radius:3px;transition:background .1s}
.nr:hover{background:#21262d}
.nr.hk{cursor:pointer}
.tg{width:14px;color:#6e7681;font-size:.65em;flex-shrink:0;text-align:center}
.ic{flex-shrink:0;font-size:.9em}
.bw{width:140px;height:7px;background:#21262d;border-radius:4px;flex-shrink:0;overflow:hidden}
.b{height:100%;border-radius:4px;min-width:2px}
.sz{min-width:76px;text-align:right;color:#8b949e;font-size:.8em;flex-shrink:0}
.nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;font-size:.9em}
.nm.f{color:#6e7681}
.ch{overflow:hidden}
.l0{padding-left:10px}.l1{padding-left:24px}.l2{padding-left:38px}.l3{padding-left:52px}.l4{padding-left:66px}.l5{padding-left:80px}.l6{padding-left:94px}
.fb{display:flex;gap:8px;align-items:center;margin-bottom:16px}
.fb input{flex:1;background:#161b22;border:1px solid #30363d;border-radius:6px;padding:8px 14px;color:#e6edf3;font-family:inherit;font-size:.9em;outline:none}
.fb input:focus{border-color:#58a6ff;box-shadow:0 0 0 2px rgba(88,166,255,.15)}
.fb input::placeholder{color:#484f58}
.fb button{background:#21262d;border:1px solid #30363d;border-radius:6px;color:#8b949e;padding:8px 13px;cursor:pointer;font-size:.9em;transition:all .1s}
.fb button:hover{background:#30363d;color:#e6edf3}
.cnt{color:#8b949e;font-size:.82em;padding:6px 2px 10px}
.rr{display:flex;align-items:center;padding:5px 12px;gap:8px;border-radius:4px;cursor:default}
.rr:hover{background:#21262d}
.ri{flex:1;overflow:hidden;min-width:0}
.rp{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.88em}
.rl{color:#8b949e;font-size:.76em;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.no-res{padding:20px;color:#8b949e;text-align:center;font-size:.9em}
.prv{flex-shrink:0;cursor:pointer;font-size:.85em;padding:1px 6px;border-radius:4px;color:#484f58;transition:color .1s;user-select:none}
.prv:hover{color:#79c0ff}
.mw{display:none;position:fixed;inset:0;background:rgba(0,0,0,.78);z-index:100;align-items:center;justify-content:center}
.mb{background:#161b22;border:1px solid #30363d;border-radius:10px;width:92%;max-width:960px;max-height:88vh;display:flex;flex-direction:column;box-shadow:0 24px 48px rgba(0,0,0,.5)}
.mh{display:flex;align-items:center;gap:10px;padding:12px 16px;border-bottom:1px solid #30363d;min-width:0}
.mp{color:#79c0ff;font-size:.82em;flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.mbtn{border-radius:6px;padding:5px 12px;cursor:pointer;font-size:.82em;white-space:nowrap;font-family:inherit}
#prv-copy{background:#238636;border:1px solid #2ea043;color:#fff}
#prv-close{background:#21262d;border:1px solid #30363d;color:#8b949e}
#prv-pre{flex:1;overflow:auto;padding:16px;font-size:.83em;line-height:1.55;color:#e6edf3;white-space:pre-wrap;word-break:break-all;margin:0;font-family:'Courier New',Consolas,monospace}
</style>
</head>
<body>
<div class="hdr">
  <h1>&#x1F5C4;&#xFE0F; PrivateBackup &mdash; Snapshot Cartelle</h1>
HTMLEOF
        printf '  <div class="m">&#x1F4C5; Data: %s</div>\n' "$date_str"
        printf '  <div class="m">&#x1F4E6; Archivio: %s</div>\n' "$archive_name"
        printf '  <div class="tot">&#x1F4BE; Totale stimato (non compresso): %s</div>\n' "$total_bytes_fmt"
        cat << 'HTMLEOF'
</div>
<div class="fb">
  <input id="flt" type="text" placeholder="Filtra per nome: .env   *.log   id_rsa   authorized_keys ..." oninput="doFilter(this.value)">
  <button onclick="clearFilter()" title="Cancella filtro">&#x2715;</button>
</div>
<div id="tree"></div>
<div id="res" style="display:none"></div>
<div id="prv-modal" class="mw" onclick="if(event.target===this)closePrv()">
  <div class="mb">
    <div class="mh">
      <span class="mp" id="prv-path"></span>
      <button id="prv-copy" class="mbtn" onclick="copyPrv()">Copia tutto</button>
      <button id="prv-close" class="mbtn" onclick="closePrv()">&#x2715;</button>
    </div>
    <pre id="prv-pre"></pre>
  </div>
</div>
<script>
HTMLEOF
        printf 'const ROOTS=%s;\n' "$roots_json"
        cat << 'HTMLEOF'
let _i=0;
function fmtB(b){b=+b;if(b>=1073741824)return(b/1073741824).toFixed(1)+' GiB';if(b>=1048576)return(b/1048576).toFixed(1)+' MiB';if(b>=1024)return(b/1024).toFixed(1)+' KiB';return b+' B';}
function col(b){if(b>=1073741824)return'#f85149';if(b>=104857600)return'#f0883e';if(b>=10485760)return'#d29922';return'#3fb950';}
function esc(s){return String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');}
function buildTree(entries,root){
  const m={};
  for(const e of entries){
    const nm=e.p===root?(e.p.split('/').filter(Boolean).pop()||e.p):e.p.split('/').pop();
    m[e.p]={name:nm||e.p,path:e.p,bytes:+e.b,isDir:e.d===1,children:[],hasContent:!!e.c};
  }
  for(const e of entries){
    if(e.p===root)continue;
    const pp=e.p.replace(/\/+$/,'').split('/').slice(0,-1).join('/');
    if(m[pp])m[pp].children.push(m[e.p]);
  }
  for(const k of Object.keys(m))m[k].children.sort((a,b)=>b.bytes-a.bytes);
  return m[root]||null;
}
function rNode(n,pb,d){
  if(!n)return'';
  const pct=pb>0?n.bytes/pb*100:100;
  const bw=Math.max(2,Math.min(100,pct)).toFixed(1);
  const hk=n.children.length>0;
  const isD=n.isDir||hk;
  const coll=hk;
  const id='n'+(++_i);
  let h='<div>';
  h+=`<div class="nr l${Math.min(d,6)}${hk?' hk':''}"${hk?` onclick="tg('${id}')" `:''}title="${esc(n.path)}">`;
  h+=`<span class="tg" id="t${id}">${hk?(coll?'&#9654;':'&#9660;'):''}</span>`;
  h+=`<span class="ic">${isD?'&#x1F4C1;':'&#x1F4C4;'}</span>`;
  h+=`<div class="bw"><div class="b" style="width:${bw}%;background:${col(n.bytes)}"></div></div>`;
  h+=`<span class="sz">${fmtB(n.bytes)}</span>`;
  h+=`<span class="nm${isD?'':' f'}">${esc(n.name)}</span>`;
  if(n.hasContent)h+=`<span class="prv" onclick="event.stopPropagation();showPrv('${esc(n.path)}')" title="Anteprima">&#x1F441;&#xFE0F;</span>`;
  h+='</div>';
  if(hk){
    h+=`<div id="${id}" class="ch"${coll?' style="display:none"':''}>`;
    for(const c of n.children)h+=rNode(c,n.bytes,d+1);
    h+='</div>';
  }
  h+='</div>';
  return h;
}
function tg(id){
  const el=document.getElementById(id),ti=document.getElementById('t'+id);
  if(!el)return;
  const hidden=el.style.display==='none';
  el.style.display=hidden?'':'none';
  if(ti)ti.innerHTML=hidden?'&#9660;':'&#9654;';
}
function globRe(q){
  const s=q.replace(/[.+^${}()|[\]\\]/g,'\\$&').replace(/\*/g,'.*').replace(/\?/g,'.');
  return new RegExp(s,'i');
}
function doFilter(q){
  const tree=document.getElementById('tree');
  const res=document.getElementById('res');
  q=q.trim();
  if(!q){tree.style.display='';res.style.display='none';res.innerHTML='';return;}
  const re=globRe(q);
  let h='',n=0;
  for(const root of ROOTS){
    for(const e of root.entries){
      const nm=e.p.split('/').pop();
      if(!nm||!re.test(nm))continue;
      n++;
      h+=`<div class="rr" title="${esc(e.p)}">`;
      h+=`<span class="ic">${e.d?'&#x1F4C1;':'&#x1F4C4;'}</span>`;
      h+=`<div class="ri"><span class="rp">${esc(e.p)}</span><span class="rl">${esc(root.label)}</span></div>`;
      h+=`<span class="sz">${fmtB(e.b)}</span>`;
      if(e.c)h+=`<span class="prv" onclick="showPrv('${esc(e.p)}')" title="Anteprima">&#x1F441;&#xFE0F;</span>`;
      h+='</div>';
    }
  }
  tree.style.display='none';
  res.style.display='';
  res.innerHTML=n?`<div class="cnt">${n} risultat${n===1?'o':'i'}</div>`+h:'<div class="no-res">Nessun risultato per &ldquo;'+esc(q)+'&rdquo;</div>';
}
function clearFilter(){
  const fi=document.getElementById('flt');
  fi.value='';
  doFilter('');
  fi.focus();
}
function showPrv(path){
  let b64=null;
  for(const r of ROOTS){const e=r.entries.find(e=>e.p===path&&e.c);if(e){b64=e.c;break;}}
  if(!b64)return;
  let txt;
  try{
    const raw=atob(b64),u8=new Uint8Array(raw.length);
    for(let i=0;i<raw.length;i++)u8[i]=raw.charCodeAt(i);
    txt=new TextDecoder('utf-8',{fatal:false}).decode(u8);
  }catch(e){txt='(errore decodifica)';}
  document.getElementById('prv-path').textContent=path;
  document.getElementById('prv-pre').textContent=txt;
  document.getElementById('prv-copy').textContent='Copia tutto';
  document.getElementById('prv-modal').style.display='flex';
}
function closePrv(){document.getElementById('prv-modal').style.display='none';}
function copyPrv(){
  const txt=document.getElementById('prv-pre').textContent;
  navigator.clipboard.writeText(txt).then(()=>{
    const b=document.getElementById('prv-copy');
    b.textContent='&#x2713; Copiato!';
    setTimeout(()=>b.textContent='Copia tutto',2200);
  }).catch(()=>{try{document.execCommand('copy');}catch(e){}});
}
document.addEventListener('DOMContentLoaded',function(){
  const c=document.getElementById('tree');
  let h='';
  for(const root of ROOTS){
    h+='<div class="src">';
    h+=`<div class="src-hdr">${esc(root.label)}</div>`;
    h+='<div class="tree">';
    if(!root.entries||!root.entries.length){
      h+='<div style="padding:12px 16px;color:#8b949e">Nessun dato disponibile</div>';
    }else{
      const t=buildTree(root.entries,root.root);
      h+=t?rNode(t,t.bytes,0):'<div style="padding:12px;color:#f85149">Errore nella costruzione dell\'albero</div>';
    }
    h+='</div></div>';
  }
  c.innerHTML=h;
  document.addEventListener('keydown',function(e){
    if(e.key==='Escape'){
      if(document.getElementById('prv-modal').style.display==='flex')closePrv();
      else clearFilter();
    }
  });
});
</script>
</body>
</html>
HTMLEOF
    } > "$snapshot_file"

    echo "📊 Snapshot HTML: ${snapshot_file}"
    if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open &>/dev/null; then
        xdg-open "$snapshot_file" 2>/dev/null &
    fi
}

# ============================================================
# Funzione: _ripristina_host
# Invia via SSH+tar la staging-dir verso l'host remoto originale
# ============================================================
_ripristina_host() {
    local stagedir="$1"
    local host="$2"
    local userhost
    local ssh_opts=(-o ConnectTimeout=5 -o IdentitiesOnly=yes \
                    -i "${SSH_KEY:-${HOME}/.ssh/id_rsa}" \
                    -o StrictHostKeyChecking=no)

    userhost=$(cat "${stagedir}/.userhost" 2>/dev/null || echo "root@${host}")

    echo ""
    echo "  Host:     ${userhost}"
    echo "  File:"
    find "$stagedir" -not -name '.userhost' -type f 2>/dev/null | \
        sed "s|${stagedir}/||" | sed 's/^/    /'
    echo ""
    echo "⚠️  Sovrascriverà i file originali su ${host}."
    read -p "Confermi? (s/n): " CONFIRM
    if [[ "${CONFIRM,,}" != "s" ]]; then
        echo "Saltato."
        return 0
    fi

    # tar locale impacchetta la staging (percorsi relativi), tar remoto estrae in /
    tar -czf - -C "${stagedir}" --exclude='.userhost' . 2>/dev/null | \
        ssh "${ssh_opts[@]}" "$userhost" "tar -xzf - -C /" 2>>"${LOG_FILE}"

    if [ $? -eq 0 ]; then
        echo "✅ Ripristino completato su ${host}"
        echo "$(date): Ripristino remoto completato su ${userhost}" >>"${LOG_FILE}"
    else
        echo "❌ Errore durante il ripristino su ${host}"
        echo "$(date): Errore ripristino remoto su ${userhost}" >>"${LOG_FILE}"
    fi
}

# ============================================================
# Funzione: ripristina_remoto
# Estrae la staging remota dall'archivio e propone il restore per host
# ============================================================
ripristina_remoto() {
    local work_archive="$1"

    if ! tar -tzf "$work_archive" 2>/dev/null | grep -q '\.remote_stage/'; then
        return 0
    fi

    echo ""
    echo "L'archivio contiene file di host remoti."
    echo "Vuoi ripristinarli sugli host originali?"
    echo "1) Sì"
    echo "0) No"
    read -p "Scelta: " REMOTE_CHOICE
    [[ "$REMOTE_CHOICE" != "1" ]] && return 0

    # Estrae solo le voci remote_stage in una dir temporanea
    local tmp_stage
    tmp_stage=$(mktemp -d /tmp/private_backup_remote_XXXXXX)

    mapfile -t remote_entries < <(tar -tzf "$work_archive" 2>/dev/null | grep '\.remote_stage/')
    tar -xzf "$work_archive" -C "$tmp_stage" "${remote_entries[@]}" >>"${LOG_FILE}" 2>&1

    local remote_stage
    remote_stage=$(find "$tmp_stage" -type d -name ".remote_stage" 2>/dev/null | head -1)

    if [ -z "$remote_stage" ]; then
        echo "❌ Impossibile estrarre i file remoti."
        rm -rf "$tmp_stage"
        return 1
    fi

    # Lista host disponibili
    local hosts=()
    while IFS= read -r d; do
        hosts+=("$(basename "$d")")
    done < <(find "$remote_stage" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)

    if [ ${#hosts[@]} -eq 0 ]; then
        echo "❌ Nessun host trovato nel backup remoto."
        rm -rf "$tmp_stage"
        return 1
    fi

    echo ""
    echo "Host disponibili per il ripristino:"
    for i in "${!hosts[@]}"; do
        local count
        count=$(find "${remote_stage}/${hosts[$i]}" -not -name '.userhost' -type f 2>/dev/null | wc -l)
        printf "  %2d) %-30s (%d file)\n" "$((i+1))" "${hosts[$i]}" "$count"
    done
    echo "   a) Tutti gli host"
    echo "   0) Annulla"
    read -p "Scelta: " HOST_CHOICE

    case "$HOST_CHOICE" in
        0)  ;;
        a)
            for host in "${hosts[@]}"; do
                _ripristina_host "${remote_stage}/${host}" "$host"
            done
            ;;
        *)
            if [[ "$HOST_CHOICE" =~ ^[0-9]+$ ]] && \
               [ "$HOST_CHOICE" -ge 1 ] && [ "$HOST_CHOICE" -le "${#hosts[@]}" ]; then
                local host="${hosts[$((HOST_CHOICE-1))]}"
                _ripristina_host "${remote_stage}/${host}" "$host"
            else
                echo "❌ Scelta non valida!"
            fi
            ;;
    esac

    rm -rf "$tmp_stage"
}

# ============================================================
# Funzione: controlla_compose_non_tracciati
# Avvisa se esistono docker-compose non presenti in BACKUP_ITEMS
# ============================================================
controlla_compose_non_tracciati() {
    [[ -z "${COMPOSE_WATCH_DIRS+x}" || ${#COMPOSE_WATCH_DIRS[@]} -eq 0 ]] && return 0
    local untracked=() found tracked item

    for watchdir in "${COMPOSE_WATCH_DIRS[@]}"; do
        while IFS= read -r found; do
            tracked=false
            for item in "${BACKUP_ITEMS[@]}"; do
                [[ "$item" == "$found" ]] && tracked=true && break
            done
            $tracked || untracked+=("$found")
        done < <(find "$watchdir" -maxdepth 2 -type f \
            \( -name "docker-compose.yml" -o -name "docker-compose.yaml" \
               -o -name "compose.yml"         -o -name "compose.yaml" \) \
            2>/dev/null | sort)
    done

    if [ ${#untracked[@]} -gt 0 ]; then
        local YLW='\033[1;33m' RED='\033[1;31m' CYN='\033[0;36m' RST='\033[0m'
        echo ""
        echo -e "${RED}❗ docker-compose non tracciati nel backup:${RST}"
        for f in "${untracked[@]}"; do
            echo -e "   ${YLW}-${RST} ${CYN}${f}${RST}"
        done
        echo -e "   Aggiungili a ${YLW}BACKUP_ITEMS${RST} in ${CONFIG_FILE}"
    fi
}

# ============================================================
# Funzione: backup
# ============================================================
backup() {
    # Validazione percorsi da BACKUP_ITEMS
    VALID_INCLUDE_PATHS=()
    MISSING_PATHS=()

    # Chiede subito la password di cifratura, così un errore non fa perdere tempo
    if [[ "${BACKUP_ENCRYPT:-false}" == "true" ]]; then
        BACKUP_PASSWORD=""
        chiedi_password
    fi

    for path in "${BACKUP_ITEMS[@]}"; do
        if [ -d "$path" ] || [ -f "$path" ]; then
            VALID_INCLUDE_PATHS+=("$path")
        else
            MISSING_PATHS+=("$path")
        fi
    done

    # Aggiunge le directory trovate tramite BACKUP_FIND_DIRS
    # Formato voci: "basedir:nomedir" — trova tutte le dir di nome "nomedir" dentro "basedir"
    for entry in "${BACKUP_FIND_DIRS[@]:-}"; do
        [[ -z "$entry" ]] && continue
        basedir="${entry%%:*}"
        dirname="${entry##*:}"
        while IFS= read -r found; do
            VALID_INCLUDE_PATHS+=("$found")
        done < <(find "$basedir" -type d -name "$dirname" 2>/dev/null)
    done

    # Recupera file da host remoti (aggiunge staging a VALID_INCLUDE_PATHS)
    recupera_remoti

    if [ ${#VALID_INCLUDE_PATHS[@]} -eq 0 ]; then
        echo "❌ Nessun percorso valido trovato per il backup!"
        echo "$(date): Errore - nessun percorso valido." >>"${LOG_FILE}"
        exit 1
    fi

    # Creazione archivio
    echo "Creazione dell'archivio di backup..."
    echo "$(date): Avvio backup in ${BACKUP_FILE}" >>"${LOG_FILE}"

    tar --warning=no-file-ignored -czvf "${BACKUP_FILE}" "${VALID_INCLUDE_PATHS[@]}" >>"${LOG_FILE}" 2>&1

    if [ $? -ne 0 ]; then
        echo "❌ Errore durante la creazione dell'archivio TAR!"
        echo "$(date): Errore durante il backup." >>"${LOG_FILE}"
        exit 1
    fi

    # Cifratura GPG (se abilitata)
    if [[ "${BACKUP_ENCRYPT:-false}" == "true" ]]; then
        echo "Cifratura archivio con GPG (AES256)..."
        gpg_encrypt_file "${BACKUP_FILE}" "${BACKUP_FILE}.gpg"
        if [ $? -ne 0 ]; then
            echo "❌ Errore durante la cifratura!"
            echo "$(date): Errore cifratura ${BACKUP_FILE}" >>"${LOG_FILE}"
            exit 1
        fi
        rm -f "${BACKUP_FILE}"
        BACKUP_FILE="${BACKUP_FILE}.gpg"
        CHECKSUM_FILE="${BACKUP_FILE}.sha256"
        echo "✅ Archivio cifrato: $(basename "${BACKUP_FILE}")"
    fi

    # Calcolo e salvataggio checksum SHA256
    echo "Calcolo checksum SHA256..."
    sha256sum "${BACKUP_FILE}" | tee "${CHECKSUM_FILE}" >>"${LOG_FILE}"

    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo "❌ Errore durante il calcolo del checksum!"
        exit 1
    fi

    # Verifica che l'archivio sia decifrabile con la password inserita
    if [[ "${BACKUP_ENCRYPT:-false}" == "true" ]]; then
        echo "Verifica cifratura con la password inserita..."
        # Usiamo PIPESTATUS per leggere l'exit reale di gpg e tar,
        # senza far dipendere il check da output testuale di tar.
        # NB: 'local' è un comando e azzera PIPESTATUS, quindi va dichiarato prima.
        local gpg_status tar_status pipe_statuses
        gpg_decrypt_to_stdout "${BACKUP_FILE}" | tar -tzf - >/dev/null 2>>"${LOG_FILE}"
        pipe_statuses=("${PIPESTATUS[@]}")
        gpg_status=${pipe_statuses[0]}
        tar_status=${pipe_statuses[1]}
        if [ "$gpg_status" -eq 0 ] && [ "$tar_status" -eq 0 ]; then
            echo "✅ Verifica cifratura OK: archivio apribile con la password inserita"
        else
            echo "⚠️  Verifica cifratura fallita: archivio non decifrabile con la password inserita!"
            echo "   gpg exit=${gpg_status}, tar exit=${tar_status}"
            echo "   Controlla ${LOG_FILE} per i dettagli."
            echo "$(date): ATTENZIONE - verifica cifratura fallita per ${BACKUP_FILE} (gpg=${gpg_status}, tar=${tar_status})" >>"${LOG_FILE}"
        fi
    fi

    echo "✅ Backup completato con successo!"
    echo "   File di backup: ${BACKUP_FILE}"
    echo "   Checksum:       ${CHECKSUM_FILE}"
    echo "$(date): Backup completato. File: ${BACKUP_FILE}" >>"${LOG_FILE}"

    snapshot_cartelle
    controlla_compose_non_tracciati

    # Avviso percorsi mancanti
    if [ ${#MISSING_PATHS[@]} -gt 0 ]; then
        echo "❗ Attenzione: i seguenti percorsi non esistono e sono stati saltati:"
        for missing in "${MISSING_PATHS[@]}"; do
            echo "   - $missing"
        done
    fi

    # Mantieni solo le ultime 7 versioni locali
    local keep=7
    mapfile -t old_archives < <(
        ls -1t "${BACKUP_DEST_DIR}"/*_private_*.tar.gz \
               "${BACKUP_DEST_DIR}"/*_private_*.tar.gz.gpg 2>/dev/null | \
        grep -v '\.sha256$' | tail -n +$((keep + 1))
    )
    for old in "${old_archives[@]}"; do
        rm -f "$old" "${old}.sha256"
        echo "$(date): Rimosso vecchio archivio: $old" >>"${LOG_FILE}"
    done
}

# ============================================================
# Funzione: lista_backup (uso interno)
# ============================================================
lista_backup() {
    mapfile -t BACKUP_FILES < <(
        ls -1t "${BACKUP_DEST_DIR}"/*_private_*.tar.gz \
               "${BACKUP_DEST_DIR}"/*_private_*.tar.gz.gpg 2>/dev/null | \
        grep -v '\.sha256$'
    )

    if [ ${#BACKUP_FILES[@]} -eq 0 ]; then
        echo "❌ Nessun backup disponibile in ${BACKUP_DEST_DIR}."
        exit 1
    fi

    # Ordina per data di modifica, dal più recente
    mapfile -t BACKUP_FILES < <(for f in "${BACKUP_FILES[@]}"; do
        echo "$(stat --format='%Y' "$f") $f"
    done | sort -n -r | cut -d' ' -f2-)

    for i in "${!BACKUP_FILES[@]}"; do
        backup_file="${BACKUP_FILES[$i]}"
        backup_hostname=$(echo "$backup_file" | sed -E "s|.*/([^/]+)_private_([0-9]{8}_[0-9]{6}).*|\1|")
        backup_date=$(echo "$backup_file" | sed -E "s|.*/([^/]+)_private_([0-9]{8}_[0-9]{6}).*|\2|")
        formatted_date=$(date -d "$(echo "$backup_date" | sed 's/_/ /' | \
            sed 's/\(....\)\(..\)\(..\) \(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')" \
            +"%d/%m/%Y %H:%M:%S" 2>/dev/null || echo "$backup_date")
        echo "$((i + 1))) Data: $formatted_date | Host: $backup_hostname"
    done
}

format_backup_label() {
    local backup_file="$1"
    local backup_hostname backup_date formatted_date size
    backup_hostname=$(echo "$backup_file" | sed -E "s|.*/([^/]+)_private_([0-9]{8}_[0-9]{6}).*|\1|")
    backup_date=$(echo "$backup_file" | sed -E "s|.*/([^/]+)_private_([0-9]{8}_[0-9]{6}).*|\2|")
    formatted_date=$(date -d "$(echo "$backup_date" | sed 's/_/ /' | \
        sed 's/\(....\)\(..\)\(..\) \(..\)\(..\)\(..\)/\1-\2-\3 \4:\5:\6/')" \
        +"%d/%m/%Y %H:%M:%S" 2>/dev/null || echo "$backup_date")
    size="$(_fmt_bytes "$(stat --format='%s' "$backup_file" 2>/dev/null || echo 0)")"
    printf "%s | %s | %s" "$formatted_date" "$backup_hostname" "$size"
}

scegli_backup_dialog() {
    local title="$1"
    lista_backup
    SELECTED_BACKUP_FILE=""

    if [ "${USE_DIALOG}" != true ]; then
        echo "Elenco dei backup privati disponibili:"
        echo ""
        lista_backup
        echo ""
        read -r -p "Scegli un backup (numero): " CHOICE
        [[ "$CHOICE" =~ ^[0-9]+$ ]] || return 1
        [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#BACKUP_FILES[@]}" ] || return 1
        SELECTED_BACKUP_FILE="${BACKUP_FILES[$((CHOICE - 1))]}"
        return 0
    fi

    local -a menu_items=()
    local i
    for i in "${!BACKUP_FILES[@]}"; do
        menu_items+=("$((i + 1))" "$(format_backup_label "${BACKUP_FILES[$i]}")")
    done

    local choice status
    dialog_menu "$title" "Seleziona un archivio in ${BACKUP_DEST_DIR}" 20 110 10 "${menu_items[@]}"
    status=$?
    choice="$DIALOG_RESULT"
    [ $status -eq 0 ] || return 1
    SELECTED_BACKUP_FILE="${BACKUP_FILES[$((choice - 1))]}"
    return 0
}

# ============================================================
# Funzione: elenca_file_archivio
# Popola l'array globale ARCHIVIO_FILES con il contenuto del tar
# ============================================================
elenca_file_archivio() {
    local archive="$1"
    local work_archive="$archive"
    local tmp_file=""

    if [[ "$archive" == *.gpg ]]; then
        chiedi_password decrypt
        tmp_file=$(mktemp /tmp/private_backup_XXXXXX.tar.gz)
        gpg_decrypt_to_file "$archive" "$tmp_file"
        if [ $? -ne 0 ]; then
            show_error "❌ Decifratura fallita.\n\nPassword errata o archivio non leggibile."
            rm -f "$tmp_file"
            return 1
        fi
        work_archive="$tmp_file"
    fi

    dialog_infobox "Lettura contenuto archivio...\n\n$(basename "$archive")" 8 72
    mapfile -t ARCHIVIO_FILES < <(tar -tzf "$work_archive" 2>/dev/null)
    [ -n "$tmp_file" ] && rm -f "$tmp_file"

    if [ ${#ARCHIVIO_FILES[@]} -eq 0 ]; then
        show_error "❌ Impossibile leggere il contenuto dell'archivio."
        return 1
    fi

    echo "Contenuto dell'archivio ($(basename "$archive")):"
    echo ""
    for i in "${!ARCHIVIO_FILES[@]}"; do
        printf "  %4d) %s\n" "$((i + 1))" "${ARCHIVIO_FILES[$i]}"
    done
}

prepare_archive_workfile() {
    local archive="$1"
    local work_archive="$archive"
    local tmp_file=""
    PREPARED_WORK_ARCHIVE=""
    PREPARED_TMP_FILE=""

    if [[ "$archive" == *.gpg ]]; then
        chiedi_password decrypt
        tmp_file=$(mktemp /tmp/private_backup_XXXXXX.tar.gz)
        gpg_decrypt_to_file "$archive" "$tmp_file"
        if [ $? -ne 0 ]; then
            show_error "❌ Decifratura fallita.\n\nPassword errata o archivio non leggibile."
            rm -f "$tmp_file"
            return 1
        fi
        work_archive="$tmp_file"
    fi

    dialog_infobox "Indicizzazione archivio...\n\n$(basename "$archive")" 8 72
    PREPARED_WORK_ARCHIVE="$work_archive"
    PREPARED_TMP_FILE="$tmp_file"
    return 0
}

archive_collect_immediate_entries() {
    local prefix="$1"
    local -n out_entries_ref="$2"
    out_entries_ref=()
    local -A seen=()
    local entry rel child fullpath kind label

    for entry in "${ARCHIVIO_FILES[@]}"; do
        [[ "$entry" == "$prefix"* ]] || continue
        rel="${entry#$prefix}"
        rel="${rel#/}"
        [ -n "$rel" ] || continue
        child="${rel%%/*}"
        if [[ "$rel" == */* ]]; then
            fullpath="${prefix}${child}/"
            kind="DIR"
            label="[dir]"
        else
            fullpath="${prefix}${child}"
            kind="FILE"
            label="[file]"
        fi
        if [ -z "${seen[$fullpath]+x}" ]; then
            seen[$fullpath]=1
            out_entries_ref+=("${kind}|${fullpath}|${child}|${label}")
        fi
    done
}

archive_toggle_selection() {
    local target="$1"
    local -A next=()
    local key entry
    local remove=false

    for key in "${SELECTED_PATHS[@]}"; do
        if [[ "$key" == "$target"* ]]; then
            remove=true
            break
        fi
    done

    if [ "$remove" = true ]; then
        for key in "${SELECTED_PATHS[@]}"; do
            [[ "$key" == "$target"* ]] || next["$key"]=1
        done
    else
        for key in "${SELECTED_PATHS[@]}"; do
            next["$key"]=1
        done
        if [[ "$target" == */ ]]; then
            for entry in "${ARCHIVIO_FILES[@]}"; do
                [[ "$entry" == "$target"* ]] && next["$entry"]=1
            done
        else
            next["$target"]=1
        fi
    fi

    SELECTED_PATHS=()
    for key in "${!next[@]}"; do
        SELECTED_PATHS+=("$key")
    done
    mapfile -t SELECTED_PATHS < <(printf '%s\n' "${SELECTED_PATHS[@]}" | sort -u)
}

archive_selected_count_for_prefix() {
    local target="$1"
    local count=0
    local key
    for key in "${SELECTED_PATHS[@]}"; do
        [[ "$key" == "$target"* ]] && ((count++))
    done
    printf '%s\n' "$count"
}

archive_preview_entry() {
    local work_archive="$1"
    local entry="$2"
    local tmp_file preview_file mime

    tmp_file=$(mktemp /tmp/private_preview_XXXXXX)
    preview_file=$(mktemp /tmp/private_preview_text_XXXXXX)
    if [[ "$entry" == */ ]]; then
        {
            printf "Cartella: %s\n\n" "$entry"
            printf "Contenuto immediato:\n"
            for item in "${ARCHIVIO_FILES[@]}"; do
                [[ "$item" == "$entry"* ]] || continue
                local rel="${item#$entry}"
                rel="${rel#/}"
                [ -n "$rel" ] || continue
                printf "  %s\n" "${rel%%/*}"
            done | sort -u
        } > "$preview_file"
        show_text_file "Archivio" "$preview_file"
        rm -f "$tmp_file" "$preview_file"
        return 0
    fi

    if ! tar -xOf "$work_archive" "$entry" >"$tmp_file" 2>/dev/null; then
        printf "Impossibile leggere %s\n" "$entry" > "$preview_file"
        show_text_file "Archivio" "$preview_file"
        rm -f "$tmp_file" "$preview_file"
        return 1
    fi

    mime=$(file -b --mime-type "$tmp_file" 2>/dev/null || echo application/octet-stream)
    case "$mime" in
        text/*|application/json|application/xml|application/x-sh|application/x-yaml)
            cp "$tmp_file" "$preview_file"
            ;;
        *)
            {
                printf "File: %s\n" "$entry"
                printf "Tipo: %s\n" "$(file -b "$tmp_file" 2>/dev/null || echo sconosciuto)"
                printf "Dimensione: %s\n\n" "$(_fmt_bytes "$(stat --format='%s' "$tmp_file" 2>/dev/null || echo 0)")"
                printf "Anteprima strings:\n"
                strings "$tmp_file" 2>/dev/null | head -n 80
            } > "$preview_file"
            ;;
    esac

    show_text_file "Archivio" "$preview_file"
    rm -f "$tmp_file" "$preview_file"
}

browse_archive_dialog() {
    local archive="$1"
    local mode="${2:-browse}"
    local work_archive tmp_file current_prefix="" choice status
    local -a entries menu_items
    local target display marker selected_count

    prepare_archive_workfile "$archive" || return 1
    work_archive="$PREPARED_WORK_ARCHIVE"
    tmp_file="$PREPARED_TMP_FILE"
    dialog_infobox "Caricamento elenco file...\n\n$(basename "$archive")" 8 72
    mapfile -t ARCHIVIO_FILES < <(tar -tzf "$work_archive" 2>/dev/null)

    if [ "${#ARCHIVIO_FILES[@]}" -eq 0 ]; then
        [ -n "$tmp_file" ] && rm -f "$tmp_file"
        show_error "❌ Impossibile leggere il contenuto dell'archivio."
        return 1
    fi

    SELECTED_PATHS=()
    while true; do
        archive_collect_immediate_entries "$current_prefix" entries
        menu_items=()
        if [ -n "$current_prefix" ]; then
            menu_items+=("__UP__" "[..] cartella superiore")
        fi

        for entry in "${entries[@]}"; do
            IFS='|' read -r _kind target display _label <<< "$entry"
            marker=""
            if [ "$mode" = "select" ]; then
                selected_count="$(archive_selected_count_for_prefix "$target")"
                [ "$selected_count" -gt 0 ] && marker="[${selected_count}] "
            fi
            menu_items+=("$target" "${marker}${display}")
        done

        if [ "${#menu_items[@]}" -eq 0 ]; then
            dialog_msgbox "Nessun contenuto visibile nel percorso corrente." 8 70
            break
        fi

        if [ "$mode" = "select" ]; then
            local tmp_output
            tmp_output="$(mktemp /tmp/private_dialog_XXXXXX)" || return 1
            "${DIALOG_BIN}" --output-fd 3 --backtitle "PrivateBackup" --title "Esplora archivio" \
                --ok-label "Apri" --extra-button --extra-label "Segna" \
                --help-button --help-label "Fine" \
                --menu "Archivio: $(basename "$archive")\nPercorso: /${current_prefix}\nSelezionati: ${#SELECTED_PATHS[@]}" \
                22 110 14 "${menu_items[@]}" 3>"$tmp_output"
            status=$?
            choice="$(cat "$tmp_output" 2>/dev/null)"
            rm -f "$tmp_output"
            case $status in
                0)
                    if [ "$choice" = "__UP__" ]; then
                        current_prefix="${current_prefix%/}"
                        current_prefix="${current_prefix%/*}"
                        [ -n "$current_prefix" ] && current_prefix="${current_prefix}/"
                    elif [[ "$choice" == */ ]]; then
                        current_prefix="$choice"
                    else
                        archive_preview_entry "$work_archive" "$choice"
                    fi
                    ;;
                1)
                    [ -n "$tmp_file" ] && rm -f "$tmp_file"
                    return 1
                    ;;
                2)
                    [ -n "$tmp_file" ] && rm -f "$tmp_file"
                    [ "${#SELECTED_PATHS[@]}" -gt 0 ] || return 1
                    mapfile -t PATHS_TO_RESTORE < <(printf '%s\n' "${SELECTED_PATHS[@]}" | sort -u)
                    return 0
                    ;;
                3)
                    [ "$choice" = "__UP__" ] || archive_toggle_selection "$choice"
                    ;;
            esac
        else
            local tmp_output
            tmp_output="$(mktemp /tmp/private_dialog_XXXXXX)" || return 1
            "${DIALOG_BIN}" --output-fd 3 --backtitle "PrivateBackup" --title "Esplora archivio" \
                --ok-label "Apri" --extra-button --extra-label "Chiudi" \
                --menu "Archivio: $(basename "$archive")\nPercorso: /${current_prefix}" \
                22 110 14 "${menu_items[@]}" 3>"$tmp_output"
            status=$?
            choice="$(cat "$tmp_output" 2>/dev/null)"
            rm -f "$tmp_output"
            case $status in
                0)
                    if [ "$choice" = "__UP__" ]; then
                        current_prefix="${current_prefix%/}"
                        current_prefix="${current_prefix%/*}"
                        [ -n "$current_prefix" ] && current_prefix="${current_prefix}/"
                    elif [[ "$choice" == */ ]]; then
                        current_prefix="$choice"
                    else
                        archive_preview_entry "$work_archive" "$choice"
                    fi
                    ;;
                *)
                    [ -n "$tmp_file" ] && rm -f "$tmp_file"
                    return 0
                    ;;
            esac
        fi
    done

    [ -n "$tmp_file" ] && rm -f "$tmp_file"
}

# ============================================================
# Funzione: parse_selezione
# Converte "1,3,5-7" in array globale SELECTED_INDICES
# ============================================================
parse_selezione() {
    local input="$1"
    local max="$2"
    SELECTED_INDICES=()

    IFS=', ' read -ra tokens <<< "$input"

    for token in "${tokens[@]}"; do
        [[ -z "$token" ]] && continue
        if [[ "$token" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local start="${BASH_REMATCH[1]}"
            local end="${BASH_REMATCH[2]}"
            for ((j=start; j<=end; j++)); do
                [[ "$j" -ge 1 && "$j" -le "$max" ]] && SELECTED_INDICES+=("$j")
            done
        elif [[ "$token" =~ ^[0-9]+$ ]]; then
            [[ "$token" -ge 1 && "$token" -le "$max" ]] && SELECTED_INDICES+=("$token")
        fi
    done

    # Rimuovi duplicati e ordina
    mapfile -t SELECTED_INDICES < <(printf '%s\n' "${SELECTED_INDICES[@]}" | sort -n -u)
}

# ============================================================
# Funzione: esegui_estrazione
# Estrae file (tutti o selezionati) nella destinazione scelta
# ============================================================
esegui_estrazione() {
    local archive="$1"
    local dest="$2"
    shift 2
    local selected_paths=("$@")
    local work_archive="$archive"
    local tmp_file=""

    if [[ "$archive" == *.gpg ]]; then
        chiedi_password decrypt
        tmp_file=$(mktemp /tmp/private_backup_XXXXXX.tar.gz)
        echo "Decifratura archivio..."
        gpg_decrypt_to_file "$archive" "$tmp_file"
        if [ $? -ne 0 ]; then
            show_error "❌ Decifratura fallita.\n\nPassword errata o archivio non leggibile."
            rm -f "$tmp_file"
            return 1
        fi
        work_archive="$tmp_file"
    fi

    local result=0
    if [ "$dest" = "/" ]; then
        if [ ${#selected_paths[@]} -eq 0 ]; then
            sudo tar -xzvf "$work_archive" -C "/" >>"${LOG_FILE}" 2>&1
        else
            sudo tar -xzvf "$work_archive" -C "/" "${selected_paths[@]}" >>"${LOG_FILE}" 2>&1
        fi
    else
        if [ ${#selected_paths[@]} -eq 0 ]; then
            tar -xzvf "$work_archive" -C "$dest" >>"${LOG_FILE}" 2>&1
        else
            tar -xzvf "$work_archive" -C "$dest" "${selected_paths[@]}" >>"${LOG_FILE}" 2>&1
        fi
    fi
    result=$?

    [ -n "$tmp_file" ] && rm -f "$tmp_file"
    return $result
}

# ============================================================
# Funzione: restore
# ============================================================
restore() {
    scegli_backup_dialog "Restore" || exit 1
    BACKUP_FILE_TO_RESTORE="$SELECTED_BACKUP_FILE"

    # Verifica integrità tramite checksum se disponibile
    CHECKSUM_TO_VERIFY="${BACKUP_FILE_TO_RESTORE}.sha256"
    if [ -f "${CHECKSUM_TO_VERIFY}" ]; then
        echo "Verifica integrità SHA256..."
        sha256sum -c "${CHECKSUM_TO_VERIFY}" >>"${LOG_FILE}" 2>&1
        if [ $? -ne 0 ]; then
            echo "❌ Verifica checksum fallita! L'archivio potrebbe essere corrotto."
            echo "$(date): Errore checksum per ${BACKUP_FILE_TO_RESTORE}" >>"${LOG_FILE}"
            exit 1
        fi
        echo "✅ Integrità verificata."
    else
        echo "❗ File checksum non trovato, verifica integrità saltata."
    fi

    # Scelta: ripristino completo o selezione file
    if [ "${USE_DIALOG}" = true ]; then
        dialog_menu "Restore" "Cosa vuoi ripristinare?" 13 70 4 \
            1 "Tutto l'archivio" \
            2 "File o cartelle specifici"
        [ $? -eq 0 ] || exit 1
        SCOPE_CHOICE="$DIALOG_RESULT"
    else
        echo ""
        echo "Cosa vuoi ripristinare?"
        echo "1) Tutto l'archivio"
        echo "2) File o cartelle specifici"
        read -r -p "Inserisci la tua scelta (1/2): " SCOPE_CHOICE
    fi

    PATHS_TO_RESTORE=()

    case "$SCOPE_CHOICE" in
        1)
            # Nessun filtro: ripristina tutto
            ;;
        2)
            if [ "${USE_DIALOG}" = true ]; then
                browse_archive_dialog "${BACKUP_FILE_TO_RESTORE}" "select" || exit 1
            else
                echo ""
                elenca_file_archivio "${BACKUP_FILE_TO_RESTORE}" || exit 1
                echo ""
                echo "Inserisci i numeri dei file/cartelle da ripristinare."
                echo "Esempi: 3        una voce sola"
                echo "        1,4,7    voci separate da virgola"
                echo "        2-5      intervallo"
                echo "        1-3,7    combinazione"
                read -r -p "Selezione: " SELEZIONE

                parse_selezione "$SELEZIONE" "${#ARCHIVIO_FILES[@]}"

                if [ ${#SELECTED_INDICES[@]} -eq 0 ]; then
                    echo "❌ Nessun elemento selezionato."
                    exit 1
                fi

                echo ""
                echo "File selezionati:"
                for idx in "${SELECTED_INDICES[@]}"; do
                    entry="${ARCHIVIO_FILES[$((idx - 1))]}"
                    PATHS_TO_RESTORE+=("$entry")
                    echo "   - $entry"
                done
            fi
            ;;
        *)
            echo "❌ Scelta non valida!"
            exit 1
            ;;
    esac

    # Selezione destinazione del ripristino
    if [ "${USE_DIALOG}" = true ]; then
        dialog_menu "Destinazione restore" "Scegli dove estrarre il backup" 14 90 5 \
            1 "Posizione originale (/)" \
            2 "Cartella di anteprima (${RESTORE_PREVIEW_DIR})"
        [ $? -eq 0 ] || exit 1
        RESTORE_CHOICE="$DIALOG_RESULT"
    else
        echo ""
        echo "Scegli la destinazione per il ripristino:"
        echo "1) Posizione originale (/)"
        echo "2) Cartella di anteprima (${RESTORE_PREVIEW_DIR})"
        read -r -p "Inserisci la tua scelta (1/2): " RESTORE_CHOICE
    fi

    case "$RESTORE_CHOICE" in
        1)
            if ! dialog_yesno "Il ripristino sovrascriverà i file nelle posizioni originali.\n\nConfermi?" 10 80; then
                echo "Ripristino annullato."
                exit 0
            fi
            echo "Estrazione nella posizione originale..."
            esegui_estrazione "${BACKUP_FILE_TO_RESTORE}" "/" "${PATHS_TO_RESTORE[@]}"
            DESTINATION_DIR="/"
            ;;
        2)
            DESTINATION_DIR="${RESTORE_PREVIEW_DIR}"
            rm -rf "${DESTINATION_DIR}"
            mkdir -p "${DESTINATION_DIR}"
            echo "Estrazione nella cartella di anteprima: ${DESTINATION_DIR}..."
            esegui_estrazione "${BACKUP_FILE_TO_RESTORE}" "${DESTINATION_DIR}" "${PATHS_TO_RESTORE[@]}"
            ;;
        *)
            echo "❌ Scelta non valida!"
            exit 1
            ;;
    esac

    if [ $? -ne 0 ]; then
        echo "❌ Errore durante l'estrazione del backup!"
        echo "$(date): Errore durante il ripristino da ${BACKUP_FILE_TO_RESTORE}" >>"${LOG_FILE}"
        exit 1
    fi

    local riepilogo_file="tutto l'archivio"
    [ ${#PATHS_TO_RESTORE[@]} -gt 0 ] && riepilogo_file="${#PATHS_TO_RESTORE[@]} file/cartelle selezionati"

    echo "✅ Ripristino locale completato! ($riepilogo_file)"
    echo "$(date): Ripristino completato da ${BACKUP_FILE_TO_RESTORE} a ${DESTINATION_DIR} [$riepilogo_file]" >>"${LOG_FILE}"

    # Propone il ripristino degli host remoti se presenti nell'archivio
    local work_for_remote="$BACKUP_FILE_TO_RESTORE"
    local tmp_for_remote=""
    if [[ "$BACKUP_FILE_TO_RESTORE" == *.gpg ]]; then
        tmp_for_remote=$(mktemp /tmp/private_backup_XXXXXX.tar.gz)
        gpg_decrypt_to_file "$BACKUP_FILE_TO_RESTORE" "$tmp_for_remote"
        work_for_remote="$tmp_for_remote"
    fi
    ripristina_remoto "$work_for_remote"
    [ -n "$tmp_for_remote" ] && rm -f "$tmp_for_remote"
}

# ============================================================
# Funzione: upload
# ============================================================
upload() {
    # Verifica che rclone sia installato
    if ! command -v rclone &>/dev/null; then
        echo "❌ rclone non trovato. Installalo e configura il remote."
        exit 1
    fi

    scegli_backup_dialog "Upload su Google Drive" || exit 1
    BACKUP_FILE_TO_UPLOAD="$SELECTED_BACKUP_FILE"
    CHECKSUM_TO_UPLOAD="${BACKUP_FILE_TO_UPLOAD}.sha256"

    echo "Caricamento su Google Drive come: ${REMOTE_ARCHIVE}"
    echo "(il file remoto verrà sovrascritto se già esistente)"
    echo "$(date): Avvio upload di ${BACKUP_FILE_TO_UPLOAD} -> ${REMOTE_ARCHIVE}" >>"${LOG_FILE}"

    rclone copyto "${BACKUP_FILE_TO_UPLOAD}" "${REMOTE_ARCHIVE}" --progress 2>>"${LOG_FILE}"

    if [ $? -ne 0 ]; then
        echo "❌ Errore durante l'upload del backup!"
        echo "$(date): Errore upload ${BACKUP_FILE_TO_UPLOAD}" >>"${LOG_FILE}"
        exit 1
    fi

    # Upload del file checksum con nome fisso
    if [ -f "${CHECKSUM_TO_UPLOAD}" ]; then
        rclone copyto "${CHECKSUM_TO_UPLOAD}" "${REMOTE_CHECKSUM}" --progress 2>>"${LOG_FILE}"
        [ $? -eq 0 ] && echo "✅ Checksum caricato: $(basename "${REMOTE_CHECKSUM}")"
    fi

    echo "✅ Upload completato con successo!"
    echo "$(date): Upload completato. ${BACKUP_FILE_TO_UPLOAD} -> ${REMOTE_ARCHIVE}" >>"${LOG_FILE}"
}

# ============================================================
# Funzione: scompatta
# Decifra (se necessario) ed estrae un archivio in una sottocartella
# dentro BACKUP_DEST_DIR, con lo stesso nome dell'archivio
# ============================================================
scompatta() {
    local archive
    scegli_backup_dialog "Scompatta archivio" || exit 1
    archive="$SELECTED_BACKUP_FILE"
    local base
    base=$(basename "$archive")
    base="${base%.gpg}"
    base="${base%.tar.gz}"
    local dest_dir="${BACKUP_DEST_DIR}/${base}"

    local checksum_file="${archive}.sha256"
    if [ -f "$checksum_file" ]; then
        echo "Verifica integrità SHA256..."
        sha256sum -c "$checksum_file" >>"${LOG_FILE}" 2>&1
        if [ $? -ne 0 ]; then
            echo "❌ Verifica checksum fallita! L'archivio potrebbe essere corrotto."
            echo "$(date): Errore checksum per ${archive}" >>"${LOG_FILE}"
            exit 1
        fi
        echo "✅ Integrità verificata."
    else
        echo "❗ File checksum non trovato, verifica integrità saltata."
    fi

    rm -rf "${dest_dir}"
    mkdir -p "${dest_dir}"
    echo "Scompattamento in: ${dest_dir}..."
    esegui_estrazione "$archive" "$dest_dir"

    if [ $? -eq 0 ]; then
        echo "✅ Scompattato in: ${dest_dir}"
        echo "   File locali:  ${dest_dir}/home/$(whoami)/..."
        local remote_in_extract="${dest_dir}${REMOTE_STAGE_DIR}"
        if [ -d "$remote_in_extract" ]; then
            echo "   File remoti:  ${remote_in_extract}/"
            ls "${remote_in_extract}/" 2>/dev/null | while read -r h; do
                echo "     → ${h}"
            done
        fi
        echo "$(date): Scompattato ${archive} -> ${dest_dir}" >>"${LOG_FILE}"
    else
        echo "❌ Errore durante la scompattazione!"
        echo "$(date): Errore scompattazione ${archive}" >>"${LOG_FILE}"
        exit 1
    fi
}

esplora_backup() {
    local archive
    scegli_backup_dialog "Esplora backup" || return 1
    archive="$SELECTED_BACKUP_FILE"
    if [ "${USE_DIALOG}" = true ]; then
        browse_archive_dialog "$archive" "browse"
    else
        elenca_file_archivio "$archive"
        _pause_if_needed
    fi
}

# ============================================================
# Funzione: backup_e_upload
# ============================================================
backup_e_upload() {
    backup
    echo ""
    echo "Avvio upload dell'archivio appena creato..."
    echo "Destinazione remota: ${REMOTE_ARCHIVE}"
    echo "$(date): Avvio upload di ${BACKUP_FILE} -> ${REMOTE_ARCHIVE}" >>"${LOG_FILE}"

    if ! command -v rclone &>/dev/null; then
        echo "❌ rclone non trovato. Upload saltato."
        exit 1
    fi

    rclone copyto "${BACKUP_FILE}" "${REMOTE_ARCHIVE}" --progress 2>>"${LOG_FILE}"

    if [ $? -ne 0 ]; then
        echo "❌ Errore durante l'upload del backup!"
        echo "$(date): Errore upload ${BACKUP_FILE}" >>"${LOG_FILE}"
        exit 1
    fi

    if [ -f "${CHECKSUM_FILE}" ]; then
        rclone copyto "${CHECKSUM_FILE}" "${REMOTE_CHECKSUM}" --progress 2>>"${LOG_FILE}"
    fi

    echo "✅ Backup e upload completati con successo!"
    echo "$(date): Backup+upload completati. ${BACKUP_FILE} -> ${REMOTE_ARCHIVE}" >>"${LOG_FILE}"
}

# ============================================================
# Menu principale
# ============================================================
while true; do
    if [ "${USE_DIALOG}" = true ]; then
        dialog_menu "PrivateBackup" "Configurazione: ${CONFIG_FILE}\nDestinazione: ${BACKUP_DEST_DIR}\nRemote rclone: ${RCLONE_REMOTE_PATH}" \
            20 110 10 \
            1 "Backup" \
            2 "Restore" \
            3 "Upload su Google Drive (rclone)" \
            4 "Backup + Upload" \
            5 "Scompatta archivio" \
            6 "Visualizza snapshot dimensioni cartelle" \
            7 "Esplora backup" \
            0 "Esci"
        if [ $? -eq 0 ]; then
            CHOICE="$DIALOG_RESULT"
        else
            CHOICE=0
        fi
    else
        echo "============================================"
        echo " PrivateBackup - Backup file privati"
        echo "============================================"
        echo "Configurazione: ${CONFIG_FILE}"
        echo "Destinazione:   ${BACKUP_DEST_DIR}"
        echo "Remote rclone:  ${RCLONE_REMOTE_PATH}"
        echo "============================================"
        echo ""
        echo "Seleziona un'operazione:"
        echo "1) Backup"
        echo "2) Restore"
        echo "3) Upload su Google Drive (rclone)"
        echo "4) Backup + Upload"
        echo "5) Scompatta archivio"
        echo "6) Visualizza snapshot dimensioni cartelle"
        echo "7) Esplora backup"
        echo "0) Esci"
        echo ""
        read -r -p "Inserisci la tua scelta (0-7): " CHOICE
    fi

    case "$CHOICE" in
        1)
            start_operation_screen
            backup
            ;;
        2)
            start_operation_screen
            restore
            ;;
        3)
            start_operation_screen
            upload
            ;;
        4)
            start_operation_screen
            backup_e_upload
            ;;
        5)
            start_operation_screen
            scompatta
            ;;
        6)
            start_operation_screen
            _snapshot_file="${BACKUP_DEST_DIR}/folder_snapshot.html"
            if [ -f "$_snapshot_file" ]; then
                if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open &>/dev/null; then
                    xdg-open "$_snapshot_file" 2>/dev/null &
                    dialog_msgbox "Snapshot aperto nel browser.\n\n${_snapshot_file}" 10 90
                else
                    dialog_msgbox "Snapshot disponibile in:\n\n${_snapshot_file}\n\nAprilo con un browser web." 12 90
                fi
            else
                dialog_msgbox "❌ Nessuno snapshot disponibile.\n\nEsegui prima un backup." 10 80
            fi
            ;;
        7)
            start_operation_screen
            esplora_backup
            ;;
        0)
            echo "Uscita."
            exit 0
            ;;
        *)
            echo "❌ Scelta non valida!"
            _pause_if_needed "Premi un tasto per continuare..."
            ;;
    esac
done

exit 0

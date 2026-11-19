#!/usr/bin/env bash
# =============================================================================
#  🐦 Sellbird – One-Click-Installer (Proxmox VE)
#  https://github.com/HatchetMan111/Sellbird-Proxmox
#
#  Erstellt einen unprivilegierten LXC-Container und installiert darin
#  Sellbird (https://github.com/ethanplusai/sellbird): die Open-Source-
#  Outreach-Plattform, die auf dem eigenen Claude- oder ChatGPT-Plan läuft –
#  findet Firmen und Entscheider, prüft E-Mails, schreibt personalisierte
#  Cold-Mails, versendet aus der eigenen Mailbox (Freigabe im Outbox-
#  Workflow, Autopilot nur opt-in) und bearbeitet Antworten.
#
#  Sellbird ist eine Python-App (FastAPI/uvicorn). Das Dashboard ist von
#  Upstream absichtlich LOOPBACK-ONLY (Token-Auth, Host-/Origin-Guard:
#  sellbird/dashboard.py "_check_loopback_bind"). Damit die UI trotzdem wie
#  gewohnt unter http://CT-IP:PORT erreichbar ist, legt dieser Installer im
#  Container einen nginx-Reverse-Proxy auf 0.0.0.0:8090 davor, der Host- und
#  Origin-Header auf localhost umschreibt (WebSocket-fähig). Das Bearer-Token
#  bleibt weiter Pflicht – ohne den Unlock-Link kann niemand im LAN Daten
#  lesen oder etwas senden. Zugrunde liegender Pin: v0.4.0 (Commit b212385).
#
#  Zusätzlich läuft ein ttyd-Webterminal (Port 8091, Basic-Auth) als
#  Benutzer "sellbird": dort passieren der Claude-Login (OAuth), `sellbird
#  setup`, `sellbird train`, `sellbird discover` und `sellbird run`.
#
#  Installation (auf dem Proxmox-Host als root):
#    bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)"
#
#  Mit Optionen (direkt hinter dem schließenden Anführungszeichen):
#    ... " --id 210 --memory 4096 --port 8090
#
#  Update / Deinstall / Status / Debug:
#    ... " --update        |  ... " --uninstall  |  ... " --status  |  ... " --debug
# =============================================================================

# shellcheck disable=SC1111  # deutsche Anführungszeichen („…“) sind Absicht
set -Eeuo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
INSTALLER_VERSION="1.0.0"   # wird in --status/-Logs ausgegeben – hilft bei Fehlersuche
APP_NAME="sellbird"
UPSTREAM_URL="https://github.com/ethanplusai/sellbird.git"
PINNED_REF="b212385259da92246a56311d790d936e75dd70dd"  # v0.4.0, 2026-11-18 – Upstream-HEAD beim Installer-Bau
PINNED_LABEL="v0.4.0"
TTYD_VERSION="1.7.7"        # statisches Web-Terminal-Binary (wie ClaudeCode-Proxmox)
CT_ID=""                    # leer = automatisch nächste freie ID ab ID_SCAN_START
ID_SCAN_START=200
CT_HOSTNAME="sellbird"
CT_STORAGE="local-lvm"
CT_ROOTFS=8                 # GB – Code+venv+Chromium ≈ 1,5-2 GB, DB wächst langsam
CT_CORES=2
CT_MEMORY=2048              # MB – Chromium-Crawl ist gelegentlicher Spitzenbraucher
CT_SWAP=512
CT_BRIDGE="vmbr0"
CT_IP="dhcp"
CT_GATEWAY=""               # nur bei statischer IP nötig, z. B. 192.168.1.1
CT_PASSWORD=""              # leer = automatisch generieren
CT_SSHKEY=""                # Pfad ODER URL zu einer Public-Key-Datei (optional)
PORT=8090                   # nginx-Proxy-Port im Container (Dashboard fürs LAN)
DASHBOARD_PORT=5555         # fest: Sellbird-Uvicorn bindet 127.0.0.1 (upstream-Default)
TTYD_PORT=8091              # Webterminal-Port im Container
TTYD_USER="sellbird"        # Basic-Auth-User für ttyd
TTYD_PASSWORD=""            # leer = automatisch generieren
APP_USER="sellbird"         # Systembenutzer im Container (nicht root!)
APP_UID=1000                # -> Host-UID 100000+1000 im unprivilegierten CT
APP_GID=1000
APP_REF=""                  # leer = PINNED_REF; fester Commit via --ref (40-stellig)
TZ_NAME=""                  # leer = Zeitzone des Proxmox-Hosts übernehmen
FORCE_RECREATE=false
UNINSTALL=false
UPDATE=false
STATUS_CHECK=false
ASSUME_YES=false
TMP_DIR=""
LOG_FILE="/tmp/${APP_NAME}-installer-$(date +%Y%m%d-%H%M%S).log"
# Der fertige Einzeiler für Hinweise/Fehlerausgaben – exakt kopierbar (Optionen
# hinter dem schließenden Anführungszeichen; der Installer erkennt sie via $0-Fallback)
# shellcheck disable=SC2016  # Absicht: Literal, das zum Ausgeben gedacht ist
ONE_LINER='bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)"'

# ── Farben & Logging ───────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

info()  { echo -e "${BLUE}ℹ${NC}  $1"; }
ok()    { echo -e "${GREEN}✔${NC}  $1"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $1"; }
err()   { echo -e "${RED}✘${NC}  $1" >&2; }
die()   { err "$1"; exit 1; }
header(){ echo -e "\n${CYAN}${BOLD}━━━ $1 ━━━${NC}"; }

# ── Vollständiges Log mitschneiden (Debugging-Anforderung) ─────────────────
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
exec > >(tee "$LOG_FILE") 2>&1

# ── Cleanup & Fehlerkette ──────────────────────────────────────────────────
cleanup() {
    # if statt [[ ]] && – sonst gibt cleanup() bei leerer TMP_DIR Exit-Code 1
    # zurück und überschreibt den eigentlichen Exit-Status des Scripts.
    if [[ -n "${TMP_DIR:-}" && -d "$TMP_DIR" ]]; then
        rm -rf "$TMP_DIR"
    fi
}
trap cleanup EXIT

# Gibt bei Fehlern die KOMPLETTE Fehlerkette aus: Zeile, Befehl, Exit-Code,
# letzte Logzeilen sowie Container-Logs (Setup + Services), falls schon ein
# Container existiert.
on_error() {
    local ec=$1 line=$2 cmd=$3
    err "Installationsfehler – Exit-Code ${ec} in Zeile ${line}"
    err "Fehlgeschlagener Befehl: ${cmd}"
    if [[ -f "$LOG_FILE" ]]; then
        info "Letzte Logzeilen (${LOG_FILE}):"
        tail -n 20 "$LOG_FILE" | sed 's/^/    /' || true
    fi
    if [[ -n "${CT_ID:-}" ]] && pct status "$CT_ID" &>/dev/null; then
        info "Container-Logs (Setup + Services):"
        pct exec "$CT_ID" -- sh -c '
            tail -n 40 /var/log/sellbird-setup.log 2>/dev/null
            echo "--- journalctl -u sellbird-dashboard ---"
            journalctl -u sellbird-dashboard --no-pager 2>/dev/null | tail -n 25
            echo "--- journalctl -u sellbird-ttyd / nginx ---"
            journalctl -u sellbird-ttyd --no-pager 2>/dev/null | tail -n 10
            journalctl -u nginx --no-pager 2>/dev/null | tail -n 10
            echo "--- nginx-Konfigtest ---"
            nginx -t 2>&1 || true
        ' 2>/dev/null | sed 's/^/    /' || true
        info "Container $CT_ID wurde NICHT gelöscht – Inspektion: pct enter $CT_ID"
        info "Aufräumen: pct stop $CT_ID && pct destroy $CT_ID --purge"
    fi
    info "Vollständiges Log: $LOG_FILE"
    info "Neu ausführen mit vollem bash -x-Trace (exakter Befehl):"
    echo "    ${ONE_LINER} --debug"
    exit "$ec"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR

# ── Debug-Modus (voller bash -x-Trace) ─────────────────────────────────────
# (Vor parse_args, damit --debug selbst noch mitgetraced wird.)
if [[ "${1:-}" == "--debug" || "$0" == "--debug" ]]; then
    set -x
fi

# ── Hilfsfunktionen ────────────────────────────────────────────────────────
ct_exists() {
    # if statt [[ ]] && … – Rückgabewert sauber halten.
    # Name ist in `pct list` IMMER die letzte Spalte (Lock kann leer sein).
    if pct list 2>/dev/null | awk '{print $NF}' | grep -qx "${1:-}"; then
        return 0
    fi
    return 1
}

find_free_id() {
    local id="$ID_SCAN_START"
    while pct list 2>/dev/null | awk '{print $1}' | grep -qx "$id"; do
        id=$((id + 1))
    done
    echo "$id"
}

find_ct_id_by_hostname() {
    pct list 2>/dev/null | awk -v h="$CT_HOSTNAME" '$NF==h {print $1; exit}'
}

get_ct_ip() {
    # Grube (pipefail): bei pct-exec-Fehlschlag stirbt die Substitution –
    # deshalb || true INNERHALB von $(). Bei statischer IP direkt nutzen.
    local ct_id="$1"
    if [[ "$CT_IP" != "dhcp" ]]; then
        echo "${CT_IP%%/*}"
        return 0
    fi
    pct exec "$ct_id" -- hostname -I 2>/dev/null | awk '{print $1}' || true
    return 0
}

wait_for_ct_network() {
    # Nach pct start nicht blind sleep 3 (DHCP/DNS-Race) – aktiv pollen.
    local id="$1" tries=0 ip=""
    info "Warte auf Netzwerk im Container (DHCP) ..."
    while true; do
        ip=$(pct exec "$id" -- hostname -I 2>/dev/null | awk '{print $1}' || true)
        if [[ -n "$ip" ]]; then
            ok "Container-IP: $ip"
            return 0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 60 ]]; then
            err "Container hat nach 60 s keine IP bekommen."
            info "Prüfe: pct exec $id -- ip a   und DHCP am Bridge-Interface ($CT_BRIDGE)"
            return 1
        fi
        sleep 1
    done
}

verify_ct_dns() {
    # IP allein reicht nicht – git/curl/claude-Download brauchen Namensauflösung.
    # DNS kann FLAKY sein: 3 Erfolge in Folge verlangen; eine Störung →
    # Fallback (DNS des Hosts + öffentliche Resolver) + dhclient-Hook.
    local id="$1" ok_count=0 tries=0
    info "Prüfe DNS im Container (3x hintereinander) ..."
    while true; do
        if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
            ok_count=$((ok_count + 1))
            if [[ $ok_count -ge 3 ]]; then
                ok "DNS im Container funktioniert (3x bestätigt)"
                return 0
            fi
        else
            ok_count=0
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 10 ]]; then
            break
        fi
        sleep 2
    done
    local host_ns ns_list
    host_ns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    ns_list="1.1.1.1 8.8.8.8 9.9.9.9"
    if [[ -n "$host_ns" ]]; then
        ns_list="$host_ns $ns_list"
    fi
    warn "DNS im Container defekt – schreibe Fallback-Nameserver ($ns_list) nach /etc/resolv.conf"
    pct exec "$id" -- sh -c "printf 'nameserver %s\n' $ns_list > /etc/resolv.conf"
    # Dauerhaft: dhclient-Hook (verhindert das Überschreiben durch Lease-Renewals —
    # chattr +i funktioniert in unprivilegierten LXCs nicht).
    pct exec "$id" -- bash -c 'mkdir -p /etc/dhcp/dhclient-enter-hooks.d && printf "make_resolv_conf() { :; }\n" > /etc/dhcp/dhclient-enter-hooks.d/no-dns'
    if pct exec "$id" -- getent hosts github.com >/dev/null 2>&1; then
        ok "DNS-Fallback aktiv und gegen DHCP-Überschreiben geschützt – Auflösung funktioniert"
        return 0
    fi
    die "DNS im Container weiterhin ohne Funktion (auch mit Fallback).\n  Prüfe: pct exec $id -- cat /etc/resolv.conf && pct exec $id -- ping -c2 1.1.1.1\n  Firewall/Router: ausgehende DNS-Anfragen (Port 53) am Bridge-Netz erlauben."
}

ensure_ct_running() {
    # Update-/Verwaltungs-Pfade müssen einen GESTOPPTEN CT selbst starten –
    # pct exec auf gestopptem CT scheitert kryptisch (Exit 255).
    local ct_id="$1"
    local state
    state=$(pct status "$ct_id" 2>/dev/null || echo "unknown")
    if [[ "$state" == *"running"* ]]; then
        return 0
    fi
    warn "Container $ct_id läuft nicht (Status: ${state}) – starte ihn ..."
    if ! pct start "$ct_id" 2>&1 | tail -2; then
        die "Container $ct_id konnte nicht gestartet werden.\n  Manuell prüfen: pct start $ct_id && pct status $ct_id"
    fi
    info "Warte auf Netzwerk des Containers ..."
    local i ip=""
    for i in $(seq 1 60); do
        ip=$(pct exec "$ct_id" -- hostname -I 2>/dev/null | tr -d ' \n' || true)
        if [[ -n "$ip" ]]; then
            ok "Container läuft (IP: ${ip%% *})"
            return 0
        fi
        sleep 1
    done
    die "Container $ct_id hat nach 60 s keine IP (Bridge/Netz prüfen: pct exec $ct_id -- ip a)"
}

# ── Argumente parsen ───────────────────────────────────────────────────────
parse_args() {
    # Grube (bash -c): `bash -c "$(wget -qLO - URL)" --id 5` belegt das ERSTE
    # Argument nach dem Script-String mit $0, nicht $1 – die Option würde
    # still geschluckt. Fallback: startet $0 mit "-", ist es eine Option.
    local args=("$@")
    if [[ "$0" == -* ]]; then
        args=("$0" "$@")
    fi
    local i=0
    while [[ $i -lt ${#args[@]} ]]; do
        case "${args[$i]}" in
            --id)             CT_ID="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --hostname)       CT_HOSTNAME="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --storage)        CT_STORAGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --rootfs)         CT_ROOTFS="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --cores)          CT_CORES="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --memory)         CT_MEMORY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --swap)           CT_SWAP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --bridge)         CT_BRIDGE="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ip)             CT_IP="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --gateway)        CT_GATEWAY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --password)       CT_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --sshkey)         CT_SSHKEY="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --port)           PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --terminal-port)  TTYD_PORT="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --terminal-password) TTYD_PASSWORD="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --ref)            APP_REF="${args[$((i+1))]:-}"; i=$((i+2)) ;;
            --force)          FORCE_RECREATE=true; i=$((i+1)) ;;
            --yes|-y)         ASSUME_YES=true; i=$((i+1)) ;;
            --update)         UPDATE=true; i=$((i+1)) ;;
            --uninstall)      UNINSTALL=true; i=$((i+1)) ;;
            --status)         STATUS_CHECK=true; i=$((i+1)) ;;
            --debug)          set -x; i=$((i+1)) ;;
            --help|-h)        print_help; exit 0 ;;
            *) die "Unbekannte Option: ${args[$i]}  (–help zeigt alle Optionen)" ;;
        esac
    done
    # Ports hart validieren – sie landen direkt in Unit/nginx-Konfig im Container.
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1 || "$PORT" -gt 65535 ]]; then
        die "Ungültiger Port: '$PORT' (1–65535 erwartet, z. B. --port 8090)"
    fi
    if ! [[ "$TTYD_PORT" =~ ^[0-9]+$ ]] || [[ "$TTYD_PORT" -lt 1 || "$TTYD_PORT" -gt 65535 ]]; then
        die "Ungültiger Terminal-Port: '$TTYD_PORT' (1–65535 erwartet)"
    fi
    if [[ "$PORT" == "$TTYD_PORT" ]]; then
        die "Proxy-Port und Terminal-Port dürfen nicht identisch sein ($PORT)."
    fi
    if [[ -n "$APP_REF" ]] && ! [[ "$APP_REF" =~ ^[0-9a-f]{40}$ ]]; then
        die "--ref erwartet einen vollen 40-stelligen Commit-SHA (z. B. ${PINNED_REF})"
    fi
    if [[ "$TTYD_PASSWORD" == *:* ]]; then
        die "Terminal-Passwort darf keinen Doppelpunkt enthalten (ttyd-Basic-Auth user:pass)."
    fi
}

print_help() {
    cat <<'EOF'
🐦 Sellbird – Proxmox-Installer (Open-Source-Outreach auf Claude-/ChatGPT-Plan)

Installation:   bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)"

Optionen (hinter dem schließenden Anführungszeichen anhängen, z. B. ... " --id 210):
  --id ID             Container-ID (Default: nächste freie ab 200)
  --hostname NAME     Container-Hostname (Default: sellbird)
  --storage NAME      Storage für rootfs (Default: local-lvm)
  --rootfs GB         Disk-Größe (Default: 8)
  --cores N           vCPUs (Default: 2)
  --memory MB         RAM (Default: 2048; Chromium-Crawl ist der Spitzenbraucher)
  --swap MB           Swap (Default: 512)
  --bridge BR         Netzwerk-Bridge (Default: vmbr0)
  --ip CIDR           Statt DHCP, z. B. 192.168.1.50/24 (+ --gateway 192.168.1.1)
  --gateway GW        Gateway für statische IP
  --password PW       Root-Passwort (Default: automatisch generiert)
  --sshkey PFAD       Public-Key-Datei oder URL – ssh-key-Login als root im CT
  --port PORT         LAN-Port des Dashboards im Container (Default: 8090;
                      dahinter: sellbird-Uvicorn auf 127.0.0.1:5555, upstream-
                      seits loopback-only → nginx-Proxy rewrites Host/Origin)
  --terminal-port P   ttyd-Webterminal-Port (Default: 8091)
  --terminal-password PW  ttyd-Basic-Auth-Passwort (Default: automatisch; User: sellbird)
  --ref SHA           Fester Sellbird-Commit (40-stellig; Default: gepinnt auf
                      ${PINNED_LABEL} = b212385). --update geht immer auf origin/main.
  --force             Vorhandenen Container mit gleichem Hostname löschen und neu anlegen
  --yes / -y          Rückfragen überspringen
  --update            Sellbird im bestehenden Container auf origin/main ziehen
  --uninstall         Container stoppen und löschen
  --status            Status anzeigen (inkl. Unlock-Link)
  --debug             Vollständiges bash -x-Trace

  Modus:  Install (Default) / --update / --uninstall / --status / --debug
EOF
}

# ── In-Container-Setup-Script (idempotent) ─────────────────────────────────
# ACHTUNG: QUOTETER Heredoc ('INNEREOF') – nichts wird vom HOST-Script expandiert.
# Alle Werte kommen als Umgebungsvariablen via `pct exec -- env …` in den
# Container. Das vermeidet Escaping-Gruben komplett.
write_inner_script() {
    cat > "$TMP_DIR/setup-inner.sh" <<'INNEREOF'
#!/usr/bin/env bash
# =============================================================================
# Sellbird In-Container-Setup (idempotent – safe für Update & Re-Run)
# Variablen via env: APP_NAME, APP_DIR, VENV_DIR, APP_USER, APP_UID, APP_GID,
#   PORT, DASHBOARD_PORT, TTYD_PORT, TTYD_USER, TTYD_PASSWORD, SELLBIRD_REF,
#   UPSTREAM_URL, UPDATE_MODE, TZ_NAME
# =============================================================================
set -Eeuo pipefail
trap 'echo "✘ Setup-Fehler: exit $? in Zeile $LINENO: $BASH_COMMAND" >&2' ERR
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C   # verhindert perl/locale-Warnungen im frischen Debian-CT

err(){ echo "✘ $1" >&2; }
die(){ err "$1"; exit 1; }
ok_echo(){ echo "✔ $1"; }
warn_echo(){ echo "⚠ $1"; }

: "${APP_NAME:?APP_NAME fehlt (env)}"
: "${APP_DIR:?APP_DIR fehlt (env)}"
: "${VENV_DIR:?VENV_DIR fehlt (env)}"
: "${APP_USER:?APP_USER fehlt (env)}"
: "${APP_UID:?APP_UID fehlt (env)}"
: "${APP_GID:?APP_GID fehlt (env)}"
: "${PORT:?PORT fehlt (env)}"
: "${DASHBOARD_PORT:?DASHBOARD_PORT fehlt (env)}"
: "${TTYD_PORT:?TTYD_PORT fehlt (env)}"
: "${TTYD_USER:?TTYD_USER fehlt (env)}"
: "${TTYD_PASSWORD:?TTYD_PASSWORD fehlt (env)}"
: "${SELLBIRD_REF:?SELLBIRD_REF fehlt (env)}"
: "${UPSTREAM_URL:?UPSTREAM_URL fehlt (env)}"
UPDATE_MODE="${UPDATE_MODE:-0}"

echo ">>> Resolver-Dateien lesbar für apt-Sandbox stellen (getent-ok/apt-tot-Grube) ..."
chmod 0644 /etc/resolv.conf /etc/hosts /etc/hostname 2>/dev/null || true
mkdir -p /etc/apt/apt.conf.d
echo "APT::Sandbox::User \"root\";" > /etc/apt/apt.conf.d/99sellbird-sandbox

echo ">>> Basis-Pakete installieren (git, python3-venv, nginx, nano) ..."
apt-get update -qq
apt-get install -y -qq curl ca-certificates tzdata git python3 python3-venv nginx nano >/dev/null

echo ">>> DNS festschreiben (DHCP-DNS des Netzes ist unzuverlässig) ..."
mkdir -p /etc/dhcp/dhclient-enter-hooks.d
printf '# Sellbird: resolv.conf nicht von DHCP überschreiben lassen\nmake_resolv_conf() { :; }\n' > /etc/dhcp/dhclient-enter-hooks.d/no-dns
if [ -n "${TZ_NAME:-}" ]; then
    timedatectl set-timezone "${TZ_NAME}" 2>/dev/null || true
fi
if [ -n "${HOST_DNS:-}" ]; then
    printf 'nameserver %s\nnameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 9.9.9.9\n' "${HOST_DNS}" > /etc/resolv.conf
fi
if ! getent hosts github.com >/dev/null 2>&1; then
    die "DNS im Container defekt – Download von GitHub nicht möglich.\n  Debug: cat /etc/resolv.conf && getent hosts github.com"
fi

echo ">>> Benutzer ${APP_USER} (${APP_UID}:${APP_GID}) und Ordner ..."
if ! getent group "${APP_GID}" >/dev/null 2>&1; then
    groupadd -g "${APP_GID}" "${APP_USER}"
fi
# || true: User existiert evtl. noch NICHT – getent-Exit 1 würde sonst unter
# pipefail das Setup töten, bevor useradd ihn überhaupt anlegt.
APP_HOME=$(getent passwd "${APP_USER}" | cut -d: -f6 || true)
if ! id -u "${APP_USER}" >/dev/null 2>&1; then
    useradd -u "${APP_UID}" -g "${APP_GID}" -m -d /home/"${APP_USER}" -s /bin/bash "${APP_USER}"
    APP_HOME=$(getent passwd "${APP_USER}" | cut -d: -f6)
fi
install -d -o "${APP_USER}" -g "${APP_USER}" -m 0755 /opt/sellbird
if [ ! -d "${APP_HOME}" ]; then
    install -d -o "${APP_USER}" -g "${APP_USER}" -m 0750 "${APP_HOME}"
fi

echo ">>> ttyd ${TTYD_VERSION} installieren (statisches Web-Terminal-Binary) ..."
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    amd64) TTYD_ASSET="ttyd.x86_64" ;;
    arm64) TTYD_ASSET="ttyd.aarch64" ;;
    *) die "ttyd: nicht unterstützte Architektur ${ARCH} (amd64/arm64)" ;;
esac
if [ ! -x /usr/local/bin/ttyd ]; then
    # Download und SHA256SUMS getrennt holen (kein curl|pipe – Fehler dürfen
    # nicht verschluckt werden), Summe explizit gegen die Release-SUMS prüfen.
    curl -fsSL --retry 3 --max-time 120 "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/${TTYD_ASSET}" -o "/tmp/${TTYD_ASSET}"
    curl -fsSL --retry 3 --max-time 60 "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/SHA256SUMS" -o /tmp/ttyd-SHA256SUMS
    TTYD_SUM=$(awk -v a="${TTYD_ASSET}" '$2==a {print $1}' /tmp/ttyd-SHA256SUMS)
    if [ -z "$TTYD_SUM" ]; then
        die "ttyd-Asset ${TTYD_ASSET} fehlt in der SHA256SUMS des Releases."
    fi
    if ! echo "${TTYD_SUM}  /tmp/${TTYD_ASSET}" | sha256sum -c - >/dev/null 2>&1; then
        die "ttyd-Checksumme stimmt NICHT mit der SHA256SUMS überein – Abbruch."
    fi
    install -m 0755 "/tmp/${TTYD_ASSET}" /usr/local/bin/ttyd
    rm -f "/tmp/${TTYD_ASSET}" /tmp/ttyd-SHA256SUMS
fi
TTYD_VER_OUT=$(/usr/local/bin/ttyd -v 2>/dev/null || true)
# ttyd 1.7.7 server.c: 'ttyd -v' gibt "ttyd version 1.7.7-40e79c7" aus; der
# Versions-Block steht in der Usage NICHT in der Zeile mit "ttyd" – deshalb
# NIE zeilenbasiert "ttyd.*VERSION" matchen, sondern Prefix-Match.
if grep -q "ttyd version ${TTYD_VERSION}" <<< "$TTYD_VER_OUT"; then
    ok_echo "ttyd ${TTYD_VERSION} einsatzbereit"
else
    die "/usr/local/bin/ttyd meldet nicht die erwartete Version ${TTYD_VERSION}\n  Ausgabe war: ${TTYD_VER_OUT}"
fi

echo ">>> Sellbird-Quellcode laden (${UPSTREAM_URL}) ..."
TARGET="${SELLBIRD_REF}"
if [ "${UPDATE_MODE}" = "1" ]; then
    TARGET="origin/main"
fi
if [ ! -d "${APP_DIR}/.git" ]; then
    # Sauberer Erst-Klon als APP_USER (alles unter /opt/sellbird gehört dem
    # App-User – Update-/pip-Läufe als root würden sonst "dubious ownership".
    rm -rf "${APP_DIR}"
    runuser -u "${APP_USER}" -- git clone --quiet "${UPSTREAM_URL}" "${APP_DIR}"
fi
runuser -u "${APP_USER}" -- git -C "${APP_DIR}" fetch origin --prune --quiet || true
runuser -u "${APP_USER}" -- git -C "${APP_DIR}" checkout --force --quiet "${TARGET}"
# KEIN `git clean` hier: prompts/ und skills/ sind laut Upstream vom Nutzer
# editierbar – ein Clean würde beim Re-Run/Update eigene Prompts löschen.
REF_SHORT=$(runuser -u "${APP_USER}" -- git -C "${APP_DIR}" rev-parse --short HEAD)
UPSTREAM_VERSION=$(grep -m1 '^version' "${APP_DIR}/pyproject.toml" | cut -d'"' -f2)
echo "${UPSTREAM_VERSION} (${REF_SHORT})" > "${APP_DIR}/VERSION"
echo "    Version: ${UPSTREAM_VERSION} @ ${REF_SHORT} (Target: ${TARGET})"

echo ">>> Python-Venv (${VENV_DIR}) + pip-Abhängigkeiten ..."
if [ ! -x "${VENV_DIR}/bin/python" ]; then
    runuser -u "${APP_USER}" -- python3 -m venv "${VENV_DIR}"
fi
runuser -u "${APP_USER}" -- "${VENV_DIR}/bin/pip" install --quiet --no-input --upgrade pip setuptools wheel
runuser -u "${APP_USER}" -- "${VENV_DIR}/bin/pip" install --quiet --no-input -e "${APP_DIR}"
runuser -u "${APP_USER}" -- "${VENV_DIR}/bin/python" -c "import sellbird.cli" \
    || die "Import-Check fehlgeschlagen – pip-Install nicht vollständig (Log oben)."
ok_echo "Sellbird ${UPSTREAM_VERSION} importiert"

echo ">>> Playwright-Chromium (Website-Signals) ..."
# System-Bibliotheken als root (install-deps nutzt apt), Browser-Binary als
# APP_USER in sein Home-Cache (der Service läuft unter diesem Benutzer).
"${VENV_DIR}/bin/python" -m playwright install-deps chromium >/dev/null
runuser -u "${APP_USER}" -- "${VENV_DIR}/bin/python" -m playwright install chromium

echo ">>> Claude Code CLI (Reasoning-Engine, offizieller Native-Installer) ..."
CLAUDE_BIN="${APP_HOME}/.local/bin/claude"
if [ ! -x /usr/local/bin/claude ] || [ ! -x "${CLAUDE_BIN}" ]; then
    # curl|bash NICHT in einer Pipeline: Download-Fehler würden still
    # verschluckt (curl-Sicherheitstellung) – erst laden, dann ausführen.
    curl -fsSL --retry 3 --max-time 120 https://claude.ai/install.sh -o /tmp/claude-install.sh
    # || die statt set -e: sonst verschluckt der ERR-Trap die konkrete Diagnose.
    if ! runuser -u "${APP_USER}" -- bash /tmp/claude-install.sh; then
        die "Claude-Installer fehlgeschlagen (Exit $?) – Ausgabe oben prüfen."
    fi
    rm -f /tmp/claude-install.sh
    if [ ! -x "${CLAUDE_BIN}" ]; then
        die "claude-Binary nach Installer-Lauf nicht gefunden: ${CLAUDE_BIN}\n  Manuell im CT: pct enter <CT-ID>, dann 'curl -fsSL https://claude.ai/install.sh | bash'"
    fi
    ln -sfn "${CLAUDE_BIN}" /usr/local/bin/claude
fi
CLAUDE_VER=$(/usr/local/bin/claude --version 2>/dev/null | head -n1 || true)
ok_echo "Claude CLI: ${CLAUDE_VER:-unbekannt}"
# Upstreams eigene Isolationsprüfung (wie im offiziellen Dockerfile) – PATH
# muss ~/.local/bin enthalten, sonst findet check_cli die Binary nicht.
if ! runuser -u "${APP_USER}" -- env PATH="${APP_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
        "${VENV_DIR}/bin/python" -c "from sellbird.claude_runtime import check_cli; print(check_cli())" >/dev/null; then
    die "Sellbird-claude_runtime.check_cli() fehlgeschlagen – Claude-CLI-Einbau unvollständig (Log oben)."
fi
ok_echo "sellbird.claude_runtime.check_cli() bestätigt die Claude-CLI"

echo ">>> .env anlegen (Credentials: Gmail-OAuth/SMTP – bleibt Benutzer-Datei) ..."
if [ ! -f "${APP_DIR}/.env" ]; then
    cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
fi
chown "${APP_USER}:${APP_USER}" "${APP_DIR}/.env"
chmod 0600 "${APP_DIR}/.env"

echo ">>> Shell-Umgebung für das Webterminal (${APP_USER}) ..."
# ttyd startet 'bash -l': Login-Shell liest .bash_profile -> .bashrc.
if ! grep -q 'sellbird-shell-env' "${APP_HOME}/.bashrc" 2>/dev/null; then
    cat >> "${APP_HOME}/.bashrc" <<ENVEOF
# --- sellbird-shell-env (vom Installer) ---
export PATH="\$HOME/.local/bin:${VENV_DIR}/bin:\$PATH"
export SELLBIRD_HOME="${APP_DIR}"
# --- end sellbird-shell-env ---
ENVEOF
fi
touch "${APP_HOME}/.bash_profile"
chown "${APP_USER}:${APP_USER}" "${APP_HOME}/.bashrc" "${APP_HOME}/.bash_profile"

echo ">>> nginx-Reverse-Proxy (0.0.0.0:${PORT} -> 127.0.0.1:${DASHBOARD_PORT}) ..."
# Sellbird-UI ist upstream loopback-only + Token-Guard. Der Proxy schreibt
# Host/Origin auf localhost um (der Guard verlangt Host=Loopback und
# Origin == http://<Host>), reicht WebSockets durch und streamt ohne
# Pufferung. Das Bearer-Token bleibt weiter Pflicht.
cat > /etc/nginx/sites-available/sellbird.conf <<'NGINXEOF'
# Sellbird-Dashboard fürs LAN – vom Installer verwaltet.
server {
    listen 0.0.0.0:__PORT__;
    listen [::]:__PORT__;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:__DASHBOARD_PORT__;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        # Guard-Requirements: Host muss Loopback sein, Origin exakt
        # http://<Host>. Browser-Rechenwerte (Sec-Fetch-Site = same-origin
        # für die Seite selbst) bleiben unangetastet.
        proxy_set_header Host "localhost";
        proxy_set_header Origin "http://localhost";
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_buffering off;
        proxy_request_buffering off;
        client_max_body_size 50m;
    }
}
NGINXEOF
sed -i "s/__PORT__/${PORT}/g; s/__DASHBOARD_PORT__/${DASHBOARD_PORT}/g" /etc/nginx/sites-available/sellbird.conf
chown root:root /etc/nginx/sites-available/sellbird.conf
ln -sfn /etc/nginx/sites-available/sellbird.conf /etc/nginx/sites-enabled/sellbird.conf
rm -f /etc/nginx/sites-enabled/default
if ! nginx -t >/dev/null 2>&1; then
    nginx -t
    die "nginx-Konfigtest fehlgeschlagen – siehe Ausgabe oben."
fi
systemctl enable nginx >/dev/null 2>&1
systemctl restart nginx

echo ">>> systemd-Units (User ${APP_USER}, Restart=always) ..."
cat > /etc/systemd/system/sellbird-dashboard.service <<UNITEOF
[Unit]
Description=Sellbird Dashboard (outreach platform, loopback :${DASHBOARD_PORT})
Documentation=https://github.com/ethanplusai/sellbird
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=SELLBIRD_HOME=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=HOME=${APP_HOME}
Environment=PATH=${APP_HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=${VENV_DIR}/bin/sellbird dashboard
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNITEOF

cat > /etc/systemd/system/sellbird-ttyd.service <<UNITEOF
[Unit]
Description=Sellbird Webterminal (ttyd als ${APP_USER}: Claude-Login, setup, train, run)
Documentation=https://github.com/ethanplusai/sellbird
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
Environment=HOME=${APP_HOME}
ExecStart=/usr/local/bin/ttyd --port ${TTYD_PORT} --credential ${TTYD_USER}:${TTYD_PASSWORD} --max-clients 3 -W bash -l
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable sellbird-dashboard >/dev/null 2>&1
systemctl enable sellbird-ttyd >/dev/null 2>&1
systemctl restart sellbird-dashboard
systemctl restart sellbird-ttyd

echo ">>> Warten auf Dashboard (127.0.0.1:${DASHBOARD_PORT}) ..."
CODE=""
for _ in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${DASHBOARD_PORT}/" || true)
    if [ "$CODE" = "200" ]; then
        break
    fi
    sleep 1
done
if [ "$CODE" != "200" ]; then
    err "Dashboard antwortet nicht (letzter HTTP-Code: ${CODE:-000})."
    journalctl -u sellbird-dashboard --no-pager 2>/dev/null | tail -n 30 || true
    die "Sellbird-Dashboard läuft nicht wie erwartet – Logs oben."
fi

echo ">>> Warten auf Proxy (127.0.0.1:${PORT}) ..."
PCODE=""
for _ in $(seq 1 30); do
    PCODE=$(curl -s -o /dev/null --max-time 3 -w '%{http_code}' "http://127.0.0.1:${PORT}/" || true)
    if [ "$PCODE" = "200" ]; then
        break
    fi
    sleep 1
done
if [ "$PCODE" != "200" ]; then
    err "Proxy antwortet nicht (letzter HTTP-Code: ${PCODE:-000})."
    nginx -t 2>&1 || true
    journalctl -u nginx --no-pager 2>/dev/null | tail -n 15 || true
    die "nginx-Proxy läuft nicht wie erwartet – Logs oben."
fi

# Token für den Unlock-Link (datei ist owner-only; Existenz prüfen, Wert
# liest der Host-Teil selbst für die Zusammenfassung).
if [ ! -f "${APP_DIR}/data/dashboard-token" ]; then
    warn_echo "dashboard-token noch nicht vorhanden – Unlock-Link nach dem ersten Dashboard-Start abrufen:"
    warn_echo "  pct exec <CT-ID> -- cat ${APP_DIR}/data/dashboard-token"
fi

echo ">>> Setup abgeschlossen (Sellbird ${UPSTREAM_VERSION} @ ${REF_SHORT})."
INNEREOF
}

run_inner_setup() {
    local ct_id="$1"
    header "⚙️  Installiere Sellbird im Container $ct_id"
    # ttyd-Passwort: bei Update das BESTEHENDE aus der Unit übernehmen (sonst
    # ändert ein --update lautlos das Passwort), sonst frisch generieren.
    if [[ -z "$TTYD_PASSWORD" ]]; then
        TTYD_PASSWORD=$(pct exec "$ct_id" -- sh -c \
            "sed -n 's/.*--credential ${TTYD_USER}:\([^ ]*\).*/\1/p' /etc/systemd/system/sellbird-ttyd.service 2>/dev/null | head -n1" || true)
        if [[ -n "$TTYD_PASSWORD" ]]; then
            ok "Bestehendes ttyd-Passwort übernommen (Update-Lauf)"
        fi
    fi
    if [[ -z "$TTYD_PASSWORD" ]]; then
        TTYD_PASSWORD=$(openssl rand -base64 12 2>/dev/null | tr '+/' '-_' || true)
        if [[ -z "$TTYD_PASSWORD" ]]; then
            TTYD_PASSWORD="td-$(date +%s)"
        fi
        TTYD_PASSWORD=${TTYD_PASSWORD%=}
    fi
    # DNS des Hosts in den Container bringen (dort resolvert das Setup garantiert –
    # der DHCP-DNS des Zielnetzes war bei früheren Installationen unzuverlässig).
    local host_dns tz_name
    host_dns=$(grep -h '^nameserver' /etc/resolv.conf 2>/dev/null \
               | awk '{print $2}' | grep -v '^127\.' | head -1 || true)
    if [[ -z "$TZ_NAME" ]]; then
        if [[ -r /etc/timezone ]]; then
            TZ_NAME=$(head -n1 /etc/timezone | tr -d '[:space:]' || true)
        fi
        if [[ -z "$TZ_NAME" ]] && command -v timedatectl >/dev/null 2>&1; then
            TZ_NAME=$(timedatectl show -p Timezone --value 2>/dev/null | head -n1 || true)
        fi
        tz_name="${TZ_NAME:-Etc/UTC}"
    else
        tz_name="$TZ_NAME"
    fi
    local ref="$APP_REF"
    if [[ -z "$ref" ]]; then
        ref="$PINNED_REF"
    fi
    local update_mode=0
    if $UPDATE; then
        update_mode=1
    fi
    write_inner_script
    pct push "$ct_id" "$TMP_DIR/setup-inner.sh" /root/setup-inner.sh
    # Variablen via env in den Container (kein Expansion-Heredoc → keine
    # Escaping-Gruben). set -o pipefail: ein Crash im Inner-Script darf nicht
    # durch `tee` maskiert werden (sonst meldet der Host Erfolg, der CT nicht).
    pct exec "$ct_id" -- env APP_NAME="$APP_NAME" APP_DIR="/opt/${APP_NAME}/app" \
        VENV_DIR="/opt/${APP_NAME}/venv" APP_USER="$APP_USER" APP_UID="$APP_UID" APP_GID="$APP_GID" \
        PORT="$PORT" DASHBOARD_PORT="$DASHBOARD_PORT" TTYD_PORT="$TTYD_PORT" \
        TTYD_USER="$TTYD_USER" TTYD_PASSWORD="$TTYD_PASSWORD" TTYD_VERSION="$TTYD_VERSION" \
        SELLBIRD_REF="$ref" UPSTREAM_URL="$UPSTREAM_URL" UPDATE_MODE="$update_mode" \
        HOST_DNS="${host_dns:-1.1.1.1}" TZ_NAME="$tz_name" \
        bash -c 'set -o pipefail; bash /root/setup-inner.sh 2>&1 | tee /var/log/sellbird-setup.log'
}

get_installed_version() {
    # Version aus /opt/sellbird/app/VERSION (vom Inner-Script geschrieben) –
    # || true INNERHALB von $() (pipefail-Grube bei pct-exec-Fehlschlag).
    local v=""
    v=$(pct exec "$1" -- cat "/opt/${APP_NAME}/app/VERSION" 2>/dev/null | tail -n 1 || true)
    echo "$v"
}

get_dashboard_token() {
    # Unlock-Token aus dem CT (Datei ist owner-only, pct exec läuft als root).
    local t=""
    t=$(pct exec "$1" -- cat "/opt/${APP_NAME}/app/data/dashboard-token" 2>/dev/null | tail -n 1 || true)
    echo "$t"
}

# ── Verifikation ───────────────────────────────────────────────────────────
verify_installation() {
    local ct_id="$1" tries=0 code="" state=""

    header "✅ Verifikation"

    # Services aktiv?
    local svc
    for svc in sellbird-dashboard sellbird-ttyd nginx; do
        tries=0
        while true; do
            if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
                ok "Service $svc läuft"
                break
            fi
            tries=$((tries + 1))
            if [[ $tries -ge 30 ]]; then
                local diag
                diag=$(pct exec "$ct_id" -- sh -c "
                    echo \"--- journalctl -u $svc ---\"
                    journalctl -u $svc --no-pager 2>/dev/null | tail -n 20 || true
                " 2>/dev/null || true)
                die "Service $svc läuft nicht.\n\n${diag}"
            fi
            sleep 1
        done
    done

    # Sellbird-CLI importierbar + Claude-CLI erreichbar (Dockerfile-Pendant)
    if pct exec "$ct_id" -- env PATH="/home/${APP_USER}/.local/bin:/usr/local/bin:/usr/bin:/bin" \
           "/opt/${APP_NAME}/venv/bin/python" -c "from sellbird.claude_runtime import check_cli; print(check_cli())" >/dev/null 2>&1; then
        ok "Sellbird-Import + claude_runtime.check_cli() im Container OK"
    else
        warn "check_cli() schlägt im Container fehl – Claude-Login/Terminal prüfen."
    fi

    # Dashboard direkt (Loopback im CT) – öffentliche Shell, HTTP 200 ohne Token.
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${DASHBOARD_PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Dashboard antwortet (HTTP 200 auf http://127.0.0.1:${DASHBOARD_PORT}/)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            local diag
            diag=$(pct exec "$ct_id" -- sh -c '
                echo "--- Listener (ss -tlnp) ---"
                ss -tlnp 2>/dev/null | grep -E ":5555" || echo "  (KEIN Listener auf Port 5555)"
                echo "--- journalctl -u sellbird-dashboard ---"
                journalctl -u sellbird-dashboard --no-pager 2>/dev/null | tail -n 12 || true
                echo "--- systemd-Unit ---"
                systemctl cat sellbird-dashboard --no-pager 2>/dev/null | grep -E "ExecStart|User=|Restart" || true
            ' 2>/dev/null || true)
            die "Dashboard antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n\n${diag}"
        fi
        sleep 1
    done

    # Proxy (LAN-Zugang) – im CT und vom PROXMOX-HOST aus.
    tries=0
    while true; do
        code=$(pct exec "$ct_id" -- curl -s -o /dev/null --max-time 3 -w '%{http_code}' \
               "http://127.0.0.1:${PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Proxy antwortet (HTTP 200 auf http://127.0.0.1:${PORT}/)"
            break
        fi
        tries=$((tries + 1))
        if [[ $tries -ge 30 ]]; then
            local diag
            diag=$(pct exec "$ct_id" -- sh -c '
                echo "--- nginx-Konfigtest ---"
                nginx -t 2>&1 || true
                echo "--- journalctl -u nginx ---"
                journalctl -u nginx --no-pager 2>/dev/null | tail -n 12 || true
            ' 2>/dev/null || true)
            die "Proxy antwortet nicht (letzter HTTP-Code: ${code:-unbekannt}).\n\n${diag}"
        fi
        sleep 1
    done

    local ct_ip="" host_code=""
    ct_ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ct_ip" ]]; then
        host_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "http://${ct_ip}:${PORT}/" || true)
        if [[ "$host_code" == "200" ]]; then
            ok "Vom Host erreichbar: http://${ct_ip}:${PORT} (HTTP 200)"
        else
            warn "Im CT OK, aber vom Proxmox-Host nicht erreichbar (HTTP ${host_code:-000} über http://${ct_ip}:${PORT})."
            info "Prüfe CT-Firewall (pct config $ct_id | grep -E 'net0|firewall') und Bridge-Setup."
        fi
    fi

    # Autostart-Status (Reboot-Sicherheit)
    state=$(pct config "$ct_id" 2>/dev/null | awk -F': ' '/^onboot:/ {print $2}' | tr -d ' ' || true)
    if [[ "$state" == "1" ]]; then
        ok "Autostart: onboot=1 (Container startet nach Host-Reboot automatisch)"
    else
        warn "Autostart: onboot ist nicht gesetzt (pct set $ct_id --onboot 1)"
    fi
    local enable_ok=true
    for svc in sellbird-dashboard sellbird-ttyd nginx; do
        if ! pct exec "$ct_id" -- systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            enable_ok=false
            warn "Service $svc ist nicht enabled – nach Container-Reboot startet er nicht."
        fi
    done
    if $enable_ok; then
        ok "Alle Services sind enabled (starten beim Booten des Containers automatisch)"
    fi
}

# ── Zusammenfassung ────────────────────────────────────────────────────────
print_summary() {
    header "🐦  Sellbird ist bereit!"

    local ct_ip installed_version="" token="" ttyd_pw_hint=""
    ct_ip=$(get_ct_ip "$CT_ID")
    if [[ -z "$ct_ip" ]]; then
        ct_ip="<IP-ADRESSE>"
    fi
    installed_version=$(get_installed_version "$CT_ID")
    token=$(get_dashboard_token "$CT_ID")
    if [[ -n "$TTYD_PASSWORD" ]]; then
        ttyd_pw_hint="$TTYD_PASSWORD"
    fi

    echo ""
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    if [[ -n "$token" ]]; then
        echo -e "  ${GREEN}  🌐 Dashboard:  http://${ct_ip}:${PORT}/#token=${token}${NC}"
    else
        echo -e "  ${GREEN}  🌐 Dashboard:  http://${ct_ip}:${PORT}  (Unlock-Link s. unten)${NC}"
    fi
    echo -e "  ${GREEN}  🐚 Terminal:   http://${ct_ip}:${TTYD_PORT}  (Login: ${TTYD_USER} / ${ttyd_pw_hint:-<PW s. Log>})${NC}"
    if [[ -n "$installed_version" ]]; then
        echo -e "  ${GREEN}  📦 Version:    ${installed_version}${NC}"
    fi
    echo -e "  ${GREEN}  🔧 Installer:  v${INSTALLER_VERSION}${NC}"
    echo -e "  ${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  ${CYAN}Erste Schritte (alles im Webterminal http://${ct_ip}:${TTYD_PORT}):${NC}"
    echo "  1. Dashboard-Unlock-Link oben im Browser öffnen (Token im #-Fragment"
    echo "     steckt – ohne ihn zeigt die UI nur das leere Shell)."
    echo "  2. Claude-Login: im Terminal 'claude' starten und per OAuth anmelden"
    echo "     (Claude Pro/Max). Alternative Codex: docs/codex.md im Repo."
    echo "  3. Sellbird einrichten: 'sellbird setup' (Persona/Produkt/ICP) und"
    echo "     Mailkanal in /opt/sellbird/app/.env (GMAIL_CLIENT_ID/SECRET oder"
    echo "     SMTP_*; danach 'sellbird gmail auth' bzw. 'sellbird smtp test')."
    echo "  4. Trainieren & loslegen: 'sellbird train https://deine-firma.tld',"
    echo "     'sellbird signals --confirm free', 'sellbird discover'."
    echo "     Versand startet NIE ohne Freigabe im Outbox (Autopilot = opt-in)."
    echo ""
    echo -e "  ${CYAN}Sicherheit & Betrieb:${NC}"
    echo "  - Das Dashboard ist upstream loopback-only; der nginx-Proxy (Port"
    echo "    ${PORT}) rewrites Host/Origin – der Bearer-Token-Guard bleibt aktiv."
    echo "    Unlock-Link NICHT weitergeben (er schaltet die volle UI frei)."
    echo "  - Headless-Secrets: das System-Keychain fehlt im LXC – Credentials"
    echo "    gehören in /opt/${APP_NAME}/app/.env (0600), nicht in die DB."
    echo "  - Port ${PORT}/${TTYD_PORT} NICHT per Router-Portforwarding ins Internet stellen."
    echo ""
    echo -e "  ${CYAN}Nützliche Befehle (exakt kopierbar):${NC}"
    echo "  Status:    ${ONE_LINER} --status"
    echo "  Update:    ${ONE_LINER} --update"
    echo "  Deinstall: ${ONE_LINER} --uninstall"
    echo "  Unlock-Link: pct exec ${CT_ID} -- cat /opt/${APP_NAME}/app/data/dashboard-token"
    echo "  Logs:      pct exec ${CT_ID} -- journalctl -u sellbird-dashboard -f"
    echo "  Terminal:  pct enter ${CT_ID}"
    echo ""
}

# ── Install ────────────────────────────────────────────────────────────────
do_install() {
    header "🐦 Installiere Sellbird (LXC)"
    info "Installer-Version: v${INSTALLER_VERSION}  |  Pin: ${PINNED_LABEL} (${PINNED_REF:0:7})"

    if [[ $EUID -ne 0 ]]; then
        die "Bitte als root ausführen (auf dem Proxmox-Host)."
    fi
    if ! command -v pct >/dev/null 2>&1; then
        die "pct nicht gefunden – das Script muss auf einem Proxmox-VE-Host laufen."
    fi

    # Bereits vorhanden?
    local existing
    existing=$(find_ct_id_by_hostname || true)
    if [[ -n "$existing" ]]; then
        if $FORCE_RECREATE; then
            # Gleiche CT-ID wiederverwenden, wenn der Nutzer keine gesetzt hat –
            # sonst rutscht der Neu-Container auf die nächste freie ID ab 200.
            if [[ -z "$CT_ID" ]]; then
                CT_ID="$existing"
            fi
            warn "Container $existing ($CT_HOSTNAME) existiert – --force: lösche und lege neu an."
            warn "DAMIT VERLIEREN ALLE DATEN (Pipeline-DB, .env, Claude-Login)!"
            pct stop "$existing" || true
            pct destroy "$existing" --purge
        else
            die "Container $existing mit Hostname '$CT_HOSTNAME' existiert bereits.\n  Update:  ${ONE_LINER} --update\n  Neu aufsetzen (Daten weg):  ${ONE_LINER} --force"
        fi
    fi

    # Debian-Template sicherstellen (13 bevorzugt = Python 3.13; Fallback 12 = 3.11)
    header "🧱 Container-Template"
    local template=""
    template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o 'debian-13-standard[^ ]*' | sort -rV | head -1 || true)
    if [[ -z "$template" ]]; then
        template=$(pveam list local 2>/dev/null | awk '{print $1}' | grep -o 'debian-12-standard[^ ]*' | sort -rV | head -1 || true)
    fi
    if [[ -z "$template" ]]; then
        info "Kein Debian-12/13-Template vorhanden – lade es herunter ..."
        pveam update
        template=$(pveam available --section system 2>/dev/null | grep -o 'debian-13-standard[^ ]*' | sort -rV | head -1 || true)
        if [[ -z "$template" ]]; then
            template=$(pveam available --section system 2>/dev/null | grep -o 'debian-12-standard[^ ]*' | sort -rV | head -1 || true)
        fi
        if [[ -z "$template" ]]; then
            die "Weder debian-13- noch debian-12-standard-Template gefunden (pveam available leer?)."
        fi
        pveam download local "$template"
    fi
    ok "Template: $template"

    # ID & Passwörter
    if [[ -z "$CT_ID" ]]; then
        CT_ID=$(find_free_id)
        info "Nächste freie CT-ID: $CT_ID"
    fi
    if [[ -z "$CT_PASSWORD" ]]; then
        CT_PASSWORD=$(openssl rand -base64 12 2>/dev/null || true)
        if [[ -z "$CT_PASSWORD" ]]; then
            CT_PASSWORD="sb-$(date +%s)"
        fi
    fi

    # Container anlegen
    header "🚀 Erzeuge Container $CT_ID ($CT_HOSTNAME)"
    local net0="name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},firewall=0"
    if [[ -n "$CT_GATEWAY" ]]; then
        net0+=",gateway=${CT_GATEWAY}"
    fi
    local ssh_keys_args=()
    if [[ -n "$CT_SSHKEY" ]]; then
        if [[ "$CT_SSHKEY" == http://* || "$CT_SSHKEY" == https://* ]]; then
            info "Lade SSH-Public-Key herunter ..."
            wget -q --tries=3 -O "$TMP_DIR/sshkey.pub" "$CT_SSHKEY" || die "SSH-Key-URL nicht ladbar: $CT_SSHKEY"
        elif [[ -f "$CT_SSHKEY" ]]; then
            cp "$CT_SSHKEY" "$TMP_DIR/sshkey.pub"
        else
            die "SSH-Key-Datei nicht gefunden: $CT_SSHKEY"
        fi
        if [[ ! -s "$TMP_DIR/sshkey.pub" ]]; then
            die "SSH-Key-Datei ist leer: $CT_SSHKEY"
        fi
        SSH_KEY_FILE="$TMP_DIR/sshkey.pub"
        ok "SSH-Public-Key wird in den Container installiert (ssh-key-Login als root)"
        ssh_keys_args=(--ssh-public-keys "$SSH_KEY_FILE")
    fi
    pct create "$CT_ID" "local:vztmpl/${template}" \
        --hostname "$CT_HOSTNAME" \
        --cores "$CT_CORES" \
        --memory "$CT_MEMORY" \
        --swap "$CT_SWAP" \
        --rootfs "${CT_STORAGE}:${CT_ROOTFS}" \
        --net0 "$net0" \
        --unprivileged 1 \
        --features nesting=1 \
        --onboot 1 \
        --password "$CT_PASSWORD" \
        "${ssh_keys_args[@]}"
    ok "Container $CT_ID erstellt"

    pct start "$CT_ID"
    ok "Container $CT_ID gestartet"

    wait_for_ct_network "$CT_ID"
    verify_ct_dns "$CT_ID"

    run_inner_setup "$CT_ID"
    verify_installation "$CT_ID"
    print_summary
}

# ── Update ─────────────────────────────────────────────────────────────────
do_update() {
    header "🔄 Update Sellbird (origin/main, gepinnter Install-Ref bleibt beim Erst-Install)"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        die "Kein Container mit Hostname '$CT_HOSTNAME' gefunden.\n  Erst installieren:  ${ONE_LINER}"
    fi
    CT_ID="$ct_id"

    ensure_ct_running "$ct_id"
    verify_ct_dns "$ct_id"

    run_inner_setup "$ct_id"
    verify_installation "$ct_id"

    ok "Update abgeschlossen – Pipeline-DB, .env, Claude-Login und dashboard-token blieben erhalten."
    info "Claude CLI wird bewusst NICHT angefasst; Update im Terminal: claude update"
    print_summary
}

# ── Uninstall ──────────────────────────────────────────────────────────────
do_uninstall() {
    header "🗑️  Deinstalliere Sellbird"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden – nichts zu tun."
        return 0
    fi
    CT_ID="$ct_id"

    warn "Container $ct_id ($CT_HOSTNAME) wird GESTOPPT und GELÖSCHT."
    warn "Damit sind auch Pipeline-DB, .env-Credentials und der Claude-Login weg!"
    warn "  Sichern:  pct exec $ct_id -- tar -C /opt -czf /tmp/sellbird.tgz ${APP_NAME}"
    if ! $ASSUME_YES; then
        local answer=""
        if ! read -r -t 60 -p "Wirklich löschen? (ja/NEIN): " answer; then
            die "Keine Bestätigung erhalten (nicht-interaktiv?) – nichts gelöscht.\n  Erzwingen:  ${ONE_LINER} --uninstall --yes"
        fi
        if [[ "$answer" != "ja" ]]; then
            info "Abgebrochen – nichts gelöscht."
            return 0
        fi
    fi
    pct stop "$ct_id" || true
    pct destroy "$ct_id" --purge
    ok "Container $ct_id entfernt."
}

# ── Status ─────────────────────────────────────────────────────────────────
do_status() {
    header "📊 Status Sellbird"
    info "Installer-Version: v${INSTALLER_VERSION}"

    local ct_id
    ct_id=$(find_ct_id_by_hostname || true)
    if [[ -z "$ct_id" ]]; then
        warn "Kein Container mit Hostname '$CT_HOSTNAME' gefunden."
        info "Installieren:  ${ONE_LINER}"
        return 0
    fi
    CT_ID="$ct_id"

    pct list 2>/dev/null | awk -v id="$ct_id" '$1==id {print "Container:  " $1 " (" $2 ") – " $4}'

    # Gestoppten CT nicht als "Service läuft nicht" fehldeklarieren
    local state
    state=$(pct status "$ct_id" 2>/dev/null | awk '{print $2}' || true)
    if [[ "$state" != "running" ]]; then
        warn "Container $ct_id ist nicht gestartet (${state:-unbekannt}) – Services/Version/Unlock-Link ohne Start nicht prüfbar."
        info "Starten:    pct start $ct_id"
        return 0
    fi

    local svc
    for svc in sellbird-dashboard sellbird-ttyd nginx; do
        if pct exec "$ct_id" -- systemctl is-active --quiet "$svc" 2>/dev/null; then
            ok "Service:   $svc läuft"
        else
            err "Service:   $svc läuft NICHT"
            info "Logs:      pct exec $ct_id -- journalctl -u $svc -e"
        fi
    done

    local installed_version=""
    installed_version=$(get_installed_version "$ct_id")
    if [[ -n "$installed_version" ]]; then
        info "Version:   ${installed_version}"
    else
        warn "Version:   nicht ermittelbar (App installiert?)"
    fi

    local ip code="" token=""
    ip=$(get_ct_ip "$ct_id")
    if [[ -n "$ip" ]]; then
        code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${ip}:${PORT}/" || true)
        if [[ "$code" == "200" ]]; then
            ok "Web-UI:    http://${ip}:${PORT}  (HTTP 200)"
        else
            warn "Web-UI:    HTTP-Code ${code:-unbekannt} von http://${ip}:${PORT}"
        fi
        token=$(get_dashboard_token "$ct_id")
        if [[ -n "$token" ]]; then
            info "Unlock:    http://${ip}:${PORT}/#token=${token}"
        fi
    else
        warn "Container hat keine IP (läuft er?)."
    fi

    local onboot=""
    onboot=$(pct config "$ct_id" 2>/dev/null | awk -F': ' '/^onboot:/ {print $2}' | tr -d ' ' || true)
    if [[ "$onboot" == "1" ]]; then
        ok "Autostart: onboot=1"
    else
        warn "Autostart: onboot nicht gesetzt (pct set $ct_id --onboot 1)"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────
parse_args "$@"

TMP_DIR=$(mktemp -d)

if $UNINSTALL; then
    do_uninstall
elif $UPDATE; then
    do_update
elif $STATUS_CHECK; then
    do_status
else
    do_install
fi

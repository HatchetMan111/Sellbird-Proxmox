# 🐦 Sellbird-Proxmox

**Sellbird als One-Click-LXC für Proxmox VE** – im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE/).

Sellbird ([ethanplusai/sellbird](https://github.com/ethanplusai/sellbird), AGPL-3.0, 6,7 k ★) ist die **Open-Source-Outreach-Plattform, die auf deinem Claude- oder ChatGPT-Plan läuft**: findet Firmen und Entscheider, liest deren Websites als Signale, verifiziert E-Mails, schreibt personalisierte Cold-Mails mit deiner Claude Code CLI als Reasoning-Engine, versendet aus deiner eigenen Mailbox und bearbeitet Antworten. Standardmäßig wird **nichts versendet, ohne dass du es im Outbox-Workflow freigibst** (Autopilot ist opt-in). Kein API-Key, kein Token-Billing – deine Claude Pro/Max- oder ChatGPT-Registrierung reicht.

## Installation – Einzeiler

Auf dem Proxmox-Host als **root** ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)"
```

Optionen hängt man **hinter dem schließenden Anführungszeichen** an:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)" --id 210 --memory 4096 --port 8090
```

### Was der Installer macht

1. Erstellt einen **unprivilegierten LXC** (`sellbird`, Debian 13 bevorzugt, sonst 12; 2 vCPU / 2 GB RAM / 512 MB Swap / 8 GB Disk; DHCP; `onboot: 1`; nächste freie CT-ID ab 200, wählbar via `--id`).
2. Klonet Sellbird **auf einen gepinnten Commit** (v0.4.0 = `b212385`, 2026-11-18) nach `/opt/sellbird/app`, installiert es in ein eigenes venv (`/opt/sellbird/venv`), dazu Playwright-Chromium für die Website-Signals.
3. Installiert die **Claude Code CLI** (offizieller Native-Installer) als Benutzer `sellbird` – das ist Sellbirds Reasoning-Engine.
4. Startet drei Services im Container (alle `Restart=always`, `enabled`):
   - `sellbird-dashboard.service` – Sellbird-Dashboard (upstream loopback-only auf `127.0.0.1:5555`)
   - `nginx` – **Reverse-Proxy `0.0.0.0:8090 → 127.0.0.1:5555`** (siehe „Dashboard-Zugriff“)
   - `sellbird-ttyd.service` – **ttyd-Webterminal auf `:8091`** (Basic-Auth, läuft als `sellbird`)
5. Verifiziert selbst: Services aktiv, Dashboard + Proxy antworten (HTTP 200 im CT **und** vom Proxmox-Host), Claude-CLI-Check (`sellbird.claude_runtime.check_cli()`), `onboot`/`enabled` – und gibt am Ende **URLs, Unlock-Link und Passwörter** aus. Bei Fehlern kommt die komplette Fehlerkette (Exit-Code, Zeile, Befehl, Log-Auszüge); Neulauf mit vollem Trace: `... " --debug`.

### Dashboard-Zugriff (wichtig!)

Upstream hält das Dashboard **absichtlich loopback-only** (`sellbird/dashboard.py` weigert sich, auf anderen Adressen zu lauschen) und sichert es mit einem Bearer-Token ab (Unlock-Link, Token im `#`-Fragment). Damit die UI trotzdem wie gewohnt unter `http://CT-IP:8090` erreichbar ist, schreibt der Installer einen nginx-Proxy davor, der Host-/Origin-Header auf `localhost` umschreibt. **Der Token-Guard bleibt vollständig aktiv** – die Unlock-URL mit `#token=…` ist der Schlüssel und nicht weiterzugeben. Ports nicht per Router-Portforwarding ins Internet stellen.

## Erste Schritte (alles im Webterminal `http://CT-IP:8091`)

1. **Claude-Login:** `claude` starten, per OAuth anmelden (Claude Pro/Max; Alternative Codex: `docs/codex.md` im Sellbird-Repo).
2. **Einrichtung:** `sellbird setup` (Persona, Produkt, ICP) und Mailkanal in `/opt/sellbird/app/.env` (`GMAIL_CLIENT_ID`/`GMAIL_CLIENT_SECRET`, `SMTP_*` oder `M365_*` – jede Variable ist dort inline dokumentiert; danach `sellbird gmail auth` bzw. `sellbird smtp test`).
3. **Trainieren & loslegen:**
   ```bash
   sellbird train https://deine-firma.tld
   sellbird signals --confirm free
   sellbird discover
   ```
   Dashboard öffnen → Signals, Outbox, Sendungen. Zwischenstand exportieren: `sellbird export`.

> **Headless-Hinweis:** Im LXC gibt es kein System-Keychain – Sellbird wirft beim *Speichern* von Secrets einen klaren Fehler und liest stattdessen `.env`-Werte (so ist es auch im offiziellen Docker-Pfad dokumentiert). Credentials gehören in `/opt/sellbird/app/.env` (0600).

## Update / Status / Deinstallation

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)" --update      # → origin/main
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)" --status     # inkl. Unlock-Link
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/Sellbird-Proxmox/main/install/sellbird.sh)" --uninstall  # CT stoppen + löschen
```

- `--update` zieht Sellbird auf `origin/main`; Pipeline-DB, `.env`, Claude-Login und `dashboard-token` bleiben erhalten. Die Claude-CLI wird bewusst nicht angefasst (im Terminal: `claude update`).
- Der Erst-Install ist auf Commit `b212385` (v0.4.0) gepinnt; mit `--ref <40-stelliger-SHA>` kann man abweichen.
- Unlock-Link jederzeit: `pct exec <CT-ID> -- cat /opt/sellbird/app/data/dashboard-token`

## Alle Optionen

`--id`, `--hostname`, `--storage`, `--rootfs`, `--cores`, `--memory`, `--swap`, `--bridge`, `--ip`, `--gateway`, `--password`, `--sshkey`, `--port` (LAN-Port des Dashboards, Default 8090), `--terminal-port` (Default 8091), `--terminal-password`, `--ref`, `--force`, `--yes`, `--update`, `--uninstall`, `--status`, `--debug` – Details: `... " --help`.

## Rechtliches

Cold-Email ist regulatorisch heikel (CAN-SPAM, GDPR, DSGVO-UWG): Sellbird dokumentiert Deliverability/Compliance im Repo (`docs/`) – eigene Absender-Domain mit SPF/DKIM/DMARC, Budget-Limits im `sellbird.yaml`. Siehe auch die Hinweise in der Installer-Zusammenfassung.

## Repo-Inhalt

```
install/sellbird.sh          # der Einzeiler-Installer (Host-Teil + In-CT-Setup)
systemd/                     # Referenz-Kopien der im CT erzeugten Units
harness/run.sh               # Mock-Harness: bash harness/run.sh (Exit 0 = grün)
```

Lizenz: MIT (Installer). Sellbird selbst: AGPL-3.0.

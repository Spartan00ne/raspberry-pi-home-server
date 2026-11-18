# Koffler Online

[![CI](https://github.com/Spartan00ne/raspberry-pi-home-server/actions/workflows/ci.yml/badge.svg)](https://github.com/Spartan00ne/raspberry-pi-home-server/actions/workflows/ci.yml)

Persönliche Homepage und Technikprojekte auf einem Raspberry Pi.

## Aktueller Aufbau

Die Website läuft als Docker-Compose-Anwendung:

```text
Internet
   │
Cloudflare Tunnel
   │
nginx-homepage ──┬── dashboard-api      Systemdaten für die Homepage
   │             │
statische        └── grafana            /monitoring/ (Monitoring-Stack)
Website                 │
                    prometheus ◄── node-exporter, cadvisor, blackbox-exporter
                        │
                   alertmanager ──► Telegram
```

### Container

- **nginx-homepage**: liefert die statischen Dateien aus `html/`.
- **cloudflared**: stellt den Cloudflare Tunnel zur Domain `koffler-online.de` bereit.
- **dashboard-api**: Flask-/Gunicorn-API auf Port 8080 für Systemdaten wie CPU, RAM,
  Temperatur, Uptime und Speicherplatz.

Zusätzlich läuft ein eigener Monitoring-Stack (Prometheus, Grafana,
Alertmanager und Exporter), siehe [Monitoring](#monitoring).

Die Container und das gemeinsame Docker-Netzwerk sind in
[`docker-compose.yml`](docker-compose.yml) definiert. Der Zugriff auf die API
erfolgt über Nginx unter `/api/`.

## Website

- Homepage: [`html/index.html`](html/index.html)
- Live-Dashboard: [`html/dashboard/index.html`](html/dashboard/index.html)
- Raspberry-Pi-Dokumentation: [`html/projekte/raspberry-pi/index.html`](html/projekte/raspberry-pi/index.html)
- Nginx-Konfiguration: [`nginx/default.conf`](nginx/default.conf)

Das Dashboard fragt `/api/status` regelmäßig ab. Der API-Container liest
Systeminformationen des Hosts über die in Compose eingebundenen Verzeichnisse.
Nginx weist Browser an, statische Dateien automatisch zu revalidieren und die
Live-API nicht zwischenzuspeichern. Dadurch müssen bei Änderungen keine
Versionsnummern in HTML-Dateien manuell angepasst werden.

## Monitoring

Live-Dashboard: <https://koffler-online.de/monitoring/>

Der Monitoring-Stack in [`monitoring/`](monitoring/) überwacht den Pi, alle
Container und die Erreichbarkeit der Website von außen. Probleme wie hohe
Temperatur, Unterspannung, volle Platten, ausgefallene Container oder eine nicht
erreichbare Website meldet er per Telegram.

- **Prometheus** sammelt die Metriken und wertet 17 Alarmregeln aus (mit Unit-Tests).
- **Grafana** zeigt das Dashboard, öffentlich nur lesend.
- **Alertmanager** schickt die Alarme an Telegram.
- **node-exporter**, **cAdvisor** und **blackbox-exporter** liefern Host-,
  Container- und Website-Daten.
- [`scripts/pi-metrics`](scripts/pi-metrics) ergänzt Pi-spezifische Werte aus
  `vcgencmd` (Unterspannung, Drosselung).

Aufbau, Alarme, Sicherheitsentscheidungen und Einrichtung stehen in
[`monitoring/README.md`](monitoring/README.md).

## CI/CD

Jede Änderung wird von GitHub Actions geprüft: Lint (ShellCheck, Ruff,
Hadolint), alle Konfigurationen (Compose, Prometheus inkl. Unit-Tests der
Alarme, Alertmanager, nginx) und ein Smoke-Test des API-Images. Das Image wird
auf einem ARM64-Runner gebaut und in der GitHub Container Registry
veröffentlicht.

Ausgerollt wird pull-basiert (GitOps): Ein systemd-Timer auf dem Pi prüft alle
2 Minuten, ob es auf `main` einen neuen Commit mit grüner CI gibt, rollt ihn
aus, prüft die Website und setzt sich bei einem Fehler selbst zurück. Der Pi
braucht dafür keine offenen Ports, und GitHub hat keinen Zugang zum Pi.
Dependabot hält Images und Pakete aktuell.

Details und Begründung: [`docs/ci-cd.md`](docs/ci-cd.md)

## Status und Backups

- [`runtime/status.json`](runtime/status.json) enthält den zuletzt erfassten
  Status der drei Docker-Container.
- [`scripts/update-status`](scripts/update-status) aktualisiert diese Datei.
- [`scripts/backup`](scripts/backup) sichert das Projekt per `rsync` nach
  `/mnt/external_drive/homepage/` und entfernt Backups älter als 30 Tage.

## Betrieb

Voraussetzungen:

- Docker und Docker Compose
- eine `.env`-Datei mit `TUNNEL_TOKEN`
- die externe Festplatte unter `/mnt/external_drive`

Aktualisiert wird automatisch per [CI/CD](docs/ci-cd.md). Manuell starten:

```bash
docker compose up -d --build
```

Monitoring starten (nach dem Homepage-Stack, da Grafana dessen Netzwerk nutzt):

```bash
cd monitoring && docker compose up -d
```

Status prüfen:

```bash
docker compose ps
curl http://localhost/api/health
```

Das Tunnel-Token liegt ausschließlich in `.env`; diese Datei wird durch
[`.gitignore`](.gitignore) nicht versioniert.

## Server-Härtung

Die einzelnen Schritte, Prüfungen und wie man sie rückgängig macht, stehen in
[`docs/server-setup.md`](docs/server-setup.md).

- SSH nur mit Schlüssel, kein Passwort-Login und kein Root-Login
- Firewall (ufw): eingehend alles gesperrt außer SSH und VNC aus dem Heimnetz
- automatische Sicherheitsupdates mit `unattended-upgrades`
- nicht benötigte Dienste (rpcbind/NFS) abgeschaltet
- keine offenen Ports für Web-Dienste: Die Website ist nur über den Cloudflare
  Tunnel erreichbar, Admin-Oberflächen nur lokal per SSH-Tunnel

## Nächste Erweiterungen

- Server-Einrichtung als Code mit Ansible
- den Raspberry Pi zusätzlich als NAS im lokalen Netzwerk nutzen

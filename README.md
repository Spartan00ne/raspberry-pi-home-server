# Koffler Online

Persönliche Homepage und Technikprojekte auf einem Raspberry Pi.

## Aktueller Aufbau

Die Website läuft als Docker-Compose-Anwendung:

```text
Internet
   │
Cloudflare Tunnel
   │
nginx-homepage ── dashboard-api
   │                    │
statische Website   Systemdaten
```

### Container

- **nginx-homepage**: liefert die statischen Dateien aus `html/`.
- **cloudflared**: stellt den Cloudflare Tunnel zur Domain `koffler-online.de` bereit.
- **dashboard-api**: Flask-/Gunicorn-API auf Port 8080 für Systemdaten wie CPU, RAM,
  Temperatur, Uptime und Speicherplatz.

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

Starten oder aktualisieren:

```bash
docker compose up -d --build
```

Status prüfen:

```bash
docker compose ps
curl http://localhost/api/health
```

Das Tunnel-Token liegt ausschließlich in `.env`; diese Datei wird durch
[`.gitignore`](.gitignore) nicht versioniert.

## Nächste Erweiterung

Als nächster Schritt ist geplant, den Raspberry Pi zusätzlich als NAS im
lokalen Netzwerk zu nutzen. Diese Erweiterung ist noch nicht umgesetzt.

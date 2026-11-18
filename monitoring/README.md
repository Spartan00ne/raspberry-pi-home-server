# Monitoring

Überwachung des Raspberry Pi und der Website `koffler-online.de` mit
Prometheus, Grafana und Alertmanager. Alarme kommen per Telegram aufs Handy.

```text
                    ┌──────────────── Raspberry Pi ────────────────┐
 Internet           │                                              │
    │               │  node-exporter ─┐  (CPU, RAM, Temperatur,    │
 Cloudflare ── nginx ── Grafana       │   Platten, Netzwerk,       │
  Tunnel      /monitoring/   │        │   Pi-Spannung)             │
    ▲               │        ▼        │                            │
    │               │   Prometheus ◄──┼── cAdvisor (Container)     │
    └── Prüfung ────┼── blackbox  ◄───┘                            │
     von außen      │        │                                     │
                    │        ▼                                     │
                    │   Alertmanager ──────────────► Telegram      │
                    └──────────────────────────────────────────────┘
```

## Komponenten

| Container | Aufgabe |
|---|---|
| **prometheus** | Sammelt alle 30 s Metriken, wertet die Alarmregeln aus, speichert 30 Tage (max. 2 GB). |
| **alertmanager** | Bündelt Alarme, unterdrückt Doppelmeldungen und schickt sie an Telegram. |
| **grafana** | Dashboard. Öffentlich nur lesend, Verwaltung nur per SSH-Tunnel. |
| **node-exporter** | Host-Metriken. Läuft im Host-Netzwerk, damit `eth0`/`wlan0` echt gemessen werden. |
| **cadvisor** | CPU, RAM und Netzwerk pro Container. |
| **blackbox-exporter** | Ruft die Website über das Internet auf: Erreichbarkeit, Antwortzeit, TLS-Zertifikat. |

Zusätzlich schreibt [`scripts/pi-metrics`](../scripts/pi-metrics) alle 30 s die
Raspberry-Pi-spezifischen Werte aus `vcgencmd` (Unterspannung, Drosselung,
Kernspannung) für den Textfile-Collector des node-exporters. Die Datei liegt in
`/run/pi-metrics` im RAM, damit die SD-Karte nicht dauernd beschrieben wird.
Gestartet wird das Skript von [`systemd/pi-metrics.timer`](systemd/pi-metrics.timer).

## Alarme

Definiert in [`prometheus/rules/alerts.yml`](prometheus/rules/alerts.yml):

| Alarm | Bedingung | Stufe |
|---|---|---|
| PiTemperaturHoch / -Kritisch | CPU > 75 °C (5 min) / > 80 °C (2 min) | warning / critical |
| PiUnterspannung | Netzteil liefert zu wenig Spannung | critical |
| PiGedrosselt | CPU wird gedrosselt (5 min) | warning |
| PiMetrikenVeraltet | `pi-metrics.timer` liefert keine Daten | warning |
| SpeicherplatzKnapp / -Kritisch | Dateisystem > 85 % / > 95 % | warning / critical |
| ArbeitsspeicherKnapp | RAM > 90 % (10 min) | warning |
| CpuDauerlast | Last > 1,5 × Kerne (15 min) | warning |
| PiNeugestartet | Laufzeit < 10 min | info |
| ContainerAusgefallen | Einer der erwarteten Container fehlt (2 min) | critical |
| ZielNichtErreichbar | Prometheus erreicht einen Exporter nicht | warning |
| WebsiteOffline | Website aus dem Internet nicht erreichbar (3 min) | critical |
| WebsiteLangsam | Antwortzeit > 3 s (10 min) | warning |
| ZertifikatLaeuftAb | TLS-Zertifikat < 14 Tage gültig | warning |
| DeploymentFehlgeschlagen | Ein Commit konnte nicht ausgerollt werden ([CI/CD](../docs/ci-cd.md)) | warning |
| DeploymentVeraltet | `homepage-deploy.timer` prüft nicht mehr (15 min) | warning |
| BackupFehlgeschlagen | Letztes Backup fehlgeschlagen ([Backup](../docs/backup.md)) | warning |
| BackupVeraltet | Seit über 26 h kein erfolgreiches Backup | warning |
| RestoreTestFehlgeschlagen | Letzter Restore-Test fehlgeschlagen | warning |
| RestoreTestVeraltet | Seit über 8 Tagen kein erfolgreicher Restore-Test | warning |

Die Regeln haben Unit-Tests ([`prometheus/tests/alerts_test.yml`](prometheus/tests/alerts_test.yml)),
die bei jedem Push in der CI laufen:

```bash
docker run --rm -v "$PWD/prometheus:/etc/prometheus:ro" --entrypoint promtool \
  prom/prometheus:v3.15.1 test rules /etc/prometheus/tests/alerts_test.yml
```

Regeln im Alertmanager ([`alertmanager/alertmanager.yml`](alertmanager/alertmanager.yml)):
Eine kritische Meldung unterdrückt die Warnung zum selben Problem, und fällt
cAdvisor aus, kommen keine Fehlmeldungen für alle Container.

## Sicherheit

- **Keine Secrets im Repo.** Telegram-Token, Chat-ID und Grafana-Passwort liegen in
  `secrets/` (per `.gitignore` ausgeschlossen) und werden als Docker-Secrets eingebunden.
- **Keine offenen Ports.** Prometheus, Alertmanager und Grafana lauschen nur auf
  `127.0.0.1`. Port 9100 (node-exporter) erlaubt ufw nur aus dem Monitoring-Netz
  `172.30.0.0/24`.
- **Grafana öffentlich nur lesend.** Besucher sind anonyme Viewer. Die Login-Seite
  ist über nginx von außen gesperrt, Basic-Auth über die API ist abgeschaltet.
  Anmelden kann man sich nur lokal über einen SSH-Tunnel.
- **Dashboards as Code.** Datenquelle und Dashboard werden aus
  [`grafana/`](grafana/) provisioniert; Änderungen in der Oberfläche werden nicht
  gespeichert.
- **Feste Image-Versionen** statt `latest`, damit Updates bewusst passieren.

## Zugriff als Admin

```bash
ssh -L 3000:localhost:3000 -L 9090:localhost:9090 -L 9093:localhost:9093 RaspberryPI
```

Danach im Browser:

- Grafana: <http://localhost:3000/monitoring/> (Benutzer `admin`, Passwort in
  `secrets/grafana_admin_password`)
- Prometheus: <http://localhost:9090> (Ziele, Abfragen, Alarmregeln)
- Alertmanager: <http://localhost:9093> (aktive Alarme, Stummschalten)

## Einrichtung

1. Telegram-Bot anlegen: In Telegram `@BotFather` öffnen, `/newbot` senden und den
   Token in `secrets/telegram_bot_token` speichern.
2. Dem neuen Bot eine Nachricht schreiben, dann die Chat-ID abfragen:
   ```bash
   curl -s "https://api.telegram.org/bot$(cat secrets/telegram_bot_token)/getUpdates" | grep -o '"chat":{"id":[0-9-]*'
   ```
   Die Zahl in `secrets/telegram_chat_id` speichern.
3. Grafana-Passwort erzeugen:
   ```bash
   openssl rand -base64 24 | tr -d '\n' > secrets/grafana_admin_password
   chmod 700 secrets && chmod 644 secrets/*
   ```
4. Pi-Metriken einrichten und Port für Prometheus freigeben:
   ```bash
   sudo install -m 644 systemd/pi-metrics.* /etc/systemd/system/
   sudo systemctl daemon-reload && sudo systemctl enable --now pi-metrics.timer
   sudo ufw allow from 172.30.0.0/24 to any port 9100 proto tcp
   ```
5. Starten (der Homepage-Stack muss laufen, weil Grafana dessen Netzwerk nutzt):
   ```bash
   docker compose up -d
   ```

## Betrieb

```bash
docker compose ps                                   # Status
docker compose logs -f alertmanager                 # Logs
curl -X POST localhost:9090/-/reload                # Prometheus-Konfiguration neu laden
docker compose restart alertmanager                 # nach Änderung an alertmanager.yml
```

Testalarm an Telegram schicken:

```bash
docker exec alertmanager amtool alert add Testalarm severity=warning \
  --annotation=summary="Test" --annotation=description="Testnachricht" \
  --alertmanager.url=http://localhost:9093
```

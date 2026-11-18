# CI/CD

Jede Änderung am Repo wird automatisch geprüft. Ist sie auf `main` und die
Prüfung grün, holt sich der Raspberry Pi den neuen Stand selbst und rollt ihn
aus. Schlägt das Ausrollen fehl, setzt er sich auf den vorherigen Stand zurück
und meldet das per Telegram.

```text
 git push ──► GitHub Actions (CI)                       Raspberry Pi
              ├─ Lint: ShellCheck, Ruff, Hadolint         homepage-deploy.timer (alle 2 min)
              ├─ Konfiguration: Compose, promtool,          │
              │  Alarm-Unit-Tests, amtool, blackbox,        ├─ git fetch: neuer Commit auf main?
              │  nginx -t                                   ├─ CI für diesen Commit grün? (GitHub-API)
              └─ Image bauen (ARM64), Smoke-Test,           ├─ Image sha-<commit> aus GHCR ziehen
                 nach GHCR pushen ─────────────────────────►├─ Code umstellen, Container/Configs neu laden
                                                            ├─ Health-Check
                                                            └─ Fehler? Rollback + Alarm
```

## Warum pull-basiert?

Der Pi nimmt bewusst keine eingehenden Verbindungen an: Die Website läuft über
den Cloudflare Tunnel, SSH ist nur im Heimnetz offen. GitHub kann den Pi also
nicht erreichen, und das soll so bleiben.

| Variante | Bewertung |
|---|---|
| GitHub Actions per SSH auf den Pi | Bräuchte einen offenen SSH-Port ins Internet und einen SSH-Schlüssel in GitHub. Abgelehnt. |
| Self-hosted Runner auf dem Pi | Keine offenen Ports, aber das Repo ist öffentlich: Ein Pull Request aus einem Fork könnte eigenen Code auf dem Pi ausführen. GitHub rät davon ab. Abgelehnt. |
| **Pull-basiert (GitOps)** | Der Pi fragt selbst nach, führt nur Code von `main` aus und nur, wenn die CI ihn geprüft hat. GitHub braucht keinerlei Zugang zum Pi. **Gewählt.** |

Das ist dasselbe Prinzip wie bei Argo CD oder Flux in Kubernetes, nur mit einem
Shell-Skript und einem systemd-Timer.

## CI: [`.github/workflows/ci.yml`](../.github/workflows/ci.yml)

Läuft bei jedem Push, jedem Pull Request und manuell.

| Job | Prüft |
|---|---|
| **Lint** | Shell-Skripte (ShellCheck), Python-API (Ruff, Regeln in [`api/ruff.toml`](../api/ruff.toml)), Dockerfile (Hadolint), Grafana-Dashboards (gültiges JSON) |
| **Konfiguration prüfen** | beide Compose-Dateien, Prometheus-Konfiguration und Regeln (`promtool check`), [Unit-Tests der Alarme](../monitoring/prometheus/tests/alerts_test.yml) (`promtool test rules`), Alertmanager (`amtool`), Blackbox-Exporter, nginx (`nginx -t`) |
| **Image bauen (arm64)** | baut die Dashboard-API auf einem nativen ARM64-Runner, startet sie und fragt `/api/health` und `/api/status` ab. Nur auf `main`: Push nach GHCR als `sha-<commit>` und `main`. |

Die Prüfwerkzeuge laufen in genau den Image-Versionen, die in den
Compose-Dateien stehen. Ein Versionssprung in Compose wird also automatisch mit
der neuen Version getestet.

[Dependabot](../.github/dependabot.yml) prüft wöchentlich GitHub Actions, das
Python-Basisimage, die Python-Pakete und die Images in beiden Compose-Dateien
und öffnet dafür Pull Requests. Deshalb sind alle Versionen fest gepinnt
(kein `latest`): Jedes Update ist ein sichtbarer, geprüfter Commit und lässt
sich per `git revert` zurücknehmen.

## CD: [`scripts/deploy`](../scripts/deploy)

Läuft als `homepage-deploy.service` alle 2 Minuten
([Timer](../deploy/systemd/homepage-deploy.timer)).

1. `git fetch`. Kein neuer Commit: fertig (keine Anfrage an die GitHub-API).
2. Sicherheitsprüfungen: Der lokale Stand muss in `origin/main` enthalten sein
   und darf keine lokalen Änderungen haben, sonst bricht das Skript ab, statt
   etwas zu überschreiben.
3. CI-Status des Commits über die GitHub-API. Läuft die CI noch, wird beim
   nächsten Lauf erneut gefragt. Ist sie rot, wird der Commit nicht ausgerollt.
4. Das Image `sha-<commit>` wird **vorher** gezogen. Fehlt es, bleibt alles
   beim Alten.
5. `git reset --hard <commit>`, dann wird nur neu geladen, was sich geändert hat:
   - `docker compose up -d` für die Homepage (startet nur geänderte Container neu)
   - `nginx/`: `nginx -t` und `nginx -s reload`, ohne Neustart
   - `monitoring/`: Compose, Prometheus und Alertmanager per Reload-API,
     Blackbox-Exporter bzw. Grafana-Provisioning per Neustart
   - HTML-Dateien sind sofort live (Verzeichnis-Mount)
6. Health-Check: Startseite und `/api/health` über nginx, bis zu 60 Sekunden.
7. Schlägt Schritt 5 oder 6 fehl: Rollback auf den vorherigen Commit und das
   vorherige Image. Der fehlgeschlagene Commit wird gemerkt und nicht in einer
   Schleife erneut versucht, sondern erst wieder, wenn ein neuer Commit kommt
   (oder mit `scripts/deploy --force`).

Jedes Image ist an einen Commit gebunden. Welche Version läuft, steht damit
immer eindeutig fest, und ein Rollback ist einfach der vorherige Commit.

### Überwachung des Deployments

Das Skript schreibt Metriken für den Textfile-Collector des node_exporters
(`/run/pi-metrics/deploy.prom`):

| Metrik | Bedeutung |
|---|---|
| `homepage_deploy_success{commit}` | 1 = letzter Lauf erfolgreich, 0 = fehlgeschlagen |
| `homepage_deploy_info{commit}` | gerade ausgerollter Commit |
| `homepage_deploy_last_run_timestamp_seconds` | letzter Lauf des Timers |
| `homepage_deploy_last_success_timestamp_seconds` | letztes erfolgreiches Deployment |

Daraus entstehen zwei Alarme (Telegram):

- **DeploymentFehlgeschlagen**: Ein Commit konnte nicht ausgerollt werden.
- **DeploymentVeraltet**: Der Timer hat seit 15 Minuten nicht geprüft.

### Sicherheit

- GitHub hat keinen Zugang zum Pi; es werden keine Zugangsdaten für den Pi in
  GitHub gespeichert.
- Ausgeführt wird nur, was auf `main` liegt **und** die CI bestanden hat. Code
  aus Pull Requests läuft nur auf den GitHub-Runnern, nie auf dem Pi.
- Der CI-Job hat nur Leserechte; Schreibrecht auf Pakete bekommt nur der
  Image-Job, und gepusht wird nur von `main`.
- Wer auf `main` pushen kann, kann Code auf dem Pi ausführen. Deshalb sollte
  `main` per Branch-Schutz abgesichert sein (siehe unten).
- Das GHCR-Image ist öffentlich, so braucht der Pi kein Registry-Passwort. Es
  enthält nur den öffentlichen Code dieses Repos.

## Ersteinrichtung

Einmalig auf dem Pi:

```bash
# Einmalig auf die CI-Images umstellen (danach übernimmt das der Timer)
cd ~/homepage
TAG=sha-$(git rev-parse HEAD)
mkdir -p ~/.local/state/homepage-deploy && echo "$TAG" > ~/.local/state/homepage-deploy/api_tag
sudo env API_TAG=$TAG docker compose up -d --no-build

# Timer installieren und starten
sudo cp ~/homepage/deploy/systemd/homepage-deploy.{service,timer} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now homepage-deploy.timer
```

Einmalig auf GitHub:

1. Prüfen, ob das Image öffentlich ist: `docker pull ghcr.io/spartan00ne/raspberry-pi-home-server/dashboard-api:main`
   ohne Login. Bei diesem Repo war es das automatisch; sonst unter
   *Profil → Packages → dashboard-api → Package settings* auf **Public** stellen.
2. Unter *Settings → Branches* für `main` eine Regel anlegen: Pull Request
   oder zumindest grüne CI (Status-Check „CI“) vor dem Merge verlangen,
   kein Force-Push.

## Betrieb

```bash
systemctl list-timers homepage-deploy.timer     # wann läuft der nächste Lauf?
journalctl -u homepage-deploy -n 50             # was hat das Deployment gemacht?
cat /run/pi-metrics/deploy.prom                 # aktueller Status als Metrik
~/homepage/scripts/deploy                       # sofort ausrollen
~/homepage/scripts/deploy --force               # fehlgeschlagenen Commit erneut versuchen
sudo systemctl stop homepage-deploy.timer       # automatische Deployments pausieren
```

Zurück auf eine ältere Version: `git revert <commit>` und pushen. Der Pi rollt
den Revert wie jede andere Änderung aus.

Änderungen an systemd-Units (`deploy/systemd/`, `monitoring/systemd/`) werden
nicht automatisch installiert, weil das Root-Rechte auf Systemebene braucht.
Das Skript weist im Log darauf hin; installiert wird wie in der Ersteinrichtung.
Das übernimmt später Ansible.

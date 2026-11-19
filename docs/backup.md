# Backup und Restore

Der Pi lässt sich jederzeit aus zwei Quellen vollständig wiederherstellen:

| Was | Woher | Werkzeug |
|---|---|---|
| Betriebssystem-Konfiguration, Härtung, Docker | Git (`ansible/`) | `ansible-playbook site.yml` |
| Code, Compose-Dateien, Dashboards, Alarmregeln | Git | Deploy-Timer ([ci-cd.md](ci-cd.md)) |
| Secrets (Tunnel-Token, Telegram, Grafana-Passwort, restic-Passwort) | Ansible Vault | `site.yml` |
| **Zustand**: Grafana-DB, Prometheus-Historie, Alertmanager-Silences | **restic-Backup** | `restore.yml` |

Gesichert wird deshalb nur der Zustand, also die drei Docker-Volumes des
Monitorings. Code und Secrets gehören nicht ins Backup: Sie liegen schon
versioniert bzw. verschlüsselt im Repo und würden im Backup nur ein weiteres
Leck öffnen.

## Überblick

```
03:00 täglich   homepage-backup.timer
                └─ scripts/backup
                   ├─ Platte eingehängt? Repository lesbar?
                   ├─ grafana, prometheus anhalten (ca. 30 s)
                   ├─ restic backup  ──────────────►  /mnt/external_drive/restic
                   ├─ Container wieder starten          (verschlüsselt, dedupliziert)
                   ├─ restic forget je Tag (7 täglich, 4 wöchentlich, 6 monatlich; sonntags prune)
                   └─ Metrik homepage_backup_*

So 04:00        homepage-restore-test.timer
                └─ scripts/restore-test
                   ├─ restic check --read-data
                   ├─ scripts/restore latest /var/tmp/...   ◄── derselbe Code wie im Ernstfall
                   ├─ Snapshot jünger als 26 h?
                   ├─ grafana.db: integrity_check, Benutzer vorhanden
                   ├─ Grafana + Prometheus als Wegwerf-Container (ohne Netzwerk) starten
                   │    Grafana: /api/health -> database ok
                   │    Prometheus: Messwerte von kurz vor dem Backup vorhanden
                   └─ Metrik homepage_restore_test_*
```

## Entscheidungen

- **restic** statt rsync: verschlüsselt (die Platte ist NTFS, dort sind alle
  Dateien für jeden lesbar, und die Grafana-DB enthält Passwort-Hashes),
  dedupliziert, mit Snapshots und eingebauter Integritätsprüfung.
- **Container kurz anhalten** statt Snapshot-APIs: Eine SQLite-DB oder TSDB im
  laufenden Betrieb zu kopieren, kann ein inkonsistentes Backup ergeben. Eine
  Lücke von etwa 30 s um 03:00 ist für einen Homeserver unkritisch, und die
  Alarme (`ContainerAusgefallen` erst nach 2 min) schlagen nicht an. Ein
  `trap` startet die Container in jedem Fall wieder.
- **Der Alertmanager läuft während des Backups weiter.** Er schreibt seine
  Dateien (`nflog`, `silences`) atomar, sie lassen sich also im laufenden
  Betrieb sichern. Ein Neustart würde dagegen die Alarme in seinem Speicher und
  noch nicht versendete Nachrichten verwerfen. Das ist beim ersten Live-Test
  passiert: Eine Fehlermeldung, die noch in `group_wait` hing, und eine
  Entwarnung kamen nie an. Läuft er weiter, verschickt er Entwarnungen auch für
  Alarme, die Prometheus nach seinem Neustart nicht mehr kennt.
- **Ein gemeinsamer Restore-Pfad**: `scripts/restore` wird vom wöchentlichen
  Test und vom Ernstfall genutzt. Ein grüner Test belegt also genau den Weg,
  der im Notfall läuft.
- **Erst vollständig zurückspielen, dann ersetzen**: Ein Restore landet immer
  zuerst in `/var/tmp`. Erst wenn restic fertig ist, werden die Volumes per
  `rsync --delete` ersetzt. Bricht restic ab, bleiben die Live-Daten unberührt.
- **Nur lokal** auf der USB-Platte, ohne Kopie außer Haus. Bewusst in Kauf
  genommen: Bei Diebstahl, Brand oder Überspannung sind Pi und Backup
  gleichzeitig weg. Verloren wäre dann nur die Monitoring-Historie, alles
  andere kommt aus Git und Vault.
- **Aufbewahrung getrennt nach Tag** (`--group-by host,paths,tags`): Reguläre
  (`auto`) und `pre-restore`-Snapshots werden getrennt ausgedünnt. Beim ersten
  Restore-Probelauf hat der `pre-restore`-Snapshot als neuester des Tages den
  regulären Snapshot verdrängt, aus dem gerade zurückgespielt worden war.
- **Kein automatisches Zurückspielen**: Ein Restore überschreibt Daten und
  wird immer bewusst ausgelöst.

## Einrichtung

Die Rolle `backup` ([`ansible/roles/backup`](../ansible/roles/backup)) installiert
restic, legt Passwort (`vault_restic_password`) und Einstellungen unter
`/etc/restic/` ab (nur root), legt das Repository einmalig an und aktiviert die
Timer:

```bash
cd ansible
ansible-playbook site.yml --tags backup
```

Das restic-Passwort steht nur im Vault. Geht das Vault-Passwort verloren,
sind auch die Backups nicht mehr lesbar. Es gehört deshalb in den
Passwortmanager.

## Betrieb

```bash
systemctl list-timers 'homepage-*'                  # nächste Läufe
sudo systemctl start homepage-backup.service        # Backup jetzt
sudo systemctl start homepage-restore-test.service  # Restore-Test jetzt
journalctl -u homepage-backup -u homepage-restore-test

# restic direkt (Einstellungen aus /etc/restic/env)
sudo sh -c 'set -a; . /etc/restic/env; restic snapshots'
```

Die Metriken landen über den Textfile-Collector im node_exporter. Dauerhaft
liegen sie in `/var/lib/homepage-backup/`; nach einem Neustart kopiert
`tmpfiles.d` sie in das RAM-Verzeichnis `/run/pi-metrics/` zurück, damit der
letzte Erfolg nicht verloren geht.

| Alarm | Bedingung |
|---|---|
| BackupFehlgeschlagen | Letzter Backup-Lauf fehlgeschlagen |
| BackupVeraltet | Seit über 26 h kein erfolgreiches Backup (oder noch nie) |
| RestoreTestFehlgeschlagen | Letzter Restore-Test fehlgeschlagen |
| RestoreTestVeraltet | Seit über 8 Tagen kein erfolgreicher Restore-Test (oder noch nie) |

## Wiederherstellen

Nach einem Neuaufbau ([ansible.md](ansible.md#neuen-pi-aufsetzen)) oder wenn
Monitoring-Daten kaputt sind:

```bash
cd ansible
ansible-playbook restore.yml                        # neuester Snapshot
ansible-playbook restore.yml -e snapshot=1a2b3c4d   # bestimmter Snapshot
ansible-playbook restore.yml -e force=true          # Volumes haben schon Daten
```

`latest` ist der neueste reguläre Snapshot (Tag `auto`). Enthalten die Volumes
schon Daten, bricht das Playbook ohne `force=true` ab. Nach einem Neuaufbau ist
das immer der Fall, weil Grafana beim ersten Start eine leere DB anlegt; dann
ist `force=true` richtig. Mit `force=true` wird der aktuelle Stand vorher noch
gesichert (Tag `pre-restore`), der Restore lässt sich also rückgängig machen:

```bash
sudo sh -c 'set -a; . /etc/restic/env; restic snapshots --tag pre-restore'
ansible-playbook restore.yml -e snapshot=<id> -e force=true
```

Ohne Controller geht es auch direkt auf dem Pi, mit demselben Skript:

```bash
sudo ~/homepage/scripts/restore latest --live --force
```

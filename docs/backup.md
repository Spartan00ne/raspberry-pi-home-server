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
                   ├─ restic backup  ──────────────►  /mnt/data/restic-monitoring
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

- **restic** statt rsync: verschlüsselt (die Grafana-DB enthält
  Passwort-Hashes, und eine abgezogene USB-Platte ist an jedem Rechner
  lesbar), dedupliziert, mit Snapshots und eingebauter Integritätsprüfung.
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

## Platte

Die externe 500-GB-Platte ist mit ext4 auf einer einzigen Partition (GPT)
formatiert und unter `/mnt/data` eingehängt. Sie hat zwei Bereiche:

| Bereich | Inhalt | Rechte |
|---|---|---|
| `/mnt/data/cloud` | Daten des Cloud-Speichers (ab Phase 3, #20) | root, 0750 |
| `/mnt/data/restic-monitoring` | restic-Repository des Monitorings | root, 0700 |

Die Rolle `storage` ([`ansible/roles/storage`](../ansible/roles/storage))
hängt die Platte per UUID ein (`storage_uuid` in der Inventory) und legt die
Bereiche an. Sie formatiert nie selbst.

- **`nofail`**: Der Pi startet auch ohne Platte. Dann liegt unter `/mnt/data`
  nur das leere Verzeichnis auf der SD-Karte. `scripts/backup-lib` bricht in
  diesem Fall ab (`mountpoint`), und der Alarm `PlatteNichtEingehaengt` meldet sich.
- **Reservierte Blöcke bleiben** (5 %, ext4-Standard): Läuft die Platte durch
  Uploads voll, kann root (das Backup) trotzdem noch schreiben. Der Füllstand
  wird wie bei `df` ohne diese Blöcke gerechnet, 100 % heißt also: Nur root
  kann noch schreiben.
- Füllstand und eine lineare Prognose, wann die Platte voll ist, zeigt das
  Grafana-Dashboard „Cloud-Speicher“. Alarme ab 80 % und 90 %
  ([Monitoring](../monitoring/README.md#alarme)).

Bis November 2026 war die Platte NTFS (`/mnt/external_drive`). Umgezogen
wurde so, wie auch ein späterer Wechsel abläuft:

### Umzug auf eine andere Platte

```bash
# 1. Repository auf die SD-Karte kopieren und die Kopie prüfen
sudo rsync -a /mnt/data/restic-monitoring/ /var/tmp/restic-umzug/
sudo env RESTIC_REPOSITORY=/var/tmp/restic-umzug RESTIC_PASSWORD_FILE=/etc/restic/password \
  restic check --read-data

# 2. Neue Platte anschließen, Gerät prüfen (lsblk), eine Partition, ext4
printf 'label: gpt\n,,L\n' | sudo sfdisk /dev/sdX
sudo mkfs.ext4 -L data /dev/sdX1
sudo blkid /dev/sdX1                    # UUID

# 3. UUID in ansible/inventory/group_vars/pi/vars.yml (storage_uuid) eintragen
cd ansible && ansible-playbook site.yml --tags storage

# 4. Zurückkopieren, prüfen, Backup und Restore-Test auslösen
sudo rsync -a --chown=root:root /var/tmp/restic-umzug/ /mnt/data/restic-monitoring/
ansible-playbook site.yml --tags storage,backup   # Rechte und Pfad
sudo sh -c 'set -a; . /etc/restic/env; restic check --read-data'
sudo systemctl start homepage-backup.service homepage-restore-test.service
ansible-playbook site.yml --check                 # changed=0
sudo rm -rf /var/tmp/restic-umzug                 # erst wenn alles grün ist
```

Die Prognose im Dashboard rechnet mit dem Trend der letzten 7 Tage. Nach
einem Umzug ist sie erst nach einigen Tagen aussagekräftig.

Bei einem Wechsel kommen später die Daten des Cloud-Speichers dazu (Bereich
`cloud`). Bei einem Neuformatieren derselben Platte muss vor dem Aushängen
alles gestoppt sein, was die Platte nutzt (`sudo fuser -vm /mnt/data`), z. B.
`dashboard-api` mit seinem Bind-Mount.

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
| PlatteNichtEingehaengt | Unter `/mnt/data` ist keine Platte eingehängt (5 min) |
| PlatteFuellstandHoch / -Kritisch | Platte über 80 % (10 min) / 90 % (5 min) belegt |

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

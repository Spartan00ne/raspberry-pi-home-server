# Server-Einrichtung und Härtung

Diese Seite erklärt, **was** auf dem Raspberry Pi eingerichtet und abgesichert
ist und **warum**. Umgesetzt wird alles mit Ansible: Jeder Abschnitt nennt die
zuständige Rolle in [`ansible/roles/`](../ansible/roles/). Wie man das Playbook
benutzt und einen Pi neu aufsetzt, steht in [`ansible.md`](ansible.md).

> **Grundregel:** Der Pi wird meist ohne Bildschirm und Tastatur betrieben. Bei
> jeder Änderung an SSH oder Firewall die bestehende SSH-Sitzung offen lassen und
> den Zugang in einer **neuen** Sitzung testen, bevor man die alte schließt. Das
> Playbook macht das bei der Firewall automatisch (Rettungs-Timer).

## Ausgangslage

- Raspberry Pi 4 Model B (4 GB), Raspberry Pi OS auf Basis von Debian 13 (trixie)
- Netzwerk: Ethernet und WLAN im Heimnetz `192.168.178.0/24`
- Vorbereitet mit dem Raspberry Pi Imager: Benutzer `simeon`, SSH mit Public Key

## 1. SSH nur mit Schlüssel — Rolle `ssh`

- Login nur mit Schlüssel, kein Passwort, kein Keyboard-Interactive und kein
  Root-Login (`/etc/ssh/sshd_config.d/00-keys-only.conf`).
- Die Datei beginnt mit `00-`, weil sshd bei doppelten Einstellungen den
  **ersten** Wert nimmt. `50-cloud-init.conf` würde sonst
  `PasswordAuthentication yes` setzen.
- `authorized_keys` enthält **genau** die Schlüssel aus
  `ansible/inventory/group_vars/pi/vars.yml`, alle anderen werden entfernt.
  Jeder Schlüssel ist ein weiterer Zugang.

Prüfen, dass der Passwort-Login abgelehnt wird:

```bash
ssh -o PubkeyAuthentication=no RaspberryPI   # erwartet: Permission denied (publickey)
```

## 2. Nicht benötigte Dienste abschalten — Rolle `base`

`rpcbind` wird nur für NFS gebraucht und lauscht sonst unnötig auf Port 111.
Die Rolle schaltet `rpcbind` und die NFS-Units ab. Vorher war geprüft, dass
kein NFS genutzt wird (`/etc/fstab`, `findmnt -t nfs,nfs4`, `/etc/exports`).

## 3. Automatische Sicherheitsupdates — Rolle `updates`

`unattended-upgrades` installiert die Debian- und Debian-Security-Updates
täglich. Kernel und Firmware kommen aus dem Raspberry-Pi-Repository und werden
davon **nicht** erfasst. Deshalb etwa monatlich `ansible-playbook upgrade.yml`
ausführen. Es meldet, ob danach ein Neustart nötig ist.

## 4. Firewall (ufw) — Rolle `firewall`

Eingehend ist alles gesperrt, außer:

| Port | Von | Zweck |
|---|---|---|
| 22/tcp | Heimnetz | SSH |
| 5900/tcp | Heimnetz | VNC |
| 5353/udp | Heimnetz | mDNS |
| 9100/tcp | Monitoring-Netz `172.30.0.0/24` | Prometheus fragt den node-exporter im Host-Netz ab |

Die Website braucht keinen offenen Port, weil `cloudflared` die Verbindung von
innen nach außen aufbaut.

> **Achtung Docker:** Mit `ports:` veröffentlichte Container-Ports umgehen ufw,
> weil Docker eigene iptables-Regeln setzt. In diesem Projekt werden deshalb
> keine Ports im Netz veröffentlicht. Admin-Oberflächen lauschen nur auf
> `127.0.0.1` und werden per SSH-Tunnel erreicht.

## 5. RAM-Messung für Container — Rolle `boot`

Die Raspberry-Pi-Firmware startet den Kernel mit `cgroup_disable=memory`. Dann
gibt es keine RAM-Werte pro Container (`docker stats` zeigt 0 B), und
Speicherlimits greifen nicht. Abhilfe: `cgroup_enable=memory` an die einzige
Zeile von `/boot/firmware/cmdline.txt` anhängen.

Ein Fehler in dieser Datei verhindert den Start. Deshalb hängt die Rolle nur an,
legt eine Sicherung an, prüft das Ergebnis (genau eine Zeile, enthält `root=`)
und startet **nie** selbst neu. Nach dem Neustart muss
`cat /sys/fs/cgroup/cgroup.controllers` den Eintrag `memory` enthalten.

## 6. Docker — Rolle `docker`

Docker kommt aus dem offiziellen Repository von Docker, nicht als `docker.io`
aus Debian. Der GPG-Schlüssel ist per SHA-256 gepinnt. Der Benutzer ist bewusst
**nicht** in der Gruppe `docker`, denn das entspräche Root-Rechten. Skripte
nutzen `sudo docker`.

## 7. Anwendung, Secrets und Zugang zu GitHub — Rolle `app`

- Der Pi pusht und pullt mit einem **Deploy-Key**. Der Schlüssel hat nur Zugriff
  auf dieses eine Repository. Bei einem Neuaufbau wird ein neuer erzeugt.
- Secrets kommen aus dem Ansible Vault:
  - `.env` mit dem Tunnel-Token: Modus 600
  - `monitoring/secrets/`: Verzeichnis 700. Die Dateien haben 644, damit die
    Container-Benutzer sie lesen können.
- systemd-Units aus `deploy/systemd/` und `monitoring/systemd/`: Deploy,
  Backup, Status und Pi-Metriken.
- Monitoring-Details stehen in [`monitoring/README.md`](../monitoring/README.md).

## Prüfliste nach dem Aufsetzen

```bash
ansible-playbook site.yml --check                                     # changed=0
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '   # no / no
sudo ufw status verbose                                               # active
systemctl is-active unattended-upgrades pi-metrics.timer              # active
sudo ss -tulpn                                                        # nur erwartete Ports
cat /sys/fs/cgroup/cgroup.controllers                                 # enthält memory
sudo docker ps                                                        # alle Container Up
vcgencmd get_throttled                                                # throttled=0x0
```

## Rückgängig machen

| Änderung | Rückgängig |
|---|---|
| SSH nur mit Schlüssel | `sudo rm /etc/ssh/sshd_config.d/00-keys-only.conf && sudo systemctl reload ssh` |
| Firewall | `sudo ufw disable` |
| rpcbind | `sudo systemctl enable --now rpcbind.socket rpcbind.service` |
| RAM-Messung | Sicherung `/boot/firmware/cmdline.txt.*~` zurückkopieren, dann `sudo reboot` |

Wichtig: Danach auch die Rolle bzw. Variable anpassen, sonst stellt der nächste
Lauf den alten Zustand wieder her.

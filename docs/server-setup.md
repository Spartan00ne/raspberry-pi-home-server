# Server-Einrichtung und Härtung

Diese Anleitung beschreibt, wie der Raspberry Pi eingerichtet und abgesichert
wurde. Sie ist so geschrieben, dass man den Server Schritt für Schritt neu
aufsetzen kann. Später soll daraus ein Ansible-Playbook werden.

> **Grundregel:** Der Pi wird meist ohne Bildschirm und Tastatur betrieben. Bei
> jeder Änderung an SSH oder Firewall die bestehende SSH-Sitzung offen lassen und
> den Zugang in einer **neuen** Sitzung testen, bevor man die alte schließt.

## Ausgangslage

- Raspberry Pi 4 Model B (4 GB), Raspberry Pi OS auf Basis von Debian 13 (trixie)
- Netzwerk: Ethernet und WLAN im Heimnetz `192.168.178.0/24`
- Docker und Docker Compose installiert

## 1. SSH nur mit Schlüssel

Auf dem Client (Windows-PowerShell) einen Schlüssel erzeugen und auf den Pi kopieren:

```powershell
ssh-keygen -t ed25519 -C "windows-pc"
type $HOME\.ssh\id_ed25519.pub | ssh RaspberryPI "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

Prüfen, dass der Schlüssel-Login funktioniert, **bevor** Passwörter abgeschaltet werden:

```bash
ssh -o PreferredAuthentications=publickey RaspberryPI "echo ok"
```

Dann auf dem Pi eine eigene Konfigurationsdatei anlegen. Sie beginnt mit `00-`,
weil sshd bei doppelten Einstellungen den **ersten** Wert nimmt und
`50-cloud-init.conf` sonst `PasswordAuthentication yes` setzen würde.

```bash
sudo tee /etc/ssh/sshd_config.d/00-keys-only.conf <<'CONF'
# Key-only SSH login
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
CONF
sudo sshd -t                     # Konfiguration prüfen, erst dann neu laden
sudo systemctl reload ssh
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '
```

Test in einer neuen Sitzung: Der Passwort-Login muss abgelehnt werden.

```bash
ssh -o PubkeyAuthentication=no RaspberryPI   # erwartet: Permission denied (publickey)
```

Nicht mehr benötigte Schlüssel aus `~/.ssh/authorized_keys` entfernen. Jeder
Schlüssel ist ein weiterer Zugang.

## 2. Nicht benötigte Dienste abschalten

`rpcbind` wird nur für NFS gebraucht und lauscht sonst unnötig auf Port 111.
Vorher prüfen, dass kein NFS genutzt wird (`/etc/fstab`, `findmnt -t nfs,nfs4`,
`/etc/exports`).

```bash
sudo systemctl disable --now rpcbind.socket rpcbind.service nfs-blkmap.service nfs-client.target
sudo ss -tulpn | grep ':111' || echo "Port 111 geschlossen"
```

## 3. Updates und automatische Sicherheitsupdates

```bash
sudo apt update && sudo apt full-upgrade
sudo apt install unattended-upgrades apt-listchanges
sudo tee /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
sudo systemctl enable --now unattended-upgrades
sudo unattended-upgrade --dry-run -d | grep 'Allowed origins'
```

`unattended-upgrades` installiert die Debian- und Debian-Security-Updates.
Kernel und Firmware kommen aus dem Raspberry-Pi-Repository und werden davon
**nicht** erfasst. Deshalb etwa monatlich von Hand `sudo apt full-upgrade`
ausführen und bei einem neuen Kernel neu starten.

## 4. Firewall (ufw)

Eingehend ist alles gesperrt, außer SSH, VNC und mDNS aus dem Heimnetz. Die
Website braucht keinen offenen Port, weil `cloudflared` die Verbindung von innen
nach außen aufbaut.

Damit man sich bei einem Fehler nicht aussperrt, wird vorher ein Timer gesetzt,
der die Firewall nach 5 Minuten wieder abschaltet:

```bash
sudo apt install ufw
sudo systemd-run --on-active=5min --unit=ufw-rescue /usr/sbin/ufw disable

sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow from 192.168.178.0/24 to any port 22 proto tcp comment 'SSH LAN'
sudo ufw allow from 192.168.178.0/24 to any port 5900 proto tcp comment 'VNC LAN'
sudo ufw allow from 192.168.178.0/24 to any port 5353 proto udp comment 'mDNS LAN'
# Prometheus (Monitoring-Netz) darf den node-exporter im Host-Netz abfragen
sudo ufw allow from 172.30.0.0/24 to any port 9100 proto tcp comment 'node-exporter fuer Prometheus'
sudo ufw --force enable
```

In einer **neuen** SSH-Sitzung testen und prüfen, dass die Container weiter ins
Internet kommen (z. B. `docker logs cloudflared`). Erst dann den Timer stoppen:

```bash
sudo systemctl stop ufw-rescue.timer
```

> **Achtung Docker:** Mit `ports:` veröffentlichte Container-Ports umgehen ufw,
> weil Docker eigene iptables-Regeln setzt. In diesem Projekt werden deshalb
> keine Ports im Netz veröffentlicht. Admin-Oberflächen lauschen nur auf
> `127.0.0.1` und werden per SSH-Tunnel erreicht.

## 5. RAM-Messung für Container aktivieren

Die Raspberry-Pi-Firmware startet den Kernel mit `cgroup_disable=memory`. Dann
gibt es keine RAM-Werte pro Container (`docker stats` zeigt 0 B), und
Speicherlimits greifen nicht. Abhilfe: `cgroup_enable=memory` an die **einzige
Zeile** von `/boot/firmware/cmdline.txt` anhängen.

Ein Fehler in dieser Datei verhindert den Start, deshalb mit Sicherung und
Prüfung:

```bash
f=/boot/firmware/cmdline.txt
sudo cp -p $f $f.bak-cgroup
printf '%s cgroup_enable=memory\n' "$(tr -d '\n' < $f)" | sudo tee $f.new >/dev/null
[ "$(wc -l < $f.new)" -eq 1 ] && grep -q 'root=' $f.new && sudo mv $f.new $f
cat $f
sudo reboot
```

Nach dem Neustart: `cat /sys/fs/cgroup/cgroup.controllers` muss `memory` enthalten.

## 6. Monitoring

Einrichtung und Betrieb stehen in [`monitoring/README.md`](../monitoring/README.md).

## 7. Zugang zu GitHub vom Pi

Der Pi pusht mit einem **Deploy-Key**. Der Schlüssel hat nur Zugriff auf dieses
eine Repository, nicht auf den ganzen GitHub-Account.

```bash
ssh-keygen -t ed25519 -N '' -C 'raspberry-pi deploy key' -f ~/.ssh/github_deploy_homepage
printf 'Host github.com\n  IdentityFile ~/.ssh/github_deploy_homepage\n  IdentitiesOnly yes\n' >> ~/.ssh/config
cat ~/.ssh/github_deploy_homepage.pub
```

Den öffentlichen Schlüssel auf GitHub unter **Settings → Deploy keys** mit
**Allow write access** eintragen. Test: `ssh -T git@github.com`.

## Prüfliste nach dem Aufsetzen

```bash
sudo sshd -T | grep -E '^(passwordauthentication|permitrootlogin) '   # no / no
sudo ufw status verbose                                               # active
systemctl is-active unattended-upgrades pi-metrics.timer              # active
sudo ss -tulpn                                                        # nur erwartete Ports
cat /sys/fs/cgroup/cgroup.controllers                                 # enthält memory
docker ps                                                             # alle Container Up
vcgencmd get_throttled                                                # throttled=0x0
```

## Rückgängig machen

| Änderung | Rückgängig |
|---|---|
| SSH nur mit Schlüssel | `sudo rm /etc/ssh/sshd_config.d/00-keys-only.conf && sudo systemctl reload ssh` |
| Firewall | `sudo ufw disable` |
| rpcbind | `sudo systemctl enable --now rpcbind.socket rpcbind.service` |
| RAM-Messung | `sudo cp /boot/firmware/cmdline.txt.bak-cgroup /boot/firmware/cmdline.txt && sudo reboot` |

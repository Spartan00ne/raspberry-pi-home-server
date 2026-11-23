# Infrastructure as Code mit Ansible

Der Raspberry Pi wird vollständig mit dem Playbook in [`ansible/`](../ansible/)
eingerichtet: Härtung, Docker, Anwendung, Secrets und Timer. Ein frisch
geflashter Pi wird damit ohne Handarbeit wieder zum laufenden Server. Was die
einzelnen Härtungen bewirken und warum, steht in [`server-setup.md`](server-setup.md).

## Aufbau

| Rolle | Aufgabe |
|---|---|
| `base` | Grundpakete, rpcbind/NFS abschalten |
| `storage` | Externe Platte (ext4) per UUID unter `/mnt/data` einhängen, Bereiche anlegen ([`backup.md`](backup.md#platte)) |
| `ssh` | `authorized_keys` exklusiv setzen, Login nur mit Schlüssel |
| `firewall` | ufw: eingehend alles gesperrt außer SSH, VNC, mDNS aus dem LAN und node-exporter |
| `tailscale` | Tailscale aus dem offiziellen Repository, Anmeldung mit `tag:cloud`, ohne DNS und Routen des Tailnets ([`tailscale.md`](tailscale.md)) |
| `updates` | `unattended-upgrades` für Sicherheitsupdates |
| `boot` | `cgroup_enable=memory` in der Kernel-Kommandozeile (RAM-Werte pro Container) |
| `docker` | Docker aus dem offiziellen Repository, GPG-Schlüssel per SHA-256 gepinnt |
| `app` | Deploy-Key, Repo-Klon, Secrets, `.env`, systemd-Units und Timer, Erststart |
| `backup` | restic, Repository-Zugang, Timer für Backup und Restore-Test ([`backup.md`](backup.md)) |

Jede Rolle hat ein gleichnamiges Tag (`--tags ssh`).

**Zuständigkeit:** Ansible richtet den Server ein. Spätere Updates der Anwendung
rollt weiterhin der Deploy-Timer aus ([`ci-cd.md`](ci-cd.md)). Ansible holt
deshalb keine neuen Commits und ändert keine getrackten Dateien im Checkout.

## Sicherheitsentscheidungen

- **Nicht aussperren:** Es gibt keinen physischen Zugang zum Pi. Deshalb gilt:
  - `authorized_keys` wird nur exklusiv gesetzt, wenn der Schlüssel, mit dem
    Ansible gerade verbunden ist, auf der Liste steht (`assert`).
  - Die sshd-Konfiguration wird vor dem Schreiben (`validate`) und vor dem
    Neuladen geprüft. Es wird nur `reload` ausgeführt, nie `restart`.
  - Firewall-Änderungen laufen nur, wenn sich wirklich etwas ändert. Dann
    startet zuerst ein Rettungs-Timer, der ufw nach 5 Minuten abschaltet. Erst
    wenn eine **neue** SSH-Verbindung klappt, wird er gestoppt.
  - Die erste Anmeldung bei Tailscale läuft genauso, der Rettungs-Timer führt
    dort `tailscale down` aus.
- **Kein automatischer Neustart.** Ändert sich die Kernel-Kommandozeile, meldet
  das Playbook das nur.
- **Secrets im Ansible Vault** (`inventory/group_vars/pi/vault.yml`, AES-256).
  - Das Passwort ist zufällig und 48 Zeichen lang. Es liegt nur auf dem
    Controller (`~/.ansible/vault-pass`) und im Passwortmanager.
  - Die CI bekommt es nie und testet mit Dummy-Werten. Ein CI-Schritt
    schlägt fehl, wenn eine Vault-Datei unverschlüsselt eingecheckt wird.
  - Tasks mit Secrets laufen mit `no_log` und ohne Diff.
- **Deploy-Key nicht im Vault.** Ein privater Schlüssel mit Schreibrecht gehört
  nicht ins öffentliche Repo, auch nicht verschlüsselt. Bei einem Neuaufbau
  wird ein neuer Schlüssel erzeugt. Das ist zugleich ein Schlüsseltausch.
- **Kein Mitglied der Gruppe `docker`:** Diese Gruppe entspricht Root-Rechten.
  Skripte rufen Docker mit `sudo` auf.
- **Controller-Zugang zu GitHub** läuft über `gh auth login` (OAuth). Das ist eine
  bewusste Abwägung für ein Ein-Personen-Projekt. Im Team wäre ein
  Fine-grained PAT, beschränkt auf das Repo, die bessere Wahl.

## Tests

Die CI (`.github/workflows/ci.yml`, Job *Ansible*) prüft jeden Pull Request:

1. Die Vault-Dateien sind verschlüsselt.
2. `ansible-lint` mit Profil `production` und ein Syntax-Check laufen ohne Fehler.
3. Ein Lauf in einem frischen Debian-13-Container mit systemd. Der Container
   ist so vorbereitet wie ein Pi nach dem Imager (`ansible/tests/Dockerfile`).
   Die Rollen `boot` und `firewall` werden dort übersprungen, ebenso das
   echte Einhängen der Platte (Tag `mount`) und die Anmeldung bei Tailscale
   (Tag `tailnet-login`). Der fstab-Eintrag wird geprüft, Tailscale wird
   installiert und gestartet.
4. **Ein zweiter Lauf muss `changed=0` melden.** Damit ist bewiesen, dass das
   Playbook idempotent ist.

Das Test-Inventar (`ansible/tests/inventory`) nutzt per Symlink dieselbe
`vars.yml` wie der echte Pi.

## Controller einrichten (WSL)

Einmalig in Ubuntu 24.04 (WSL2):

```bash
sudo apt update && sudo apt install -y pipx gh git
pipx install "ansible-core==2.21.6"     # 2.22 braucht Python 3.13
pipx inject --include-apps ansible-core "ansible-lint==26.11.0"
gh auth login                           # HTTPS, Git über gh anmelden
gh repo clone Spartan00ne/raspberry-pi-home-server
cd raspberry-pi-home-server/ansible
ansible-galaxy collection install -r requirements.yml

# Eigener Schlüssel für Ansible, zusätzlich auf dem Pi eintragen
ssh-keygen -t ed25519 -N '' -C 'ansible-controller (wsl)' -f ~/.ssh/ansible-controller
# Vault-Passwort aus dem Passwortmanager ablegen
install -m 600 /dev/null ~/.ansible/vault-pass && nano ~/.ansible/vault-pass
```

## Benutzung

Alle Befehle laufen im Verzeichnis `ansible/`:

```bash
ansible-playbook site.yml --check --diff     # nur anzeigen, was sich ändern würde
ansible-playbook site.yml                    # anwenden
ansible-playbook site.yml --tags app         # nur eine Rolle
ansible-playbook upgrade.yml                 # monatlich: Voll-Upgrade inkl. Kernel
ansible-playbook restore.yml -e force=true   # Zustand aus dem Backup zurückspielen
ansible-vault edit inventory/group_vars/pi/vault.yml   # Secrets ändern
```

Die Erwartung im Normalbetrieb: `--check` meldet `changed=0`. Jede Abweichung
heißt, dass jemand von Hand etwas geändert hat (Drift).

## Neuen Pi aufsetzen

1. Mit dem Raspberry Pi Imager Raspberry Pi OS (64-bit, trixie) flashen. Dabei
   Benutzer `simeon`, SSH mit Public Key (Windows- und Controller-Schlüssel)
   und Hostname einstellen.
2. IP-Adresse in `inventory/hosts.yml` prüfen.
3. `ansible-playbook site.yml`. Der erste Lauf bricht bei `app` mit dem neuen
   Deploy-Key ab. Den Key unter *GitHub → Settings → Deploy keys* mit
   Schreibrecht eintragen und den alten Eintrag löschen.
4. `ansible-playbook site.yml` erneut ausführen. Das Repo wird geklont, und die
   Secrets, Units und Timer werden eingerichtet. Danach startet der Erststart
   die Container: erst die Homepage, dann das Monitoring.
5. Der Lauf meldet „Neustart nötig“ (cgroup). Dann `sudo reboot` ausführen.
6. Den Zustand (Grafana, Prometheus-Historie) aus dem Backup zurückspielen:
   `ansible-playbook restore.yml -e force=true`. `force` ist hier nötig, weil
   Grafana beim Erststart schon eine leere DB angelegt hat
   ([`backup.md`](backup.md#wiederherstellen)).

## Rückgängig machen

Jede Rolle setzt nur Zustände, die in [`server-setup.md`](server-setup.md#rückgängig-machen)
mit ihrem Gegenbefehl stehen. Wenn ein Lauf mittendrin abbricht:

- Firewall: Der Rettungs-Timer schaltet ufw nach 5 Minuten selbst ab.
- SSH: Die Konfiguration wird erst nach erfolgreicher Prüfung neu geladen.
  Bestehende Sitzungen bleiben bei `reload` offen.
- `cmdline.txt`: Ansible legt eine Sicherung mit Zeitstempel daneben
  (`cmdline.txt.<datum>~`).

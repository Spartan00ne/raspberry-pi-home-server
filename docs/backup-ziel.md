# Backup-Ziel auf dem Windows-PC

Die Backup-Kopien des Cloud-Speichers liegen auf dem Windows-PC im anderen
Haus. Dort läuft ein [rest-server](https://github.com/restic/rest-server) im
Modus append-only, der nur über Tailscale erreichbar ist. Der Pi kann dort neue
Snapshots anlegen, aber keine löschen oder ändern. Warum so:
[ADR 0003](adr/0003-backup-ziel-append-only-auf-windows-pc.md).

Eingerichtet wird der PC mit einem wiederholbaren PowerShell-Skript,
[`windows/backup-ziel.ps1`](../windows/backup-ziel.ps1). Ansible verwaltet den
PC nicht.

```text
Pi (tag:cloud)                          Windows-PC (tag:backup-target)
restic ──── Tailnet, nur tcp:8000 ────► rest-server --append-only
                                        │  Dienst "rest-server" (WinSW),
                                        │  Konto NT SERVICE\rest-server,
                                        │  lauscht nur auf <Tailscale-IP>:8000
                                        └─ E:\Backup-Ziel\<Repository>
                                           (externe Platte, eigenes Verzeichnis)
```

Was noch folgt: die tägliche Backup-Kopie vom Pi (#29), Restore und
Restore-Test (#30), die monatliche Prüfung und das Ausdünnen auf dem PC (#31).

## Schutzschichten

| Schicht | Wirkung |
|---|---|
| ACL: `tag:cloud` → `tag:backup-target` nur `tcp:8000` ([`policy.hujson`](../tailscale/policy.hujson)) | Ein kompromittierter Pi erreicht auf dem PC nur den rest-server, kein SMB, RDP oder SSH. |
| rest-server nur an die Tailscale-IP gebunden | Aus dem LAN des PCs ist er nicht erreichbar, auch wenn die Firewall falsch steht. |
| Windows-Firewall-Regel `Backup-Ziel-rest-server` | Eingehend nur TCP 8000 auf der Tailscale-IP, nur aus `100.64.0.0/10`, nur für `rest-server.exe`. |
| `--append-only` | Der Pi kann nichts löschen oder überschreiben, also auch kein `forget` und kein `prune`. |
| restic-Verschlüsselung | Eine gestohlene Platte gibt nichts preis. Das Passwort hat nur der Pi (Vault), später der PC für die Prüfung (#31). |
| Eigenes virtuelles Dienstkonto | rest-server darf nur in sein Verzeichnis und seine Logs schreiben. Beide (`E:\Backup-Ziel`, `C:\ProgramData\Backup-Ziel`) sind nur für Administratoren, SYSTEM und dieses Konto zugänglich. |

## Entscheidungen

- **WinSW als Dienst-Hülle:** rest-server kann sich nicht selbst als
  Windows-Dienst anmelden. [WinSW](https://github.com/winsw/winsw) 2.12 ist die
  letzte stabile Version mit mehr als zwei Wochen Abstand (3.x ist noch Alpha),
  NSSM wird seit 2017 nicht mehr gepflegt. Genommen wird die Variante für
  .NET Framework 4.6.1, das in Windows 10 und 11 enthalten ist.
- **Keine Anmeldung am rest-server (`--no-auth`):** Erreichbar ist er nur aus
  dem Tailnet, und dort laut ACL nur für den Pi und meine eigenen Geräte. Ein
  Passwort würde nur gegen meine eigenen Geräte schützen, bräuchte ein
  weiteres Geheimnis auf beiden Seiten, und rest-server liest nur bcrypt- oder
  SHA-Hashes, die sich unter Windows nicht ohne Zusatzprogramm erzeugen lassen.
  Löschen kann übers Netz ohnehin niemand, und lesen bringt ohne das
  restic-Passwort nichts.
- **HTTP statt HTTPS:** Im Tailnet verschlüsselt WireGuard die Verbindung.
- **Feste Versionen mit Prüfsumme:** restic, rest-server und WinSW werden in
  festen Versionen geladen und vor dem Installieren per SHA-256 geprüft, bei
  den Archiven auch die entpackte Datei. Eine installierte Datei mit passender
  Prüfsumme wird nicht erneut geladen. WinSW ist nicht signiert und hat keine
  veröffentlichten Prüfsummen; der Wert im Skript stammt vom Release-Asset
  (2023). Tailscale wird nur installiert, wenn es fehlt, danach aktualisiert es
  sich selbst.
- **PC mit Tag statt als eigenes Gerät:** Wie der Pi gehört der PC keinem
  Benutzer, sein Schlüssel läuft nicht ab. Er erreicht selbst nichts im
  Tailnet. War der PC vorher als eigenes Gerät angemeldet, bricht das Skript
  ab, statt ihn ungefragt umzumelden.
- **Tailscale läuft unattended:** Auch ohne angemeldeten Windows-Benutzer, also
  direkt nach dem Hochfahren. DNS und Routen des PCs bleiben unverändert
  (`--accept-dns=false`, `--accept-routes=false`), wie beim Pi.
- **Startreihenfolge:** Der Dienst hängt vom Dienst `Tailscale` ab. Hat
  Tailscale die IP beim Start noch nicht vergeben, scheitert das Binden, und
  Windows startet rest-server nach 10 Sekunden neu.
- **Eigenes Verzeichnis:** Die Repositorys liegen in einem eigenen Verzeichnis
  auf der externen Platte (z. B. `E:\Backup-Ziel`), getrennt von den manuellen
  Backups, mit einer `LIESMICH.txt` und eigenen Rechten. Das Skript lehnt das
  Wurzelverzeichnis und das Systemlaufwerk ab.

## Einrichten

Voraussetzungen: Windows 10 oder 11 (64 Bit), ein Konto mit Administratorrechten
und die externe Platte, am besten mit NTFS (unter exFAT lassen sich keine
Zugriffsrechte setzen, das Skript warnt dann).

1. **Policy zuerst:** Erst wenn dieser Stand auf `main` ist und die Action die
   Policy eingespielt hat, gibt es `tag:backup-target`.
2. **Auth-Key:** In der Admin-Konsole unter *Settings → Keys → Generate auth
   key*: nicht wiederverwendbar, nicht ephemeral, vorab autorisiert, Tag
   `tag:backup-target`. Er wird nur für die erste Anmeldung gebraucht und nicht
   gespeichert.
3. **Ist der PC schon im Tailnet** (als eigenes Gerät): `tailscale logout` und
   das Gerät in der Admin-Konsole entfernen.
4. **Fester Laufwerksbuchstabe:** In der Datenträgerverwaltung
   (`diskmgmt.msc`) der externen Platte einen festen Buchstaben geben, z. B.
   `E:`. Bekommt sie später einen anderen, findet rest-server die Repositorys
   nicht mehr.
5. **Skript laden und starten**, in einer PowerShell als Administrator:

   ```powershell
   Invoke-WebRequest https://raw.githubusercontent.com/Spartan00ne/raspberry-pi-home-server/main/windows/backup-ziel.ps1 -OutFile $env:TEMP\backup-ziel.ps1
   powershell -ExecutionPolicy Bypass -File $env:TEMP\backup-ziel.ps1 -Repository E:\Backup-Ziel
   ```

   Beim ersten Lauf fragt es nach dem Auth-Key. Am Ende stehen die
   Repository-URL für den Pi und die Zahl der Änderungen.
6. **Zweiter Lauf** mit demselben Befehl: Er muss mit `Änderungen: 0` enden.

Jede Zeile der Ausgabe beginnt mit `ok:` (stimmt schon) oder `geändert:`. Der
Port 8000 steht fest im Skript (`$Port`) und in der Regel in
[`policy.hujson`](../tailscale/policy.hujson); ändern nur an beiden Stellen.

Der Pi spricht den PC über die **Tailscale-IP** an, nicht über den
MagicDNS-Namen, weil er die DNS-Auflösung von Tailscale nicht nutzt
([tailscale.md](tailscale.md#der-pi-im-tailnet)). Die IP bleibt, solange das
Gerät im Tailnet bleibt.

## Abnahme

**Auf dem PC** (PowerShell als Administrator):

```powershell
Get-Service rest-server                               # Running
Get-NetTCPConnection -State Listen -LocalPort 8000    # nur die Tailscale-IP, nicht 0.0.0.0
Get-NetFirewallRule -Name Backup-Ziel-rest-server | Get-NetFirewallAddressFilter
& "$env:ProgramFiles\Tailscale\tailscale.exe" status --json | ConvertFrom-Json |
  Select-Object -ExpandProperty Self | Select-Object HostName, Tags, TailscaleIPs
```

**Aus dem LAN des PCs** (ein anderes Gerät im selben Haus, nicht über
Tailscale): rest-server darf nicht antworten.

```powershell
Test-NetConnection <LAN-IP des PCs> -Port 8000        # TcpTestSucceeded : False
```

**Vom Pi aus:** Nur der rest-server ist erreichbar, ein Test-Repository lässt
sich anlegen und beschreiben, Löschen scheitert.

```bash
PC=100.x.y.z    # Tailscale-IP des PCs (Ausgabe des Skripts)

for p in 8000 22 445 3389 5985; do
  timeout 3 bash -c "</dev/tcp/$PC/$p" 2>/dev/null && echo "$p offen" || echo "$p zu"
done
# Erwartet: 8000 offen, alle anderen zu

# Wegwerf-Repository mit Wegwerf-Passwort, ohne Spuren im Home-Verzeichnis
tmp=$(mktemp -d)
echo abnahme > "$tmp/password"
export RESTIC_REPOSITORY=rest:http://$PC:8000/abnahme-test
export RESTIC_PASSWORD_FILE=$tmp/password RESTIC_CACHE_DIR=$tmp/cache

restic init
restic backup /etc/os-release --tag abnahme
id=$(restic snapshots --json | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["id"])')
restic forget "$id"        # muss scheitern (rest-server antwortet 403 Forbidden)
restic snapshots           # der Snapshot ist noch da

rm -rf "$tmp"; unset RESTIC_REPOSITORY RESTIC_PASSWORD_FILE RESTIC_CACHE_DIR
```

Das Test-Repository kann nur der PC selbst löschen:
`Remove-Item -Recurse E:\Backup-Ziel\abnahme-test`.

## Betrieb

| Was | Wo |
|---|---|
| Programme | `C:\Program Files\Backup-Ziel\` (restic, rest-server, WinSW samt `rest-server-dienst.xml`) |
| Logs | `C:\ProgramData\Backup-Ziel\logs\`: `rest-server-dienst.out.log` (jede Anfrage), `rest-server-dienst.err.log`, `rest-server-dienst.wrapper.log` (WinSW benennt sie nach seiner exe), je 5 × 10 MB |
| Repositorys | das Verzeichnis aus `-Repository`, z. B. `E:\Backup-Ziel\` |

```powershell
Get-Service rest-server
Restart-Service rest-server
Get-Content C:\ProgramData\Backup-Ziel\logs\rest-server-dienst.err.log -Tail 20
```

Der PC darf aus sein: Der Pi versucht es stündlich und sichert, sobald der PC
erreichbar ist (#29). Erst nach 3 Tagen ohne Backup-Kopie kommt ein Alarm.

**Nach einer Neuinstallation von Windows:** Einrichten ab Schritt 2 wiederholen.
Das alte Gerät vorher in der Admin-Konsole entfernen. Der PC bekommt dabei eine
neue Tailscale-IP, die dann auch auf dem Pi geändert werden muss. Die
Repositorys auf der externen Platte bleiben, das Skript setzt ihre Rechte
wieder (das virtuelle Konto hat auf jedem Windows dieselbe SID, sie wird aus dem
Dienstnamen gebildet).

### Versionen aktualisieren

Dependabot kennt das Skript nicht. Neue Versionen von Hand prüfen, frühestens
zwei Wochen nach dem Release übernehmen, und im Skript (`$Pinned`) Version,
URL und beide Prüfsummen ändern. Die Prüfsumme des Archivs muss mit der
`SHA256SUMS` des Releases übereinstimmen:

```bash
v=0.19.1; a=restic_${v}_windows_amd64.zip
curl -fsSLO https://github.com/restic/restic/releases/download/v$v/$a
curl -fsSL https://github.com/restic/restic/releases/download/v$v/SHA256SUMS | grep " $a\$"
sha256sum "$a"                                          # ArchiveSha256
python3 -c 'import hashlib,sys,zipfile; print(hashlib.sha256(zipfile.ZipFile(sys.argv[1]).read(sys.argv[2])).hexdigest())' \
  "$a" restic_${v}_windows_amd64.exe                    # Sha256 der entpackten Datei
```

Danach das Skript auf dem PC erneut starten. Es hält den Dienst an, ersetzt die
Dateien und startet ihn wieder.

## Rückgängig machen

```powershell
Stop-Service rest-server
& "$env:ProgramFiles\Backup-Ziel\rest-server-dienst.exe" uninstall
Remove-NetFirewallRule -Name Backup-Ziel-rest-server
Remove-Item -Recurse "$env:ProgramFiles\Backup-Ziel", "$env:ProgramData\Backup-Ziel"
& "$env:ProgramFiles\Tailscale\tailscale.exe" logout   # dann das Gerät in der Admin-Konsole entfernen
```

Die Repositorys auf der externen Platte bleiben dabei erhalten.

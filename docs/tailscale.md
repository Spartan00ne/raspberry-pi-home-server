# Tailscale und Zugriffsregeln

Der Pi ist Mitglied in einem Tailnet. Darüber wird später der Cloud-Speicher
erreicht, von Mobilgeräten unterwegs und von geteilten Benutzern, ohne
Portfreigabe am Router und ohne dass er öffentlich im Internet steht. Warum
Tailscale und nicht der Cloudflare-Tunnel: [ADR 0001](adr/0001-tailscale-statt-cloudflare-tunnel.md).

| Teil | Wo |
|---|---|
| Installation und Anmeldung des Pi | Rolle [`tailscale`](../ansible/roles/tailscale/) |
| Zugriffsregeln (ACL-Policy) | [`tailscale/policy.hujson`](../tailscale/policy.hujson) |
| Prüfen und Einspielen der Policy | [`.github/workflows/tailscale-acl.yml`](../.github/workflows/tailscale-acl.yml) |
| Windows-PC als Backup-Ziel (`tag:backup-target`) | [`windows/backup-ziel.ps1`](../windows/backup-ziel.ps1), [`backup-ziel.md`](backup-ziel.md) |

## Der Pi im Tailnet

- **Tag `cloud`:** Der Pi gehört keinem Benutzer, sondern trägt den Tag
  `tag:cloud`. Die Regeln beziehen sich auf den Tag, nicht auf das Gerät.
- **Kein Ablauf des Schlüssels:** Bei getaggten Geräten schaltet Tailscale
  den Ablauf ab. Der Pi fällt also nicht nach 180 Tagen still aus dem
  Tailnet. Die Rolle prüft das bei jedem Lauf (`KeyExpiry` nicht gesetzt).
- **DNS unverändert:** `--accept-dns=false`. MagicDNS schreibt nicht in
  `/etc/resolv.conf`, der Pi löst Namen weiter über den Router auf.
- **Keine fremden Routen:** `--accept-routes=false`. Ein Gerät im Tailnet,
  das zum Beispiel ebenfalls `192.168.178.0/24` anbietet, kann den Weg ins
  LAN und damit SSH nicht umbiegen.
- **SSH bleibt im LAN:** Tailscale SSH ist aus (kein Abschnitt `ssh` in der
  Policy). Über die Tailnet-IP ist SSH nur von meinen eigenen Geräten aus
  erreichbar, als Notzugang.

Weicht eine dieser Einstellungen ab (etwa nach einem `tailscale up` von Hand),
korrigiert die Rolle DNS und Routen. Fehlen Tag oder Status `Running`, oder ist
ein Ablauf gesetzt, bricht sie mit einer Meldung ab.

### Anmeldung ohne Aussperren

Die Anmeldung läuft nur, wenn der Pi nicht im Tailnet läuft. Sie folgt
demselben Muster wie die Firewall ([`ansible.md`](ansible.md#sicherheitsentscheidungen)):

1. Ein Rettungs-Timer startet. Er führt nach 5 Minuten `tailscale down` aus.
2. `tailscale up`. Den Auth-Key aus dem Vault bekommt es nur bei der ersten
   Anmeldung (`NeedsLogin`), und zwar als Datei mit Modus 600
   (`--auth-key=file:`), damit er nicht in der Prozessliste steht. War der Pi
   nur gestoppt (`Stopped`, etwa durch den Rettungs-Timer), gilt der
   Schlüssel des Geräts noch, und der verbrauchte Auth-Key wird nicht gebraucht.
3. Eine **neue** SSH-Verbindung über das LAN wird getestet.
4. Erst wenn sie klappt, wird der Timer gestoppt.

Die Anmeldung hat das Tag `tailnet-login`. Die CI überspringt es: Der Testcontainer
installiert Tailscale und startet `tailscaled`, tritt aber keinem Tailnet bei.

## Zugriffsregeln

Erlaubt ist nur, was in der Policy steht.

| Von | Nach | Erlaubt |
|---|---|---|
| Meine eigenen Geräte (`autogroup:member`) | alle Geräte | alles |
| Geteilte Benutzer (`autogroup:shared`) | `tag:cloud` | nur `tcp:443` |
| `tag:cloud` (der Pi) | `tag:backup-target` | nur `tcp:8000` (rest-server) |
| `tag:backup-target` (der Windows-PC) | – | nichts |

- Weitere Benutzer bekommen den Pi per **Node Sharing**, sie werden nicht
  Mitglied im Tailnet. Damit sehen sie nur den geteilten Pi und darauf nur
  Port 443, kein SSH.
- Der Pi erreicht auf dem Backup-Ziel nur den rest-server, kein SMB, RDP
  oder SSH ([ADR 0003](adr/0003-backup-ziel-append-only-auf-windows-pc.md)).
  Ein kompromittierter Pi kommt so nicht weiter auf den PC.
- Die Tags darf nur ein Admin des Tailnets vergeben (`tagOwners`).

> **Achtung ufw:** ufw filtert den Verkehr über `tailscale0` nicht. Tailscale
> setzt eine eigene Kette `ts-input` an den Anfang von `INPUT` und lässt dort
> alles von `tailscale0` durch. Im Tailnet ist die Policy die Firewall.
> Prüfen: `sudo iptables -S ts-input`.

### Tests in der Policy

Der Abschnitt `tests` wird bei jedem Prüfen und Einspielen ausgewertet. Ein
Fehlschlag verhindert das Einspielen. Getestet wird, dass `tag:cloud` auf
`tag:backup-target` nur Port 8000 erreicht (und nicht 22, 445, 3389, 5985 oder
8001) und dass `tag:backup-target` nichts erreicht. Tests für eigene Geräte und geteilte Benutzer bräuchten eine
E-Mail-Adresse als Quelle. Die gehört nicht ins öffentliche Repo.

### GitOps

- **Pull Request**, der die Policy oder den Workflow ändert: Die Action
  prüft die Policy bei Tailscale (Syntax und Tests), spielt aber nichts ein.
- **Push auf `main`:** Die Action spielt die Policy ein. Sie ersetzt die
  Policy in der Admin-Konsole vollständig. Änderungen von Hand dort gehen
  beim nächsten Einspielen verloren.
- Die Anmeldung läuft über einen **OAuth-Client** mit nur dem Scope
  `policy_file`. Er läuft nicht ab, anders als ein API-Key (höchstens
  90 Tage), und darf nur die Policy lesen und schreiben.
- Die Action ist per Commit-SHA gepinnt, weil sie dieses Secret bekommt.
- Dependabot-PRs bekommen die normalen Secrets nicht. Ein Update der Action
  schlägt deshalb im PR fehl, bis es unter *Dependabot secrets* dieselben
  Werte gibt.

## Einrichten

Einmalig, in dieser Reihenfolge:

1. **Policy zuerst:** In der Admin-Konsole unter *Settings → OAuth clients*
   einen Client mit Scope `policy_file` (lesen und schreiben) anlegen. In
   GitHub unter *Settings → Secrets and variables → Actions* `TS_OAUTH_CLIENT_ID`
   und `TS_OAUTH_SECRET` eintragen. Nach dem Merge spielt die Action die
   Policy ein. Erst dann gibt es `tag:cloud`.
2. Optional in der Admin-Konsole unter *Access controls* das Bearbeiten von
   Hand sperren und auf das Repo verweisen.
3. **Auth-Key für den Pi:** *Settings → Keys → Generate auth key*:
   nicht wiederverwendbar, nicht ephemeral, vorab autorisiert, Tag `tag:cloud`.
   Die Ablaufzeit des Keys ist egal, er wird nur für die erste Anmeldung
   gebraucht.
4. In den Vault eintragen: `ansible-vault edit inventory/group_vars/pi/vault.yml`,
   Schlüssel `vault_tailscale_auth_key`.
5. `ansible-playbook site.yml --tags tailscale` und dann `--check` (changed=0).

Bei einem Neuaufbau des Pi braucht es einen neuen Auth-Key (Schritt 3 und 4).
Das alte Gerät vorher in der Admin-Konsole entfernen, sonst erscheint der Pi
doppelt.

## Prüfen

```bash
tailscale status            # Pi und eigene Geräte
tailscale status --json | python3 -c 'import json,sys; s=json.load(sys.stdin)["Self"]; print(s.get("Tags"), s.get("KeyExpiry"))'
                            # ['tag:cloud'] None
sudo tailscale debug prefs | python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["CorpDNS"], p["RouteAll"])'
                            # False False
cat /etc/resolv.conf        # nameserver 192.168.178.1, kein 100.100.100.100
sudo iptables -S ts-input
```

## Rückgängig machen

`sudo tailscale logout` meldet den Pi ab, das Gerät dann in der Admin-Konsole
entfernen. `sudo apt purge tailscale` entfernt das Paket. Danach die Rolle aus
`site.yml` nehmen, sonst installiert der nächste Lauf sie wieder.

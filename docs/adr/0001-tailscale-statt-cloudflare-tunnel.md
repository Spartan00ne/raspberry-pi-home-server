# Cloud-Speicher nur über Tailscale, nicht über den Cloudflare-Tunnel

Der Cloud-Speicher ist ausschließlich im Tailnet erreichbar, obwohl der Cloudflare-Tunnel für die Homepage schon existiert. Über den Tunnel wäre er öffentlich im Internet. Cloudflare würde den Verkehr entschlüsseln und damit Fotos und Chats im Klartext sehen, und der Gratis-Tarif begrenzt Uploads auf 100 MB, was für Handyvideos nicht reicht. Für die Verbindung zum Backup-Ziel im anderen Haus taugt er außerdem nicht. Tailscale deckt Mobilgeräte und Backup-Ziel mit einem Mechanismus ab, ohne Portfreigabe am Router.

## Considered Options

- **Cloudflare-Tunnel**: verworfen (öffentlich, Cloudflare sieht Klartext, Upload-Grenze, kein Weg zum Backup-Ziel).
- **WireGuard mit Portfreigabe**: verworfen (braucht Portfreigabe und eine erreichbare öffentliche IP, kein Notzugang, falls der Tunnel ausfällt).

## Consequences

- „Von überall“ heißt: von Geräten mit Tailscale. Weitere Benutzer bekommen den Pi per Node Sharing, nicht als Mitglied im Tailnet.
- Die Zugriffsregeln liegen als Code im Repo und sind von Anfang an eng, damit kein neues Gerät mehr erreicht als vorgesehen.
- Ein späterer Wechsel zu Headscale bleibt möglich, ohne die Adresse zu ändern (siehe [0004](0004-eigene-subdomain-und-caddy.md)).

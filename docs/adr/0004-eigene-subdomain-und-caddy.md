# Eigene Subdomain auf der Tailscale-IP, eigener Caddy getrennt vom öffentlichen nginx

Der Cloud-Speicher heißt `cloud.koffler-online.de`. Der öffentliche DNS-Eintrag zeigt auf die Tailscale-IP des Pi, aus dem Internet ist er also unerreichbar. Das Zertifikat kommt von Let's Encrypt per DNS-Challenge über Cloudflare. Die Adresse steckt in jeder App und jedem Freigabelink, deshalb soll sie dauerhaft gelten, unabhängig davon, ob Tailscale später durch Headscale oder etwas anderes ersetzt wird. TLS übernimmt ein eigener Caddy, der nur an die Tailscale-IP gebunden ist. So trennt keine bloße Konfigurationszeile im öffentlichen nginx die privaten Originale vom Internet.

## Considered Options

- **Tailscale-Name (`*.ts.net`) per `tailscale serve`**: verworfen. Das wäre weniger Aufwand, aber die Adresse gehört Tailscale und ändert sich bei einem Anbieterwechsel auf allen Geräten.
- **Den vorhandenen nginx mitbenutzen**: verworfen. Ein falscher `server_name` oder eine neue Tunnel-Regel würde Nextcloud öffentlich machen.
- **Traefik**: verworfen. Die Cloudflare-DNS-Challenge ist zwar eingebaut, aber Traefik braucht Zugriff auf den Docker-Socket (praktisch Root), und für einen einzigen Dienst ist es mehr Konzept als nötig.

## Consequences

- Caddy braucht ein eigenes Image mit dem Plugin `caddy-dns/cloudflare`, das in der CI gebaut wird.
- Das Cloudflare-Token darf nur `Zone:DNS:Edit` für `koffler-online.de` und kommt aus dem Vault.
- Der Name steht in den öffentlichen Certificate-Transparency-Logs, ist aber nur im Tailnet erreichbar.
- Weil Docker ufw umgeht, wird der Port ausdrücklich an die Tailscale-IP gebunden, und Caddy startet erst, wenn `tailscale0` existiert.

# Testziel für die CI: ein frisches Debian 13 (trixie) mit systemd, so wie es
# der Raspberry Pi Imager vorbereitet (Benutzer simeon, sudo ohne Passwort).
FROM debian:trixie

ENV container=docker DEBIAN_FRONTEND=noninteractive

# acl: Ansible braucht setfacl, um als anderer Benutzer (become_user) zu laufen.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus python3 sudo acl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -s /bin/bash -G sudo,video simeon \
 && echo 'simeon ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/010_simeon-nopasswd \
 && chmod 0440 /etc/sudoers.d/010_simeon-nopasswd

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

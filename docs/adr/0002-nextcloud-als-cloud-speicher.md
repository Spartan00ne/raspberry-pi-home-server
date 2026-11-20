# Nextcloud als Cloud-Speicher, schlank betrieben

Der Cloud-Speicher ist ein schlankes Nextcloud (offizielles Image mit PostgreSQL und Redis, nur Dateien, Fotos, Versionen und Papierkorb), obwohl es auf dem Pi 4 deutlich schwerer ist als die Alternativen. Ausschlaggebend ist das Modell: Der Pi hält die Originale, und Mobilgeräte laden in eine Richtung hoch. Löscht das Handy ein Foto, bleibt das Original erhalten. Außerdem liegen die Dateien als normale Dateien auf der Platte und lassen sich auch ohne Nextcloud lesen.

## Considered Options

- **Syncthing**: verworfen. Alle Geräte sind gleichberechtigt, Löschungen auf dem Handy würden sich auf den Pi übertragen (nur per nicht empfohlenem `ignoreDelete` zu verhindern). Keine Web-Oberfläche, die offizielle Android-App ist eingestellt.
- **ownCloud Infinite Scale (oCIS)**: verworfen trotz weniger RAM. Es speichert Dateien in einem eigenen Format statt als lesbare Dateien, die Originale wären also nur über oCIS zugänglich.
- **Nextcloud AIO**: verworfen. Zu viele Container und Zugriff auf den Docker-Socket.
- **SQLite statt PostgreSQL**: verworfen. Offiziell nur für Tests gedacht, und es gibt Sperrprobleme mit den Sync-Clients.

## Consequences

- Hauptversionen von Nextcloud und PostgreSQL werden nicht automatisch ausgerollt (Dependabot ignoriert sie), sondern von Hand, eine nach der anderen.
- Der Desktop-Client synchronisiert in beide Richtungen. Löschungen am Laptop erreichen den Pi, deshalb gibt es einen Papierkorb mit fester Frist und eine lange Aufbewahrung der Backup-Kopien.

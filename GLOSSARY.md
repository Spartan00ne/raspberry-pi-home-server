# Raspberry Pi Home Server

Ein selbst betriebener Raspberry Pi, der eine öffentliche Homepage ausliefert, sich selbst überwacht und als privater Cloud-Speicher für persönliche Dateien dient.

## Cloud-Speicher

**Cloud-Speicher**:
Der Dienst auf dem Pi, auf den Mobilgeräte ihre Dateien hochladen und über den diese Dateien von überall abrufbar sind, vergleichbar mit Google Drive.
_Avoid_: NAS, Netzlaufwerk, Freigabe

**Mobilgerät**:
Ein persönliches Gerät (Smartphone, Laptop), dessen Dateien in den Cloud-Speicher hochgeladen werden.
_Avoid_: Client, Endgerät

**Benutzer**:
Eine Person mit eigenem Zugang zum Cloud-Speicher und eigenen Originalen darin.
_Avoid_: Nutzer, Account, Konto

**Admin**:
Ein eigener Zugang nur zur Verwaltung des Cloud-Speichers, getrennt vom Benutzer, mit dem man im Alltag arbeitet.
_Avoid_: Root, Superuser

**Original**:
Die maßgebliche Fassung einer Datei. Für hochgeladene Dateien liegt das Original im Cloud-Speicher, denn das Mobilgerät darf seine Kopie danach löschen.
_Avoid_: Master, Primärdaten

**Backup-Kopie**:
Eine zusätzliche Fassung eines Originals an einem anderen Ort, die nur zur Wiederherstellung dient.
_Avoid_: Sicherung (mehrdeutig), Spiegel

**Backup-Ziel**:
Der Ort außer Haus, an dem die Backup-Kopien des Cloud-Speichers liegen. Der Pi kann dort nur neue Kopien ablegen, aber keine alten löschen.
_Avoid_: Backup-Server, Remote

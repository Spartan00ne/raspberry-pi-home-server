# Backup-Ziel: append-only rest-server auf dem Windows-PC im anderen Haus

Die Backup-Kopien des Cloud-Speichers schiebt der Pi per restic an einen rest-server mit `--append-only` auf dem Windows-PC, der in einem anderen Haus steht und über Tailscale erreichbar ist. Der Pi kann dort neue Snapshots anlegen, aber keine löschen. Ein kompromittierter oder fehlbedienter Pi zerstört also nicht zugleich Original und Backup-Kopie. Das Ausdünnen und die vollständige Prüfung der Daten laufen lokal auf dem PC, der Pi erfährt deren Erfolg über einen Marker-Snapshot (`pc-check-ok`) im selben Repository.

## Considered Options

- **SFTP auf den PC**: verworfen. Der Pi bräuchte einen SSH-Zugang zum PC und könnte Backups löschen.
- **Der PC holt sich die Daten**: verworfen. Die Konsistenz (Wartungsmodus, `pg_dump`) muss auf dem Pi hergestellt werden, die Steuerung wäre über zwei Maschinen verteilt.
- **Zweite Platte am Pi**: verworfen. Original und Backup-Kopie lägen dann im selben Haus.
- **Prüfung auf dem PC per windows_exporter überwachen**: verworfen. Der PC ist oft aus, das ergäbe Dauer-Alarme. Der Marker im Repository braucht keine neue Infrastruktur.

## Consequences

- Der Pi sichert, sobald der PC erreichbar ist (stündlicher Versuch), statt zu einer festen Uhrzeit. Ein Alarm meldet, wenn die letzte Backup-Kopie älter als 3 Tage ist.
- Der wöchentliche Restore-Test auf dem Pi zieht nur eine Stichprobe über die Leitung. Jedes Byte prüft der PC monatlich lokal.
- Die Aufbewahrungsregeln auf dem PC müssen Marker und reguläre Snapshots getrennt ausdünnen (`--group-by host,paths,tags`).

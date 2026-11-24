#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Richtet den Windows-PC als Backup-Ziel des Pi ein (ADR 0003, docs/backup-ziel.md).

.DESCRIPTION
Wiederholbar: Jeder Lauf bringt den PC auf denselben Stand und ändert nur, was
abweicht. Am Ende steht die Zahl der Änderungen, beim zweiten Lauf muss sie 0
sein.

- Tailscale: installiert (falls es fehlt), angemeldet mit dem Tag
  tag:backup-target, läuft auch ohne angemeldeten Windows-Benutzer.
- restic, rest-server und WinSW (macht rest-server zum Windows-Dienst) in festen
  Versionen, jede Datei mit geprüfter SHA-256-Prüfsumme.
- rest-server als Dienst im Modus append-only, nur an die Tailscale-IP gebunden,
  unter einem eigenen virtuellen Konto (NT SERVICE\rest-server).
- Eine Windows-Firewall-Regel lässt nur diesen Port aus dem Tailnet zu.

Was der Pi dort erreichen darf, regelt die ACL in tailscale/policy.hujson.

.PARAMETER Repository
Verzeichnis für die Repositorys auf der externen Platte, getrennt vom Bereich
für die manuellen Backups, z. B. E:\Backup-Ziel. Nicht das Wurzelverzeichnis
und nicht das Systemlaufwerk.

.PARAMETER Port
Port des rest-servers. Muss zur Regel für tag:cloud in tailscale/policy.hujson
passen.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File .\backup-ziel.ps1 -Repository E:\Backup-Ziel
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '',
    Justification = 'Einrichtungsskript für die Konsole, die Ausgabe ist für Menschen.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^[A-Za-z]:\\.+')]
    [string] $Repository,

    [ValidateRange(1, 65535)]
    [int] $Port = 8000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest ist sonst in 5.1 sehr langsam
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Feste Versionen ---------------------------------------------------------
# Beim Aktualisieren Version, URL und beide Prüfsummen ändern (Archiv und die
# daraus entpackte Datei), siehe docs/backup-ziel.md#versionen-aktualisieren.
# Die Prüfsumme der entpackten Datei erkennt eine installierte Datei wieder,
# ohne sie erneut herunterzuladen.
$Pinned = @{
    Restic     = @{
        Version       = '0.19.1'
        Url           = 'https://github.com/restic/restic/releases/download/v0.19.1/restic_0.19.1_windows_amd64.zip'
        ArchiveSha256 = 'da948ad707ed690426473aaba2046cd61f8f90f6f0e7dab6be0d5796531de67d'
        Entry         = 'restic_0.19.1_windows_amd64.exe'
        Sha256        = 'b0dd1fd21eea5d8fe1325f55f7118213c21f36de8a261e04c0624a5ab9fd7830'
    }
    RestServer = @{
        Version       = '0.14.0'
        Url           = 'https://github.com/restic/rest-server/releases/download/v0.14.0/rest-server_0.14.0_windows_amd64.zip'
        ArchiveSha256 = '98e31e33816861722e0f04c7f56811a3ff2f37e006def217ad6eda8e438c9d82'
        Entry         = 'rest-server_0.14.0_windows_amd64/rest-server.exe'
        Sha256        = '66e185d33b4777bcc3b939085e48fc487de597f7c8607727f82b6be5a01d15f4'
    }
    # Die Variante für .NET Framework 4.6.1, das in Windows 10/11 enthalten ist.
    WinSW      = @{
        Version = '2.12.0'
        Url     = 'https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW.NET461.exe'
        Sha256  = 'b5066b7bbdfba1293e5d15cda3caaea88fbeab35bd5b38c41c913d492aadfc4f'
    }
    # Nur für die Erstinstallation. Danach aktualisiert sich Tailscale selbst,
    # eine neuere installierte Version bleibt unangetastet.
    Tailscale  = @{
        Version = '1.104.5'
        Url     = 'https://pkgs.tailscale.com/stable/tailscale-setup-1.104.5-amd64.msi'
        Sha256  = '3c41318c83c5d95d0b017b1baa08ba7c99fd5334166122bbb1931e55af99839c'
    }
}

# --- Feste Namen ---------------------------------------------------------------
$Tag = 'tag:backup-target'                 # tagOwners in tailscale/policy.hujson
$TailnetRange = '100.64.0.0/10'            # Adressbereich der Tailscale-Geräte
$ServiceName = 'rest-server'
$ServiceAccount = "NT SERVICE\$ServiceName"
$FirewallRuleName = 'Backup-Ziel-rest-server'
$InstallDir = Join-Path $env:ProgramFiles 'Backup-Ziel'
$LogDir = Join-Path $env:ProgramData 'Backup-Ziel\logs'
$Tailscale = Join-Path $env:ProgramFiles 'Tailscale\tailscale.exe'
$ResticExe = Join-Path $InstallDir 'restic.exe'
$RestServerExe = Join-Path $InstallDir 'rest-server.exe'
$WrapperExe = Join-Path $InstallDir 'rest-server-dienst.exe'
$WrapperXml = Join-Path $InstallDir 'rest-server-dienst.xml'   # WinSW liest <exe-Name>.xml

$script:Changes = New-Object System.Collections.Generic.List[string]

# --- Hilfsfunktionen -------------------------------------------------------------

function Write-Unchanged([string] $Message) {
    Write-Host "ok:        $Message"
}

function Add-Change([string] $Message) {
    $script:Changes.Add($Message)
    Write-Host "geändert:  $Message" -ForegroundColor Yellow
}

# Ruft ein Programm auf und bricht ab, wenn es nicht mit 0 endet.
function Invoke-Native {
    param([string] $FilePath, [string[]] $ArgumentList)
    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "$(Split-Path -Leaf $FilePath) $($ArgumentList -join ' ') endete mit Exit-Code $LASTEXITCODE."
    }
}

# Führt $Script mit einem frischen Verzeichnis unter %TEMP% aus und löscht es
# danach in jedem Fall wieder.
function Use-TemporaryDirectory([scriptblock] $Script) {
    $path = Join-Path $env:TEMP ('backup-ziel-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $path | Out-Null
    try {
        & $Script $path
    }
    finally {
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

function Test-Sha256([string] $Path, [string] $Sha256) {
    (Test-Path -LiteralPath $Path -PathType Leaf) -and
    ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Sha256)
}

function Assert-Sha256([string] $Path, [string] $Sha256) {
    if (-not (Test-Sha256 $Path $Sha256)) {
        throw "Prüfsumme von $Path stimmt nicht (erwartet $Sha256). Abbruch, nichts installiert."
    }
}

# Lädt eine Datei, prüft sie und gibt den Pfad der geprüften Datei zurück
# (bei einem Archiv die entpackte Datei) im Verzeichnis $TempDir.
function Get-PinnedFile([hashtable] $Pin, [string] $TempDir) {
    $download = Join-Path $TempDir (Split-Path -Leaf $Pin.Url)
    Invoke-WebRequest -Uri $Pin.Url -OutFile $download -UseBasicParsing
    if (-not $Pin.ContainsKey('Entry')) {
        Assert-Sha256 $download $Pin.Sha256
        return $download
    }
    Assert-Sha256 $download $Pin.ArchiveSha256
    $extracted = Join-Path $TempDir 'entpackt'
    Expand-Archive -LiteralPath $download -DestinationPath $extracted
    $file = Join-Path $extracted $Pin.Entry
    Assert-Sha256 $file $Pin.Sha256
    $file
}

function Install-PinnedBinary([string] $Name, [hashtable] $Pin, [string] $Destination) {
    if (Test-Sha256 $Destination $Pin.Sha256) {
        Write-Unchanged "$Name $($Pin.Version)"
        return
    }
    Use-TemporaryDirectory {
        param($temp)
        Copy-Item -LiteralPath (Get-PinnedFile $Pin $temp) -Destination $Destination -Force
    }
    Add-Change "$Name $($Pin.Version) installiert"
}

# Liest eine Eigenschaft eines JSON-Objekts, $null wenn sie fehlt
# (StrictMode bricht sonst beim Zugriff ab).
function Get-JsonProperty($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function Get-TailscaleStatus {
    # Ohne Anmeldung endet "status" mit Exit-Code 1, das JSON stimmt trotzdem.
    $json = & $Tailscale status --json
    ($json -join "`n") | ConvertFrom-Json
}

# Kurz nach der Installation antwortet der Dienst noch nicht.
function Wait-TailscaleService {
    for ($i = 0; $i -lt 60; $i++) {
        try {
            if (Get-JsonProperty (Get-TailscaleStatus) 'BackendState') { return }
        }
        catch {
            Write-Verbose "Tailscale antwortet noch nicht: $_"
        }
        Start-Sleep -Seconds 1
    }
    throw 'Der Dienst Tailscale antwortet nicht.'
}

# Verzeichnis nur für Administratoren, SYSTEM und das Dienstkonto, ohne
# geerbte Rechte. Vergleicht die Regeln einzeln, damit ein zweiter Lauf
# nichts ändert.
function Grant-ServiceDirectoryAccess([string] $Path, [string] $Label) {
    $serviceSid = (New-Object Security.Principal.NTAccount $ServiceAccount).Translate([Security.Principal.SecurityIdentifier])
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none = [Security.AccessControl.PropagationFlags]::None
    $allow = [Security.AccessControl.AccessControlType]::Allow
    $rules = @(
        @((New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'), 'FullControl'),   # Administratoren
        @((New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'), 'FullControl'),       # SYSTEM
        @($serviceSid, 'Modify, Synchronize')
    )
    $desired = New-Object Security.AccessControl.DirectorySecurity
    $desired.SetAccessRuleProtection($true, $false)
    foreach ($rule in $rules) {
        $rights = [Security.AccessControl.FileSystemRights]$rule[1]
        $desired.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $rule[0], $rights, $inherit, $none, $allow))
    }

    $describe = {
        param($Acl)
        $entries = foreach ($r in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
            '{0}|{1}|{2}|{3}|{4}|{5}' -f $r.IdentityReference.Value, [int]$r.FileSystemRights,
            [int]$r.InheritanceFlags, [int]$r.PropagationFlags, $r.AccessControlType, $r.IsInherited
        }
        "protected=$($Acl.AreAccessRulesProtected);" + (($entries | Sort-Object) -join ';')
    }
    $current = Get-Acl -LiteralPath $Path
    if ((& $describe $current) -eq (& $describe $desired)) {
        Write-Unchanged "Zugriffsrechte $Label"
        return
    }
    Set-Acl -LiteralPath $Path -AclObject $desired
    Add-Change "Zugriffsrechte $Label (nur Administratoren, SYSTEM, $ServiceAccount)"
}

function Install-Directory([string] $Path, [string] $Label) {
    if (Test-Path -LiteralPath $Path -PathType Container) {
        Write-Unchanged "Verzeichnis $Label"
        return
    }
    New-Item -ItemType Directory -Path $Path | Out-Null
    Add-Change "Verzeichnis $Label angelegt ($Path)"
}

function Install-TextFile([string] $Path, [string] $Content, [string] $Label) {
    if ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        ([IO.File]::ReadAllText($Path) -ceq $Content)) {
        Write-Unchanged $Label
        return $false
    }
    [IO.File]::WriteAllText($Path, $Content)   # UTF-8 ohne BOM
    Add-Change $Label
    $true
}

# Stimmt die Firewall-Regel genau? Windows zeigt /10 auch als Netzmaske an.
function Test-FirewallRule([string] $LocalAddress) {
    $rule = Get-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    if (-not $rule) { return $false }
    $portFilter = $rule | Get-NetFirewallPortFilter
    $addressFilter = $rule | Get-NetFirewallAddressFilter
    $appFilter = $rule | Get-NetFirewallApplicationFilter
    $rule.Enabled -eq 'True' -and $rule.Direction -eq 'Inbound' -and $rule.Action -eq 'Allow' -and
    "$($rule.Profile)" -eq 'Any' -and
    $portFilter.Protocol -eq 'TCP' -and "$($portFilter.LocalPort)" -eq "$Port" -and "$($portFilter.RemotePort)" -eq 'Any' -and
    "$($addressFilter.LocalAddress)" -eq $LocalAddress -and
    "$($addressFilter.RemoteAddress)" -in @($TailnetRange, '100.64.0.0/255.192.0.0') -and
    $appFilter.Program -eq $RestServerExe
}

# --- Prüfen der Eingaben -----------------------------------------------------------

$Repository = [IO.Path]::GetFullPath($Repository).TrimEnd('\')
$drive = [IO.Path]::GetPathRoot($Repository)
if ($Repository -eq $drive.TrimEnd('\')) {
    throw "-Repository darf nicht das Wurzelverzeichnis $drive sein, sondern ein eigenes Verzeichnis darin."
}
if ($drive -eq "$env:SystemDrive\") {
    throw "-Repository muss auf der externen Platte liegen, nicht auf dem Systemlaufwerk $drive."
}
if (-not (Test-Path -LiteralPath $drive)) {
    throw "Laufwerk $drive nicht gefunden. Ist die externe Platte angeschlossen?"
}
$fileSystem = (Get-Volume -DriveLetter $drive[0]).FileSystemType
$supportsAcl = $fileSystem -eq 'NTFS'

Write-Host "Backup-Ziel: $Repository, Port $Port"
Write-Host ''

# --- Tailscale -------------------------------------------------------------------

if (Test-Path -LiteralPath $Tailscale) {
    Write-Unchanged 'Tailscale installiert'
}
else {
    Use-TemporaryDirectory {
        param($temp)
        $msi = Get-PinnedFile $Pinned.Tailscale $temp
        $msiexec = Start-Process -FilePath msiexec.exe -Wait -PassThru `
            -ArgumentList '/i', "`"$msi`"", '/quiet', '/norestart'
        if ($msiexec.ExitCode -notin 0, 3010) {
            throw "Installation von Tailscale fehlgeschlagen (msiexec $($msiexec.ExitCode))."
        }
    }
    Add-Change "Tailscale $($Pinned.Tailscale.Version) installiert"
}
Wait-TailscaleService

# Angemeldet wird nur, wenn der PC nicht im Tailnet läuft. Den Auth-Key
# braucht nur die erste Anmeldung (NeedsLogin). Er geht als Datei an
# tailscale, damit er nicht in der Prozessliste steht.
$status = Get-TailscaleStatus
$upArgs = @('up', '--unattended', "--advertise-tags=$Tag", '--accept-dns=false', '--accept-routes=false')
switch ($status.BackendState) {
    'Running' {
        Write-Unchanged 'Tailscale angemeldet'
    }
    'NeedsLogin' {
        Write-Host ''
        Write-Host "Auth-Key aus der Admin-Konsole (Tag $Tag, nicht wiederverwendbar, vorab autorisiert):"
        $secure = Read-Host -AsSecureString 'Auth-Key'
        # %TEMP% des Administrators ist nur für ihn lesbar.
        Use-TemporaryDirectory {
            param($keyDir)
            $keyFile = Join-Path $keyDir 'auth-key'
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try {
                [IO.File]::WriteAllText($keyFile, [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr))
            }
            finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            Invoke-Native $Tailscale ($upArgs + "--auth-key=file:$keyFile")
        }
        Add-Change "Tailscale angemeldet ($Tag)"
    }
    default {
        # Stopped (z. B. nach "tailscale down"): Der Schlüssel des Geräts gilt noch.
        Invoke-Native $Tailscale $upArgs
        Add-Change "Tailscale gestartet (war $($status.BackendState))"
    }
}

$status = Get-TailscaleStatus
$self = Get-JsonProperty $status 'Self'
$tags = @(Get-JsonProperty $self 'Tags')
if ($status.BackendState -ne 'Running' -or $tags -notcontains $Tag) {
    throw ("Tailscale läuft ohne den Tag $Tag (Status $($status.BackendState), Tags: $($tags -join ', ')). " +
        "Ist der PC als eigenes Gerät angemeldet, erst 'tailscale logout', dann das Skript erneut starten.")
}
if (Get-JsonProperty $self 'KeyExpiry') {
    throw 'Der Schlüssel des PCs läuft ab. Getaggte Geräte haben keinen Ablauf, ist der Tag richtig vergeben?'
}

# DNS und Routen des PCs bleiben unverändert, und Tailscale läuft auch ohne
# angemeldeten Windows-Benutzer (unattended).
$prefsJson = & $Tailscale debug prefs
if ($LASTEXITCODE -ne 0) { throw 'tailscale debug prefs fehlgeschlagen.' }
$prefs = ($prefsJson -join "`n") | ConvertFrom-Json
if ((Get-JsonProperty $prefs 'CorpDNS') -or (Get-JsonProperty $prefs 'RouteAll') -or
    -not (Get-JsonProperty $prefs 'ForceDaemon')) {
    Invoke-Native $Tailscale @('set', '--accept-dns=false', '--accept-routes=false', '--unattended')
    Add-Change 'Tailscale: DNS und Routen aus, unattended an'
}
else {
    Write-Unchanged 'Tailscale: DNS und Routen aus, unattended an'
}

$tailscaleIp = "$(@(& $Tailscale ip -4)[0])".Trim()
if ($LASTEXITCODE -ne 0 -or $tailscaleIp -notmatch '^100\.\d+\.\d+\.\d+$') {
    throw "Keine Tailscale-IPv4-Adresse gefunden ($tailscaleIp)."
}

# --- Programme -------------------------------------------------------------------

Install-Directory $InstallDir 'Programme'

# Laufende Dateien lassen sich nicht ersetzen: Dienst vorher anhalten.
$service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$restart = $false
if ($service -and -not ((Test-Sha256 $RestServerExe $Pinned.RestServer.Sha256) -and
        (Test-Sha256 $WrapperExe $Pinned.WinSW.Sha256))) {
    Stop-Service -Name $ServiceName
    $restart = $true
}
Install-PinnedBinary -Name 'restic' -Pin $Pinned.Restic -Destination $ResticExe
Install-PinnedBinary -Name 'rest-server' -Pin $Pinned.RestServer -Destination $RestServerExe
Install-PinnedBinary -Name 'WinSW' -Pin $Pinned.WinSW -Destination $WrapperExe

# --- Dienst --------------------------------------------------------------------------

Install-Directory (Split-Path $LogDir) 'Daten des Dienstes'
Install-Directory $LogDir 'Logs'
Install-Directory $Repository 'Repositorys'

$esc = { param($s) [Security.SecurityElement]::Escape($s) }
$arguments = "--path `"$Repository`" --listen $($tailscaleIp):$Port --append-only --no-auth --log -"
$serviceXml = @"
<!-- Erzeugt von windows/backup-ziel.ps1, Änderungen von Hand gehen verloren. -->
<service>
  <id>$ServiceName</id>
  <name>restic rest-server (Backup-Ziel)</name>
  <description>Backup-Ziel des Pi: rest-server im Modus append-only, nur über Tailscale erreichbar. Siehe docs/backup-ziel.md.</description>
  <executable>$(& $esc $RestServerExe)</executable>
  <arguments>$(& $esc $arguments)</arguments>
  <startmode>Automatic</startmode>
  <depend>Tailscale</depend>
  <!-- Ist die Tailscale-IP beim Start noch nicht da, scheitert das Binden: neu versuchen. -->
  <onfailure action="restart" delay="10 sec"/>
  <resetfailure>1 hour</resetfailure>
  <stoptimeout>15 sec</stoptimeout>
  <logpath>$(& $esc $LogDir)</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10240</sizeThreshold>
    <keepFiles>5</keepFiles>
  </log>
</service>
"@ -replace "`r`n", "`n"

$configChanged = Install-TextFile -Path $WrapperXml -Content $serviceXml -Label 'Dienstkonfiguration'
if ($configChanged) { $restart = $true }
if ($configChanged -and $service) {
    # Startart, Abhängigkeit und Neustart bei Fehlern übernimmt Windows nur bei
    # der Installation des Dienstes, deshalb neu installieren.
    Stop-Service -Name $ServiceName
    Invoke-Native $WrapperExe @('uninstall')
    for ($i = 0; $i -lt 30 -and (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Seconds 1
    }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) {
        throw "Dienst $ServiceName ist zum Löschen markiert. Dienste-Konsole (services.msc) schließen und erneut starten."
    }
    $service = $null
}
if (-not $service) {
    Invoke-Native $WrapperExe @('install')
    Add-Change "Dienst $ServiceName installiert"
    $restart = $true
}
else {
    Write-Unchanged "Dienst $ServiceName installiert"
}

$startName = (Get-CimInstance Win32_Service -Filter "Name='$ServiceName'").StartName
if ($startName -ne $ServiceAccount) {
    Invoke-Native sc.exe @('config', $ServiceName, 'obj=', $ServiceAccount)
    Add-Change "Dienst läuft als $ServiceAccount (war $startName)"
    $restart = $true
}
else {
    Write-Unchanged "Dienst läuft als $ServiceAccount"
}

Grant-ServiceDirectoryAccess $LogDir 'Logs'
if ($supportsAcl) {
    Grant-ServiceDirectoryAccess $Repository 'Repositorys'
}
else {
    Write-Warning "$drive ist $fileSystem, nicht NTFS: Zugriffsrechte für $Repository lassen sich nicht setzen."
}

$readme = @"
Backup-Ziel des Pi (Cloud-Speicher), verschlüsselt mit restic.
Geschrieben vom Dienst rest-server im Modus append-only.

Nicht von Hand ändern, verschieben oder löschen. Manuelle Backups gehören
nicht in dieses Verzeichnis.

Einrichtung und Betrieb: docs/backup-ziel.md im Repository
raspberry-pi-home-server.
"@ -replace "`r?`n", "`r`n"
Install-TextFile -Path (Join-Path $Repository 'LIESMICH.txt') -Content $readme -Label 'LIESMICH.txt im Backup-Ziel' | Out-Null

# --- Firewall ----------------------------------------------------------------------

if (Test-FirewallRule -LocalAddress $tailscaleIp) {
    Write-Unchanged "Firewall-Regel $FirewallRuleName"
}
else {
    Remove-NetFirewallRule -Name $FirewallRuleName -ErrorAction SilentlyContinue
    New-NetFirewallRule -Name $FirewallRuleName -DisplayName 'Backup-Ziel: rest-server (nur Tailnet)' `
        -Description 'Erzeugt von windows/backup-ziel.ps1. Nur der Port des rest-servers, nur aus dem Tailnet.' `
        -Direction Inbound -Action Allow -Profile Any -Protocol TCP -LocalPort $Port `
        -LocalAddress $tailscaleIp -RemoteAddress $TailnetRange -Program $RestServerExe | Out-Null
    Add-Change "Firewall-Regel $FirewallRuleName (TCP $Port auf $tailscaleIp aus $TailnetRange)"
}

# --- Starten und prüfen ------------------------------------------------------------

# Ein nötiger Neustart folgt aus einer Änderung weiter oben, die schon gezählt ist.
$service = Get-Service -Name $ServiceName
if ($service.Status -ne 'Running') {
    Start-Service -Name $ServiceName
    if (-not $restart) { Add-Change "Dienst $ServiceName gestartet (war $($service.Status))" }
}
elseif ($restart) {
    Restart-Service -Name $ServiceName
}
else {
    Write-Unchanged "Dienst $ServiceName läuft"
}

# rest-server darf nur auf der Tailscale-IP lauschen, nie auf allen Adressen.
$listeners = @()
for ($i = 0; $i -lt 20 -and -not $listeners; $i++) {
    Start-Sleep -Seconds 1
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
}
if (-not $listeners) {
    throw "rest-server lauscht nicht auf Port $Port. Logs: $LogDir"
}
foreach ($listener in $listeners) {
    $process = Get-Process -Id $listener.OwningProcess
    if ($listener.LocalAddress -ne $tailscaleIp -or $process.ProcessName -ne 'rest-server') {
        throw "Port ${Port}: $($process.ProcessName) lauscht auf $($listener.LocalAddress), erwartet nur rest-server auf $tailscaleIp."
    }
}
Write-Unchanged "rest-server lauscht nur auf $($tailscaleIp):$Port"

Write-Host ''
Write-Host "Repository-URL für den Pi: rest:http://$($tailscaleIp):$Port/<name>"
Write-Host "Änderungen: $($script:Changes.Count)"

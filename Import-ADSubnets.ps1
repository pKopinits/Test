<#
.SYNOPSIS
    Importiert IP-Subnetze aus einer CSV-Datei in Active Directory Sites and Services.

.DESCRIPTION
    Liest eine CSV-Datei mit Subnetzdefinitionen ein, prüft die Existenz der AD-Sites
    sowie der Subnetze und erstellt oder aktualisiert diese entsprechend.
    Unterstützt -WhatIf für risikofreie Testläufe.

.PARAMETER CsvPath
    Pfad zur CSV-Datei mit den Spalten 'Subnet', 'SiteName', 'Description'.
    Standard: '.\subnets.csv'

.PARAMETER Delimiter
    Trennzeichen der CSV-Datei (z. B. ',' oder ';' für deutsches Excel).
    Standard: ','

.EXAMPLE
    .\Import-ADSubnets.ps1 -WhatIf
    Führt eine Simulation durch und zeigt an, was getan werden würde.

.EXAMPLE
    .\Import-ADSubnets.ps1 -CsvPath "C:\Data\ad_subnets.csv" -Delimiter ";"
    Führt den Import mit einer Semikolon-getrennten CSV-Datei durch.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [string]$CsvPath = ".\subnets.csv",

    [Parameter(Mandatory = $false)]
    [string]$Delimiter = ","
)

# 1. Active Directory Modul prüfen
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Error "Das ActiveDirectory-Modul (RSAT) ist auf diesem Computer nicht verfügbar!"
    return
}

Import-Module ActiveDirectory -ErrorAction Stop

# 2. Prüfen, ob die CSV-Datei existiert
if (-not (Test-Path $CsvPath)) {
    Write-Error "Die CSV-Datei wurde nicht gefunden: $CsvPath"
    return
}

# Auto-Erkennung für Trennzeichen, falls standardmäßig Semikolon (z. B. aus deutschem Excel) verwendet wird
$firstLine = Get-Content -Path $CsvPath -TotalCount 1
if ($Delimiter -eq "," -and $firstLine -match ";" -and -not ($firstLine -match ",")) {
    Write-Verbose "Semikolon als Trennzeichen erkannt. Passe Delimiter an."
    $Delimiter = ";"
}

try {
    $subnets = Import-Csv -Path $CsvPath -Delimiter $Delimiter -ErrorAction Stop
}
catch {
    Write-Error "Fehler beim Einlesen der CSV-Datei: $_"
    return
}

if ($subnets.Count -eq 0) {
    Write-Warning "Die CSV-Datei enthält keine Datensätze."
    return
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host " Starte Import von $($subnets.Count) Subnetzen in AD Sites" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$stats = [ordered]@{
    Created = 0
    Updated = 0
    Skipped = 0
    Errors  = 0
}

foreach ($row in $subnets) {
    if ([string]::IsNullOrWhiteSpace($row.Subnet) -or [string]::IsNullOrWhiteSpace($row.SiteName)) {
        Write-Warning "Zeile mit unvollständigen Daten übersprungen: $($row | Out-String)"
        $stats.Skipped++
        continue
    }

    $subnetName = $row.Subnet.Trim()
    $siteName   = $row.SiteName.Trim()
    $desc       = if ($row.Description) { $row.Description.Trim() } else { "" }

    Write-Host "`nPrüfe: $subnetName -> Ziel-Site: $siteName" -ForegroundColor White

    # 3. Prüfen, ob die Ziel-Site im AD existiert
    try {
        $targetSite = Get-ADReplicationSite -Identity $siteName -ErrorAction Stop
    }
    catch {
        Write-Warning "  [SKIP] Site '$siteName' existiert nicht im Active Directory! Subnetz wird übersprungen."
        $stats.Errors++
        continue
    }

    # 4. Prüfen, ob das Subnetz bereits existiert
    $existingSubnet = Get-ADReplicationSubnet -Filter "Name -eq '$subnetName'" -Properties Site, Description -ErrorAction SilentlyContinue

    if (-not $existingSubnet) {
        # Fall A: Subnetz existiert noch nicht -> Neu anlegen
        if ($PSCmdlet.ShouldProcess("$subnetName (Site: $siteName)", "Neues AD-Subnetz erstellen")) {
            try {
                New-ADReplicationSubnet -Name $subnetName -Site $siteName -Description $desc -ErrorAction Stop
                Write-Host "  [NEU] Subnetz '$subnetName' erfolgreich angelegt und '$siteName' zugewiesen." -ForegroundColor Green
                $stats.Created++
            }
            catch {
                Write-Error "  [FEHLER] Konnte Subnetz '$subnetName' nicht erstellen: $_"
                $stats.Errors++
            }
        }
    }
    else {
        # Fall B: Subnetz existiert bereits -> Zugeordnete Site ermitteln
        # Das Site-Attribut enthält den DN (z.B. "CN=Default-First-Site-Name,CN=Sites,CN=Configuration,...")
        $currentSiteName = ($existingSubnet.Site -split ",*..=")[1]

        if ($currentSiteName -ne $siteName) {
            # Subnetz ist einer anderen Site zugewiesen -> Aktualisieren
            if ($PSCmdlet.ShouldProcess("$subnetName (Alt: $currentSiteName -> Neu: $siteName)", "Subnetz-Site aktualisieren")) {
                try {
                    Set-ADReplicationSubnet -Identity $subnetName -Site $siteName -Description $desc -ErrorAction Stop
                    Write-Host "  [AKTUALISIERT] Subnetz '$subnetName' von '$currentSiteName' nach '$siteName' verschoben." -ForegroundColor Yellow
                    $stats.Updated++
                }
                catch {
                    Write-Error "  [FEHLER] Konnte Subnetz '$subnetName' nicht aktualisieren: $_"
                    $stats.Errors++
                }
            }
        }
        else {
            Write-Host "  [OK] Subnetz '$subnetName' existiert bereits und ist korrekt '$siteName' zugewiesen." -ForegroundColor DarkGray
            $stats.Skipped++
        }
    }
}

Write-Host "`n================ Zusammenfassung ================" -ForegroundColor Cyan
Write-Host " Neu erstellt:  $($stats.Created)" -ForegroundColor Green
Write-Host " Aktualisiert:  $($stats.Updated)" -ForegroundColor Yellow
Write-Host " Unverändert:   $($stats.Skipped)" -ForegroundColor Gray
Write-Host " Fehler/Skips:  $($stats.Errors)"  -ForegroundColor $(if ($stats.Errors -gt 0) { "Red" } else { "Gray" })
Write-Host "=================================================" -ForegroundColor Cyan

# Funktion zur Extraktion der physischen Seriennummer
function Get-PhysicalSerialNumber {
    param (
        [string]$InstanceId
    )
    $currentId = $InstanceId
    while ($currentId) {
        $parts = $currentId -split '\\'
        if ($parts.Count -gt 1) {
            $lastPart = $parts[-1]
            # Wenn der letzte Teil kein '&' enthält, ist es wahrscheinlich die physische Seriennummer
            if ($lastPart -and $lastPart -notlike "*&*") {
                return $lastPart
            }
        }
        
        # Gehe zum übergeordneten Gerät (Parent)
        try {
            $parentProp = Get-PnpDeviceProperty -InstanceId $currentId -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
            if ($parentProp -and $parentProp.Data) {
                $currentId = $parentProp.Data
            } else {
                $currentId = $null
            }
        } catch {
            $currentId = $null
        }
    }
    return "N/A"
}

# 1. Aktuelle Dockingstation-Seriennummer ermitteln
$Docks = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.FriendlyName -like "*Dock*" -or $_.FriendlyName -like "*Station*") -and
    ($_.Class -in @('USB', 'USBDevice', 'System'))
}

$CurrentDockSerial = "NoDock"
if ($Docks) {
    $resolvedSerials = $Docks | ForEach-Object { Get-PhysicalSerialNumber -InstanceId $_.InstanceId } | Where-Object { $_ -ne "N/A" }
    if ($resolvedSerials) {
        $CurrentDockSerial = $resolvedSerials[0] # Erste physische Seriennummer nehmen
    }
}

# String bereinigen (nur alphanumerisch)
$CurrentDockSerialClean = $CurrentDockSerial -replace '[^a-zA-Z0-9]', ''

$LastRunFile = "C:\ProgramData\PC_Inventory\LastRun.txt"
$LastDockFile = "C:\ProgramData\PC_Inventory\LastDock.txt"

# Sonderregel: Wenn eine der Dateien fehlt, sofort exit 1
if (-not (Test-Path $LastRunFile) -or -not (Test-Path $LastDockFile)) {
    Write-Host "Erkennung: Lokale Inventurdaten fehlen. Inventur wird erzwungen."
    exit 1
}

$LastRun = Get-Content $LastRunFile -Raw -ErrorAction SilentlyContinue
$LastDock = (Get-Content $LastDockFile -Raw -ErrorAction SilentlyContinue).Trim()

# Datumsüberprüfung (älter als 7 Tage?)
try {
    $LastRunDate = [datetime]$LastRun.Trim()
    $IsOlderThan7Days = (Get-Date) -ge $LastRunDate.AddDays(7)
} catch {
    $IsOlderThan7Days = $true
}

# Vergleich der aktuellen Dock-Seriennummer mit der letzten
$DockChanged = $CurrentDockSerialClean -ne $LastDock

if ($IsOlderThan7Days -or $DockChanged) {
    Write-Host "Erkennung: Erneute Inventur nötig (Alter > 7 Tage: $IsOlderThan7Days, Dock geändert: $DockChanged)."
    exit 1 # Triggert das Behebungsskript
}

Write-Host "Erkennung: Inventur ist aktuell (Zuletzt am $LastRunDate mit Dock: $LastDock)."
exit 0 # Kein Handlungsbedarf

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The Azure Blob Storage Container SAS URI or a local folder path for testing.")]
    [string]$ContainerSasUri
)

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

# 1. System-Informationen erfassen
$ComputerName = $env:COMPUTERNAME
$BiosSerial = (Get-CimInstance -ClassName Win32_Bios).SerialNumber
$Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

# Aktuell angemeldeten Benutzer ermitteln
$LoggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ([string]::IsNullOrEmpty($LoggedInUser)) {
    $LoggedInUser = Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
        $owner = $_ | Invoke-CimMethod -MethodName GetOwner
        if ($owner.ReturnValue -eq 0) {
            "$($owner.Domain)\$($owner.User)"
        }
    } | Select-Object -Unique -First 1
}
if ([string]::IsNullOrEmpty($LoggedInUser)) {
    $LoggedInUser = "Kein Benutzer angemeldet"
}

# 2. Aktive Monitore via WmiMonitorID auslesen und decodieren
$ActiveMonitors = @()
try {
    $WmiMonitors = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction SilentlyContinue
    foreach ($mon in $WmiMonitors) {
        $name = ""
        if ($mon.UserFriendlyName) {
            $name = [System.Text.Encoding]::ASCII.GetString($mon.UserFriendlyName).Trim().Replace("`0", "")
        }
        $serial = ""
        if ($mon.SerialNumberID) {
            $serial = [System.Text.Encoding]::ASCII.GetString($mon.SerialNumberID).Trim().Replace("`0", "")
        }
        
        # Integrierte Laptop-Displays oder ungültige Werte ("Unknown", "0", leer) herausfiltern
        if ([string]::IsNullOrEmpty($name) -or $name -eq "Unknown" -or $serial -eq "0" -or [string]::IsNullOrEmpty($serial)) {
            continue
        }
        
        $ActiveMonitors += [PSCustomObject]@{
            Name   = $name
            Serial = $serial
        }
    }
} catch {
    Write-Warning "Monitore konnten nicht über WmiMonitorID ausgelesen werden."
}

# 3. PnpDevices abfragen und filtern (Nur Hauptgeräte der Dockingstationen)
$Docks = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.FriendlyName -like "*Dock*" -or $_.FriendlyName -like "*Station*") -and
    ($_.Class -in @('USB', 'USBDevice', 'System'))
}

# 4. USB-Drucker ermitteln
$UsbPrinters = @()
$PrinterDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.Class -in @('Printer', 'PNPPrinters', 'USB')) -and
    ($_.FriendlyName -like "*Printer*" -or $_.FriendlyName -like "*Drucker*" -or $_.Class -eq 'Printer') -and
    ($_.InstanceId -like "USB\*")
}
foreach ($pr in $PrinterDevices) {
    $serial = Get-PhysicalSerialNumber -InstanceId $pr.InstanceId
    $UsbPrinters += [PSCustomObject]@{
        Name   = $pr.FriendlyName
        Serial = $serial
    }
}


# 5. Dock-Daten extrahieren
$DockNames = "No Dockingstation found"
$DockSerials = "N/A"
if ($Docks) {
    $DockNames = ($Docks | ForEach-Object { $_.FriendlyName }) -join "; "
    $DockSerials = ($Docks | ForEach-Object { Get-PhysicalSerialNumber -InstanceId $_.InstanceId }) -join "; "
}

# 6. Monitor-Daten extrahieren
$MonitorNames = "No active Monitors found"
$MonitorSerials = "N/A"
if ($ActiveMonitors.Count -gt 0) {
    $MonitorNames = ($ActiveMonitors | ForEach-Object { $_.Name }) -join "; "
    $MonitorSerials = ($ActiveMonitors | ForEach-Object { $_.Serial }) -join "; "
}

# 7. USB-Drucker-Daten extrahieren
$PrinterNames = "No USB-Printers found"
$PrinterSerials = "N/A"
if ($UsbPrinters.Count -gt 0) {
    $PrinterNames = ($UsbPrinters | ForEach-Object { $_.Name }) -join "; "
    $PrinterSerials = ($UsbPrinters | ForEach-Object { $_.Serial }) -join "; "
}

# 8. Daten für die CSV zusammenführen
$InventoryData = [PSCustomObject]@{
    ComputerName        = $ComputerName
    LoggedInUser        = $LoggedInUser
    BiosSerialNumber    = $BiosSerial
    DockName            = $DockNames
    DockSerialNumber    = $DockSerials
    MonitorModel        = $MonitorNames
    MonitorSerialNumber = $MonitorSerials
    UsbPrinterName      = $PrinterNames
    UsbPrinterSerial    = $PrinterSerials
    Timestamp           = $Timestamp
}

# 9. CSV-Inhalt generieren und in UTF-8 konvertieren
$CsvContent = $InventoryData | ConvertTo-Csv -NoTypeInformation -Delimiter ";" | Out-String
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($CsvContent)

# 10. Dock-Seriennummer für den Upload und die lokale Speicherung bereinigen
# (Entfernt alle Sonderzeichen für Azure Storage Konformität)
$CleanDockSerial = $DockSerials -replace '[^a-zA-Z0-9]', ''
if ([string]::IsNullOrEmpty($CleanDockSerial) -or $CleanDockSerial -eq "NA") {
    $CleanDockSerial = "NoDock"
}

$BlobName = "Inventar_$($ComputerName)_$($CleanDockSerial).csv"

# 11. Daten abspeichern (Lokaler Testpfad oder Azure Blob Storage Upload)
try {
    if ($ContainerSasUri -like "http*") {
        # Echter Azure-Upload
        $SasParts = $ContainerSasUri -split '\?'
        if ($SasParts.Count -ne 2) {
            throw "Ungültiges Container-SAS-URI-Format. Ein '?' zur Trennung des SAS-Tokens wird erwartet."
        }
        
        $BaseUrl = $SasParts[0].TrimEnd('/')
        $SasToken = $SasParts[1]
        $UploadUrl = "$BaseUrl/$BlobName`?$SasToken"
        
        $Headers = @{
            "x-ms-blob-type" = "BlockBlob"
        }
        
        Write-Host "Lade Inventardaten hoch zu Azure Blob Storage..."
        $Response = Invoke-RestMethod -Uri $UploadUrl -Method Put -Headers $Headers -Body $Bytes -ContentType "text/csv; charset=utf-8"
        Write-Host "Azure Upload erfolgreich! Blob-Name: $BlobName"
    } else {
        # Lokaler Test-Mock (wenn ein lokaler Ordnerpfad übergeben wird)
        if (-not (Test-Path $ContainerSasUri)) {
            New-Item -ItemType Directory -Path $ContainerSasUri -Force | Out-Null
        }
        $LocalPath = Join-Path $ContainerSasUri $BlobName
        [System.IO.File]::WriteAllBytes($LocalPath, $Bytes)
        Write-Host "LOKALER MOCK: Datei erfolgreich geschrieben nach: $LocalPath"
    }
    
    # 12. Lokalen Ordner und Statusdateien schreiben
    $InventoryPath = "C:\ProgramData\PC_Inventory"
    if (-not (Test-Path $InventoryPath)) {
        New-Item -ItemType Directory -Path $InventoryPath -Force | Out-Null
    }
    
    $LastRunFile = Join-Path $InventoryPath "LastRun.txt"
    $LastDockFile = Join-Path $InventoryPath "LastDock.txt"
    
    $CleanDockSerial | Out-File -FilePath $LastDockFile -Force -Encoding utf8
    (Get-Date).ToString("o") | Out-File -FilePath $LastRunFile -Force -Encoding utf8
    Write-Host "Zeitstempel und Dock-Seriennummer ($CleanDockSerial) lokal unter $InventoryPath aktualisiert."
} catch {
    Write-Error "Fehler bei der Datenübertragung/Speicherung: $_"
    exit 1
}

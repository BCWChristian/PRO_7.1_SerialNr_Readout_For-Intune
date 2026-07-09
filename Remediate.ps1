[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "The Azure Blob Storage Container SAS URI or a local folder path for testing.")]
    [string]$ContainerSasUri
)

# Function to extract the physical serial number from a device instance ID
function Get-PhysicalSerialNumber {
    param (
        [string]$InstanceId
    )
    $currentId = $InstanceId
    while ($currentId) {
        $parts = $currentId -split '\\'
        if ($parts.Count -gt 1) {
            $lastPart = $parts[-1]
            # If the last part does not contain '&', it is likely the physical serial number
            if ($lastPart -and $lastPart -notlike "*&*") {
                return $lastPart
            }
        }
        
        # Go to the parent device
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

# 1. Gather system information
$ComputerName = $env:COMPUTERNAME
$BiosSerial = (Get-CimInstance -ClassName Win32_Bios).SerialNumber
$Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

# Determine currently logged-in user
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
    $LoggedInUser = "No user logged in"
}

# 2. Read and decode active monitors via WmiMonitorID
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
        
        # Filter out internal laptop displays or invalid values ("Unknown", "0", empty)
        if ([string]::IsNullOrEmpty($name) -or $name -eq "Unknown" -or $serial -eq "0" -or [string]::IsNullOrEmpty($serial)) {
            continue
        }
        
        $ActiveMonitors += [PSCustomObject]@{
            Name   = $name
            Serial = $serial
        }
    }
} catch {
    Write-Warning "Failed to read monitors via WmiMonitorID."
}

# 3. Query and filter PnpDevices (Only main devices of docking stations)
$Docks = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.FriendlyName -like "*Dock*" -or $_.FriendlyName -like "*Station*") -and
    ($_.Class -in @('USB', 'USBDevice', 'System'))
}

# 4. Discover USB printers
$UsbPrinters = @()
$PrinterDevices = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.Class -in @('Printer', 'PNPPrinters', 'USB')) -and
    ($_.FriendlyName -like "*Printer*" -or $_.Class -eq 'Printer') -and
    ($_.InstanceId -like "USB\*")
}
foreach ($pr in $PrinterDevices) {
    $serial = Get-PhysicalSerialNumber -InstanceId $pr.InstanceId
    $UsbPrinters += [PSCustomObject]@{
        Name   = $pr.FriendlyName
        Serial = $serial
    }
}


# 5. Extract dock data
$DockNames = "No Dockingstation found"
$DockSerials = "N/A"
if ($Docks) {
    $DockNames = ($Docks | ForEach-Object { $_.FriendlyName }) -join "; "
    $DockSerials = ($Docks | ForEach-Object { Get-PhysicalSerialNumber -InstanceId $_.InstanceId }) -join "; "
}

# 6. Extract USB printer data
$PrinterNames = "No USB-Printers found"
$PrinterSerials = "N/A"
if ($UsbPrinters.Count -gt 0) {
    $PrinterNames = ($UsbPrinters | ForEach-Object { $_.Name }) -join "; "
    $PrinterSerials = ($UsbPrinters | ForEach-Object { $_.Serial }) -join "; "
}

# 7. Merge data for the CSV (Multi-Monitor support)
$Properties = [ordered]@{
    ComputerName     = $ComputerName
    LoggedInUser     = $LoggedInUser
    BiosSerialNumber = $BiosSerial
    DockName         = $DockNames
    DockSerialNumber = $DockSerials
}

# Add each monitor in its own separate lane (column), padded to a fixed 5 slots
$MaxMonitors = 5
for ($i = 0; $i -lt $MaxMonitors; $i++) {
    $num = $i + 1
    if ($i -lt $ActiveMonitors.Count) {
        $Properties["MonitorModel_$num"] = $ActiveMonitors[$i].Name
        $Properties["MonitorSerialNumber_$num"] = $ActiveMonitors[$i].Serial
    } else {
        if ($i -eq 0 -and $ActiveMonitors.Count -eq 0) {
            $Properties["MonitorModel_1"] = "No active Monitors found"
        } else {
            $Properties["MonitorModel_$num"] = "N/A"
        }
        $Properties["MonitorSerialNumber_$num"] = "N/A"
    }
}

$Properties["UsbPrinterName"]   = $PrinterNames
$Properties["UsbPrinterSerial"] = $PrinterSerials
$Properties["Timestamp"]        = $Timestamp

$InventoryData = [PSCustomObject]$Properties

# 9. Generate CSV content and convert to UTF-8
$CsvContent = $InventoryData | ConvertTo-Csv -NoTypeInformation -Delimiter ";" | Out-String
$Bytes = [System.Text.Encoding]::UTF8.GetBytes($CsvContent)

# 10. Clean dock serial number for upload and local storage
# (Removes all special characters for Azure Storage compliance)
$CleanDockSerial = $DockSerials -replace '[^a-zA-Z0-9]', ''
if ([string]::IsNullOrEmpty($CleanDockSerial) -or $CleanDockSerial -eq "NA") {
    $CleanDockSerial = "NoDock"
}

$BlobName = "Inventar_$($ComputerName)_$($CleanDockSerial).csv"

# 11. Save data (Local test path or Azure Blob Storage upload)
try {
    if ($ContainerSasUri -like "http*") {
        # Real Azure upload
        $SasParts = $ContainerSasUri -split '\?'
        if ($SasParts.Count -ne 2) {
            throw "Invalid Container-SAS-URI format. A '?' to separate the SAS token is expected."
        }
        
        $BaseUrl = $SasParts[0].TrimEnd('/')
        $SasToken = $SasParts[1]
        $UploadUrl = "$BaseUrl/$BlobName`?$SasToken"
        
        $Headers = @{
            "x-ms-blob-type" = "BlockBlob"
        }
        
        Write-Host "Uploading inventory data to Azure Blob Storage..."
        $null = Invoke-RestMethod -Uri $UploadUrl -Method Put -Headers $Headers -Body $Bytes -ContentType "text/csv; charset=utf-8" -TimeoutSec 120
        Write-Host "Azure upload successful! Blob name: $BlobName"
    } else {
        # Local test mock (if a local folder path is provided)
        if (-not (Test-Path $ContainerSasUri)) {
            New-Item -ItemType Directory -Path $ContainerSasUri -Force | Out-Null
        }
        $LocalPath = Join-Path $ContainerSasUri $BlobName
        [System.IO.File]::WriteAllBytes($LocalPath, $Bytes)
        Write-Host "LOCAL MOCK: File successfully written to: $LocalPath"
    }
    
    # 12. Write local folder and status files
    $InventoryPath = "C:\ProgramData\PC_Inventory"
    if (-not (Test-Path $InventoryPath)) {
        New-Item -ItemType Directory -Path $InventoryPath -Force | Out-Null
    }
    
    $LastRunFile = Join-Path $InventoryPath "LastRun.txt"
    $LastDockFile = Join-Path $InventoryPath "LastDock.txt"
    
    $CleanDockSerial | Out-File -FilePath $LastDockFile -Force -Encoding utf8
    (Get-Date).ToString("o") | Out-File -FilePath $LastRunFile -Force -Encoding utf8
    Write-Host "Timestamp and dock serial number ($CleanDockSerial) locally updated under $InventoryPath."
} catch {
    Write-Error "Error during data transfer/storage: $_"
    exit 1
}

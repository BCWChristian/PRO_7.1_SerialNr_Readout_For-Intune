# Function to extract the physical serial number
function Get-PhysicalSerialNumber {
    param (
        [string]$InstanceId
    )
    $currentId = $InstanceId
    $maxDepth = 20
    while ($currentId -and $maxDepth-- -gt 0) {
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

# 1. Determine current docking station serial number
$Docks = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object {
    ($_.FriendlyName -like "*Dock*" -or $_.FriendlyName -like "*Station*") -and
    ($_.Class -in @('USB', 'USBDevice', 'System'))
}

$CurrentDockSerial = "NoDock"
if ($Docks) {
    $resolvedSerials = $Docks | ForEach-Object { Get-PhysicalSerialNumber -InstanceId $_.InstanceId } | Where-Object { $_ -ne "N/A" }
    if ($resolvedSerials) {
        $CurrentDockSerial = $resolvedSerials[0] # Take the first physical serial number
    }
}

# Clean string (alphanumeric only)
$CurrentDockSerialClean = $CurrentDockSerial -replace '[^a-zA-Z0-9]', ''

$LastRunFile = "C:\ProgramData\PC_Inventory\LastRun.txt"
$LastDockFile = "C:\ProgramData\PC_Inventory\LastDock.txt"

# Special rule: If one of the files is missing, immediately exit 1
if (-not (Test-Path $LastRunFile) -or -not (Test-Path $LastDockFile)) {
    Write-Host "Detection: Local inventory data missing. Inventory check enforced."
    exit 1
}

$LastRun = Get-Content $LastRunFile -Raw -ErrorAction SilentlyContinue
$LastDock = (Get-Content $LastDockFile -Raw -ErrorAction SilentlyContinue).Trim()

# Date check (older than 7 days?)
try {
    $LastRunDate = [datetime]$LastRun.Trim()
    $IsOlderThan7Days = (Get-Date) -ge $LastRunDate.AddDays(7)
} catch {
    $IsOlderThan7Days = $true
}

# Comparison of current dock serial with the last one
$DockChanged = $CurrentDockSerialClean -ne $LastDock

if ($IsOlderThan7Days -or $DockChanged) {
    Write-Host "Detection: Inventory check necessary (Older > 7 days: $IsOlderThan7Days, Dock changed: $DockChanged)."
    exit 1 # Triggers the remediation script
}

Write-Host "Detection: Inventory is up to date (Last run: $LastRunDate with Dock: $LastDock)."
exit 0 # No action required

$Detect = Join-Path $PSScriptRoot "Detect.ps1"
$Remediate = Join-Path $PSScriptRoot "Remediate.ps1"
$Target = Join-Path $PSScriptRoot "..\PRO_7_Results"

powershell -ExecutionPolicy Bypass -File "$Detect"
if ($LASTEXITCODE -eq 1) {
    powershell -ExecutionPolicy Bypass -File "$Remediate" -ContainerSasUri "$Target"
}

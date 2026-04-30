#Requires -Version 5.1
<#
.SYNOPSIS
    Builds gk-script.exe using NSIS.
.NOTES
    Requires NSIS installed from https://nsis.sourceforge.io/Download
#>

[CmdletBinding()]
param(
    [string]$OutputFile = "",
    [string]$MakensisPath = ""
)

if (-not $OutputFile) {
    $OutputFile = "$PSScriptRoot\gk-script.exe"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Locate makensis
$candidates = @(
    @(
        $MakensisPath,
        "C:\Program Files (x86)\NSIS\makensis.exe",
        "C:\Program Files\NSIS\makensis.exe",
        (Get-Command makensis -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Where-Object { Test-Path $_ }
)

if ($candidates.Count -eq 0) {
    Write-Error "NSIS not found. Download and install from https://nsis.sourceforge.io/Download"
}
$makensis = $candidates[0]
Write-Host "Using NSIS: $makensis" -ForegroundColor Cyan

# Verify required files exist
foreach ($item in @("$PSScriptRoot\launch.bat", "$PSScriptRoot\src")) {
    if (-not (Test-Path $item)) {
        Write-Error "Required item not found: $item"
    }
}

# Build
Write-Host "Building gk-script.exe..." -ForegroundColor Cyan
Push-Location $PSScriptRoot
try {
    & $makensis "/DOUTFILE=$OutputFile" "$PSScriptRoot\gk-script.nsi"
    if ($LASTEXITCODE -ne 0) { throw "NSIS build failed (exit $LASTEXITCODE)" }
} finally {
    Pop-Location
}

$sizeMB = [math]::Round((Get-Item $OutputFile).Length / 1MB, 1)
Write-Host ""
Write-Host "Build successful!" -ForegroundColor Green
Write-Host "   Output : $OutputFile" -ForegroundColor Green
Write-Host "   Size   : $sizeMB MB" -ForegroundColor Green
Write-Host ""
Write-Host "Deploy by copying gk-script.exe to the target PC and double-clicking it." -ForegroundColor Yellow

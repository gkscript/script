#Requires -Version 5.1
<#
.SYNOPSIS
    Builds a self-extracting deployment archive (deploy.exe) using 7-Zip SFX.
.DESCRIPTION
    Packages launch.bat and the src/ directory into a single .exe file.
    Double-clicking deploy.exe on the target PC extracts the files and launches the GUI automatically.
.NOTES
    Requires 7-Zip to be installed (checks common paths automatically).
#>

[CmdletBinding()]
param(
    [string]$OutputFile = "",
    [string]$SevenZipPath = "",
    [string]$RceditPath = ""
)

# Derive output filename if not explicitly supplied
if (-not $OutputFile) {
    $OutputFile = "$PSScriptRoot\gk-script.exe"
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── 1. Locate 7-Zip ────────────────────────────────────────────────────────────
$candidates = @(
    @(
        $SevenZipPath,
        "C:\Program Files\7-Zip\7z.exe",
        "C:\Program Files (x86)\7-Zip\7z.exe",
        (Get-Command 7z -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Where-Object { Test-Path $_ }
)

if ($candidates.Count -eq 0) {
    Write-Error "7-Zip not found. Install it from https://www.7-zip.org/ or pass -SevenZipPath."
}
$7z = $candidates[0]
Write-Host "Using 7-Zip: $7z" -ForegroundColor Cyan

# ── 2. Locate rcedit (optional — used to embed netixx.ico into the output exe) ─
$rcedit = $null
$rceditCandidates = @(
    @(
        $RceditPath,
        "$PSScriptRoot\tools\rcedit.exe",
        (Get-Command rcedit -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Get-Command rcedit-x64 -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ) | Where-Object { -not [string]::IsNullOrEmpty($_) } | Where-Object { Test-Path $_ }
)

if ($rceditCandidates.Count -gt 0) {
    $rcedit = $rceditCandidates[0]
    Write-Host "Using rcedit: $rcedit" -ForegroundColor Cyan
} else {
    Write-Host "rcedit not found - exe icon will not be set. Place rcedit.exe in tools\ to enable." -ForegroundColor Yellow
}

# ── 3. Locate SFX module ──────────────────────────────────────────────────────
# Preference order: 7zSD.sfx (silent) > 7z.sfx (GUI dialog) > 7zCon.sfx (console)
$sfxDir = Split-Path $7z
$sfxModule = $null
foreach ($sfxName in @("7zSD.sfx", "7z.sfx", "7zCon.sfx")) {
    $candidate = Join-Path $sfxDir $sfxName
    if (Test-Path $candidate) { $sfxModule = $candidate; break }
}
if (-not $sfxModule) {
    Write-Error "No SFX module found in '$sfxDir'. Expected 7zSD.sfx, 7z.sfx or 7zCon.sfx."
}
Write-Host "Using SFX module: $(Split-Path $sfxModule -Leaf)" -ForegroundColor Cyan

# ── 3. Build file list ─────────────────────────────────────────────────────────
$root = $PSScriptRoot
$include = @(
    "$root\launch.bat",
    "$root\src\"
)

foreach ($item in $include) {
    if (-not (Test-Path $item)) {
        Write-Error "Required item not found: $item"
    }
}

# ── 4. Create SFX config ──────────────────────────────────────────────────────
$sfxConfig = @"
;!@Install@!UTF-8!
Title="Netixx Grundkonfiguration"
BeginPrompt="Setup starten?"
Directory="%TEMP%\NetixxSetup"
RunProgram="launch.bat"
;!@InstallEnd@!
"@

$tempDir     = Join-Path $env:TEMP "netixx_build_$([guid]::NewGuid().ToString('N').Substring(0,8))"
$archivePath = Join-Path $tempDir "payload.7z"
$configPath  = Join-Path $tempDir "sfx.cfg"

New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

try {
    # ── 5. Patch icon into a temp copy of the SFX stub ────────────────────────
    $patchedSfx = Join-Path $tempDir "stub.sfx"
    Copy-Item $sfxModule $patchedSfx
    $iconPath = "$root\src\netixx.ico"
    if ($rcedit -and (Test-Path $iconPath)) {
        Write-Host "Patching icon into SFX stub..." -ForegroundColor Cyan
        & $rcedit $patchedSfx --set-icon $iconPath
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "rcedit exited with code $LASTEXITCODE - icon may not have been set."
        }
    }

    # ── 7. Create the 7z archive ───────────────────────────────────────────────
    Write-Host "Compressing files..." -ForegroundColor Cyan
    $7zArgs = @(
        'a', '-t7z', $archivePath,
        "$root\launch.bat",
        "$root\src",
        '-mx=5',   # compression level (0=store, 9=ultra, 5=normal)
        '-mmt=on', # multi-thread
        '-bso0',   # suppress stdout
        '-bse0'    # suppress stderr
    )
    & $7z @7zArgs
    if ($LASTEXITCODE -ne 0) { throw "7-Zip compression failed (exit $LASTEXITCODE)" }

    # ── 8. Write SFX config ────────────────────────────────────────────────────
    [System.IO.File]::WriteAllText($configPath, $sfxConfig, [System.Text.Encoding]::UTF8)

    # ── 9. Combine: patched SFX stub + config + archive = .exe ────────────────
    Write-Host "Building deploy.exe..." -ForegroundColor Cyan
    $outStream = [System.IO.File]::OpenWrite($OutputFile)
    try {
        foreach ($part in @($patchedSfx, $configPath, $archivePath)) {
            $bytes = [System.IO.File]::ReadAllBytes($part)
            $outStream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $outStream.Close()
    }

    $sizeMB = [math]::Round((Get-Item $OutputFile).Length / 1MB, 1)
    Write-Host ""
    Write-Host "Build successful!" -ForegroundColor Green
    Write-Host "   Output : $OutputFile" -ForegroundColor Green
    Write-Host "   Size   : $sizeMB MB" -ForegroundColor Green
    Write-Host ""
    Write-Host "Deploy by copying deploy.exe to the target PC and double-clicking it." -ForegroundColor Yellow
}
finally {
    Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

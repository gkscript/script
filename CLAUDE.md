# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gk-script** is a Windows enterprise deployment tool for Netixx IT Solutions. It automates full system setup — package installation, GPU drivers, Office removal, branding, registry customization, bloat removal — across three deployment profiles. It ships as a self-contained `.exe` (built with NSIS) that presents a WPF GUI menu.

## Build

Build the `.exe` from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Optional parameters: `-OutputFile <path>` (default: `gk-script.exe` in repo root), `-MakensisPath <path>` (overrides auto-detection). Requires `makensis.exe` installed (searched in standard `Program Files` locations automatically). Output: `gk-script.exe`.

The NSIS script (`gk-script.nsi`) bundles `launch.bat` and the entire `src/` directory into the exe. `tools/7zSD.sfx` provides the self-extracting archive core; `tools/rcedit.exe` sets the exe icon and metadata.

## Running

From the repository root (admin required):

```powershell
# Launch GUI menu
launch.bat

# Run a deployment profile directly
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType business
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType consumer
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType consumer-nolo

# Optional flags
-SkipBloatwareRemoval   # Skip bloat/shortcut cleanup
-SkipHideConsole        # Keep the console window visible
-ConfigPath <path>      # Use alternate config.json
```

## Architecture

```
launch.bat              → UAC elevation → PowerShell GUI
src/gui.csv             → WPF menu entries (PSScriptMenuGui module)
src/main.ps1            → Main orchestration script
src/lib/PSSetupUtility.psm1  → Shared utilities (logging, pre-flight checks)
src/debloat.ps1         → Windows debloat (called by main.ps1)
src/config.json         → Deployment profiles, paths, package lists, validation config
src/version.txt         → Current version string (e.g. 1.1.2)
```

### Execution Flow (main.ps1)

1. Pre-flight checks: admin, internet, disk space (5 GB), Windows version, GPU, BitLocker
2. Remove pre-installed AV (McAfee, Norton, HP Wolf, Avast, AVG, Trend Micro) — winget + registry fallback
3. Install Chocolatey (downloaded to temp file, not piped to `iex`)
4. Install packages from `config.json` profile with 3-attempt retry + verification
5. Install GPU drivers (NVIDIA/AMD/Intel auto-detected)
6. Apply `.reg` files for registry settings, branding, desktop layout
7. Remove bloatware shortcuts and clean desktop via whitelist (`whitelist.txt`)
8. Disable BitLocker if encrypted
9. Copy install folder assets to `C:\Install`
10. Uninstall Office 365 — winget + registry fallback + language-variant detection
12. Run `debloat.ps1`
13. Re-apply OEM branding registry (OEM services can reset `OEMInformation` during debloat)
14. Set file associations via `SetUserFTA.exe` + `assoc.txt`
15. Apply desktop icon layout (`.reg`)
16. Stop/restart Explorer to apply changes

### Deployment Profiles (config.json)

| Profile | Packages | Notes |
|---|---|---|
| `business` | VLC, Firefox, Chrome, 7-Zip, Adobe Reader | Branded |
| `consumer` | business + LibreOffice + Paint.NET | Branded |
| `consumer-nolo` | business + Paint.NET (no LibreOffice) | Branded |

### Key Modules

- **PSScriptMenuGui** (`src/PSScriptMenuGui/`) — WPF-based CSV-driven menu GUI. Reads `gui.csv` and renders clickable buttons that launch PowerShell scripts. Split into `public/functions.ps1` and `private/functions.ps1`; XAML layout assembled from `xaml/start.xaml` + `xaml/end.xaml`. Requires .NET WPF assemblies (Windows only).
- **PSSetupUtility** (`src/lib/PSSetupUtility.psm1`) — Shared functions: `Write-Log`, `Initialize-Logging`, `Test-Prerequisite*`, `Sync-SystemTimeWithInternet`, `Get-SystemGPU`, `Get-BitlockerStatus`, `Invoke-SafeProcess`.

### gui.csv Schema

`gui.csv` is the only input to PSScriptMenuGui. Each row defines one button:

| Column | Value used in this repo |
|---|---|
| `Section` | Group header shown above buttons (`Netixx GK`) |
| `Method` | How to run the command (`powershell_inline`) |
| `Command` | Script path relative to repo root |
| `Arguments` | Extra args passed to Command |
| `Name` | Button label |
| `Description` | Tooltip / subtitle |

### Asset Files

| File | Purpose |
|---|---|
| `src/config.json` | Package lists, paths, logging, validation config |
| `src/gui.csv` | GUI menu button definitions |
| `src/debloat.ps1` | UWP app removal, winget uninstalls, telemetry disable |
| `src/assoc.txt` | File type association mappings |
| `src/whitelist.txt` | Desktop icons to keep (all others removed) |
| `src/desktop.reg` / `desktop_libreoffice.reg` | Desktop icon layout (profile-specific) |
| `src/icons.reg` | Desktop icon visibility settings |
| `src/Logo_Info.reg` | OEM branding (Support Info in System Properties) |
| `src/disable_telemetry.reg` | Windows telemetry disable settings |
| `src/OfficeSetup.exe` | Office deployment tool |
| `src/SetUserFTA.exe` | File association utility |
| `src/office.xml` | Office deployment configuration |
| `src/AutoHotkey32.exe` + `src/chrome.ahk` | Automated Chrome web app removal |
| `src/netixx.ico` / `src/oemlogo.bmp` | Branding assets |

## Logging

Logs write to `C:\Logs\PSScriptSetup\` (configurable in `config.json`). Use `Write-Log` from PSSetupUtility for all log output — it writes color-coded to console and timestamped to file simultaneously.

## Important Patterns

- **Fallback chains**: winget is tried first, then Chocolatey, then registry-based uninstall. Never assume a single method works.
- **3-attempt retry**: Package installs loop up to 3 times before failing.
- **Explorer stop/start**: Registry writes that affect the shell require `Stop-Process -Name explorer` before and a restart after. This is intentional.
- **Office removal**: Must handle language variant package IDs (e.g., `Microsoft.Office.Desktop.en-us`) in addition to the base package.
- **Admin guard**: All operations require elevation; checked at startup via `Test-PrerequisiteAdmin`.
- **Config-driven**: All profile differences (packages, paths, flags) live in `config.json`. Avoid hardcoding profile-specific values in scripts.

## Encoding Pitfalls

These have caused real runtime bugs — understand them before editing any source file.

### PowerShell 5.x script encoding
PowerShell 5.x (used on deployed machines) reads `.ps1` files as **Windows-1252** unless a UTF-8 BOM is present. Em dashes (—, U+2014) encoded as UTF-8 are 3 bytes (`0xE2 0x80 0x94`). In Windows-1252, byte `0x94` maps to `"` (right double quotation mark), which **closes a string literal prematurely** and causes parse errors. This will not reproduce in VS Code or pwsh 7 (which default to UTF-8).

**Rule**: Never use em dashes (—) inside string literals in `.ps1` files. In comments they are harmless; in strings they break PS5 parsing. Use ASCII hyphens (`-`) instead.

### .reg file encoding
`reg.exe import` only accepts **UTF-16 LE BOM** (`FF FE`) or **ANSI** encoded `.reg` files. UTF-8 BOM files are rejected with `FEHLER: Die angegebene Datei ist keine Registrierungsdatei`. To convert:

```powershell
$content = Get-Content .\src\file.reg -Raw -Encoding UTF8
[System.IO.File]::WriteAllText("$PWD\src\file.reg", $content, [System.Text.Encoding]::Unicode)
```

All `.reg` files in `src/` must be UTF-16 LE or ANSI — never UTF-8 BOM.

### $ErrorActionPreference = 'Stop' and native commands
`main.ps1` sets `$ErrorActionPreference = 'Stop'` globally at line 17. When a native executable (e.g. `reg.exe`) writes to stderr, capturing with `2>&1 | Out-Null` is **not** sufficient — the merged ErrorRecord can still throw a terminating exception before reaching `Out-Null`. Always wrap native command calls in `try/catch`:

```powershell
try {
    $null = & "$env:SystemRoot\System32\reg.exe" import "$regFile" 2>&1
} catch {
    Write-Log "Warning: $_" -Level Warning
}
```

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gk-script** is a Windows enterprise deployment tool for Netixx IT Solutions. It automates full system setup — package installation, GPU drivers, Office removal, branding, registry customization, bloat removal — across three deployment profiles. It ships as a self-contained `.exe` (built with NSIS) that presents a WPF GUI menu.

## Build

Build the `.exe` from the repository root:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Requires `makensis.exe` installed (searched in `Program Files` automatically). Output: `gk-script.exe`.

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
10. Install Dynamic Theme via bundled `DynamicTheme.msixbundle` (Windows 11 only)
11. Uninstall Office 365 — winget + registry fallback + language-variant detection
12. Run `debloat.ps1`
13. Set file associations via `SetUserFTA.exe` + `assoc.txt`
14. Apply desktop icon layout (`.reg`)
15. Stop/restart Explorer to apply changes

### Deployment Profiles (config.json)

| Profile | Packages | Notes |
|---|---|---|
| `business` | VLC, Firefox, Chrome, 7-Zip, Adobe Reader | Branded |
| `consumer` | business + LibreOffice + Paint.NET | Branded |
| `consumer-nolo` | business + Paint.NET (no LibreOffice) | Branded |

### Key Modules

- **PSScriptMenuGui** (`src/PSScriptMenuGui/`) — WPF-based CSV-driven menu GUI. Reads `gui.csv` and renders clickable buttons that launch PowerShell scripts. Requires .NET WPF assemblies (Windows only).
- **PSSetupUtility** (`src/lib/PSSetupUtility.psm1`) — Shared functions: `Write-Log`, `Test-Prerequisite*`, `Sync-SystemTimeWithInternet`, `Get-SystemGPU`, `Get-BitlockerStatus`, `Invoke-SafeProcess`.

### Asset Files

| File | Purpose |
|---|---|
| `src/config.json` | Package lists, paths, logging, validation config |
| `src/gui.csv` | GUI menu button definitions |
| `src/debloat.ps1` | Windows debloat script |
| `src/assoc.txt` | File type association mappings |
| `src/whitelist.txt` | Desktop icons to keep |
| `src/desktop.reg` / `desktop_libreoffice.reg` | Desktop icon layout variants |
| `src/DynamicTheme.msixbundle` | Bundled Dynamic Theme package |
| `src/OfficeSetup.exe` | Office deployment tool |
| `src/SetUserFTA.exe` | File association utility |
| `src/office.xml` | Office deployment configuration |

## Logging

Logs write to `C:\Logs\PSScriptSetup\` (configurable in `config.json`). Use `Write-Log` from PSSetupUtility for all log output — it writes color-coded to console and timestamped to file simultaneously.

## Important Patterns

- **Fallback chains**: winget is tried first, then Chocolatey, then registry-based uninstall. Never assume a single method works.
- **3-attempt retry**: Package installs loop up to 3 times before failing.
- **Explorer stop/start**: Registry writes that affect the shell require `Stop-Process -Name explorer` before and a restart after. This is intentional.
- **Office removal**: Must handle language variant package IDs (e.g., `Microsoft.Office.Desktop.en-us`) in addition to the base package.
- **Admin guard**: All operations require elevation; checked at startup via `Test-PrerequisiteAdmin`.

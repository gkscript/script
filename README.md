# gk-script

Windows enterprise deployment tool for Netixx IT Solutions. Automates full system setup — software installation, GPU drivers, Office removal, OEM branding, registry tweaks, and bloatware removal — across three deployment profiles. Ships as a self-contained `.exe` with a WPF GUI menu.

## Requirements

- Windows 11
- Administrator privileges
- Internet connection (for package downloads)

## Deploy

Copy `gk-script.exe` to the target machine and double-click it. UAC elevation is handled automatically.

## Profiles

| | Profile | Packages |
|---|---|---|
| 💼 | Business | VLC · Firefox · Chrome · 7-Zip · Adobe Reader |
| 🏠 | Consumer | + LibreOffice · Paint.NET |
| ⚡ | Consumer (No LibreOffice) | + Paint.NET |

All profiles include: AV removal, GPU driver install, Office 365 uninstall, OEM branding, registry tweaks, bloatware/UWP removal, file associations, desktop layout.

## What it does (in order)

1. Pre-flight checks — admin, internet, disk space (5 GB), Windows version, GPU, BitLocker
2. Remove pre-installed AV — McAfee, Norton, HP Wolf, Avast, AVG, Trend Micro
3. Install Chocolatey
4. Install packages (3-attempt retry + verification per package)
5. Install GPU drivers — NVIDIA / AMD / Intel auto-detected
6. Apply registry settings, OEM branding, desktop layout
7. Remove bloatware shortcuts, clean desktop (whitelist-based)
8. Disable BitLocker if encrypted
9. Copy assets to `C:\Install`
10. Uninstall Office 365 (winget + registry fallback + language-variant detection)
12. Remove UWP bloat (live Win11Debloat list + OEM extras, with offline fallback)
13. Set default file associations
14. Apply desktop icon layout, restart Explorer

## Logs

All operations log to `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log`.

```powershell
# Open the latest log
Get-ChildItem C:\Logs\PSScriptSetup\ -Filter *.log |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 | ForEach-Object { notepad $_.FullName }
```

## Build

Requires `makensis.exe` (NSIS) installed.

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Output: `gk-script.exe` in the repo root.

## Run without building

```powershell
# Launch GUI (admin required)
launch.bat

# Run a profile directly
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType business
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType consumer
powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType consumer-nolo

# Optional flags
-SkipBloatwareRemoval   # Skip bloat/shortcut cleanup
-SkipHideConsole        # Keep the console window visible
-ConfigPath <path>      # Use alternate config.json
```

## Project structure

```
gk-script.exe           ← self-contained deployment exe
launch.bat              → UAC elevation → PowerShell GUI
build.ps1               → builds gk-script.exe via NSIS
src/
├── main.ps1            → main orchestration script
├── config.json         → deployment profiles, package lists, paths
├── gui.csv             → WPF menu button definitions
├── debloat.ps1         → UWP removal, winget uninstalls, telemetry disable
├── lib/
│   └── PSSetupUtility.psm1   → shared utilities (logging, pre-flight, GPU, BitLocker)
└── PSScriptMenuGui/    → WPF CSV-driven menu module
```

## Customisation

- **Packages**: edit `src/config.json` — add/remove from the `packages` array per profile
- **Bloat exclusions**: edit `$excluded` set in `src/debloat.ps1`
- **Desktop icons to keep**: edit `src/whitelist.txt`
- **OEM branding**: replace `src/oemlogo.bmp` and `src/Logo_Info.reg`
- **Menu buttons**: edit `src/gui.csv`

## Changelog

### v1.1.2 — 2026-05-07
- Removed redundant GUI header; title bar shows version
- Emoji-differentiated deployment buttons (💼 🏠 ⚡)
- Added Lenovo Smart Meeting to bloat removal list
- Kept Clipchamp from removal
- Fixed `disable_telemetry.reg` encoding (UTF-16 LE — required by reg.exe)
- Fixed OEM branding re-apply crash after debloat

### v1.1.1 — 2026-05-07
- Fixed debloat.ps1 parse error caused by em dash encoding in PS5
- Live Win11Debloat list fetch with offline fallback
- OEM branding re-applied after debloat step

### v1.1.0
- consumer-nolo profile (consumer without LibreOffice)
- Animated WPF button hover effects
- Gradient button styling

### v1.0.0
- Initial release

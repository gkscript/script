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

All profiles include: GPU and Windows Update drivers, Office 365 uninstall, OEM branding, Netixx Helpdesk, registry tweaks, bloatware/UWP removal, file associations, desktop layout.

## What it does (in order)

1. Pre-flight checks — admin, internet, time sync, disk space (5 GB), GPU, BitLocker
2. Install Chocolatey
3. Install packages (3-attempt retry + verification per package)
4. Install GPU tools (NVIDIA App / Intel Graphics Command Center), then all pending drivers from Windows Update (covers AMD)
5. Apply registry settings and OEM branding
6. Remove bloatware shortcuts, clean desktop (whitelist-based)
7. Disable BitLocker if encrypted
8. Set up `C:\Install`, download the Netixx Helpdesk (signature-checked)
9. Uninstall Office 365 (Office Deployment Tool → winget → silent registry fallback)
10. Remove UWP bloat (live Win11Debloat list minus "unsafe" entries + OEM extras, offline fallback)
11. Set default file associations
12. Apply desktop icon layout, restart Explorer
13. Show the result window: green done / yellow warnings / red failed, with the warnings listed and a restart button when drivers need it

The PC and display are kept awake for the whole run, so the result is on screen when you come back.

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
│   ├── PSSetupUtility.psm1   → shared utilities (logging, pre-flight, result window)
│   ├── Theme.xaml            → shared look of all windows
│   ├── WindowTheme.ps1       → theme loader, Mica, title-bar color
│   └── SetupResult.xaml      → end-of-run result window
└── PSScriptMenuGui/    → WPF CSV-driven menu module
```

## Customisation

- **Packages**: edit `src/config.json` — add/remove from the `packages` array per profile
- **Bloat exclusions**: edit `$excluded` set in `src/debloat.ps1`
- **Desktop icons to keep**: edit `src/whitelist.txt`
- **OEM branding**: replace `src/oemlogo.bmp` and `src/Logo_Info.reg`
- **Menu buttons**: edit `src/gui.csv` (`Icon` = Segoe Fluent Icons code, e.g. `E821`)
- **Window look**: edit `src/lib/Theme.xaml` (rules in `DESIGN.md`)

## Changelog

### v1.2.0 — 2026-10-04
- New result window replaces all message boxes: green / yellow / red status band (also in title bar and taskbar), warnings listed, Open log, Restart now when drivers need it
- Menu redesigned on the same Windows 11 window system (Mica, settings-card rows, Fluent icons); one shared theme for all windows
- Windows Update driver install on every machine (covers AMD, which has no package source)
- Office removal: silent Office Deployment Tool restored as first pass; never opens the interactive uninstall wizard
- PC and display kept awake during the run
- Helpdesk download is signature-checked (TeamViewer) before it lands on the desktop
- Fixed: every message box crashed on PowerShell 5.1 (WinForms not loaded), which also turned successful runs into "Setup failed"
- Fixed: native-command errors aborting the whole run; killed installers counted as success; NVIDIA App skipped when any NVIDIA component existed; debloat stopping at the first non-removable app; unsafe Win11Debloat removals; empty log path in messages

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

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gk-script** ("Netixx Grundkonfiguration") is a Windows 11 deployment tool for Netixx IT Solutions. It automates first-time PC setup: package installation, GPU drivers, Office 365 removal, OEM branding, registry customization and bloat removal, across three deployment profiles. It ships as a single NSIS-built `.exe` that opens a WPF button menu.

There is no test suite or linter. Changes can only be verified by running a profile on a real (or VM) Windows machine as admin, then checking the log.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Optional: `-OutputFile <path>` (default `gk-script.exe` in repo root), `-MakensisPath <path>`. `makensis.exe` is auto-detected in `Program Files (x86)\NSIS`, `Program Files\NSIS` or PATH.

`gk-script.nsi` is the whole packaging step. It bundles `launch.bat` + all of `src/`, requests admin, sets the icon from `src/netixx.ico`, extracts to `%TEMP%\NetixxSetup` (wiping it first) and runs `launch.bat`. Nothing under `tools/` is used by the build (`tools/` is gitignored).

`gk-script.exe` appears in `.gitignore`, but it is tracked anyway, and releases commit the rebuilt exe. The version string lives in `src/version.txt` and is logged at startup.

## Running

From the repository root (admin required):

```powershell
launch.bat   # UAC self-elevation via VBS, then Show-ScriptMenuGui -csvpath .\src\gui.csv

powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType business|consumer|consumer-nolo
    [-SkipUpdates]            # no Windows Update, no app updates (menu: "install all updates" off)
    [-SkipBloatwareRemoval]   # skips Step 5 (shortcut cleanup + desktop whitelist) only; debloat.ps1 still runs
    [-ConfigPath <path>]      # alternate config.json
    [-Language de|en|it]      # UI language of the result window (default de); the log stays English
```

`-SkipHideConsole` is declared in `main.ps1` but currently does nothing.

## Architecture

```
gk-script.exe (NSIS) → launch.bat → PSScriptMenuGui (reads src/gui.csv) → src/main.ps1 -DeploymentType X
                                                                             ├─ src/lib/PSSetupUtility.psm1
                                                                             └─ src/debloat.ps1 (dot-invoked, same session)
```

- **`src/gui.csv`** is the only input to the vendored `PSScriptMenuGui` module. Each row is one button: `Section, Method (powershell_inline), Command, Arguments, Name, Description, Icon, NameKey`.
  - When a row is launched, `{lang}` in `Command` becomes the menu's current language, and `{updates}` becomes `-SkipUpdates` while the menu's updates switch is off.
  - `NameKey` points to a translated name in `src/lang` (it falls back to `Name`). `Icon` is an optional Segoe Fluent Icons code point in hex (e.g. `E821`). Keep emoji out of `Name`, because screen readers announce them.
  - Profile names must also match `ValidateSet` in `main.ps1` and a key under `deployment` in `config.json`.
- **`src/config.json`** defines:
  - the profiles: `packages` are catalog keys, plus the `branded` flag;
  - `packageCatalog`: per key, the winget ID list (tried in order; `{uilang}` = Windows display language), an optional `wingetSource`/`wingetArgs`, and the Chocolatey fallback ID plus `chocoParams`;
  - the install folder, the Start-menu shortcuts to delete, the log path and the minimum disk space.
  - `main.ps1` converts only the **top level** to hashtables (nested objects stay `PSCustomObject`; keys starting with `_` are skipped).
- **`src/lib/PSSetupUtility.psm1`**: `Write-Log`, `Initialize-Logging`, `Test-Prerequisite*`, `Sync-SystemTimeWithInternet`, `Get-SystemGPU`, `Get-BitlockerStatus`, `Invoke-NativeCommand`, `Invoke-SilentUninstall`, `Get-UninstallEntries`, `Get-LogIssues`, `Set-KeepAwake`, `Show-SetupResult` and the language functions. `debloat.ps1` runs in the same session, so these are available there too.
- **Result window**: `Show-SetupResult` loads `src/lib/SetupResult.xaml`, a WPF window with Success, Warning and Failed states. It replaces every MessageBox in the run.
  - The status color fills the band, the title bar (DWM caption color) and the taskbar button (`TaskbarItemInfo`), so the outcome reads from across the room.
  - `-Notes` shows steps left to the technician, with an info icon and no effect on the band color. Today that is the reminder to confirm default apps for the current account.
  - If the XAML fails to load, the function falls back to a MessageBox, because this window is the only result signal. The design contract is the comment at the top of the XAML.
- **Visual rules live in `DESIGN.md`** (tokens, the band anatomy, named rules, do's and don'ts). `PRODUCT.md` holds who uses the tool and why. Read both before touching any window.
- **One window system**: the menu (`src/PSScriptMenuGui/xaml/start.xaml`) and the result window share `src/lib/Theme.xaml`.
  - The theme holds the palette, type ramp, `Band`, `ActionButton`/`AccentButton`/`ProfileRow`, `ToggleSwitch`, `LanguageChip` and the focus rings.
  - Both windows have the same anatomy: 600 px wide, a colored band that also colors the title bar, a mark beside a 32 px headline, and Mica below. Change the look in `Theme.xaml`, not per window.
  - Each window XAML has a `<!--THEME-->` placeholder in `<Window.Resources>`. `Get-ThemedXaml` inserts the theme there as text before parsing, so `StaticResource` keeps working.
- **`src/lib/WindowTheme.ps1`**: `Get-ThemedXaml`, `Enable-WindowBackdrop` (Mica plus rounded corners, Win11 22H2+, with a solid background as fallback) and `Set-WindowCaptionColor`.
  - It is dot-sourced by both PSSetupUtility and PSScriptMenuGui, because the menu and `main.ps1` run in separate PowerShell processes.
  - Windows 11 is the target; Windows 10 only gets the built-in fallbacks.

### main.ps1 flow

The step numbers below match the `Write-Log "Step N"` messages in the code.

- **Start.** Load config, init logging, then pre-flight checks: admin, internet, NTP time sync, disk space, GPU detect, BitLocker status.
  - If config loading or pre-flight fails, the script shows the result window (Failed, "Setup didn't start") and exits. The console closes on exit, so that window is the only trace on screen.
  - `Set-KeepAwake -Enable` holds off sleep for the whole run, and the final `finally` releases it.
- **0. Antivirus trials.** `Remove-TrialAntivirus` detects third-party AV through `root/SecurityCenter2` and the uninstall registry (McAfee, Norton, Avast, AVG, Avira, Trend Micro, Bitdefender, Kaspersky, ESET, HP Wolf/Sure Sense/Sure Click).
  - It uninstalls through `Invoke-SilentUninstall`: `msiexec /x /qn` or `QuietUninstallString` only, with a timeout, never a wizard. HP Wolf is removed in order: product, then console, then update service.
  - The rest becomes a "manual removal" warning (`$script:ThirdPartyAvRemains`).
  - Then it records whether Chocolatey was already present, and `Initialize-Winget` registers App Installer if winget isn't usable yet (a documented first-logon delay).
- **2. Packages.** `Install-AppPackages` tries winget for each package first (`Install-WingetPackage`: up to 2 attempts, 20-min timeout, success verified with `winget list`; exit `0x8A150014` = ID not found, so try the next ID).
  - If winget fails, Chocolatey is the fallback, installed on demand. The old `Install-Packages` choco loop is kept for that: retry, kill timer, `Wait-MsiIdle`, and `--ignore-checksums` only for Chrome.
  - Firefox resolves to `Mozilla.Firefox.de`/`.it` by display language. Chrome and PowerToys use `--scope machine`. Adobe from winget keeps its auto-update; the Chocolatey fallback gets `/UpdateMode:3 /EnableUpdateService`.
- **3. GPU and updates.** Drivers for every GPU vendor come from Windows Update. Intel's control panel is installed by the Intel driver itself.
  - **3b.** Unless `-SkipUpdates`, `Install-WindowsUpdates` installs **every** update via the `Microsoft.Update.Session` COM API: drivers (`Type='Driver'`), plus all software updates (`Type='Software'`, which includes optional/`BrowseOnly`, preview, feature upgrades and Defender definitions).
    - Only updates that `CanRequestUserInput` are skipped.
    - Up to 3 passes, stopping when a reboot is required. A feature upgrade is staged and completes at the restart.
  - **3c.** On an NVIDIA GPU, the NVIDIA App installs from msstore `XP8CLZL93F5Z4P`, after 3b because it needs an installed driver.
- **4. Registry and system settings.** These `.reg` files are imported via `reg.exe import`: `Logo_Info.reg` (if branded), `icons.reg`, `user_settings.reg` and `machine_settings.reg`, plus the theme values.
  - `user_settings.reg` (HKCU) covers Windows suggestions/ads, silently installed suggested apps, SCOOBE, lock-screen tips, the Chat button, Bing in search, Recall/Click to Do, taskbar End task, and Windows Terminal as the default console host.
  - `machine_settings.reg` (HKLM) covers the Widgets policy, Recall/Click to Do, Edge ads/first-run, the Storage Sense policy (weekly; temp files; recycle bin 30 days; Downloads never), and Fast Startup off.
  - Values come from Win11Debloat's Regfiles and the local ADMX files. Both files are ASCII.
  - Then: Defender PUA blocking on; `Set-NotebookPower` (battery present only: on AC no sleep, display off after 30 min, lid = nothing); `Enable-WindowsSudo` (`sudo config --enable forceNewWindow`; explicit mode, because `--enable enable` means inline).
- **5. Shortcuts and desktop.** Shortcuts from `config.windows.shortcuts` are deleted.
  - `Clear-DesktopIcons` removes only `.lnk`/`.url` files that aren't in `whitelist.txt` (wildcards allowed), never recursively.
  - It cleans the Public Desktop, and the user's desktop **only while it is the local folder**. A OneDrive-redirected desktop holds the customer's synced files.
- **6. BitLocker.** Disabled on C: if encrypted. This is a deliberate Netixx decision.
- **7. Install folder and Helpdesk.** `C:\Install` is created and restricted (`Protect-InstallFolder`: Administrators/SYSTEM full, Users read/execute).
  - If branded, the **Netixx Helpdesk** is downloaded at runtime. A POST to `https://www.898.tv/api/CustomDesign` returns a signed Azure Blob URL.
  - The Helpdesk is linked on the Public Desktop only if its Authenticode signer is `CN=TeamViewer ...`. Otherwise it is deleted.
- **9. Office.** `Uninstall-Microsoft365` runs three silent passes: the Office Deployment Tool (`OfficeSetup.exe /configure office.xml`), then winget (locale variants), then registry uninstall strings (`msiexec /qn`, `OfficeClickToRun.exe ... DisplayLevel=False`).
  - A bare Click-to-Run `UninstallString` opens a blocking wizard, so it is never run.
- **10. Debloat.** `debloat.ps1` runs with `$ErrorActionPreference = 'Continue'`.
  - **UWP:** the live Win11Debloat `Config/Apps.json` (strip the UTF-8 BOM, or PS 5.1's `ConvertFrom-Json` fails) supplies only its **default** selection (`SelectedByDefault`, never `unsafe`). On top come `$oemAndExtras`: OEM promo apps, the Widgets packages, new Outlook/Mail/Whiteboard/People, and **Samsung's Galaxy ecosystem and promo apps** (Samsung Account included).
    - `$excluded` holds kept apps plus an **OEM keep-list** for BIOS/driver updates, Fn keys and battery care: HP Support Assistant/Power Manager/myHP, Lenovo Vantage, Dell SupportAssist/MyDell, Acer Quick Access, and Samsung Settings/Settings Runtime/Device Care/Update/Recovery and the ARM Settings app. Never remove these.
    - The offline fallback is the same default selection as of 2026-10-04.
    - Per-user removal and deprovisioning have separate try blocks.
  - **Win32 promo/trial software:** `Remove-Win32Bloat` matches the uninstall-registry `DisplayName` (language-independent) and uninstalls through `Invoke-SilentUninstall`. Kept on purpose: HP System Event Utility, HP Smart/myHP, Intel Optane tools. The old "office" winget name also matched OneDrive, so it is gone.
  - `disable_telemetry.reg`.
  - Then `Logo_Info.reg` is re-applied, because OEM services can reset `OEMInformation`. Branding is Manufacturer, SupportProvider, phone and URL; the Logo value is deprecated and no longer shown in Windows 11.
  - **10b.** Unless `-SkipUpdates`: `winget upgrade --all --source winget`, silently, with a 30-min timeout.
- **11. Future accounts, Start pins, wallpaper.** These steps cover accounts created later, typically the customer's own.
  - `Set-DefaultUserProfile` loads `C:\Users\Default\NTUSER.DAT` and imports `icons.reg`, `user_settings.reg` and `disable_telemetry.reg` with HKCU redirected, then sets the theme values. The unload happens in `finally`, after a GC run.
  - `Set-NewUserDefaultApps` writes the DISM default-associations XML from `assoc.txt`. It includes only ProgIds that exist, fixes VLC's `VLC.<ext>` ProgId and keeps `.url` with Windows. Windows applies it at each new profile's first logon.
    - SetUserFTA was removed: it can't change protected defaults on Home/Pro (UCPD, UserChoiceLatest), and its free edition is non-commercial.
    - The current account gets a note in the result window instead.
  - `Set-StartPins` writes `C:\Install\StartPins.json` (`applyOnce: true`, existing shortcuts only) and sets the "Configure Start Pins" policy (`HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer`: `ConfigureStartPins=1`, `ConfigureStartPinsJSON` = path, per Microsoft Learn). This needs 24H2 + KB5062660.
    - The pins: Chrome, Firefox, File Explorer, Settings, Store, Photos, Calculator, Notepad, Snipping Tool, LibreOffice Writer/Calc (consumer) and Netixx Helpdesk (via a Start-menu `.lnk`).
  - `Register-BingWallpaper` copies `BingWallpaper.ps1` to `C:\Install` and registers the task `\Netixx\Bing Wallpaper` for the Users group (at sign-in and daily at 06:00, hidden via `conhost --headless`), then runs it once for the current account.
    - The script takes the newest picture of the last 8 days that Bing allows as wallpaper (`wp` not false), at the largest size (`_UHD`, 3840x2160). The market is it-IT or de-DE, by display language.
- **12. Health checks.** `Test-SetupHealth` covers activation, Defender (signatures updated, `AMRunningMode` Normal plus real-time on) and a Business profile on a Home edition.
- **13. Cleanup.** `DISM /StartComponentCleanup` (unless `-SkipUpdates`; no `/ResetBase`), then `Remove-ChocolateyIfInstalledByUs`.
  - `Invoke-FinalCleanup` clears the Windows and user temp folders (never the running setup folder), the recycle bin and the Delivery Optimization cache.
  - `Register-SetupFolderCleanup` sets up a one-shot SYSTEM task that deletes `%TEMP%\NetixxSetup` at the next start. It applies only when running from the exe extract.
  - `New-SetupRestorePoint` turns on System Protection and creates a restore point.
- **Final.** The Explorer dance (see below), then `Test-PendingReboot`, then the result window. The result window must come last, because a modal window would hold back the layout step.
  - Warnings make it yellow and are listed (`Get-LogIssues`). A pending reboot adds "Restart required" and **Restart now**. Nothing restarts automatically.

Most steps catch their own errors and log a Warning so the run can continue. Only pre-flight failures and unexpected exceptions abort.

**Languages.** The UI is German by default, with English and Italian; the menu has DE/EN/IT chips in the band.
- Every user-visible string lives in `src/lang/<code>.json` (UTF-8) and is read with `Get-UiText <key> [args]` (`src/lib/Language.ps1`). A missing key falls back to English, then to the key itself. All three files must keep the same keys.
- For a Warning a technician may see, call `Write-Log "English text" -Level Warning -Key warn.<name> -KeyArgs ...`. The log gets English; the result window gets the translation.
- The failure window names the step via `$script:CurrentStep` (`step.<name>` keys); set it when adding a step.

**Log levels are user-facing.** Every `Warning`/`Error` line ends up in the end-of-run box.
- Use `Warning` only for an **outcome**, such as a package that failed through every source, or Office still installed.
- Intermediate states are logged at `Info`.
- debloat's per-app removals log at `Info`.

### Explorer / desktop layout (fragile; read before touching)

The desktop icon layout reg (`desktop_libreoffice.reg` if the profile's packages include `libreoffice`, else `desktop.reg`) must be written **while Explorer is dead**. Otherwise Explorer overwrites `IconLayouts` on shutdown. The sequence:
1. Blank `HKLM\...\Winlogon\Shell` so Windows won't auto-restart Explorer.
2. `Stop-ProcessWithTimeout explorer`.
3. Import the layout reg.
4. Restore `Shell` **in a `finally` block**. An empty Shell value would leave every user without a desktop at the next logon, so it must be restored whatever fails before it.
5. Start `explorer.exe` as the logged-in user via a scheduled task (`GKScript-StartExplorer`), also in the `finally`. An elevated Explorer is rejected as the shell.

## Stale / unused files

- `desktop.reg` / `desktop_libreoffice.reg` were captured on a dev machine and still position icons no code creates (e.g. "Dynamic Theme.lnk").
- The desktop-layout choice keys off the package list instead of a config field, which goes against the "config-driven" intent.

## Logging

`main.ps1` and the module have separate `$script:` scopes. `main.ps1` gets the log path from `Initialize-Logging`'s return value (`$script:LogFile = Initialize-Logging ...`).

Logs go to `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log` (from `config.logging.logPath`). In `main.ps1` and the module, use `Write-Log -Level Info|Success|Warning|Error`. It writes color-coded output to the console and a timestamped line to the file.

## Important Patterns

- **Fallback chains**: winget first, then Chocolatey; uninstalls only ever silent (`Invoke-SilentUninstall`). Never assume a single method works, and never run an interactive uninstaller.
- **User-context actions** (starting Explorer) run as `Win32_ComputerSystem.UserName` via a short-lived scheduled task; tasks for every account (Bing wallpaper) use the Users group SID. Never run them directly from the elevated session.
- **Accounts created later** (the customer's) only get what is written to the Default profile, the DISM associations, machine policies or all-users tasks - an HKCU-only change reaches the technician's account and nobody else.
- **Config-driven**: profile differences belong in `config.json`. Avoid hardcoding profile-specific values in scripts.
- **Verify, don't guess**: package IDs, registry values and Appx names come from live checks or documented sources (winget, Store catalog, local ADMX, Microsoft Learn, Win11Debloat Regfiles). Note the source in a comment.
- Target machines are German- or Italian-locale Windows. Match on IDs or patterns that don't depend on the display language; `reg.exe` errors come back localized.

## Encoding Pitfalls

These have caused real runtime bugs. Understand them before editing any source file.

### PowerShell 5.x script encoding
Deployed machines run Windows PowerShell 5.1, which reads `.ps1` files as **Windows-1252** unless they have a UTF-8 BOM. A UTF-8 em dash (U+2014) is the 3 bytes `E2 80 94`, and `0x94` maps to `"` in Windows-1252. That **closes a string literal early** and causes parse errors. The bug does not reproduce in VS Code or pwsh 7, which default to UTF-8.

**Rule**: never put em dashes or other non-ASCII characters inside string literals in `.ps1` files. They are harmless in comments. Use ASCII `-`. None of the `.ps1`/`.psm1` files has a BOM. When a string needs a non-ASCII character, build it from its code point, as `debloat.ps1` does: `"pr$([char]0xE4)sentationen"`.

### WPF XAML loaded from PowerShell
`XamlReader.Load` takes WPF XAML only. UWP/WinUI attributes such as `AutomationProperties.AccessibilityView` fail at load time. Template `Setter TargetName` must name an element, not a Freezable such as a `ScaleTransform`. Read `.xaml` files with `-Encoding UTF8`, and keep them ASCII (use `&#xE7BA;`-style entities). Check a change by actually loading the window, because a parse error otherwise only shows up on a technician's machine.

### WinForms is not loaded by default
In Windows PowerShell 5.1, `[System.Windows.Forms.MessageBox]` throws "type not found" unless the assembly is loaded. PSSetupUtility runs `Add-Type -AssemblyName System.Windows.Forms` at import. Any script that shows a MessageBox without importing the module must load the assembly itself.

### .reg file encoding
`reg.exe import` accepts only **UTF-16 LE BOM** (`FF FE`) or **ANSI** `.reg` files. It rejects UTF-8 BOM files with `FEHLER: Die angegebene Datei ist keine Registrierungsdatei`. To convert:

```powershell
$content = Get-Content .\src\file.reg -Raw -Encoding UTF8
[System.IO.File]::WriteAllText("$PWD\src\file.reg", $content, [System.Text.Encoding]::Unicode)
```

### $ErrorActionPreference = 'Stop' and native commands
`main.ps1` sets `$ErrorActionPreference = 'Stop'` globally. When a native exe (e.g. `reg.exe`, `taskkill`, `choco`, `winget`) writes to stderr, `2>&1 | Out-Null` is **not** enough: the merged ErrorRecord can throw before it reaches `Out-Null`. Use `Invoke-NativeCommand` from PSSetupUtility. It returns the merged output as strings, never throws on stderr, and leaves `$LASTEXITCODE` set:

```powershell
$out = Invoke-NativeCommand choco @('list', '--local-only', '--exact', $package, '--limit-output')
```

Or wrap the call in `try/catch`:

```powershell
try {
    $null = & "$env:SystemRoot\System32\reg.exe" import "$regFile" 2>&1
} catch {
    Write-Log "Warning: $_" -Level Warning
}
```

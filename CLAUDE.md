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

- **`src/gui.csv`** is the only input to the vendored `PSScriptMenuGui` module. Each row is one button: `Section, Method (powershell_inline), Command, Arguments, Name, Description, Icon, NameKey`. `{lang}` in `Command` is replaced with the menu's current language when the row is launched. `NameKey` points to a translated name in `src/lang` (it falls back to `Name`). `Icon` is an optional Segoe Fluent Icons code point in hex (e.g. `E821`, a briefcase), drawn beside the name. Keep emoji out of `Name`, because screen readers announce them. To add or rename a profile button, edit this file. Profile names must also match `ValidateSet` in `main.ps1` and a key under `deployment` in `config.json`.
- **`src/config.json`** defines the profiles (`packages` = Chocolatey IDs, `branded` flag), the install folder, the start-menu shortcuts to delete, the log path and the minimum disk space. `main.ps1` converts only the **top level** of the config to hashtables. Nested objects like `deployment.<profile>` stay `PSCustomObject`.
- **`src/lib/PSSetupUtility.psm1`**: `Write-Log`, `Initialize-Logging`, `Test-Prerequisite*`, `Sync-SystemTimeWithInternet`, `Get-SystemGPU`, `Get-BitlockerStatus`, `Invoke-SafeProcess`, `Invoke-NativeCommand`, `Get-LogIssues`, `Set-KeepAwake`, `Show-SetupResult`. `debloat.ps1` runs in the same session, so these are available there too, although it currently logs with `Write-Output`.
- **Result window**: `Show-SetupResult` loads `src/lib/SetupResult.xaml`, a WPF window with Success, Warning and Failed states. It replaces every MessageBox in the run. The status color fills the band, the title bar (DWM caption color) and the taskbar button (`TaskbarItemInfo`), so the outcome reads from across the room. If the XAML fails to load, the function falls back to a MessageBox, because this window is the only result signal. The design contract is the comment at the top of the XAML.
- **Visual rules live in `DESIGN.md`** (tokens, the band anatomy, named rules, do's and don'ts). `PRODUCT.md` holds who uses the tool and why. Read both before touching any window.
- **One window system**: the menu (`src/PSScriptMenuGui/xaml/start.xaml`) and the result window share `src/lib/Theme.xaml`, which holds the palette, type ramp, the `Band` style, `ActionButton`/`AccentButton`/`ProfileRow` and the focus ring. Both have the same anatomy: 600 px wide, a colored band that also colors the title bar, a mark beside a 32 px headline, and Mica below. Change the look in `Theme.xaml`, not per window. Each window XAML has a `<!--THEME-->` placeholder in `<Window.Resources>`, and `Get-ThemedXaml` inserts the theme there as text before parsing, so `StaticResource` keeps working.
- **`src/lib/WindowTheme.ps1`**: `Get-ThemedXaml`, `Enable-WindowBackdrop` (Mica plus rounded corners, Win11 22H2+, with a solid background as fallback) and `Set-WindowCaptionColor`. It is dot-sourced by both PSSetupUtility and PSScriptMenuGui, because the menu and `main.ps1` run in separate PowerShell processes. Windows 11 is the target; Windows 10 only gets the built-in fallbacks.

### main.ps1 flow

The step numbers below match the `Write-Log "Step N"` messages in the code. There is no Step 8.

0. Load config → init logging → pre-flight (admin, internet, NTP time sync, disk space, GPU detect, BitLocker status). If config loading or pre-flight fails, the script shows the result window (Failed, "Setup didn't start") and exits. The console closes on exit (no `-NoExit`), so that window is the only trace on screen. `Test-PrerequisiteAdmin` and `Test-PrerequisiteInternet` throw, and do not show UI themselves. `Set-KeepAwake -Enable` holds off display and system sleep for the whole run, and the final `finally` block releases it.
1. Install Chocolatey (downloads `install.ps1` to `%TEMP%` and runs it; no `iex` piping).
2. `choco install` each profile package: up to 3 attempts, then verify via `choco list --local-only`. Exit codes 0/1641/3010 count as success. An installer still running 5 min after its download finishes is killed (`taskkill /T`). A killed attempt only counts if choco tracking confirms it, and the script waits for the `Global\_MSIExecute` mutex (`Wait-MsiIdle`) before continuing. `googlechrome` gets `--ignore-checksums` and has a winget fallback. The registry pre-check (`Test-PackageInstalledInRegistry`) matches `DisplayName` by **prefix**, using `$script:PackageDisplayNames`.
3. GPU driver: NVIDIA → choco `nvidia-app`; AMD → nothing here (no AMD driver package exists in winget, Chocolatey or the Store); Intel → winget `Intel.GraphicsCommand` (choco's Intel package hits CDN 403s).
   - **3b.** `Install-WindowsUpdateDrivers` runs on **every** machine. It installs all pending drivers from Windows Update via the built-in `Microsoft.Update.Session` COM API, which is also how AMD GPUs get their driver. Updates that `CanRequestUserInput` are skipped. A required reboot sets `$script:RebootRequired`, and the final box mentions it.
4. Registry: `Logo_Info.reg` (if branded) + `icons.reg` via `reg.exe import`, plus direct theme values.
5. Delete shortcuts from `config.windows.shortcuts`. Remove desktop items not in `whitelist.txt`.
6. Disable BitLocker on C: if it's encrypted.
7. Create `C:\Install`. If branded: copy `oemlogo.bmp` to System32 and **download Netixx Helpdesk at runtime**. A POST to `https://www.898.tv/api/CustomDesign` returns a time-limited signed Azure Blob URL (a bare string), which is fetched with `WebClient.DownloadFile`. The exe is only symlinked to the Public Desktop if its Authenticode signature is valid and the signer is `CN=TeamViewer ...` (currently TeamViewer Germany GmbH). Otherwise it is deleted. The exe is not bundled.
9. `Uninstall-Microsoft365` has three passes, each skipped once Office is gone:
   1. Office Deployment Tool: `OfficeSetup.exe /configure office.xml`, which is silent and removes all Click-to-Run and MSI Office.
   2. winget, which finds locale variants via `winget list --name "Microsoft 365 - "`.
   3. Registry uninstall strings, run **silently only**: `msiexec /x /quiet`, and `OfficeClickToRun.exe ... DisplayLevel=False`.

   A bare Click-to-Run `UninstallString` opens an interactive wizard that blocks the unattended run. Office counts as present if ClickToRun `ProductReleaseIds` is set or an uninstall entry starts with `Microsoft 365`/`Microsoft Office`.
10. `debloat.ps1` runs with `$ErrorActionPreference = 'Continue'`, and each app is removed in its own try/catch. It does:
    - UWP removal: fetches Win11Debloat's live `Config/Apps.json`, skips entries upstream marks `"Recommendation": "unsafe"`, merges OEM extras, and falls back to a built-in list when offline. `$excluded` filters both lists.
    - winget uninstall of a German-named adware list.
    - `disable_telemetry.reg`.
    - Chrome web-app removal via `AutoHotkey32.exe chrome.ahk`.
    Then `Logo_Info.reg` is re-applied, because OEM services (Lenovo/HP/Dell) can reset `OEMInformation`.
11. File associations: `SetUserFTA.exe assoc.txt` runs as the **logged-in user** via a temporary scheduled task (`GKScript-SetFileAssoc`). Running it elevated would set them for the admin context. The exe and the list are first copied to `C:\Install`, because the script folder sits in the elevated account's `%TEMP%`. Completion is detected via `Get-ScheduledTaskInfo` (`LastTaskResult` 0x41303 means not run yet, 0x41301 means running), and a non-zero result is logged as a warning. The task runs at `-Priority 4`. The default priority of 7 is below normal, and child processes inherit it.
- Final: the Explorer dance (see below), then the result window. It must come last, because a modal window would hold back the layout step until someone clicks it. If anything was logged at Warning/Error level, the window shows the yellow "Finished with N warnings" state and lists them (`Get-LogIssues`). Otherwise it shows green "Setup complete". A pending driver reboot adds "Restart required" and a **Restart now** button. Nothing restarts automatically.

Most steps catch their own errors and log a Warning so the run can continue. Only pre-flight, Chocolatey and package failures abort.

**Languages.** The UI is German by default, with English and Italian available; the menu has DE/EN/IT chips in the band. Every user-visible string lives in `src/lang/<code>.json` (UTF-8, so umlauts never enter a `.ps1`), and is read with `Get-UiText <key> [args]` from `src/lib/Language.ps1`. A missing key falls back to English, then to the key itself. All three files must keep the same keys. For any Warning/Error a technician may see, call `Write-Log "English text" -Level Warning -Key warn.<name> -KeyArgs ...`: the log gets the English message, and the result window gets the translation. The failure window names the step that stopped via `$script:CurrentStep` (`step.<name>` keys); set it when adding a step.

**Log levels are user-facing.** Every `Warning`/`Error` line ends up in the end-of-run box the technician sees. Use `Warning` only for an **outcome** (e.g. a package failed after all retries, or Office is still installed). Intermediate states such as "attempt 1 not confirmed", "falling back to winget" or "ODT failed, trying winget" are logged at `Info`. Messages from `debloat.ps1` (`Write-Output`) are not collected.

### Explorer / desktop layout (fragile; read before touching)

The desktop icon layout reg (`desktop_libreoffice.reg` if the profile's packages include `libreoffice`, else `desktop.reg`) must be written **while Explorer is dead**. Otherwise Explorer overwrites `IconLayouts` on shutdown. The sequence:
1. Blank `HKLM\...\Winlogon\Shell` so Windows won't auto-restart Explorer.
2. `Stop-ProcessWithTimeout explorer`.
3. Import the layout reg.
4. Restore `Shell`.
5. Start `explorer.exe` as the logged-in user via a scheduled task (`GKScript-StartExplorer`). An elevated Explorer is rejected as the shell.

## Stale / unused files

- `config.json` → `paths.helpDeskExe`, `paths.logoPath` and `paths.startMenuPath` are not read. The Helpdesk exe no longer exists in the repo.
- The desktop-layout choice keys off the package list instead of a config field, which goes against the "config-driven" intent.

## Logging

`main.ps1` and the module have separate `$script:` scopes. `main.ps1` gets the log path from `Initialize-Logging`'s return value (`$script:LogFile = Initialize-Logging ...`).

Logs go to `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log` (from `config.logging.logPath`). In `main.ps1` and the module, use `Write-Log -Level Info|Success|Warning|Error`. It writes color-coded output to the console and a timestamped line to the file.

## Important Patterns

- **Fallback chains**: winget first, then Chocolatey or a registry `UninstallString`. Never assume a single method works.
- **User-context actions** (file associations, starting Explorer) run as `Win32_ComputerSystem.UserName` via a short-lived scheduled task. Never run them directly from the elevated session.
- **Config-driven**: profile differences belong in `config.json`. Avoid hardcoding profile-specific values in scripts.
- Target machines are German-locale Windows. Uninstall names in `debloat.ps1` are display names in German (e.g. `"Microsoft-Tipps"`, `"tabellen"`), and `reg.exe` errors come back in German.

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

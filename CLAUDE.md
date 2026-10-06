# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**gk-script** ("Netixx Grundkonfiguration") is a Windows 11 deployment tool for Netixx IT Solutions. It automates first-time PC setup: package installation, GPU drivers, Office 365 removal, OEM branding, registry customization and bloat removal, across three deployment profiles. It ships as a single NSIS-built `.exe` that opens a WPF button menu.

License: MIT (`LICENSE`, Netixx GmbH / Srl); the Netixx brand assets are excluded (README). Code taken from other projects needs its notice in `src/THIRD-PARTY-NOTICES.txt` - that file ships inside the exe.

`tests/sandbox/Start-SandboxTest.ps1 -DeploymentType business [-InstallOnly] [-WithUpdates]` runs a profile end to end in Windows Sandbox (fresh Windows each time; repo mapped read-only; logs, the report and a desktop screenshot every 20 s land in an output folder on the host). It starts `main.ps1` from a 32-bit PowerShell like the exe. The sandbox has no Store/App Installer (winget unusable - the Chocolatey path runs), no Windows Update, no restarts, no BitLocker or OEM hardware, the host's edition, and de-DE without some PowerShell module resources. Only one sandbox runs at a time; `wsb list` / `wsb stop --id` (Store version) manage it.

`tests/Test-Repository.ps1` runs the static checks that caught real bugs: every script parses in Windows PowerShell 5.1, no non-ASCII inside strings, no BOM, XAML well-formed, the three language files have the same keys and every key the code uses exists, config/gui.csv consistent, .reg files UTF-16 LE or ASCII. GitHub Actions (`.github/workflows/ci.yml`) runs it on every push in Windows PowerShell 5.1 and builds a test exe (artifact). Behaviour itself can only be verified by running on a real or VM Windows machine as admin, then checking the log.

## Build

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

Optional: `-OutputFile <path>` (default `gk-script.exe` in repo root), `-MakensisPath <path>`. `makensis.exe` is auto-detected in `Program Files (x86)\NSIS`, `Program Files\NSIS` or PATH.

`gk-script.nsi` is the whole packaging step. It bundles `launch.bat` + all of `src/`, requests admin, sets the icon from `src/netixx.ico`, extracts to `%TEMP%\NetixxSetup` (wiping it first) and runs `launch.bat`. Nothing under `tools/` is used by the build (`tools/` is gitignored).

`gk-script.exe` appears in `.gitignore`, but it is tracked anyway, and releases commit the rebuilt exe. The version string lives in `src/version.txt` and is logged at startup.

A release is one command, once README has a `### Unreleased` section with the changes:

```powershell
powershell -ExecutionPolicy Bypass -File release.ps1 -Version 2.2.0 -Summary "short description"
```

`release.ps1` sets `src/version.txt`, dates the changelog entry (`### vX.Y.Z — YYYY-MM-DD`) and the version shown in DESIGN.md / `.impeccable/design.json`, runs the checks, renders the screenshots in `docs/screenshots` (so they show the new version) and the build (stops on failure), commits everything including `gk-script.exe`, pushes `master`, and publishes the GitHub Release with the changelog entry and the exe (full commit SHA as target - `gh` rejects a short one). `-NoPublish` stops after the local commit. It refuses untracked files and an existing tag.

The repo is public. `https://github.com/gkscript/script/releases/latest/download/gk-script.exe` always serves the newest exe.

## Running

From the repository root (admin required):

```powershell
launch.bat   # UAC self-elevation via VBS, then Show-ScriptMenuGui -csvpath .\src\gui.csv

powershell -ExecutionPolicy Bypass -File src\office.ps1 [-Product m365business|homebusiness2024|home2024|m365home] [-Language de|en|it]
    # Office on its own (menu item "Microsoft Office installieren"); without -Product it asks

powershell -ExecutionPolicy Bypass -File src\main.ps1 -DeploymentType business|consumer|consumer-nolo
    [-SkipUpdates]            # no Windows Update, no app updates (menu: "install all updates" off)
    [-InstallOnly]            # PC already in use: install and configure, remove nothing (menu: "install only")
    [-SkipBloatwareRemoval]   # skips Step 5 (shortcut cleanup + desktop whitelist) only; debloat.ps1 still runs
    [-ConfigPath <path>]      # alternate config.json
    [-Language de|en|it]      # UI language of the result window (default de); the log stays English
```


## Architecture

```
gk-script.exe (NSIS) → launch.bat → PSScriptMenuGui (reads src/gui.csv) → src/main.ps1 -DeploymentType X
                                                                             ├─ src/lib/PSSetupUtility.psm1
                                                                             └─ src/debloat.ps1 (dot-invoked, same session)
```

- **`src/gui.csv`** is the only input to the vendored `PSScriptMenuGui` module. Each row is one button: `Section, Method (powershell_inline), Command, Arguments, Name, Description, Icon, NameKey`.
  - When a row is launched, `{lang}` in `Command` becomes the menu's current language, `{updates}` becomes `-SkipUpdates` while the menu's updates switch is off, and `{mode}` becomes `-InstallOnly` while the install-only switch is on. Each switch's `Tag` names the menu state key it sets.
  - `NameKey` points to a translated name in `src/lang` (it falls back to `Name`). `Icon` is an optional Segoe Fluent Icons code point in hex (e.g. `E821`). Keep emoji out of `Name`, because screen readers announce them.
  - Profile names must also match `ValidateSet` in `main.ps1` and a key under `deployment` in `config.json`.
- **`src/config.json`** defines:
  - the profiles: `packages` are catalog keys, plus the `branded` flag;
  - `packageCatalog`: per key, the winget ID list (tried in order; `{uilang}` = Windows display language), an optional `wingetSource`/`wingetArgs`, and the Chocolatey fallback ID plus `chocoParams`;
  - the install folder, the Start-menu shortcuts to delete, the log path and the minimum disk space.
  - `main.ps1` converts only the **top level** to hashtables (nested objects stay `PSCustomObject`; keys starting with `_` are skipped).
- **`src/office.ps1`** installs one Office product, separately from the profiles. Microsoft: "If you use the wrong product ID, you can't activate Office", so the technician picks the product matching the customer's licence in a question window (rows from `config.office.products`).
  - `O365BusinessRetail` covers Apps for Business, Business Standard and Business Premium; `HomeBusiness2024Retail` and `Home2024Retail` are the 2024 one-time purchases; `O365HomePremRetail` is Family/Personal.
  - It downloads the current ODT `setup.exe` from `config.office.setupUrl` (Microsoft signature checked; nothing is bundled - the run needs internet anyway, and the Office files always come from the CDN). Any other Office suite is removed first (`Uninstall-Microsoft365`); the same product is just updated.
  - `New-OfficeConfiguration` writes the XML: 64-bit, Current Channel, `MatchOS` language, proofing tools for the other `proofingLanguages`, `excludeApps` (+ OneDrive for products with `oneDrive: false`), classic and new Outlook, RemoveMSI, silent. Success = the product is in `ProductReleaseIds` and `WINWORD.EXE` exists. It logs to `office_*.log`, which the used-PC check ignores.
- **`src/lib/Office.ps1`** (dot-sourced by the module): `Get-OfficeProductIds`, `Get-OfficeSetup`, `New-OfficeConfiguration`, `Uninstall-Microsoft365` (shared with `main.ps1` Step 9).
- **`src/lib/PSSetupUtility.psm1`**: `Write-Log`, `Initialize-Logging` (`-Name` = log prefix), `Restart-In64BitPowerShell`, `Test-Prerequisite*`, `Sync-SystemTimeWithInternet`, `Get-SystemGPU`, `Get-BitlockerStatus`, `Invoke-NativeCommand`, `Invoke-SilentUninstall`, `Get-UninstallEntries`, `Get-LogIssues`, `Set-KeepAwake`, `Show-SetupResult` and the language functions. `debloat.ps1` runs in the same session, so these are available there too.
- **`src/steps/*.ps1`** hold `main.ps1`'s step functions (Packages, Updates, Antivirus, Settings, Desktop, Checks, Cleanup, Report). `main.ps1` dot-sources them into its own scope - they are not a module - so they read `$script:config`, `$SkipUpdates`, `$InstallOnly` and the other run state directly. `main.ps1` itself is only parameters, start-up, pre-flight and the step sequence.
- **`src/postupdate.ps1`**: the update follow-up after the end-of-run restart (see Final).
- **Menu update hint**: the menu asks `config.release.latestApi` (GitHub's latest release) in a background runspace and, if it is newer than `version.txt`, shows a link to `config.release.downloadUrl` under the subline.
- **Result window**: `Show-SetupResult` loads `src/lib/SetupResult.xaml`, a WPF window with Success, Warning and Failed states. It replaces every MessageBox in the run. `-ReportFile` adds an "Open report" button.
  - The status color fills the band, the title bar (DWM caption color) and the taskbar button (`TaskbarItemInfo`), so the outcome reads from across the room.
  - `-Notes` shows steps left to the technician, with an info icon and no effect on the band color. Today that is the reminder to confirm default apps for the current account.
  - `-Choices` turns the window into a question: the given buttons replace Open log / Restart / Close, and the clicked choice's `Key` is returned (the MessageBox fallback maps them to Yes/No/Cancel). `-Heading` replaces the heading above the items. Used for the used-PC question. Choices with a `Description` render as menu-style rows (title, caption, chevron) instead of buttons; `-Status Question` gives the menu's Netixx-blue band (office.ps1's product choice).
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

**Two modes.** The full setup is for a new PC. `-InstallOnly` is for a PC already in use: it installs and configures, and removes or turns off nothing.
- Install only skips: antivirus removal (0), notebook power and the current account's theme colors (4), the whitelist cleanup (5: only shortcuts the installers just added and that aren't whitelisted are removed, via a snapshot before Step 2), BitLocker (6), Office removal, debloat, OneDrive removal and the branding re-apply (9-10), Start pins and the default-apps note (11), emptying the recycle bin (13) and the Explorer restart.
- It keeps everything else, including all Netixx settings, `disable_telemetry.reg` (imported in Step 4 because debloat doesn't run), all updates, branding and the Helpdesk. The restore point is created first instead of last.
- Before Step 0, a full run checks for signs of use (`Get-UsedPcSigns`): a log from an earlier run, 10+ personal files in an account's Desktop/Documents/Pictures/Videos/Music/OneDrive folders, or Windows installed more than 30 days ago. If any is found, the result window asks: install only (recommended), full setup anyway, or cancel (exits without changes).

The step numbers below match the `Write-Log "Step N"` messages in the code.

- **Start.** Load config, init logging, then pre-flight checks: admin, internet, NTP time sync, disk space, GPU detect, BitLocker status.
  - If config loading or pre-flight fails, the script shows the result window (Failed, "Setup didn't start") and exits. The console closes on exit, so that window is the only trace on screen.
  - `Set-KeepAwake -Enable` holds off sleep for the whole run, and the final `finally` releases it.
- **0. Antivirus trials.** `Remove-TrialAntivirus` detects third-party AV through `root/SecurityCenter2` and the uninstall registry (McAfee, Norton, Avast, AVG, Avira, Trend Micro, Bitdefender, Kaspersky, ESET, HP Wolf/Sure Sense/Sure Click).
  - It uninstalls through `Invoke-SilentUninstall`: `msiexec /x /qn` or `QuietUninstallString` only, with a timeout, never a wizard. HP Wolf is removed in order: product, then console, then update service.
  - The rest becomes a "manual removal" warning (`$script:ThirdPartyAvRemains`).
  - Then it records whether Chocolatey was already present, and `Initialize-Winget` registers App Installer if winget isn't usable yet (a documented first-logon delay).
- **2. Packages.** `Install-AppPackages` tries winget for each package first (`Install-WingetPackage`: up to 2 attempts, 20-min timeout, success verified with `winget list`; exit `0x8A150014` = ID not found, so try the next ID). An already installed package is updated (`winget upgrade`), unless `-SkipUpdates`. A catalog entry without `choco` (Store-only apps) has no Chocolatey fallback.
  - The consumer profiles include the free **new Outlook** (msstore `9NRX63209R7B`, preinstalled on Windows 11 and updated here). Its catalog `appx` name is passed to `debloat.ps1 -KeepApps`, so debloat doesn't remove it; the business profile still removes it.
  - If winget fails, Chocolatey is the fallback, installed on demand. `Install-Chocolatey` and `Install-ChocolateyPackages` do that: retry, kill timer, `Wait-MsiIdle`, and `--ignore-checksums` only for Chrome.
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
- **5. Shortcuts and desktop.** Shortcuts from `config.windows.shortcuts` are deleted. First `Add-DesktopShortcuts` copies the profile's `desktopShortcuts` from the Start menu to the Public Desktop (consumer: LibreOffice Writer, Calc, Impress - its installer only adds a Start Center icon, which the whitelist drops). Chrome and Firefox stay on the desktop and are also pinned to the taskbar (Step 11).
  - `Clear-DesktopIcons` removes only `.lnk`/`.url` files that aren't in `whitelist.txt` (wildcards allowed), never recursively.
  - It cleans the Public Desktop, and the user's desktop **only while it is the local folder**. A OneDrive-redirected desktop holds the customer's synced files.
- **6. BitLocker.** Disabled on C: if encrypted. This is a deliberate Netixx decision. The full run also sets `HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption=1` (Microsoft Learn, BitLocker for OEMs), because Windows 11 24H2+ turns device encryption on by itself on more PCs, e.g. once a Microsoft account signs in; turning BitLocker on by hand stays possible. Install only touches neither.
- **7. Install folder and Helpdesk.** `C:\Install` is created and restricted (`Protect-InstallFolder`: Administrators/SYSTEM full, Users read/execute).
  - If branded, the **Netixx Helpdesk** is downloaded at runtime. A POST to `https://www.898.tv/api/CustomDesign` returns a signed Azure Blob URL.
  - The Helpdesk is linked on the Public Desktop only if its Authenticode signer is `CN=TeamViewer ...`. Otherwise it is deleted.
- **9. Office.** `Uninstall-Microsoft365` runs three silent passes: the Office Deployment Tool (the current `setup.exe` from `config.office.setupUrl`, downloaded only when Office is found, `/configure office.xml`), then winget (locale variants), then registry uninstall strings (`msiexec /qn`, `OfficeClickToRun.exe ... DisplayLevel=False`).
  - A bare Click-to-Run `UninstallString` opens a blocking wizard, so it is never run.
- **10. Debloat.** `debloat.ps1` runs with `$ErrorActionPreference = 'Continue'`.
  - **UWP:** the live Win11Debloat `Config/Apps.json` (strip the UTF-8 BOM, or PS 5.1's `ConvertFrom-Json` fails) supplies only its **default** selection (`SelectedByDefault`, never `unsafe`). On top come `$oemAndExtras`: OEM promo apps, the Widgets packages, new Outlook/Mail/Whiteboard/People, and **Samsung's Galaxy ecosystem and promo apps** (Samsung Account included).
    - `$excluded` holds kept apps plus an **OEM keep-list** for BIOS/driver updates, Fn keys and battery care: HP Support Assistant/Power Manager/myHP, Lenovo Vantage, Dell SupportAssist/MyDell, Acer Quick Access, and Samsung Settings/Settings Runtime/Device Care/Update/Recovery and the ARM Settings app. Never remove these.
    - The offline fallback is the same default selection as of 2026-10-04.
    - Per-user removal and deprovisioning have separate try blocks.
  - **Win32 promo/trial software:** `Remove-Win32Bloat` matches the uninstall-registry `DisplayName` (language-independent) and uninstalls through `Invoke-SilentUninstall`. Kept on purpose: HP System Event Utility, HP Smart/myHP, Intel Optane tools. The old "office" winget name also matched OneDrive, so it is gone.
  - **OneDrive** is uninstalled on every profile (`Remove-OneDrive`: `OneDriveSetup.exe /uninstall [/allusers]`, silent by design, hence `Invoke-SilentUninstall -UninstallStringIsSilent`). The Run value `OneDriveSetup` installs OneDrive at an account's first sign-in; the full run imports `onedrive_setup_off.reg` into the Default profile (Step 11) to delete it, so accounts created later don't get OneDrive back. Install only keeps OneDrive and that value.
  - `disable_telemetry.reg`.
  - Then `Logo_Info.reg` is re-applied, because OEM services can reset `OEMInformation`. Branding is Manufacturer, SupportProvider, phone and URL; the Logo value is deprecated and no longer shown in Windows 11.
  - **10b.** Unless `-SkipUpdates`: `winget upgrade --all --source winget`, silently, with a 30-min timeout.
- **11. Future accounts, Start pins, wallpaper.** These steps cover accounts created later, typically the customer's own.
  - `Set-DefaultUserProfile` loads `C:\Users\Default\NTUSER.DAT` and imports `icons.reg`, `user_settings.reg` and `disable_telemetry.reg` with HKCU redirected, then sets the theme values. The unload happens in `finally`, after a GC run.
  - `Set-NewUserDefaultApps` writes the DISM default-associations XML from `assoc.txt`. It includes only ProgIds that exist, fixes VLC's `VLC.<ext>` ProgId and keeps `.url` with Windows. Windows applies it at each new profile's first logon.
    - SetUserFTA was removed: it can't change protected defaults on Home/Pro (UCPD, UserChoiceLatest), and its free edition is non-commercial.
    - The current account gets a note in the result window instead.
  - `Set-StartPins` writes `C:\Install\StartPins.json` (`applyOnce: true`, existing shortcuts only) and sets the "Configure Start Pins" policy (`HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer`: `ConfigureStartPins=1`, `ConfigureStartPinsJSON` = path, per Microsoft Learn). This needs 24H2 + KB5062660.
  - `Set-TaskbarPins` (both modes) writes `C:\Install\TaskbarLayout.xml` and sets the "Start Layout" policy (`LockedStartLayout=1`, `StartLayoutFile` = path; Microsoft Learn taskbar/pinned-apps, local StartMenu.admx). No `PinListPlacement="Replace"`, so Edge, Store and File Explorer stay and Chrome/Firefox follow; `PinGeneration="1"` applies each pin once, so one the user removes stays removed. Current and later accounts get it at their next sign-in. The XML must keep existing and must not contain comments.
    - The pins: Chrome, Firefox, File Explorer, Settings, Store, Photos, Calculator, Notepad, Snipping Tool, LibreOffice Writer/Calc (consumer) and Netixx Helpdesk (via a Start-menu `.lnk`).
  - `Register-BingWallpaper` copies `BingWallpaper.ps1` to `C:\Install` and registers the task `\Netixx\Bing Wallpaper` for the Users group (at sign-in and daily at 06:00, hidden via `conhost --headless`), then runs it once for the current account.
    - The script takes the newest picture of the last 8 days that Bing allows as wallpaper (`wp` not false), at the largest size (`_UHD`, 3840x2160). The market is it-IT or de-DE, by display language.
    - It only replaces the Windows/OEM default (under `%SystemRoot%` or `%ProgramData%`), Spotlight or an earlier Bing picture. A picture of the user's own, a slideshow or a solid color stays (`Test-WallpaperReplaceable`).
- **12. Health checks.** `Test-SetupHealth` covers activation, Defender (signatures updated, `AMRunningMode` Normal plus real-time on) and a Business profile on a Home edition.
- **13. Cleanup.** `DISM /StartComponentCleanup` (unless `-SkipUpdates`; no `/ResetBase`), then `Remove-ChocolateyIfInstalledByUs`.
  - `Invoke-FinalCleanup` clears the Windows and user temp folders (never the running setup folder), the recycle bin and the Delivery Optimization cache.
  - `Register-SetupFolderCleanup` sets up a one-shot SYSTEM task that deletes `%TEMP%\NetixxSetup` at the next start. It applies only when running from the exe extract.
  - `New-SetupRestorePoint` turns on System Protection and creates a restore point.
- **Final.** `Restart-Explorer` (see below), then `Test-PendingReboot`, then:
  - **BIOS/firmware from the maker's tool** (profiles with `"oemFirmware": true`, default: business; full run with updates): `Invoke-OemFirmwareUpdate` (`steps/Firmware.ps1`) runs Dell Command Update (`dcu-cli /applyUpdates -silent -reboot=disable -updateType=bios,firmware,driver -autoSuspendBitLocker=disable`) or HP Image Assistant (`/Operation:Analyze /Action:Install /Category:BIOS,Drivers,Firmware /Selection:All /Silent`) and removes the tool again. Only Dell and HP business models have a supported silent CLI; consumer lines and other makers get firmware from Windows Update (Step 3b installs UEFI capsules as driver updates). It runs in the update follow-up, where BitLocker is off and no restart is pending (both make the tools skip the BIOS or refuse); without a pending restart, right away. On battery the BIOS category is dropped (a flash needs mains power). Exit codes from Dell's DCU reference and HP's HPIA guide; "model not supported" (Dell 7, HP 4096) is informational.
  - **Update follow-up** (updates on and a restart pending): `Register-UpdateFollowUp` copies `postupdate.ps1` with `lib/`, `lang/` and the Updates/Packages/Report step files to `C:\Install\gk-script` (the `%TEMP%` setup folder is deleted at the next start) and registers `\Netixx\Update-Nachlauf`: at this account's next sign-in, one minute delay, elevated, visible; it expires after 7 days and deletes itself. It refuses a signed-in account that isn't an administrator (RunLevel Highest would give it a standard token). `postupdate.ps1` waits up to 5 minutes for the network (Wi-Fi connects after sign-in) and `Install-WindowsUpdates` retries for up to 15 minutes while Windows Update is busy or offline (0x80240009, 0x80240016, 0x80242014, 0x8024402C, 0x8024001F, 0x80246005). `postupdate.ps1` removes its task first, installs the updates that only appear after the restart, updates apps, appends to the report and shows the result window; if that restart brings more updates it registers the next pass (at most 3), and the last pass deletes its copy. Logs `update_*.log`.
  - **Handover report** `C:\Install\<report.title>.html` (`New-SetupReport`): device and serial number, Windows and activation, profile/mode/duration/technician, apps with their installed versions, installed updates, warnings, notes. It uses what the run collected (`$script:Health`, `$script:InstalledUpdates`).
  - The result window comes last, because a modal window would hold back the Explorer restart.
  - Warnings make it yellow and are listed (`Get-LogIssues`). A pending reboot adds "Restart required" and **Restart now**. Nothing restarts automatically.

Most steps catch their own errors and log a Warning so the run can continue. Only pre-flight failures and unexpected exceptions abort.

**Languages.** The UI is German by default, with English and Italian; the menu has DE/EN/IT chips in the band.
- Every user-visible string lives in `src/lang/<code>.json` (UTF-8) and is read with `Get-UiText <key> [args]` (`src/lib/Language.ps1`). A missing key falls back to English, then to the key itself. All three files must keep the same keys. Exception: the menu footer tagline "Created for the people by www.netixx.it" is never translated, so it sits in `start.xaml`, not in the language files.
- For a Warning a technician may see, call `Write-Log "English text" -Level Warning -Key warn.<name> -KeyArgs ...`. The log gets English; the result window gets the translation.
- The failure window names the step via `$script:CurrentStep` (`step.<name>` keys); set it when adding a step.

**Log levels are user-facing.** Every `Warning`/`Error` line ends up in the end-of-run box.
- Use `Warning` only for an **outcome**, such as a package that failed through every source, or Office still installed.
- Intermediate states are logged at `Info`.
- debloat's per-app removals log at `Info`.

### Explorer restart

At the end of a full run, `Restart-Explorer` ends Explorer so settings written to the registry (taskbar, desktop icons, Start) show without a sign-out. Windows restarts the shell by itself (AutoRestartShell) as the signed-in user; if it isn't back within 15 s, it is started as `Win32_ComputerSystem.UserName` via a short-lived scheduled task (`GKScript-StartExplorer`), because an Explorer started from the elevated session is rejected as the shell. Install only skips it.

**Desktop icon layout.** Each profile names a layout in `config.json` (`desktopLayout`): `desktop_business.reg` (business and consumer-nolo: This PC, user folder, Control Panel, Firefox, Chrome, Netixx Helpdesk, Recycle Bin), `desktop_consumer.reg` (plus LibreOffice Writer/Calc/Impress); `office.ps1` applies `desktop_office.reg` (plus Word/Excel/PowerPoint, which it copies to the desktop) - but only while `Test-DesktopIsOurs` finds nothing on the desktop beyond the whitelist, so a customer's own arrangement is never replaced. LibreOffice and Office are never installed together. The files are `reg export`s of `HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop` from a reference PC, taken after a sign-out (Explorer writes `IconLayouts` then); they must stay UTF-16 LE.
- `Restart-Explorer -LayoutFile` writes the layout while Explorer is down - a running Explorer overwrites `IconLayouts` when it exits. For that moment it sets Winlogon `AutoRestartShell=0` (restored in `finally`) instead of the old blanked `Shell` value, which could have left every user without a desktop; a leftover 0 only means Explorer isn't restarted after a crash. Install only skips it (customer's desktop).

## Logging

`main.ps1` and the module have separate `$script:` scopes. `main.ps1` gets the log path from `Initialize-Logging`'s return value (`$script:LogFile = Initialize-Logging ...`).

Logs go to `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log` (from `config.logging.logPath`); `office.ps1` writes `office_*.log` and `postupdate.ps1` `update_*.log` there (`Initialize-Logging -Name`), which the used-PC check ignores. In `main.ps1` and the module, use `Write-Log -Level Info|Success|Warning|Error`. It writes color-coded output to the console and a timestamped line to the file.

## Important Patterns

- **Fallback chains**: winget first, then Chocolatey; uninstalls only ever silent (`Invoke-SilentUninstall`). Never assume a single method works, and never run an interactive uninstaller.
- **User-context actions** (starting Explorer) run as `Win32_ComputerSystem.UserName` via a short-lived scheduled task; tasks for every account (Bing wallpaper) use the Users group SID. Never run them directly from the elevated session.
- **Accounts created later** (the customer's) only get what is written to the Default profile, the DISM associations, machine policies or all-users tasks - an HKCU-only change reaches the technician's account and nobody else.
- **Config-driven**: profile differences belong in `config.json`. Avoid hardcoding profile-specific values in scripts.
- **Verify, don't guess**: package IDs, registry values and Appx names come from live checks or documented sources (winget, Store catalog, local ADMX, Microsoft Learn, Win11Debloat Regfiles). Note the source in a comment.
- Target machines are German- or Italian-locale Windows. Match on IDs or patterns that don't depend on the display language; `reg.exe` errors come back localized.

## Encoding Pitfalls

These have caused real runtime bugs. Understand them before editing any source file.

### 32-bit launcher (the exe)
The NSIS stub of `gk-script.exe` is a 32-bit process, and every child inherits that: a plain `powershell` started from it is `SysWOW64\...\powershell.exe`.
- A 32-bit PowerShell writes `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion` (OEMInformation, Uninstall) and `Winlogon` to `WOW6432Node`. `HKLM\SOFTWARE\Policies` is shared and was unaffected.
- It sees only the 32-bit half of the uninstall registry, and it gets the 32-bit DISM.
- `launch.bat` therefore starts `%SystemRoot%\Sysnative\...\powershell.exe` when that path exists, and `main.ps1` and `office.ps1` relaunch themselves in 64-bit via `Restart-In64BitPowerShell` (forwarding their parameters) when started from any 32-bit process.
- Testing from VS Code or a normal console never shows this. To reproduce the exe's context, start from `%SystemRoot%\SysWOW64\cmd.exe`.


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

### $ErrorActionPreference = 'Stop' and module autoloading
A module whose import writes a non-terminating error fails to load under `Stop`, and every later call reports "the module could not be loaded". Seen with `Microsoft.PowerShell.Archive` (Expand-Archive, used by the Chocolatey installer) when the display language's `ArchiveResources.psd1` is missing. Modules read the **global** preference, so a function-local `Continue` is not enough: import such a module once with `$global:ErrorActionPreference = 'Continue'` (restored in `finally`), as `Install-Chocolatey` does. Files in `src/steps` must reach files in `src` via `Split-Path $PSScriptRoot -Parent` (the repository check enforces it).

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

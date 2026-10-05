# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

<!-- Actually a Windows desktop WPF window (PSScriptMenuGui, XAML in src/PSScriptMenuGui/xaml/), not a browser page. It draws its own custom design rather than native Fluent/WinUI, so `web` is the closest valid value. -->

## Users

Netixx IT Solutions technicians setting up new Windows 11 PCs for customers. Some of this happens at the Netixx workshop bench before delivery, and some on-site at the customer on freshly unboxed machines. They are technical staff who know what each profile installs. Customers do not run the tool.

## Product Purpose

gk-script ("Netixx Grundkonfiguration") turns a new OEM Windows 11 PC into a clean, Netixx-branded machine with one click. The technician picks a deployment profile (Business, Consumer, Consumer without LibreOffice). The tool then installs the standard software, installs GPU drivers, removes Office 365 and OEM/Microsoft bloat, applies registry tweaks and OEM branding, sets file associations, lays out the desktop, and drops the Netixx Helpdesk onto it.

Success: the technician starts the run, walks away, and comes back to a finished machine. They can tell at a glance whether it succeeded, and the log explains anything that didn't.

## Positioning

It encodes Netixx's own house standard for a delivered PC: the package set, the desktop layout, OEM support info, and the Helpdesk remote-support client. It runs from a single self-extracting exe with no infrastructure (no MDM, domain, or imaging server). That makes it usable both at the bench and at a customer site.

## Operating Context

- The tool is run as a self-extracting `gk-script.exe` (NSIS) copied onto the target machine and started with a double-click. UAC elevation happens automatically.
- A run takes roughly 15-40 minutes. **The technician starts it and walks away.** They do not watch progress and come back later to check the result.
- Target machines are new OEM PCs (HP, Lenovo, Dell, etc.) with German-locale Windows 11, often carrying preinstalled bloat and trial AV.
- The tool needs an internet connection (Chocolatey, winget, the Win11Debloat list, the Helpdesk download).
- Interface: one small WPF window with one button per profile, a language selector (DE/EN/IT), an "install only (remove nothing)" switch for PCs already in use (off by default) and an "install all updates" switch (on by default; off for a quick run without Windows/app updates). A full run on a PC that looks used asks first and offers the install-only run. "Microsoft Office installieren" is a separate menu item that runs on its own: the technician picks the product matching the customer's licence; the customer signs in afterwards to activate it. Clicking one launches `main.ps1` in a PowerShell console, which shows color-coded log lines. At the end, a result window (`src/lib/SetupResult.xaml`) shows the outcome in a full-width status color (green done, yellow warnings, red failed) that reads from across the room. It lists what needs attention and offers Open log and, when drivers need it, Restart now. The PC and display are kept awake for the whole run so the window is visible when the technician returns.
- Logs are written to `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log`.

## Capabilities and Constraints

- Three profiles, defined in `src/config.json`, `src/gui.csv` and the `main.ps1` ValidateSet.
- It runs on Windows PowerShell 5.1. Non-ASCII characters in string literals break or garble output unless the file has a BOM.
- It needs admin rights, an internet connection and 5 GB of free disk space. It exits if pre-flight checks fail.
- Most steps fail soft: they log a warning and the run continues. Only pre-flight, Chocolatey and package-install failures abort.
- The GUI is the vendored PSScriptMenuGui module and is driven only by `gui.csv`.
- UI languages: **German (default), English, Italian**. The technician switches with a subtle selector in the menu, and the choice carries over to the result window. Netixx serves German- and Italian-speaking customers. The log file stays English for support.

## Brand Commitments

- Name: Netixx IT Solutions. Website: www.netixx.it.
- Assets: `src/netixx.ico` (window/exe icon) and `src/oemlogo.bmp` (System Properties OEM logo). `src/Logo_Info.reg` holds the OEM support info.
- The current GUI footer reads "Created for the people by www.netixx.it". It is existing copy, not a confirmed binding commitment.

## Evidence on Hand

- Brand assets: `src/netixx.ico` and `src/oemlogo.bmp`.
- The real profile contents are in `src/config.json` and `src/gui.csv`.
- There are no usage metrics, run-time statistics, testimonials or customer counts. Do not invent any.

## Product Principles

1. **One decision, then hands-off.** The only input the tool asks for is the profile. Nothing during a run should wait for a click before setup has finished.
2. **The outcome must be readable from across the room.** The technician comes back after walking away, so success, failure and "finished with warnings" must be obvious without reading console scrollback.
3. **Fail soft, report honestly.** Keep going when a non-critical step fails, but surface every warning afterwards with a pointer to the log.
4. **Works anywhere, with nothing but the exe.** Bench and on-site use require no setup, no network shares and no extra tooling.

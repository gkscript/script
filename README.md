# PSScript Setup & Menu GUI

A comprehensive Windows setup and customization tool with a graphical script menu system. Automates software installation, system configuration, and provides an easy-to-use GUI for launching scripts and applications.

## Features

### Setup Script (`main.ps1`)
- **Automated Windows Configuration**: Installs software packages, applies registry tweaks, removes bloatware
- **Pre-flight Validation**: Checks admin rights, internet connectivity, disk space, and Windows version
- **Multiple Deployment Types**: Business, Consumer, IT configurations
- **Comprehensive Logging**: All operations logged to `C:\Logs\PSScriptSetup\`
- **GPU Support**: Detects and installs NVIDIA drivers if available
- **BitLocker Management**: Safely handles encrypted drives
- **Error Handling**: Robust error handling with graceful fallbacks
- **Configuration-Driven**: JSON-based configuration for easy customization

### PSScriptMenuGui Module
- **WPF GUI Menu**: Modern Windows Presentation Foundation interface
- **Data Binding**: Clean separation of data model from presentation
- **CSV-Based Configuration**: Easy menu definition in spreadsheet format
- **Custom Colors & Icons**: Personalize appearance for your organization
- **Flexible Execution**: Run scripts, batch files, PowerShell inline code, or launch applications
- **Optional Descriptions**: Add help text to menu items

## Requirements

- **Windows 10 or Windows 11**
- **PowerShell 5.1+** (Desktop Edition recommended, Core 7+ also supported)
- **Administrator Privileges** (required for setup and system modifications)
- **Internet Connection** (for package downloads)
- **.NET Framework 4.7+** (for WPF)

## Installation

### Quick Start

1. Clone or download the repository:
```powershell
git clone https://github.com/weebsnore/PowerShell-Script-Menu-Gui.git
cd PSScript
```

2. Run the setup script with your desired deployment type:
```powershell
# As Administrator
.\src\main.ps1 -DeploymentType consumer
```

3. Verify configuration in `src/config.json`

### Deployment Types

Choose one based on your needs:

| Type | Packages | Office | Branded |
|------|----------|--------|---------|
| `business` | VLC, Firefox, Chrome, 7zip, Adobe Reader | No | Yes |
| `consumer` | business + LibreOffice, Paint.NET | No | Yes |


## Usage

### Setup Script

#### Basic Usage
```powershell
# Run with default settings
.\src\main.ps1 -DeploymentType consumer

# Skip bloatware removal
.\src\main.ps1 -DeploymentType consumer -SkipBloatwareRemoval

# Custom config file
.\src\main.ps1 -DeploymentType business -ConfigPath C:\CustomConfig\config.json

# Verbose logging
.\src\main.ps1 -DeploymentType consumer -Verbose
```

#### Parameters
- **DeploymentType** (Required): One of `business`, `consumer`
- **SkipBloatwareRemoval**: Skip removal of unwanted shortcuts and desktop icons
- **SkipHideConsole**: Keep PowerShell console visible during execution
- **ConfigPath**: Custom path to `config.json`

#### What It Does
1. ✅ Validates administrator rights and internet connectivity
2. ✅ Checks disk space and Windows version
3. ✅ Installs Chocolatey package manager
4. ✅ Installs configured software packages
5. ✅ Applies registry customizations
6. ✅ Detects and installs NVIDIA drivers if found
7. ✅ Removes bloatware and unwanted shortcuts
8. ✅ Disables BitLocker if encrypted
9. ✅ Installs Dynamic Theme (Windows 11 only)
10. ✅ Uninstalls MS Office
11. ✅ Sets default file associations
12. ✅ Logs all operations to `C:\Logs\PSScriptSetup\`

### PSScriptMenuGui Module

#### Import the Module
```powershell
Import-Module .\src\PSScriptMenuGui\PSScriptMenuGui.psm1
```

#### Create Menu from CSV
```powershell
Show-ScriptMenuGui -csvPath '.\menu-items.csv' `
    -windowTitle 'Company IT Tools' `
    -buttonBackgroundColor '#366EE8' `
    -buttonForegroundColor 'White' `
    -iconPath '.\company-logo.ico'
```

#### CSV Format

Create a CSV file with this structure:

```csv
Name,Description,Method,Command,Arguments,Section,Reference
Restart Computer,Immediately restart the system,powershell_inline,restart-computer -force,,,
Check Updates,Search Windows Update,cmd,ms-settings:windowsupdate,,,
Run Script,Execute external script,powershell_file,C:\scripts\deploy.ps1,,,
Inline Command,Run a one-liner,powershell_inline,Get-Process | Where-Object {$_.CPU -gt 50},,,
```

**CSV Columns:**
- **Name**: Button text (required)
- **Description**: Hover text and column 2 display (optional)
- **Method**: `cmd`, `powershell_file`, `powershell_inline`, `pwsh_file`, `pwsh_inline` (required)
- **Command**: Script path or command (required)
- **Arguments**: Additional command-line arguments (optional)
- **Section**: Group name (optional; used for visual grouping)
- **Reference**: Internal identifier (auto-generated if omitted)

#### Menu Examples

Create focused menus for different user groups:

**IT Support Menu:**
```csv
Name,Description,Method,Command,Section
Event Viewer,View Windows logs,cmd,eventvwr.msc,Diagnostics
Device Manager,Manage hardware devices,cmd,devmgmt.msc,Diagnostics
Services,Manage Windows services,cmd,services.msc,Diagnostics
```

**User Self-Service:**
```csv
Name,Description,Method,Command,Section
View Network,Check IP and connection,powershell_inline,ipconfig /all,Network
Restart,Restart computer safely,powershell_inline,restart-computer -force,System
Clear Disk Space,Remove temp files,powershell_file,C:\scripts\cleanup.ps1,Maintenance
```

## Configuration

### config.json
Centralized settings for deployment:

```json
{
  "logging": {
    "enabled": true,
    "logPath": "C:\\Logs\\PSScriptSetup",
    "logLevel": "Info"
  },
  "deployment": {
    "consumer": {
      "name": "Consumer",
      "packages": ["vlc", "firefox", "googlechrome"],
      "branded": true
    }
  },
  "paths": {
    "installFolder": "C:\\Install",
    "logoPath": "src/oemlogo.bmp"
  }
}
```

Edit this file to:
- Add/remove software packages
- Change installation paths
- Configure logging behavior
- Customize registry settings

## Project Structure

```
script/
├── README.md                          # This file
├── launch.bat                         # Quick launcher
├── src/
│   ├── main.ps1                       # Setup script (v2.0 - improved)
│   ├── main.legacy.ps1                  # Original script (backup)
│   ├── config.json                    # Configuration file (NEW)
│   ├── debloat.ps1                    # Remove unwanted Windows features
│   ├── office.xml                     # Office uninstall configuration
│   ├── assoc.txt                      # File type associations
│   ├── whitelist.txt                  # Desktop icons to keep
│   ├── PSScriptMenuGui/               # WPF Menu Module
│   │   ├── PSScriptMenuGui.psd1       # Module manifest (UPDATED)
│   │   ├── PSScriptMenuGui.psm1       # Module implementation
│   │   ├── public/
│   │   │   └── functions.ps1          # Public functions (REFACTORED)
│   │   ├── private/
│   │   │   └── functions.ps1          # Private functions (REFACTORED)
│   │   └── xaml/
│   │       ├── start.xaml             # Main window (REFACTORED)
│   │       └── end.xaml               # Window closing
│   └── lib/
│       └── PSSetupUtility.psm1        # Utility functions (NEW)
└── .git/                              # Version control
```

## Key Improvements in main.ps1

### Error Handling
- Comprehensive try-catch blocks
- Graceful error recovery
- Detailed error logging

### Logging
- Timestamped log entries
- Color-coded console output
- Persistent file logging to `C:\Logs\PSScriptSetup\`

### Security
- Safer Chocolatey installation (downloads to file, not direct pipe-to-iex)
- Admin rights verification
- Input validation

### Configuration
- JSON-based settings (no hardcoding)
- Extensible design
- Easy customization

### Code Quality
- Function-based architecture
- DRY (Don't Repeat Yourself) principle
- Clear separation of concerns
- Comprehensive help documentation

### Compatibility
- PowerShell 5.1+ compatible
- Windows 10 & 11 support
- GPU detection (NVIDIA/AMD)
- BitLocker awareness

## Logs

All operations are logged to: `C:\Logs\PSScriptSetup\setup_YYYYMMDD_HHmmss.log`

View recent logs:
```powershell
Get-ChildItem C:\Logs\PSScriptSetup\ -Filter "*.log" | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | % { notepad $_.FullName }
```

## Troubleshooting

### Setup fails with "Access Denied"
- Run PowerShell as Administrator
- Disable Windows Defender temporarily (revert after)
- Check file permissions in `src/` folder

### Chocolatey installation fails
- Verify internet connectivity: `Test-Connection 8.8.8.8 -Quiet`
- Check TLS version: `[Net.ServicePointManager]::SecurityProtocol`
- Run with verbose: `.\main.ps1 -Verbose`

### GUI menu doesn't display
- Verify .NET Framework 4.7+ is installed
- Check CSV file exists and is readable
- Review logs in `C:\Logs\PSScriptSetup\`

### NVIDIA drivers not installing
- Verify GPU detection: `Get-CimInstance Win32_VideoController`
- Chocolatey package may be outdated; update and retry

## Module Documentation

### Show-ScriptMenuGui
Creates and displays a graphical menu from CSV data.

**Syntax:**
```powershell
Show-ScriptMenuGui [-csvPath] <string>
    [[-windowTitle] <string>]
    [[-buttonForegroundColor] <string>]
    [[-buttonBackgroundColor] <string>]
    [[-iconPath] <string>]
    [-hideConsole]
    [-noExit]
    [<CommonParameters>]
```

**Example:**
```powershell
Show-ScriptMenuGui -csvPath 'tools.csv' -windowTitle 'IT Tools' -hideConsole
```

### New-ScriptMenuGuiExample
Creates sample configuration files.

**Syntax:**
```powershell
New-ScriptMenuGuiExample [[-path] <string>] [<CommonParameters>]
```

**Example:**
```powershell
New-ScriptMenuGuiExample -path 'C:\MyMenu'
```

## Contributing

Issues and pull requests welcome! Please:
1. Describe the issue thoroughly
2. Include log file excerpts if applicable
3. Specify Windows version and PowerShell version
4. Test changes before submitting

## License

MIT License - See LICENSE file for details

## Credits

- **Original Module**: Dan O'Sullivan
- **Refactoring & Improvements**: 2026 Updates
- **Contributors**: See GitHub repository

## Changelog

### v2.0.0 (February 2026)
- ✨ Refactored main.ps1 into modular functions
- ✨ Added comprehensive logging system
- ✨ Created JSON-based configuration
- ✨ Improved error handling and validation
- ✨ Updated PSScriptMenuGui with WPF data binding
- ✨ Added utility module with helper functions
- ✨ Replaced deprecated PowerShell APIs
- 📖 Added comprehensive documentation

### v1.0.1 (Original)
- Initial release with string-based XAML generation

## Support

For issues and questions:
1. Check the logs: `C:\Logs\PSScriptSetup\`
2. Review this README
3. Open an issue on GitHub
4. Contact: [Your Contact Info]

---

**Last Updated**: February 2026  
**PowerShell Version**: 5.1+  
**Windows Version**: 10, 11

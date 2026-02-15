# Quick Start Guide

## Installation & Setup (5 minutes)

### Step 1: Download
```bash
git clone https://github.com/weebsnore/PowerShell-Script-Menu-Gui.git
cd PSScript
```

### Step 2: Run Setup
```powershell
# As Administrator
cd src
.\main.ps1 -DeploymentType consumer
```

**Choose your type:**
- `business` - Office computer
- `business_it` - IT computer  
- `consumer` - Home user
- `consumer_it` - Home with extras
- `unbranded` - No company branding

### Step 3: Check Logs
```powershell
# View setup results
notepad C:\Logs\PSScriptSetup\
```

---

## Create Custom Menu (10 minutes)

### Step 1: Create CSV File (`my-menu.csv`)
```csv
Name,Description,Method,Command
Restart,Restart computer,powershell_inline,Restart-Computer -Force
IP Config,Show network info,cmd,ipconfig /all
Remote Desktop,Open RDP,cmd,mstsc.exe
```

### Step 2: Show Menu
```powershell
Import-Module .\src\PSScriptMenuGui\PSScriptMenuGui.psm1

Show-ScriptMenuGui -csvPath my-menu.csv `
    -windowTitle 'My Tools' `
    -buttonBackgroundColor '#366EE8' `
    -hideConsole
```

Done! Your menu appears.

---

## Configuration

### Edit `src/config.json`
```json
{
  "deployment": {
    "consumer": {
      "packages": [
        "vlc",
        "firefox",
        "YOUR_PACKAGE_HERE"
      ]
    }
  }
}
```

Save and re-run setup.

---

## Troubleshooting

### "Access Denied"
```powershell
# Run as Administrator
Start-Process powershell -Verb RunAs
```

### "No Internet"
```powershell
Test-Connection 8.8.8.8 -Quiet
# Should return True
```

### Menu doesn't display
```powershell
# Check if CSV exists
Test-Path my-menu.csv

# Verify it loads
Import-Csv my-menu.csv | Format-Table
```

### Check Logs
```powershell
Get-ChildItem C:\Logs\PSScriptSetup\ | 
  Sort-Object LastWriteTime | 
  Select-Object -Last 1 | 
  % { notepad $_.FullName }
```

---

## Common Tasks

### Install Custom Package
Edit `src/config.json` → Add to packages list → Run setup

### Change Button Colors
```powershell
Show-ScriptMenuGui -csvPath my-menu.csv `
    -buttonBackgroundColor '#FF0000' `   # Red
    -buttonForegroundColor '#FFFFFF'     # White
```

### Set Custom Icon
```powershell
Show-ScriptMenuGui -csvPath my-menu.csv `
    -iconPath 'C:\path\to\icon.ico'
```

### Add Menu Section
```csv
Name,Description,Method,Command,Section
Restart,Restart computer,powershell_inline,Restart-Computer -Force,System
Update,Check Windows Update,cmd,ms-settings:windowsupdate,System
Diagnostics,Event Viewer,cmd,eventvwr.msc,Troubleshooting
```

### Hide PowerShell Window
```powershell
Show-ScriptMenuGui -csvPath my-menu.csv -hideConsole
```

### Keep Window Open After Script
```powershell
Show-ScriptMenuGui -csvPath my-menu.csv -noExit
```

Or set in CSV Arguments: `-NoExit`

---

## File Locations

| Item | Path |
|------|------|
| Setup logs | `C:\Logs\PSScriptSetup\` |
| Installation files | `C:\Install\` |
| Config file | `src\config.json` |
| Module | `src\PSScriptMenuGui\` |
| Setup script | `src\main.ps1` |

---

## CSV Format Cheat Sheet

```csv
Name,Description,Method,Command,Arguments,Section,Reference
Button Name,Hover text,EXECUTION METHOD,SCRIPT/COMMAND,EXTRA ARGS,Group Name,button123
```

### Method Options
- `cmd` - Run .exe file
- `powershell_file` - Run .ps1 script
- `powershell_inline` - Run PowerShell code
- `pwsh_file` - Run in PowerShell 7+
- `pwsh_inline` - Inline PowerShell 7+

### Examples
```csv
Name,Description,Method,Command,Section
Restart Computer,Restart safely,powershell_inline,Restart-Computer -Force,System
Open Notepad,Text editor,cmd,notepad.exe,Tools
Show Processes,List running programs,powershell_inline,Get-Process | Select-Object Name,Diagnostics
```

---

## Parameters Reference

### main.ps1
```powershell
-DeploymentType consumer    # Required: deployment type
-ConfigPath config.json     # Optional: config file location
-SkipBloatwareRemoval       # Optional: don't remove shortcuts
-SkipHideConsole            # Optional: keep console visible
-Verbose                    # Optional: detailed output
```

### Show-ScriptMenuGui
```powershell
-csvPath file.csv                    # Required: CSV file path
-windowTitle 'My Menu'               # Optional: window title
-buttonBackgroundColor '#366EE8'     # Optional: button color
-buttonForegroundColor 'White'       # Optional: text color
-iconPath 'logo.ico'                 # Optional: window icon
-hideConsole                         # Optional: hide PowerShell
-noExit                              # Optional: keep window open
```

---

## Performance Tips

### Faster Setup
```powershell
# Measure time
Measure-Command { .\main.ps1 -DeploymentType consumer }

# Run background tasks in parallel if possible
```

### Faster Menu Display
```powershell
# Pre-check CSV
& { Start-Job { Import-Csv my-menu.csv } | Wait-Job | Receive-Job }

# Large CSV? Use filtering
Import-Csv my-menu.csv | Where-Object Section -eq 'System'
```

---

## Support

### Need Help?
1. Check `README.md` for full documentation
2. Review logs in `C:\Logs\PSScriptSetup\`
3. Check `IMPROVEMENTS.md` for detailed changes
4. Run test suite: `.\test.ps1`

### Report Issues
GitHub: https://github.com/weebsnore/PowerShell-Script-Menu-Gui/issues

Include:
- OS version (Windows 10/11)
- PowerShell version: `$PSVersionTable`
- Relevant log file
- Steps to reproduce

---

**Last Updated**: February 2026
**Quick Links**: [README](README.md) | [Improvements](IMPROVEMENTS.md) | [GitHub](https://github.com/weebsnore/PowerShell-Script-Menu-Gui)

# Code & File Analysis Report
**Date**: February 16, 2026  
**Status**: Analysis Complete  

---

## 📋 Overview
This document identifies unnecessary files, redundant code, and optimization opportunities in the PSScript repository.

---

## 🗑️ UNNECESSARY FILES (Ready to Delete)

### 1. **Legacy & Deprecated Files** (HIGH PRIORITY)

#### `src/main.legacy.ps1` 
- **Status**: OBSOLETE - Not in use
- **Size**: 256 lines  
- **Reason**: Replaced by modern `main.ps1` v2.0
- **Dependencies**: None active (all references point to main.ps1)
- **Risk**: LOW - Safe to delete
- **Action**: ✅ **DELETE**

#### `src/RefreshEnv.cmd`
- **Status**: UNUSED - Referenced only in legacy script
- **Size**: 68 lines
- **Last Used**: main.legacy.ps1 (line 45)
- **Modern Alternative**: PowerShell's environment variable refresh
- **Risk**: LOW
- **Action**: ✅ **DELETE**

#### `src/start2.bin`
- **Status**: UNUSED - Start Menu cache file (Windows internal)
- **Size**: 7,644 bytes
- **Last Used**: main.legacy.ps1 only (lines 178-191)
- **Note**: Windows generates this automatically
- **Risk**: LOW - Windows will recreate if needed
- **Action**: ✅ **DELETE**

#### `src/88000784`
- **Status**: UNUSED - Windows Start Menu binary cache
- **Size**: 7,351 bytes
- **Last Used**: main.legacy.ps1 only (line 191)
- **Note**: Windows internal file, auto-generated
- **Risk**: LOW
- **Action**: ✅ **DELETE**

---

### 2. **Unused Registry Files** (MEDIUM PRIORITY)

#### `src/desktop.reg`
- **Status**: NOT REFERENCED anywhere
- **Analysis**: No grep matches in any .ps1 files
- **Risk**: MEDIUM - Might be needed for specific use cases
- **Action**: ⚠️ **REVIEW before deleting** - Check if this is intentionally reserved for future use

#### `src/desktop_libreoffice.reg`
- **Status**: NOT REFERENCED anywhere
- **Analysis**: Commented out in old scripts only
- **Risk**: MEDIUM
- **Action**: ⚠️ **REVIEW before deleting**

#### `src/disable_telemetry.reg`
- **Status**: NOT REFERENCED anywhere
- **Analysis**: No active references
- **Risk**: MEDIUM
- **Action**: ⚠️ **REVIEW before deleting**

**Currently Used Registry Files**:
- ✅ `src/Logo_Info.reg` - Applied when branded=true
- ✅ `src/icons.reg` - Always applied

---

### 3. **Orphaned Installation Files** (MEDIUM PRIORITY)

#### `src/readerdc_it_xa_crd_install.exe`
- **Status**: COMMENTED OUT & UNUSED
- **Size**: Actual installer binary (probably 20-100MB+)
- **Last Used**: main.legacy.ps1 line 122-123 (both commented out)
- **Note**: Adobe Reader installation is handled via Chocolatey
- **Risk**: LOW - Redundant with package manager
- **Action**: ✅ **DELETE** - Use `adobereader` package instead

#### `src/officesetup.exe` & `src/office.xml`
- **Status**: CONDITIONALLY USED
- **Analysis**: Used in main.ps1 lines 451-454 - but only if file exists
- **Note**: Not listed in package installations, only removes Office
- **Risk**: LOW - Conditional, can be removed if Office removal isn't needed
- **Action**: ⚠️ **KEEP IF** Office uninstallation is required, **DELETE OTHERWISE**

---

### 4. **Potentially Redundant Application Files**

#### `src/DynamicTheme.Msixbundle`
- **Status**: REFERENCED in Enable-DynamicTheme() but no actual implementation shown
- **Note**: Windows 11 feature
- **Risk**: MEDIUM - Check if function actually uses it
- **Action**: ⚠️ **VERIFY** - Check if Enable-DynamicTheme() function actually deploys this

---

## ⚙️ REDUNDANT CODE & FUNCTIONS

### 1. **Duplicate Deployment Types** (LOW PRIORITY)

Current configuration in `config.json`:
```json
"business": { "packages": [...], ... }
"consumer": { "packages": [...], ... }
```

**Analysis**:
- Redundant `business_it` and `consumer_it` variants have been removed
- Consolidated to 2 core deployment types: `business` and `consumer`
- Default system locale is used for installed applications

**Completed**:
✅ Removed `business_it` & `consumer_it` from config.json
✅ Updated parameter validation in main.ps1
✅ Updated all documentation and test references

---

### 2. **Legacy Code Patterns in debloat.ps1**

#### Old Progress Bar Pattern (Line 1)
```powershell
Write-Progress -Activity "Uninstalling Adware" -Status "85% Complete:" -PercentComplete 85
```
- **Issue**: main.ps1 handles progress reporting centrally
- **Status**: Duplicate progress indication
- **Risk**: LOW - Not harmful, just redundant
- **Action**: ⚠️ **OPTIONAL** - Consider removing if main.ps1 already reports progress

---

### 3. **Conditional File Checks That Could Fail**

Multiple locations have this pattern:
```powershell
if (Test-Path "src/SomeFile.exe") {
    & "src/SomeFile.exe"
}
```

**Issue**: What happens if file doesn't exist?
- Silent failure, setup continues
- User never knows feature was skipped
- Could lead to incomplete configurations

**Affected Files**:
- SetUserFTA.exe (line 474-476)
- officesetup.exe (line 451-454)
- debloat.ps1 (implied)
- Netixx Helpdesk.exe (line 436-438)

**Better Approach**: 
```powershell
if (Test-Path "src/SomeFile.exe") {
    ...
} else {
    Write-Log "Warning: SomeFile.exe not found. Feature skipped." -Level Warning
}
```

**Risk**: MEDIUM - Silent-fail scenarios
**Action**: ⚠️ **IMPROVE** - Add explicit warnings

---

## 📦 UNUSED MODULE/DATA FILES (LOW PRIORITY)

### `src/oemlogo.bmp`
- **Status**: USED - Branded deployments only
- **Action**: ✅ KEEP (conditional dependency)

### `src/netixx.ico`
- **Status**: UNCLEAR - Check if used by GUI or shortcuts
- **Action**: ⚠️ **CHECK USAGE** - Not found in grep search

### `src/assoc.txt`
- **Status**: USED - File associations configuration
- **Lines**: 66 entries mapping file types to applications (VLC, Chrome)
- **Action**: ✅ KEEP - Active configuration file

### `src/whitelist.txt`
- **Status**: USED - Desktop icon whitelist
- **Line 410**: Desktop cleanup uses this
- **Action**: ✅ KEEP - Active configuration file

### `src/version.txt`
- **Status**: POSSIBLY UNUSED - Contains "1.1.0"
- **Analysis**: No references in grep search
- **Action**: ⚠️ **CHECK USAGE** - Should configuration have version field?

### `src/gui.csv`
- **Status**: USED - Menu definition for GUI launcher
- **Analysis**: Referenced in launch.bat and documentation
- **Action**: ✅ KEEP - Active

---

## 🎯 CLEANUP PRIORITY MATRIX

| Priority | Item | Action | Risk | Effort |
|----------|------|--------|------|--------|
| 🔴 CRITICAL | `src/main.legacy.ps1` | DELETE | LOW | 5 min |
| 🔴 CRITICAL | `src/RefreshEnv.cmd` | DELETE | LOW | 2 min |
| 🟠 HIGH | `src/start2.bin` | DELETE | LOW | 1 min |
| 🟠 HIGH | `src/88000784` | DELETE | LOW | 1 min |
| 🟠 HIGH | `src/readerdc_it_xa_crd_install.exe` | DELETE | LOW | 1 min |
| 🟡 MEDIUM | `src/desktop.reg` | REVIEW | MEDIUM | 5 min |
| 🟡 MEDIUM | `src/desktop_libreoffice.reg` | REVIEW | MEDIUM | 5 min |
| 🟡 MEDIUM | `src/disable_telemetry.reg` | REVIEW | MEDIUM | 5 min |
| 🟡 MEDIUM | Deploy types consolidation | CLARIFY | MEDIUM | 20 min |
| 🟡 MEDIUM | Duplicate progress bars | IMPROVE | LOW | 10 min |
| 🟢 LOW | netixx.ico usage | CHECK | LOW | 5 min |
| 🟢 LOW | version.txt tracking | CHECK | LOW | 5 min |

---

## ✅ CONFIRMED ACTIVE FILES (Keep As-Is)

- ✅ `src/main.ps1` - Active setup script (v2.0)
- ✅ `src/config.json` - Configuration (actively used)
- ✅ `src/gui.csv` - Menu launcher configuration
- ✅ `src/debloat.ps1` - Bloatware removal
- ✅ `src/assoc.txt` - File association settings
- ✅ `src/whitelist.txt` - Desktop icon whitelist
- ✅ `src/office.xml` - Office removal configuration (if using Office removal)
- ✅ `src/Logo_Info.reg` - Branded deployments
- ✅ `src/icons.reg` - Icon customization
- ✅ `src/oemlogo.bmp` - Branded deployments (conditional)
- ✅ `src/Netixx Helpdesk.exe` - Branded deployments (conditional)
- ✅ `src/SetUserFTA.exe` - File association utility
- ✅ `src/AutoHotkey32.exe` - Chrome automation
- ✅ `src/chrome.ahk` - Chrome startup automation
- ✅ `src/officesetup.exe` - Office uninstaller (if needed)
- ✅ `PSScriptMenuGui/` - Active module

---

## 🚀 RECOMMENDATIONS

### Immediate Actions (Safe, No Risk)
1. Delete `src/main.legacy.ps1`
2. Delete `src/RefreshEnv.cmd`
3. Delete `src/start2.bin`
4. Delete `src/88000784`
5. Delete `src/readerdc_it_xa_crd_install.exe`

**Estimated Cleanup**: ~1.5 MB space freed

### Review & Decide (Need Clarification)
1. **Registry Files**: Are `desktop.reg`, `desktop_libreoffice.reg`, `disable_telemetry.reg` reserved for future use?
   - If not, delete them
   - If yes, document their purpose in README

3. **Office Setup**: Is `officesetup.exe` still required?
   - If Office isn't a requirement, these files can be removed
   - Modern approach: Use Chocolatey for Office deployment/removal

### Code Quality (Optional Improvements)
1. Add explicit logging when optional steps are skipped
2. Consolidate duplicate registry imports
3. Consolidate duplicate file associations (if identical across types)

---

## 📊 Current State Summary

| Category | Count | Used | Unused | Action |
|----------|-------|------|--------|--------|
| PS1 scripts | 2 | 1 | 1 | Delete legacy |
| Config files | 2 (JSON+CSV) | 2 | 0 | Keep all |
| Registry files | 5 | 2 | 3 | Review 3 |
| Executables | 7+ | 5-6 | 1-2 | Evaluate |
| Binary/Data | 4 | 2-3 | 1-2 | Clean up |
| **TOTAL** | **~25** | **~18** | **~7** | **~28% waste** |

---

## 🔍 How to Verify Before Deleting

Before removing any file, run these checks:
```powershell
# Check if file is referenced anywhere
grep -r "filename" c:\Users\marob\Documents\Code\script

# Check in git history
git log -p --all -- filename

# Check in git blame
git log -p --follow -- filename
```

---

*For implementation, proceed with Immediate Actions first, then review other recommendations.*

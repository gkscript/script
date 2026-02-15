param(
    [Parameter(Mandatory)]
    [ValidateSet('business', 'business_it', 'consumer', 'consumer_it', 'unbranded')]
    [string]$DeploymentType,
    
    [Parameter()]
    [switch]$SkipBloatwareRemoval,
    
    [Parameter()]
    [switch]$SkipHideConsole,
    
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\config.json"
)

# Stop on first error
$ErrorActionPreference = 'Stop'

# Import utility functions
Import-Module "$PSScriptRoot\lib\PSSetupUtility.psm1" -Force

# Initialize
Initialize-Logging -logPath "C:\Logs\PSScriptSetup"
Write-Log "=== PSScript Setup Starting ===" -Level Success
Write-Log "Deployment Type: $DeploymentType"
Write-Log "Config Path: $ConfigPath"

# Load configuration
try {
    $script:config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    Write-Log "Configuration loaded successfully"
}
catch {
    Write-Log "Failed to load configuration: $_" -Level Error
    throw
}

# Pre-flight checks
try {
    Write-Log "Running pre-flight checks..."
    Test-PrerequisiteAdmin
    Test-PrerequisiteInternet
    Test-PrerequisiteDiskSpace -requiredBytes $script:config.validation.minDiskSpace
    
    $windowsInfo = Test-WindowsVersion
    $gpuInfo = Get-SystemGPU
    $bitlockerStatus = Get-BitlockerStatus
    
    Write-Log "All pre-flight checks passed" -Level Success
}
catch {
    Write-Log "Pre-flight checks failed: $_" -Level Error
    exit 1
}

# Get deployment configuration
$deploymentConfig = $script:config.deployment[$DeploymentType]
if (-not $deploymentConfig) {
    Write-Log "Invalid deployment type: $DeploymentType" -Level Error
    exit 1
}

Write-Log "Deploying: $($deploymentConfig.name)"

# ============================================================================
# FUNCTION DEFINITIONS
# ============================================================================

Function Install-PackageManager {
    <#
    .SYNOPSIS
        Install Chocolatey package manager with security checks
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('chocolatey', 'winget')]
        [string]$Manager
    )
    
    Write-Log "Installing $Manager..."
    
    try {
        if (Get-Command $Manager -ErrorAction SilentlyContinue) {
            Write-Log "$Manager is already installed" -Level Success
            return $true
        }
        
        switch ($Manager) {
            'chocolatey' {
                # Use environment variable for the script, don't pipe downloads directly to iex
                $chocoScriptPath = Join-Path $env:TEMP "install-choco.ps1"
                
                Write-Log "Downloading Chocolatey installation script..."
                try {
                    $ProgressPreference = 'SilentlyContinue'
                    Invoke-WebRequest -Uri "https://community.chocolatey.org/install.ps1" `
                        -OutFile $chocoScriptPath `
                        -ErrorAction Stop
                    
                    # Verify file was downloaded
                    if (Test-Path $chocoScriptPath) {
                        Write-Log "Executing Chocolatey installation script..."
                        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
                        & $chocoScriptPath
                        Remove-Item $chocoScriptPath -Force
                        
                        if (Get-Command choco -ErrorAction SilentlyContinue) {
                            Write-Log "$Manager installed successfully" -Level Success
                            return $true
                        } else {
                            throw "Chocolatey installation failed"
                        }
                    }
                } finally {
                    $ProgressPreference = 'Continue'
                }
            }
            
            'winget' {
                Write-Log "Winget installation not implemented - please install manually from Microsoft Store"
                return $false
            }
        }
    }
    catch {
        Write-Log "Failed to install $Manager : $_" -Level Error
        throw
    }
}

Function Install-Packages {
    <#
    .SYNOPSIS
        Install software packages from Chocolatey
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$PackageList,
        
        [ValidateSet('chocolatey', 'winget')]
        [string]$Manager = 'chocolatey'
    )
    
    if ($PackageList.Count -eq 0) {
        Write-Log "No packages to install"
        return
    }
    
    Write-Log "Installing packages: $($PackageList -join ', ')"
    
    try {
        if ($Manager -eq 'chocolatey') {
            choco feature enable -n allowGlobalConfirmation
            
            # Install packages (retry once if fails)
            $attemptCount = 0
            do {
                $attemptCount++
                Write-Log "Installation attempt $attemptCount..."
                
                foreach ($package in $PackageList) {
                    Write-Log "  Installing: $package"
                    choco install -y --ignorechecksum $package
                    
                    if ($LASTEXITCODE -ne 0) {
                        Write-Log "    Package installation returned exit code $LASTEXITCODE" -Level Warning
                    }
                }
            } while ((-not $?) -and ($attemptCount -lt 2))
            
            Write-Log "Package installation completed" -Level Success
        }
    }
    catch {
        Write-Log "Package installation failed: $_" -Level Error
        throw
    }
}

Function Apply-RegistrySettings {
    <#
    .SYNOPSIS
        Apply Windows registry settings
    #>
    param(
        [string[]]$RegistryFiles,
        [hashtable]$RegistryValues
    )
    
    Write-Log "Applying registry settings..."
    
    try {
        # Import .reg files
        foreach ($regFile in $RegistryFiles) {
            if (Test-Path $regFile) {
                Write-Log "  Importing: $regFile"
                reg import $regFile
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "    Registry import returned exit code $LASTEXITCODE" -Level Warning
                }
            } else {
                Write-Log "    Registry file not found: $regFile" -Level Warning
            }
        }
        
        # Set individual registry values
        foreach ($path in $RegistryValues.Keys) {
            $valueName = $RegistryValues[$path].Name
            $value = $RegistryValues[$path].Value
            $type = $RegistryValues[$path].Type
            
            Write-Log "  Setting: $path\$valueName = $value"
            
            try {
                Set-ItemProperty -Path $path -Name $valueName -Value $value -Type $type -Force
            }
            catch {
                Write-Log "    Failed to set registry value: $_" -Level Warning
            }
        }
        
        Write-Log "Registry settings applied" -Level Success
    }
    catch {
        Write-Log "Registry settings failed: $_" -Level Error
        throw
    }
}

Function Remove-BloatwareShortcuts {
    <#
    .SYNOPSIS
        Remove unwanted shortcuts from Start Menu
    #>
    param(
        [string[]]$ShortcutPaths
    )
    
    Write-Log "Removing bloatware shortcuts..."
    
    try {
        foreach ($shortcut in $ShortcutPaths) {
            if (Test-Path $shortcut) {
                Write-Log "  Removing: $shortcut"
                Remove-Item $shortcut -Force -ErrorAction Continue
            }
        }
        
        Write-Log "Bloatware removal completed" -Level Success
    }
    catch {
        Write-Log "Bloatware removal failed: $_" -Level Error
        throw
    }
}

Function Clean-DesktopIcons {
    <#
    .SYNOPSIS
        Clean desktop of unwanted icons using whitelist
    #>
    param(
        [string]$WhitelistPath
    )
    
    Write-Log "Cleaning desktop icons..."
    
    try {
        if (-not (Test-Path $WhitelistPath)) {
            Write-Log "Whitelist not found: $WhitelistPath" -Level Warning
            return
        }
        
        $whitelist = Get-Content $WhitelistPath
        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $desktopItems = Get-ChildItem $desktopPath
        
        $removedCount = 0
        foreach ($item in $desktopItems) {
            if ($item.Name -notin $whitelist) {
                Write-Log "  Removing: $($item.Name)"
                Remove-Item $item.FullName -Force -ErrorAction Continue
                $removedCount++
            }
        }
        
        Write-Log "Removed $removedCount desktop items" -Level Success
    }
    catch {
        Write-Log "Desktop cleanup failed: $_" -Level Error
        throw
    }
}

Function Enable-DynamicTheme {
    <#
    .SYNOPSIS
        Install Windows Dynamic Theme from Microsoft Store
    #>
    Write-Log "Installing Dynamic Theme..."
    
    try {
        winget install --accept-package-agreements --accept-source-agreements --source msstore "dynamic theme"
        
        # Create desktop shortcut
        $targetPath = "shell:AppsFolder\55888ChristopheLavalle.DynamicTheme_jdggxwd41xcr0!App"
        $shortcutFile = "$env:USERPROFILE\Desktop\Dynamic Theme.lnk"
        
        Write-Log "  Creating desktop shortcut"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutFile)
        $shortcut.TargetPath = $targetPath
        $shortcut.Save()
        
        Write-Log "Dynamic Theme installed" -Level Success
    }
    catch {
        Write-Log "Dynamic Theme installation failed: $_" -Level Warning
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    # Step 1: Install package managers
    Write-Log "Step 1: Installing package managers (5%)" -Level Success
    Install-PackageManager -Manager chocolatey
    
    # Step 2: Install software packages
    Write-Log "Step 2: Installing software packages (20%)" -Level Success
    Install-Packages -PackageList $deploymentConfig.packages -Manager chocolatey
    
    # Step 3: Install GPU drivers if applicable
    if ($gpuInfo.IsNvidia) {
        Write-Log "Step 3a: Installing NVIDIA drivers (30%)" -Level Success
        Install-Packages -PackageList @('nvidia-app') -Manager chocolatey
    }
    
    # Step 4: Apply registry settings
    Write-Log "Step 4: Applying registry settings (40%)" -Level Success
    $registryFiles = @()
    if (-not $deploymentConfig.branded -eq $false) {
        $registryFiles += "src/Logo_Info.reg"
    }
    $registryFiles += "src/icons.reg"
    
    $registryValues = @{
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' = @{
            Name = 'SystemUsesLightTheme'
            Value = 0
            Type = 'DWord'
        }
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' = @{
            Name = 'AppsUseLightTheme'
            Value = 1
            Type = 'DWord'
        }
    }
    
    Apply-RegistrySettings -RegistryFiles $registryFiles -RegistryValues $registryValues
    
    # Step 5: Remove bloatware shortcuts
    if (-not $SkipBloatwareRemoval) {
        Write-Log "Step 5: Removing bloatware (50%)" -Level Success
        Remove-BloatwareShortcuts -ShortcutPaths $script:config.windows.shortcuts
        Clean-DesktopIcons -WhitelistPath "src/whitelist.txt"
    }
    
    # Step 6: Disable BitLocker if needed
    if ($bitlockerStatus.IsEncrypted) {
        Write-Log "Step 6: Disabling BitLocker (60%)" -Level Success
        try {
            Disable-BitLocker -MountPoint "C:"
            Write-Log "BitLocker disabled" -Level Success
        }
        catch {
            Write-Log "BitLocker disable failed: $_" -Level Warning
        }
    }
    
    # Step 7: Copy files to installation folder
    Write-Log "Step 7: Setting up installation folder (70%)" -Level Success
    $installFolder = $script:config.paths.installFolder
    if (-not (Test-Path $installFolder)) {
        $null = New-Item -Path $installFolder -ItemType Directory -Force
        Write-Log "Created installation folder: $installFolder"
    }
    
    if ($deploymentConfig.branded) {
        if (Test-Path "src/oemlogo.bmp") {
            Copy-Item "src/oemlogo.bmp" "C:\Windows\System32" -Force
            Write-Log "Copied OEM logo"
        }
        if (Test-Path "src/Netixx Helpdesk.exe") {
            Copy-Item "src/Netixx Helpdesk.exe" $installFolder -Force
            New-Item -Path "$env:PUBLIC\Desktop\Netixx Helpdesk" -ItemType SymbolicLink -Value "$installFolder\Netixx Helpdesk.exe" -Force -ErrorAction Continue
            Write-Log "Installed HelpDesk application"
        }
    }
    
    # Step 8: Install Dynamic Theme
    if ($windowsInfo.Is11) {
        Write-Log "Step 8: Installing Dynamic Theme (75%)" -Level Success
        Enable-DynamicTheme
    }
    
    # Step 9: Uninstall Office
    Write-Log "Step 9: Uninstalling Office (80%)" -Level Success
    if (Test-Path "src\officesetup.exe" -PathType Leaf) {
        try {
            Write-Log "Running Office uninstaller..."
            & "src\officesetup.exe" /configure "src\office.xml"
        }
        catch {
            Write-Log "Office uninstall failed: $_" -Level Warning
        }
    }
    
    # Step 10: Run debloat script
    Write-Log "Step 10: Running debloat script (90%)" -Level Success
    if (Test-Path "src/debloat.ps1") {
        try {
            & "src/debloat.ps1"
        }
        catch {
            Write-Log "Debloat script failed: $_" -Level Warning
        }
    }
    
    # Step 11: Set default file associations
    Write-Log "Step 11: Setting default associations (95%)" -Level Success
    if (Test-Path "src/SetUserFTA.exe") {
        try {
            & "src/SetUserFTA.exe" "src/assoc.txt"
        }
        catch {
            Write-Log "Set file associations failed: $_" -Level Warning
        }
    }
    
    # Final: Restart Explorer
    Write-Log "Finalizing... (98%)" -Level Success
    try {
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
        Start-Process explorer.exe
    }
    catch {
        Write-Log "Explorer restart failed: $_" -Level Warning
    }
    
    Write-Log "=== Setup Completed Successfully ===" -Level Success
    Write-Log "Log file: $($script:LogFile)"
    
    [System.Windows.Forms.MessageBox]::Show("Setup completed successfully!`nLog file: $($script:LogFile)", "Setup Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}
catch {
    Write-Log "=== Setup Failed ===" -Level Error
    Write-Log "Error: $_" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    Write-Log "Log file: $($script:LogFile)"
    
    [System.Windows.Forms.MessageBox]::Show("Setup failed!`nCheck: $($script:LogFile)`n`nError: $_", "Setup Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    
    exit 1
}
finally {
    Write-Log "Setup script ended at $(Get-Date)"
}

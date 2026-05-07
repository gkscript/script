param(
    [Parameter(Mandatory)]
    [ValidateSet('business', 'consumer', 'consumer-nolo')]
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

# Load configuration first (to get log path from config)
try {
    $configObject = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    
    # Convert to hashtable for proper key access
    $script:config = @{}
    $configObject.PSObject.Properties | ForEach-Object {
        if ($_.Value -is [PSCustomObject]) {
            # Convert nested objects to hashtables
            $nestedHash = @{}
            $_.Value.PSObject.Properties | ForEach-Object {
                $nestedHash[$_.Name] = $_.Value
            }
            $script:config[$_.Name] = $nestedHash
        } else {
            $script:config[$_.Name] = $_.Value
        }
    }
}
catch {
    Write-Error "Failed to load configuration from '$ConfigPath': $_"
    exit 1
}

# Initialize logging using path from config
Initialize-Logging -logPath $script:config.logging.logPath
$script:Version = (Get-Content "$PSScriptRoot\version.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s'
Write-Log "=== PSScript Setup Starting (v$script:Version) ===" -Level Success
Write-Log "Deployment Type: $DeploymentType"
Write-Log "Config Path: $ConfigPath"
Write-Log "Configuration loaded successfully"
Write-Log "Available deployment types: $($script:config.deployment.Keys -join ', ')"

# Pre-flight checks
try {
    Write-Log "Running pre-flight checks..."
    Test-PrerequisiteAdmin
    Test-PrerequisiteInternet
    Sync-SystemTimeWithInternet
    Test-PrerequisiteDiskSpace -requiredBytes $script:config.validation.minDiskSpace
    
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

$script:PackageDisplayNames = @{
    'googlechrome'       = 'Google Chrome'
    'nvidia-app'         = 'NVIDIA'
    'vlc'                = 'VLC media player'
    'firefox'            = 'Mozilla Firefox'
    '7zip'               = '7-Zip'
    'adobereader'        = 'Adobe Acrobat Reader'
    'libreoffice'        = 'LibreOffice'
    'paint.net'          = 'paint.net'
}

Function Test-PackageInstalledInRegistry {
    param([string]$PackageName)
    $displayName = $script:PackageDisplayNames[$PackageName]
    if (-not $displayName) { return $false }
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $found = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "*$displayName*" } |
        Select-Object -First 1
    if ($found) {
        Write-Log "  $PackageName found in system as '$($found.DisplayName) $($found.DisplayVersion)'" -Level Info
        return $true
    }
    return $false
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

            foreach ($package in $PackageList) {
                # Pre-check: already tracked by choco
                $preCheck = & choco list --local-only --exact $package --limit-output 2>&1
                if ($preCheck -match "(?m)^$([regex]::Escape($package))\|") {
                    Write-Log "  Already installed: $package" -Level Info
                    continue
                }

                if (Test-PackageInstalledInRegistry -PackageName $package) {
                    Write-Log "  Already installed (registry): $package - skipping" -Level Info
                    continue
                }

                $installed = $false
                $maxAttempts = 3

                for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
                    Write-Log "  Installing: $package (attempt $attempt/$maxAttempts)"
                    $chocoArgs = @('install', '-y', $package)
                    # Chrome's choco package frequently has a stale expected hash; ignore-checksums is safe here
                    if ($package -eq 'googlechrome') { $chocoArgs += '--ignore-checksums' }

                    # Redirect stdout to a temp file so we can detect when the download finishes
                    # and the installer actually starts — only then begin the 5-min kill timer.
                    # stderr is left unredirected so choco error messages still appear in the console.
                    $tmpOut = [System.IO.Path]::GetTempFileName()
                    $proc = Start-Process -FilePath "choco" -ArgumentList $chocoArgs `
                        -RedirectStandardOutput $tmpOut -NoNewWindow -PassThru
                    $fs = [System.IO.FileStream]::new(
                        $tmpOut,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::ReadWrite)
                    $sr = [System.IO.StreamReader]::new($fs)
                    $downloadCompleteAt = $null  # nil until download finishes; used to start kill timer
                    $installDeadline    = $null
                    $killedEarly        = $false
                    $lastWasProgress    = $false
                    $chocoNoise = '(?i)' + (@(
                        '^Chocolatey v'
                        '^Installing the following packages:'
                        '^By installing'
                        '^Downloading package from source'
                        '\[Approved\]'
                        'package files install completed\.'
                        '^Downloading .+ \d+ bit'
                        '^  from '
                        'Hashes match\.'
                        'has been installed\.'
                        'The install of .+ was successful\.'
                        "^Deployed to '"
                        '^Chocolatey installed \d+/\d+ packages\.'
                        '^See the log for details'
                        'using locale'
                        '^\s*$'
                    ) -join '|')
                    # dot-sourced so it reads/writes $line and $lastWasProgress from caller scope
                    $writeChocoLine = {
                        if ($line -match '^Progress:') {
                            # Pad to 80 chars so shorter lines fully overwrite longer ones
                            Write-Host "`r$($line.PadRight(80))" -NoNewline
                            $lastWasProgress = $true
                        } elseif ($line -notmatch $chocoNoise) {
                            if ($lastWasProgress) { Write-Host "" }
                            Write-Host $line
                            $lastWasProgress = $false
                        }
                    }
                    try {
                        while ($true) {
                            $line = $sr.ReadLine()
                            while ($null -ne $line) {
                                . $writeChocoLine
                                if ($null -eq $downloadCompleteAt -and $line -match '(?i)Download of .+ completed\.') {
                                    $downloadCompleteAt = [datetime]::UtcNow
                                    $installDeadline    = $downloadCompleteAt.AddMinutes(5)
                                    Write-Log "    Download complete - 5 min installer timeout started" -Level Info
                                }
                                $line = $sr.ReadLine()
                            }
                            if ($proc.WaitForExit(500)) { break }
                            if ($null -ne $installDeadline -and [datetime]::UtcNow -gt $installDeadline) {
                                Write-Log "    $package installer running for 5 min - terminating" -Level Warning
                                $null = & taskkill /T /F /PID $proc.Id 2>&1
                                Write-Log "    taskkill exit: $LASTEXITCODE" -Level Warning
                                $killedEarly = $true
                                break
                            }
                        }
                        while ($null -ne ($line = $sr.ReadLine())) { . $writeChocoLine }
                    } finally {
                        $sr.Dispose()
                        $fs.Dispose()
                        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
                    }
                    $chocoExit = if ($killedEarly) { 0 } else { $proc.ExitCode }

                    # Verify via choco tracking (--limit-output gives clean name|version format)
                    $localPackage = & choco list --local-only --exact $package --limit-output 2>&1
                    if ($localPackage -match "(?m)^$([regex]::Escape($package))\|") {
                        $installed = $true
                        Write-Log "    Installed: $package" -Level Success
                        break
                    }

                    # Exit 0/1641/3010 = success or reboot-pending; choco may have skipped an
                    # externally-installed package without adding it to its tracking DB
                    if ($chocoExit -in @(0, 1641, 3010)) {
                        $installed = $true
                        Write-Log "    Installed: $package" -Level Success
                        break
                    }

                    Write-Log "    Package install not confirmed for '$package'" -Level Warning
                    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 3 }
                }

                if (-not $installed -and $package -eq 'googlechrome') {
                    Write-Log "  Falling back to winget for Google Chrome..." -Level Warning
                    if (Get-Command winget -ErrorAction SilentlyContinue) {
                        Write-Log "    Resetting winget sources..." -Level Info
                        $null = & winget source reset --force 2>&1
                        $null = & winget source update --disable-interactivity 2>&1
                        & winget install --id Google.Chrome --silent --accept-package-agreements --accept-source-agreements --source winget
                        if ($LASTEXITCODE -eq 0) {
                            $installed = $true
                            Write-Log "    Installed googlechrome via winget fallback" -Level Success
                        }
                        else {
                            Write-Log "    Winget fallback failed for googlechrome (exit code $LASTEXITCODE)" -Level Warning
                        }
                    }
                    else {
                        Write-Log "    Winget not available for googlechrome fallback" -Level Warning
                    }
                }

                if (-not $installed) {
                    if (Test-PackageInstalledInRegistry -PackageName $package) {
                        $installed = $true
                    } else {
                        Write-Log "    Failed to install '$package' after retries" -Level Warning
                    }
                }
            }

            Write-Log "Package installation completed" -Level Success
        }
    }
    catch {
        Write-Log "Package installation failed: $_" -Level Error
        throw
    }
}

Function Set-RegistrySettings {
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
                & "$env:SystemRoot\System32\reg.exe" import $regFile
                
                if ($LASTEXITCODE -ne 0) {
                    Write-Log "    Registry import returned exit code $LASTEXITCODE" -Level Warning
                }
            } else {
                Write-Log "    Registry file not found: $regFile" -Level Warning
            }
        }
        
        # Set individual registry values
        foreach ($path in $RegistryValues.Keys) {
            $values = $RegistryValues[$path]
            
            # Handle both single hash and array of hashes
            if ($values -is [array]) {
                foreach ($item in $values) {
                    $valueName = $item.Name
                    $value = $item.Value
                    $type = $item.Type
                    
                    Write-Log "  Setting: $path\$valueName = $value"
                    
                    try {
                        Set-ItemProperty -Path $path -Name $valueName -Value $value -Type $type -Force
                    }
                    catch {
                        Write-Log "    Failed to set registry value: $_" -Level Warning
                    }
                }
            } else {
                $valueName = $values.Name
                $value = $values.Value
                $type = $values.Type
                
                Write-Log "  Setting: $path\$valueName = $value"
                
                try {
                    Set-ItemProperty -Path $path -Name $valueName -Value $value -Type $type -Force
                }
                catch {
                    Write-Log "    Failed to set registry value: $_" -Level Warning
                }
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

Function Clear-DesktopIcons {
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
                Remove-Item $item.FullName -Force -Recurse -ErrorAction Continue
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



Function Uninstall-Microsoft365 {
    Write-Log "Uninstalling Microsoft 365..."

    $clickToRunKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

    # Helper: check if Office is still present
    function Test-OfficeStillInstalled {
        if (-not (Test-Path $clickToRunKey)) { return $false }
        $ids = (Get-ItemProperty -Path $clickToRunKey -Name ProductReleaseIds -ErrorAction SilentlyContinue).ProductReleaseIds
        return (-not [string]::IsNullOrWhiteSpace($ids))
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 not detected - skipping" -Level Info
        return
    }

    # Pass 1: winget (fast, handles modern Click-to-Run and locale variants)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Log "Attempting Office removal via winget..." -Level Info
        $null = & winget source update --disable-interactivity 2>&1

        $officeNames = @('Microsoft 365', 'Microsoft Office 365', 'Microsoft Office')

        try {
            $wingetListOutput = & winget list --name "Microsoft 365 - " --accept-source-agreements --source winget 2>&1
            $detectedNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($line in $wingetListOutput) {
                if ($line -match '^\s*(Microsoft 365\s*-\s*[A-Za-z]{2,3}-[A-Za-z]{2,3})\s{2,}') {
                    $null = $detectedNames.Add($Matches[1].Trim())
                }
            }
            foreach ($n in $detectedNames) { if ($n -notin $officeNames) { $officeNames += $n } }
        }
        catch {
            Write-Log "Could not enumerate Microsoft 365 language variants: $_" -Level Warning
        }

        foreach ($officeName in $officeNames) {
            $null = & winget uninstall --name $officeName --silent --disable-interactivity --accept-source-agreements --all-versions 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  Removed '$officeName' via winget" -Level Success
            }
        }
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 removed successfully" -Level Success
        return
    }

    # Pass 2: registry uninstall string
    if (Test-OfficeStillInstalled) {
        Write-Log "Attempting registry-based Office uninstall..." -Level Warning
        $regPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $officeEntries = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like '*Microsoft 365*' -or $_.DisplayName -like '*Microsoft Office*' }
        foreach ($entry in $officeEntries) {
            $uninst = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
            if ($uninst) {
                Write-Log "  Running uninstaller for '$($entry.DisplayName)'"
                try {
                    if ($uninst -match '(?i)msiexec') {
                        $guid = [regex]::Match($uninst, '\{[^}]+\}').Value
                        $null = & msiexec.exe /x $guid /quiet /norestart 2>&1
                    } else {
                        $null = & cmd /c "$uninst" 2>&1
                    }
                } catch {
                    Write-Log "  Uninstaller failed for '$($entry.DisplayName)': $_" -Level Warning
                }
            }
        }
    }

    if (Test-OfficeStillInstalled) {
        Write-Log "Microsoft 365 may still be partially installed - manual removal may be needed" -Level Warning
    } else {
        Write-Log "Microsoft 365 removed successfully" -Level Success
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    # Step 1: Install package managers
    Write-Log "Step 1: Installing package managers (5%)"
    Install-PackageManager -Manager chocolatey

    # Step 2: Install software packages
    Write-Log "Step 2: Installing software packages (20%)"
    Install-Packages -PackageList $deploymentConfig.packages -Manager chocolatey

    # Step 3: Install GPU drivers if applicable
    if ($gpuInfo.IsNvidia) {
        Write-Log "Step 3a: Installing NVIDIA drivers (30%)"
        Install-Packages -PackageList @('nvidia-app') -Manager chocolatey
    }
    elseif ($gpuInfo.IsAmd) {
        Write-Log "Step 3a: Installing AMD drivers (30%)"
        try {
            winget install --id AMD.AdrenalinEdition --silent --accept-package-agreements --accept-source-agreements --source winget
            if ($LASTEXITCODE -ne 0) {
                Write-Log "AMD Radeon Software install returned exit code $LASTEXITCODE" -Level Warning
            } else {
                Write-Log "AMD Radeon Software installed" -Level Success
            }
        }
        catch {
            Write-Log "AMD Radeon Software installation failed: $_" -Level Warning
        }
    }
    elseif ($gpuInfo.IsIntel) {
        Write-Log "Step 3a: Installing Intel Graphics drivers (30%)"
        try {
            # Chocolatey's intel-graphics-driver package downloads from Intel's CDN which often returns 403.
            # Use winget instead, which resolves directly via the official Intel store entry.
            winget install --id Intel.GraphicsCommand --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Intel Graphics driver install returned exit code $LASTEXITCODE" -Level Warning
            } else {
                Write-Log "Intel Graphics driver installed" -Level Success
            }
        }
        catch {
            Write-Log "Intel Graphics driver installation failed: $_" -Level Warning
        }
    }
    
    # Step 4: Apply registry settings
    Write-Log "Step 4: Applying registry settings (40%)"
    $registryFiles = @()
    if ($deploymentConfig.branded) {
        $registryFiles += "$PSScriptRoot\Logo_Info.reg"
    }
    $registryFiles += "$PSScriptRoot\icons.reg"
    
    $registryValues = @{
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' = @(
            @{
                Name = 'SystemUsesLightTheme'
                Value = 0
                Type = 'DWord'
            },
            @{
                Name = 'AppsUseLightTheme'
                Value = 1
                Type = 'DWord'
            }
        )
    }
    
    Set-RegistrySettings -RegistryFiles $registryFiles -RegistryValues $registryValues
    
    # Step 5: Remove bloatware shortcuts
    if (-not $SkipBloatwareRemoval) {
        Write-Log "Step 5: Removing bloatware (50%)"
        Remove-BloatwareShortcuts -ShortcutPaths $script:config.windows.shortcuts
        Clear-DesktopIcons -WhitelistPath "$PSScriptRoot\whitelist.txt"
    }
    
    # Step 6: Disable BitLocker if needed
    if ($bitlockerStatus.IsEncrypted) {
        Write-Log "Step 6: Disabling BitLocker (60%)"
        try {
            Disable-BitLocker -MountPoint "C:"
            Write-Log "BitLocker disabled" -Level Success
        }
        catch {
            Write-Log "BitLocker disable failed: $_" -Level Warning
        }
    }
    
    # Step 7: Copy files to installation folder
    Write-Log "Step 7: Setting up installation folder (70%)"
    $installFolder = $script:config.paths.installFolder
    if (-not (Test-Path $installFolder)) {
        $null = New-Item -Path $installFolder -ItemType Directory -Force
        Write-Log "Created installation folder: $installFolder"
    }
    
    if ($deploymentConfig.branded) {
        if (Test-Path "$PSScriptRoot\oemlogo.bmp") {
            Copy-Item "$PSScriptRoot\oemlogo.bmp" "C:\Windows\System32" -Force
            Write-Log "Copied OEM logo"
        }
        try {
            Write-Log "Downloading Netixx Helpdesk..."
            # 898.tv serves a TeamViewer QuickSupport page; the actual exe URL is a
            # time-limited signed Azure Blob obtained by calling the API the page uses.
            $apiBody = '{"ConfigId":"6ie5cnr","Version":"15","IsCustomModule":true,"Subdomain":"1","ConnectionId":""}'
            $signedUrl = Invoke-RestMethod -Uri "https://www.898.tv/api/CustomDesign" -Method Post `
                -ContentType "application/json; charset=utf-8" -Body $apiBody `
                -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            $helpdeskDest = "$installFolder\Netixx Helpdesk.exe"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($signedUrl, $helpdeskDest)
            New-Item -Path "$env:PUBLIC\Desktop\Netixx Helpdesk" -ItemType SymbolicLink -Value $helpdeskDest -Force -ErrorAction Continue
            Write-Log "Installed HelpDesk application" -Level Success
        } catch {
            Write-Log "HelpDesk download failed: $_" -Level Warning
        }
    }
    
    # Step 9: Uninstall Office
    Write-Log "Step 9: Uninstalling Office (80%)"
    Uninstall-Microsoft365
    
    # Step 10: Run debloat script
    Write-Log "Step 10: Running debloat script (90%)"
    if (Test-Path "$PSScriptRoot\debloat.ps1") {
        try {
            & "$PSScriptRoot\debloat.ps1"
        }
        catch {
            Write-Log "Debloat script failed: $_" -Level Warning
        }
    }
    
    # Re-apply OEM branding after debloat — Lenovo/HP/Dell services can reset
    # OEMInformation while their software is still running during earlier steps.
    if ($deploymentConfig.branded) {
        $brandingReg = "$PSScriptRoot\Logo_Info.reg"
        if (Test-Path $brandingReg) {
            Write-Log "Re-applying OEM branding registry..."
            try {
                $null = & "$env:SystemRoot\System32\reg.exe" import "$brandingReg" 2>&1
                Write-Log "OEM branding applied" -Level Success
            } catch {
                Write-Log "OEM branding registry warning: $_" -Level Warning
            }
        }
    }

    # Step 11: Set default file associations
    Write-Log "Step 11: Setting default associations (95%)"
    if (Test-Path "$PSScriptRoot\SetUserFTA.exe") {
        try {
            $loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
            if (-not $loggedInUser) {
                Write-Log "  No interactive user detected - skipping file associations" -Level Warning
            } else {
                Write-Log "  Running SetUserFTA as $loggedInUser via scheduled task..."
                $taskName  = "GKScript-SetFileAssoc"
                $action    = New-ScheduledTaskAction -Execute "$PSScriptRoot\SetUserFTA.exe" `
                                 -Argument "`"$PSScriptRoot\assoc.txt`""
                $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
                $principal = New-ScheduledTaskPrincipal -UserId $loggedInUser `
                                 -LogonType Interactive -RunLevel Limited

                Register-ScheduledTask -TaskName $taskName -Action $action `
                    -Settings $settings -Principal $principal -Force | Out-Null
                Start-ScheduledTask -TaskName $taskName

                $deadline = [datetime]::UtcNow.AddSeconds(30)
                while ((Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State -ne 'Ready') {
                    if ([datetime]::UtcNow -gt $deadline) {
                        Write-Log "  File association task timed out" -Level Warning
                        break
                    }
                    Start-Sleep -Milliseconds 500
                }

                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                Write-Log "  File associations set" -Level Success
            }
        }
        catch {
            Write-Log "Set file associations failed: $_" -Level Warning
        }
    }
    
    Write-Log "=== Setup Completed Successfully ===" -Level Success
    Write-Log "Log file: $($script:LogFile)"

    [System.Windows.Forms.MessageBox]::Show("Setup completed successfully!`nLog file: $($script:LogFile)", "Setup Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

    # Final: Stop Explorer, write icon layout to registry, then restart Explorer.
    # The registry write MUST happen while Explorer is dead - otherwise Explorer
    # overwrites IconLayouts with the current layout on shutdown.
    Write-Log "Finalizing... (98%)"
    try {
        # Prevent Windows from auto-restarting Explorer after we kill it
        $explorerKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $originalShell = (Get-ItemProperty -Path $explorerKey -Name Shell -ErrorAction SilentlyContinue).Shell
        Set-ItemProperty -Path $explorerKey -Name Shell -Value '' -Force

        # Wait-Process is unreliable if Win11 auto-restarts Explorer before we write the registry.
        Stop-ProcessWithTimeout -Name 'explorer' -TimeoutSeconds 15

        $desktopRegFile = if ($deploymentConfig.packages -contains "libreoffice") {
            "$PSScriptRoot\desktop_libreoffice.reg"
        } else {
            "$PSScriptRoot\desktop.reg"
        }
        if (Test-Path $desktopRegFile) {
            Write-Log "Applying desktop icon layout ($desktopRegFile)..."
            Set-RegistrySettings -RegistryFiles @($desktopRegFile) -RegistryValues @{}
            Write-Log "Desktop icon layout applied" -Level Success
        } else {
            Write-Log "Desktop reg file not found: $desktopRegFile" -Level Warning
        }

        # Restore shell value so Explorer starts normally and reads the new layout
        if ($originalShell) {
            Set-ItemProperty -Path $explorerKey -Name Shell -Value $originalShell -Force
        } else {
            Set-ItemProperty -Path $explorerKey -Name Shell -Value 'explorer.exe' -Force
        }

        # Start Explorer as the logged-in user (not elevated) so it properly becomes the shell.
        # Start-Process from an admin session would launch it elevated, which Windows rejects as shell.
        $shellUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if ($shellUser) {
            $explorerAction    = New-ScheduledTaskAction -Execute 'C:\Windows\explorer.exe'
            $explorerPrincipal = New-ScheduledTaskPrincipal -UserId $shellUser -LogonType Interactive -RunLevel Limited
            $explorerSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1)
            Register-ScheduledTask -TaskName 'GKScript-StartExplorer' -Action $explorerAction `
                -Settings $explorerSettings -Principal $explorerPrincipal -Force | Out-Null
            Start-ScheduledTask -TaskName 'GKScript-StartExplorer'
            Start-Sleep -Seconds 2
            Unregister-ScheduledTask -TaskName 'GKScript-StartExplorer' -Confirm:$false -ErrorAction SilentlyContinue
        } else {
            Start-Process explorer.exe
        }
    }
    catch {
        Write-Log "Explorer restart failed: $_" -Level Warning
    }
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

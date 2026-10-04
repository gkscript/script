param(
    [Parameter(Mandatory)]
    [ValidateSet('business', 'consumer', 'consumer-nolo')]
    [string]$DeploymentType,
    
    [Parameter()]
    [switch]$SkipBloatwareRemoval,
    
    [Parameter()]
    [switch]$SkipHideConsole,
    
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\config.json",

    # UI language of the result window (the log stays English); the menu passes its choice
    [Parameter()]
    [ValidateSet('de', 'en', 'it')]
    [string]$Language = 'de'
)

# Stop on first error
$ErrorActionPreference = 'Stop'

# Import utility functions
Import-Module "$PSScriptRoot\lib\PSSetupUtility.psm1" -Force
Set-UiLanguage $Language

$script:StartTime = Get-Date
$script:CurrentStep = 'start'
Set-KeepAwake -Enable   # released in the final 'finally' block (or when the process exits)

# Subline for the result window: profile, machine, elapsed time
Function Get-RunSummary {
    $minutes = [int][math]::Floor(((Get-Date) - $script:StartTime).TotalMinutes)
    $duration = if ($minutes -lt 1) { Get-UiText duration.lessThanMinute } else { Get-UiText duration.minutes $minutes }
    $profileName = Get-UiText "profile.$DeploymentType"
    return ($profileName, $env:COMPUTERNAME, $duration) -join " $([char]0xB7) "
}

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
    # The console closes on exit, so this window is the only thing left on screen
    Show-SetupResult -Status Failed -Title (Get-UiText result.notStarted.title) -Subtitle (Get-UiText result.nothingChanged) `
        -Items @((Get-UiText preflight.config $ConfigPath), "$_")
    exit 1
}

# Initialize logging using path from config
# The module keeps its own $script:LogFile; capture the path here so main.ps1 can show it
$script:LogFile = Initialize-Logging -logPath $script:config.logging.logPath
$script:Version = (Get-Content "$PSScriptRoot\version.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s'
Write-Log "=== PSScript Setup Starting (v$script:Version) ===" -Level Success
Write-Log "Deployment Type: $DeploymentType"
Write-Log "Config Path: $ConfigPath"
Write-Log "Configuration loaded successfully"
Write-Log "Available deployment types: $($script:config.deployment.Keys -join ', ')"

# Pre-flight checks
try {
    Write-Log "Running pre-flight checks..."
    # Remembered so the result window can explain a failure in the UI language
    $preflightCheck = 'admin'
    Test-PrerequisiteAdmin
    $preflightCheck = 'internet'
    Test-PrerequisiteInternet
    $preflightCheck = 'other'
    Sync-SystemTimeWithInternet
    $preflightCheck = 'disk'
    Test-PrerequisiteDiskSpace -requiredBytes $script:config.validation.minDiskSpace
    $preflightCheck = 'other'
    
    $gpuInfo = Get-SystemGPU
    $bitlockerStatus = Get-BitlockerStatus
    
    Write-Log "All pre-flight checks passed" -Level Success
}
catch {
    Write-Log "Pre-flight checks failed: $_" -Level Error
    $reason = switch ($preflightCheck) {
        'admin'    { Get-UiText preflight.admin }
        'internet' { Get-UiText preflight.internet }
        'disk'     {
            $freeGb = try { '{0:N1}' -f ((Get-Volume -DriveLetter $env:SystemDrive[0]).SizeRemaining / 1GB) } catch { '?' }
            Get-UiText preflight.disk @($freeGb, ('{0:N0}' -f ($script:config.validation.minDiskSpace / 1GB)))
        }
        default    { Get-UiText preflight.other "$_" }
    }
    Show-SetupResult -Status Failed -Title (Get-UiText result.notStarted.title) -Subtitle (Get-UiText result.nothingChanged) `
        -Items @($reason) -LogFile $script:LogFile
    exit 1
}

# Get deployment configuration
$deploymentConfig = $script:config.deployment[$DeploymentType]
if (-not $deploymentConfig) {
    Write-Log "Invalid deployment type: $DeploymentType" -Level Error
    Show-SetupResult -Status Failed -Title (Get-UiText result.notStarted.title) -Subtitle (Get-UiText result.nothingChanged) `
        -Items @(Get-UiText preflight.badProfile $DeploymentType) -LogFile $script:LogFile
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
        Write-Log "Failed to install $Manager : $_" -Level Error -Key warn.chocoFailed -KeyArgs "$_"
        throw
    }
}

$script:PackageDisplayNames = @{
    'googlechrome'       = 'Google Chrome'
    'nvidia-app'         = 'NVIDIA App'
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
    # Prefix match: a substring match lets unrelated entries count as installed
    # (e.g. 'NVIDIA PhysX' satisfying 'NVIDIA App')
    $found = Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "$displayName*" } |
        Select-Object -First 1
    if ($found) {
        Write-Log "  $PackageName found in system as '$($found.DisplayName) $($found.DisplayVersion)'" -Level Info
        return $true
    }
    return $false
}

Function Wait-MsiIdle {
    <#
    .SYNOPSIS
        Wait until no Windows Installer transaction holds the global _MSIExecute mutex
    #>
    param([int]$TimeoutSeconds = 120)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([datetime]::UtcNow -lt $deadline) {
        try {
            $mutex = [System.Threading.Mutex]::OpenExisting('Global\_MSIExecute')
            $mutex.Dispose()
            Start-Sleep -Seconds 2
        }
        catch [System.Threading.WaitHandleCannotBeOpenedException] {
            return $true
        }
        catch {
            # Mutex exists but can't be opened (e.g. access denied) - still busy
            Start-Sleep -Seconds 2
        }
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
            $null = Invoke-NativeCommand choco @('feature', 'enable', '-n', 'allowGlobalConfirmation')

            foreach ($package in $PackageList) {
                # Pre-check: already tracked by choco
                $preCheck = Invoke-NativeCommand choco @('list', '--local-only', '--exact', $package, '--limit-output')
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
                    # Touch the handle now: without it, Start-Process -PassThru often reports
                    # ExitCode as $null once the process has exited
                    $null = $proc.Handle
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
                                Write-Log "    $package installer running for 5 min - terminating" -Level Info
                                $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
                                Write-Log "    taskkill exit: $LASTEXITCODE" -Level Info
                                $killedEarly = $true
                                # msiexec runs outside choco's process tree; wait for it to release
                                # the installer mutex so the next attempt/package doesn't fail with 1618
                                if (-not (Wait-MsiIdle -TimeoutSeconds 120)) {
                                    Write-Log "    Windows Installer still busy after 2 min" -Level Warning -Key warn.msiBusy
                                }
                                break
                            }
                        }
                        while ($null -ne ($line = $sr.ReadLine())) { . $writeChocoLine }
                    } finally {
                        $sr.Dispose()
                        $fs.Dispose()
                        Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
                    }
                    # A killed installer has no meaningful exit code; only choco tracking can confirm it
                    $chocoExit = if ($killedEarly) { $null } else { $proc.ExitCode }

                    # Verify via choco tracking (--limit-output gives clean name|version format)
                    $localPackage = Invoke-NativeCommand choco @('list', '--local-only', '--exact', $package, '--limit-output')
                    if ($localPackage -match "(?m)^$([regex]::Escape($package))\|") {
                        $installed = $true
                        Write-Log "    Installed: $package" -Level Success
                        break
                    }

                    # Exit 0/1641/3010 = success or reboot-pending; choco may have skipped an
                    # externally-installed package without adding it to its tracking DB
                    if ($null -ne $chocoExit -and $chocoExit -in @(0, 1641, 3010)) {
                        $installed = $true
                        Write-Log "    Installed: $package" -Level Success
                        break
                    }

                    Write-Log "    Package install not confirmed for '$package'" -Level Info
                    if ($attempt -lt $maxAttempts) { Start-Sleep -Seconds 3 }
                }

                if (-not $installed -and $package -eq 'googlechrome') {
                    Write-Log "  Falling back to winget for Google Chrome..." -Level Info
                    if (Get-Command winget -ErrorAction SilentlyContinue) {
                        Write-Log "    Resetting winget sources..." -Level Info
                        $null = Invoke-NativeCommand winget @('source', 'reset', '--force')
                        $null = Invoke-NativeCommand winget @('source', 'update', '--disable-interactivity')
                        Invoke-NativeCommand winget @('install', '--id', 'Google.Chrome', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--source', 'winget') | Write-Host
                        if ($LASTEXITCODE -eq 0) {
                            $installed = $true
                            Write-Log "    Installed googlechrome via winget fallback" -Level Success
                        }
                        else {
                            Write-Log "    Winget fallback failed for googlechrome (exit code $LASTEXITCODE)" -Level Info
                        }
                    }
                    else {
                        Write-Log "    Winget not available for googlechrome fallback" -Level Info
                    }
                }

                if (-not $installed) {
                    if (Test-PackageInstalledInRegistry -PackageName $package) {
                        $installed = $true
                    } else {
                        Write-Log "    Failed to install '$package' after retries" -Level Warning -Key warn.pkgFailed -KeyArgs $package
                    }
                }
            }

            Write-Log "Package installation completed" -Level Success
        }
    }
    catch {
        Write-Log "Package installation failed: $_" -Level Error -Key warn.pkgFatal -KeyArgs "$_"
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
                    Write-Log "    Registry import returned exit code $LASTEXITCODE" -Level Warning -Key warn.regImport -KeyArgs (Split-Path $regFile -Leaf), $LASTEXITCODE
                }
            } else {
                Write-Log "    Registry file not found: $regFile" -Level Warning -Key warn.regMissing -KeyArgs (Split-Path $regFile -Leaf)
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
                        Write-Log "    Failed to set registry value: $_" -Level Warning -Key warn.regValue -KeyArgs "$path\$valueName"
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
                    Write-Log "    Failed to set registry value: $_" -Level Warning -Key warn.regValue -KeyArgs "$path\$valueName"
                }
            }
        }
        
        Write-Log "Registry settings applied" -Level Success
    }
    catch {
        Write-Log "Registry settings failed: $_" -Level Error -Key warn.regFatal -KeyArgs "$_"
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
        Write-Log "Bloatware removal failed: $_" -Level Error -Key warn.bloatFatal -KeyArgs "$_"
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
            Write-Log "Whitelist not found: $WhitelistPath" -Level Warning -Key warn.whitelistMissing -KeyArgs $WhitelistPath
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
        Write-Log "Desktop cleanup failed: $_" -Level Error -Key warn.desktopFatal -KeyArgs "$_"
        throw
    }
}



Function Uninstall-Microsoft365 {
    Write-Log "Uninstalling Microsoft 365..."

    $clickToRunKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    function Get-OfficeUninstallEntries {
        Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^(Microsoft 365|Microsoft Office)' -and -not $_.SystemComponent }
    }

    # Covers Click-to-Run (ProductReleaseIds) and MSI-based Office (uninstall entries)
    function Test-OfficeStillInstalled {
        if (Test-Path $clickToRunKey) {
            $ids = (Get-ItemProperty -Path $clickToRunKey -Name ProductReleaseIds -ErrorAction SilentlyContinue).ProductReleaseIds
            if (-not [string]::IsNullOrWhiteSpace($ids)) { return $true }
        }
        return [bool](Get-OfficeUninstallEntries)
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 not detected - skipping" -Level Info
        return
    }

    # Pass 1: Office Deployment Tool - silent by design (Display Level=None), removes
    # every Click-to-Run product/language and MSI Office in one go
    $odtPath = Join-Path $PSScriptRoot "OfficeSetup.exe"
    $odtXml  = Join-Path $PSScriptRoot "office.xml"
    if ((Test-Path $odtPath -PathType Leaf) -and (Test-Path $odtXml -PathType Leaf)) {
        Write-Log "Attempting Office removal via Office Deployment Tool..." -Level Info
        try {
            $odt = Start-Process -FilePath $odtPath -ArgumentList @('/configure', "`"$odtXml`"") -NoNewWindow -PassThru
            $null = $odt.Handle
            if ($odt.WaitForExit(20 * 60 * 1000)) {
                Write-Log "  Office Deployment Tool exit code: $($odt.ExitCode)"
            } else {
                Write-Log "  Office Deployment Tool still running after 20 min - continuing" -Level Info
            }
        }
        catch {
            Write-Log "  Office Deployment Tool failed: $_" -Level Info
        }
    } else {
        Write-Log "  OfficeSetup.exe or office.xml missing - skipping ODT removal" -Level Info
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 removed successfully" -Level Success
        return
    }

    # Pass 2: winget (handles locale variants by display name)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Log "Attempting Office removal via winget..." -Level Info
        $null = Invoke-NativeCommand winget @('source', 'update', '--disable-interactivity')

        $officeNames = @('Microsoft 365', 'Microsoft Office 365', 'Microsoft Office')

        $wingetListOutput = Invoke-NativeCommand winget @('list', '--name', 'Microsoft 365 - ', '--accept-source-agreements', '--source', 'winget')
        foreach ($line in $wingetListOutput) {
            if ($line -match '^\s*(Microsoft 365\s*-\s*[A-Za-z]{2,3}-[A-Za-z]{2,3})\s{2,}') {
                $variant = $Matches[1].Trim()
                if ($variant -notin $officeNames) { $officeNames += $variant }
            }
        }

        foreach ($officeName in $officeNames) {
            $null = Invoke-NativeCommand winget @('uninstall', '--name', $officeName, '--silent', '--disable-interactivity', '--accept-source-agreements', '--all-versions')
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  Removed '$officeName' via winget" -Level Success
            }
        }
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 removed successfully" -Level Success
        return
    }

    # Pass 3: registry uninstall strings - only ever run silently. A bare Click-to-Run
    # UninstallString opens Office's interactive wizard and would block the unattended run.
    Write-Log "Attempting registry-based Office uninstall..." -Level Info
    foreach ($entry in Get-OfficeUninstallEntries) {
        $uninst = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
        if (-not $uninst) { continue }
        try {
            if ($uninst -match '(?i)msiexec') {
                $guid = [regex]::Match($uninst, '\{[^}]+\}').Value
                if (-not $guid) { continue }
                Write-Log "  Running msiexec /x for '$($entry.DisplayName)'"
                $null = Invoke-NativeCommand msiexec.exe @('/x', $guid, '/quiet', '/norestart')
            }
            elseif ($uninst -match '(?i)OfficeClickToRun\.exe') {
                Write-Log "  Running silent Click-to-Run removal for '$($entry.DisplayName)'"
                $silent = if ($uninst -match '(?i)DisplayLevel=') { $uninst } else { "$uninst DisplayLevel=False" }
                $null = Invoke-NativeCommand cmd.exe @('/c', $silent)
            }
            else {
                Write-Log "  No silent uninstall available for '$($entry.DisplayName)' - skipped" -Level Info
            }
        }
        catch {
            Write-Log "  Uninstaller failed for '$($entry.DisplayName)': $_" -Level Info
        }
    }

    if (Test-OfficeStillInstalled) {
        Write-Log "Microsoft 365 may still be partially installed - manual removal may be needed" -Level Warning -Key warn.officeRemains
    } else {
        Write-Log "Microsoft 365 removed successfully" -Level Success
    }
}

Function Install-WindowsUpdateDrivers {
    <#
    .SYNOPSIS
        Install all pending driver updates from Windows Update (GPU, chipset, etc.)
    .DESCRIPTION
        Uses the built-in Windows Update Agent COM API - no extra modules. Microsoft-signed
        WHQL drivers; covers AMD, for which no winget/Chocolatey package exists.
    #>
    Write-Log "Searching Windows Update for driver updates..."
    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $found    = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0").Updates

        $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
        foreach ($update in $found) {
            # Anything that may prompt would block the unattended run
            if ($update.InstallationBehavior.CanRequestUserInput) {
                Write-Log "  Skipping (needs user input): $($update.Title)"
                continue
            }
            if (-not $update.EulaAccepted) { $update.AcceptEula() }
            Write-Log "  Found: $($update.Title)"
            $null = $toInstall.Add($update)
        }

        if ($toInstall.Count -eq 0) {
            Write-Log "No driver updates available" -Level Success
            return
        }

        Write-Log "Downloading $($toInstall.Count) driver update(s)..."
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $toInstall
        $null = $downloader.Download()

        Write-Log "Installing $($toInstall.Count) driver update(s)..."
        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $toInstall
        $result = $installer.Install()

        # OperationResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
        $failed = 0
        for ($i = 0; $i -lt $toInstall.Count; $i++) {
            $code = $result.GetUpdateResult($i).ResultCode
            if ($code -eq 2) {
                Write-Log "  Installed: $($toInstall.Item($i).Title)" -Level Success
            } else {
                $failed++
                Write-Log "  Driver update failed (result $code): $($toInstall.Item($i).Title)" -Level Warning -Key warn.driverFailed -KeyArgs $code, $toInstall.Item($i).Title
            }
        }
        if ($result.RebootRequired) {
            $script:RebootRequired = $true
            Write-Log "Driver updates need a reboot to finish"
        }
        Write-Log "Driver updates done: $($toInstall.Count - $failed) installed, $failed failed"
    }
    catch {
        Write-Log "Windows Update driver install failed: $_" -Level Warning -Key warn.driversError -KeyArgs "$_"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    # Step 1: Install package managers
    Write-Log "Step 1: Installing package managers (5%)"
    $script:CurrentStep = 'packageManager'
    Install-PackageManager -Manager chocolatey

    # Step 2: Install software packages
    Write-Log "Step 2: Installing software packages (20%)"
    $script:CurrentStep = 'packages'
    Install-Packages -PackageList $deploymentConfig.packages -Manager chocolatey

    # Step 3: Install GPU drivers if applicable
    if ($gpuInfo.IsNvidia) {
        Write-Log "Step 3a: Installing NVIDIA drivers (30%)"
        $script:CurrentStep = 'gpu'
        Install-Packages -PackageList @('nvidia-app') -Manager chocolatey
    }
    elseif ($gpuInfo.IsAmd) {
        # No unattended AMD Adrenalin package exists in winget, Chocolatey or the Store
        # (AMD.AdrenalinEdition / amd-radeon-software do not exist) - Step 3b covers it.
        Write-Log "Step 3a: AMD GPU detected ($($gpuInfo.Name)) - driver comes from Windows Update (Step 3b)"
    }
    elseif ($gpuInfo.IsIntel) {
        Write-Log "Step 3a: Installing Intel Graphics drivers (30%)"
        $script:CurrentStep = 'gpu'
        try {
            # Chocolatey's intel-graphics-driver package downloads from Intel's CDN which often returns 403.
            # Use winget instead, which resolves directly via the official Intel store entry.
            winget install --id Intel.GraphicsCommand --silent --accept-package-agreements --accept-source-agreements
            if ($LASTEXITCODE -ne 0) {
                Write-Log "Intel Graphics driver install returned exit code $LASTEXITCODE" -Level Warning -Key warn.intelExit -KeyArgs $LASTEXITCODE
            } else {
                Write-Log "Intel Graphics driver installed" -Level Success
            }
        }
        catch {
            Write-Log "Intel Graphics driver installation failed: $_" -Level Warning -Key warn.intelFailed -KeyArgs "$_"
        }
    }

    # Step 3b: All pending drivers from Windows Update (GPU incl. AMD, chipset, etc.)
    Write-Log "Step 3b: Installing driver updates from Windows Update (35%)"
    $script:CurrentStep = 'drivers'
    Install-WindowsUpdateDrivers
    
    # Step 4: Apply registry settings
    Write-Log "Step 4: Applying registry settings (40%)"
    $script:CurrentStep = 'registry'
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
        $script:CurrentStep = 'bloat'
        Remove-BloatwareShortcuts -ShortcutPaths $script:config.windows.shortcuts
        Clear-DesktopIcons -WhitelistPath "$PSScriptRoot\whitelist.txt"
    }
    
    # Step 6: Disable BitLocker if needed
    if ($bitlockerStatus.IsEncrypted) {
        Write-Log "Step 6: Disabling BitLocker (60%)"
        $script:CurrentStep = 'bitlocker'
        try {
            Disable-BitLocker -MountPoint "C:"
            Write-Log "BitLocker disabled" -Level Success
        }
        catch {
            Write-Log "BitLocker disable failed: $_" -Level Warning -Key warn.bitlocker -KeyArgs "$_"
        }
    }
    
    # Step 7: Copy files to installation folder
    Write-Log "Step 7: Setting up installation folder (70%)"
    $script:CurrentStep = 'install'
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
            if (-not ($signedUrl -is [string] -and $signedUrl -like 'https://*')) {
                throw "Unexpected response from 898.tv API (API may have changed): $signedUrl"
            }
            $helpdeskDest = "$installFolder\Netixx Helpdesk.exe"
            $wc = New-Object System.Net.WebClient
            $wc.DownloadFile($signedUrl, $helpdeskDest)
            # The URL comes from an undocumented API - only publish the exe if it is
            # genuinely TeamViewer-signed
            $sig = Get-AuthenticodeSignature $helpdeskDest
            if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=TeamViewer ') {
                Remove-Item $helpdeskDest -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed signature check (status: $($sig.Status), signer: $($sig.SignerCertificate.Subject)) - deleted"
            }
            New-Item -Path "$env:PUBLIC\Desktop\Netixx Helpdesk" -ItemType SymbolicLink -Value $helpdeskDest -Force -ErrorAction Continue
            Write-Log "Installed HelpDesk application" -Level Success
        } catch {
            Write-Log "HelpDesk download failed: $_" -Level Warning -Key warn.helpdesk -KeyArgs "$_"
        }
    }
    
    # Step 9: Uninstall Office
    Write-Log "Step 9: Uninstalling Office (80%)"
    $script:CurrentStep = 'office'
    Uninstall-Microsoft365
    
    # Step 10: Run debloat script
    Write-Log "Step 10: Running debloat script (90%)"
    $script:CurrentStep = 'debloat'
    if (Test-Path "$PSScriptRoot\debloat.ps1") {
        try {
            & "$PSScriptRoot\debloat.ps1"
        }
        catch {
            Write-Log "Debloat script failed: $_" -Level Warning -Key warn.debloat -KeyArgs "$_"
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
                Write-Log "OEM branding registry warning: $_" -Level Warning -Key warn.branding -KeyArgs "$_"
            }
        }
    }

    # Step 11: Set default file associations
    Write-Log "Step 11: Setting default associations (95%)"
    $script:CurrentStep = 'fta'
    if (Test-Path "$PSScriptRoot\SetUserFTA.exe") {
        try {
            $loggedInUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
            if (-not $loggedInUser) {
                Write-Log "  No interactive user detected - skipping file associations" -Level Warning -Key warn.ftaNoUser
            } else {
                # The script folder lives in the elevated account's %TEMP%, which the
                # logged-in user may not be able to read - run from C:\Install instead
                $ftaExe  = Join-Path $installFolder 'SetUserFTA.exe'
                $ftaList = Join-Path $installFolder 'assoc.txt'
                Copy-Item "$PSScriptRoot\SetUserFTA.exe" $ftaExe -Force
                Copy-Item "$PSScriptRoot\assoc.txt" $ftaList -Force

                Write-Log "  Running SetUserFTA as $loggedInUser via scheduled task..."
                $taskName  = "GKScript-SetFileAssoc"
                $action    = New-ScheduledTaskAction -Execute $ftaExe -Argument "`"$ftaList`""
                $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -Priority 4
                $principal = New-ScheduledTaskPrincipal -UserId $loggedInUser `
                                 -LogonType Interactive -RunLevel Limited

                Register-ScheduledTask -TaskName $taskName -Action $action `
                    -Settings $settings -Principal $principal -Force | Out-Null
                Start-ScheduledTask -TaskName $taskName

                # LastTaskResult 0x41303 = has not run yet, 0x41301 = still running. Checking
                # State alone races: it can still read 'Ready' before the task has started.
                $pending  = @(0x41303, 0x41301)
                $deadline = [datetime]::UtcNow.AddSeconds(60)
                do {
                    Start-Sleep -Milliseconds 500
                    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                    $state    = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
                    $done     = $taskInfo -and $state -eq 'Ready' -and $taskInfo.LastTaskResult -notin $pending
                } until ($done -or [datetime]::UtcNow -gt $deadline)

                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

                if (-not $done) {
                    Write-Log "File associations: SetUserFTA did not finish within 60 s" -Level Warning -Key warn.ftaTimeout
                } elseif ($taskInfo.LastTaskResult -ne 0) {
                    Write-Log ("File associations: SetUserFTA failed (exit code 0x{0:X})" -f $taskInfo.LastTaskResult) -Level Warning -Key warn.ftaExit -KeyArgs ('0x{0:X}' -f $taskInfo.LastTaskResult)
                } else {
                    Write-Log "  File associations set" -Level Success
                }
            }
        }
        catch {
            Write-Log "Set file associations failed: $_" -Level Warning -Key warn.ftaFailed -KeyArgs "$_"
        }
    }
    
    # Final: Stop Explorer, write icon layout to registry, then restart Explorer.
    # The registry write MUST happen while Explorer is dead - otherwise Explorer
    # overwrites IconLayouts with the current layout on shutdown.
    Write-Log "Finalizing... (98%)"
    $script:CurrentStep = 'finalize'
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
            Write-Log "Desktop reg file not found: $desktopRegFile" -Level Warning -Key warn.layoutMissing -KeyArgs (Split-Path $desktopRegFile -Leaf)
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
            $explorerSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -Priority 4
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
        Write-Log "Explorer restart failed: $_" -Level Warning -Key warn.explorer -KeyArgs "$_"
    }

    # Shown last: the technician has usually walked away, and a window before the
    # Explorer step would hold back the desktop layout until someone clicks
    $issues = Get-LogIssues
    if ($issues.Count -eq 0) {
        Write-Log "=== Setup Completed Successfully ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        Show-SetupResult -Status Success -Title (Get-UiText result.success.title) -Subtitle (Get-RunSummary) `
            -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired)
    } else {
        Write-Log "=== Setup Finished With $($issues.Count) Warning(s) ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        $warningTitle = if ($issues.Count -eq 1) { Get-UiText result.warning.title.one } else { Get-UiText result.warning.title.many $issues.Count }
        Show-SetupResult -Status Warning -Title $warningTitle -Subtitle (Get-RunSummary) `
            -Items $issues -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired)
    }
}
catch {
    # Collect earlier warnings before the failure lines below join the list
    # Plain assignment: Get-LogIssues returns one string[]; @() would nest it as a single item
    $earlier = Get-LogIssues
    $fatal = $_
    Write-Log "=== Setup Failed ===" -Level Error
    Write-Log "Error: $_" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
    Write-Log "Log file: $($script:LogFile)"

    # Which step stopped, then what was logged; the raw error only if no keyed line already explains it
    $items = @(Get-UiText failed.duringStep (Get-UiText "step.$script:CurrentStep")) + $earlier
    if (-not ($earlier | Where-Object { $_.Contains($fatal.Exception.Message) })) { $items += "$fatal" }
    Show-SetupResult -Status Failed -Title (Get-UiText result.failed.title) `
        -Subtitle "$(Get-RunSummary) $([char]0xB7) $(Get-UiText result.stoppedEarly)" `
        -Items $items -LogFile $script:LogFile

    exit 1
}
finally {
    Set-KeepAwake
    Write-Log "Setup script ended at $(Get-Date)"
}

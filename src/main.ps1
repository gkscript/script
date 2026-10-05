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
    [string]$Language = 'de',

    # No Windows Update and no app updates (menu: "install all updates" switched off)
    [Parameter()]
    [switch]$SkipUpdates
)

# gk-script.exe's NSIS stub is a 32-bit process, and everything it starts inherits that. A 32-bit
# PowerShell writes HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion (OEMInformation) and Winlogon
# to WOW6432Node, sees only 32-bit programs in the uninstall registry and gets the 32-bit DISM.
# launch.bat starts the 64-bit PowerShell; this catches any other 32-bit caller.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $relaunch = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    foreach ($parameter in $PSBoundParameters.GetEnumerator()) {
        if ($parameter.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($parameter.Value.IsPresent) { $relaunch += "-$($parameter.Key)" }
        } else {
            $relaunch += "-$($parameter.Key)", "`"$($parameter.Value)`""
        }
    }
    $native = Start-Process -FilePath "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $relaunch -NoNewWindow -Wait -PassThru
    exit $native.ExitCode
}

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
            $_.Value.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object {
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
    # 'Adobe Acrobat' also matches the 64-bit build, which registers as 'Adobe Acrobat (64-bit)'
    'adobereader'        = 'Adobe Acrobat'
    'libreoffice'        = 'LibreOffice'
    'libreoffice-still'  = 'LibreOffice'
    'paint.net'          = 'paint.net'
    'powertoys'          = 'PowerToys'
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
        [string]$Manager = 'chocolatey',

        # Package parameters passed as --params (e.g. Adobe's update mode)
        [string]$ChocoParams
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
                    if ($ChocoParams) { $chocoArgs += "--params=`"'$ChocoParams'`"" }

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
                $null = Invoke-NativeCommand "$env:SystemRoot\System32\reg.exe" @('import', $regFile)

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
        Remove desktop shortcuts that are not on the whitelist
    .DESCRIPTION
        Only shortcut files (.lnk/.url) are removed - never folders or documents, never
        recursively. Covers the Public Desktop (where installers put their shortcuts) and
        the user's desktop only while it is the local folder: with OneDrive backup it holds
        the customer's synced files, and deletions there would sync to the cloud.
        Whitelist entries may use wildcards (e.g. LibreOffice*.lnk).
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

        $whitelist = @(Get-Content $WhitelistPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
        $isWhitelisted = { param($name) [bool]($whitelist | Where-Object { $name -like $_ }) }

        $folders = @([Environment]::GetFolderPath('CommonDesktopDirectory'))
        $userDesktop = [Environment]::GetFolderPath('Desktop')
        $localDesktop = Join-Path $env:USERPROFILE 'Desktop'
        if ($userDesktop.TrimEnd('\') -ieq $localDesktop.TrimEnd('\')) {
            $folders += $userDesktop
        } else {
            Write-Log "  User desktop is redirected ($userDesktop) - left untouched"
        }

        $removedCount = 0
        foreach ($folder in $folders) {
            if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
            $shortcuts = Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.lnk', '.url' }
            foreach ($item in $shortcuts) {
                if (& $isWhitelisted $item.Name) { continue }
                Write-Log "  Removing: $($item.FullName)"
                Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Continue
                $removedCount++
            }
        }

        Write-Log "Removed $removedCount desktop shortcuts" -Level Success
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

Function Install-WindowsUpdates {
    <#
    .SYNOPSIS
        Install every available Windows update: drivers, security/quality updates, optional
        and preview updates, feature upgrades, Defender definitions
    .DESCRIPTION
        Uses the built-in Windows Update Agent COM API - no extra modules. OEM images are
        often months behind, so a new PC gets everything Windows Update offers before it goes
        to the customer - including optional updates (BrowseOnly=1: optional drivers, preview
        cumulative updates, .NET previews) and feature upgrades. A feature upgrade is staged
        here and completes during the restart at the end. Skipped: anything that may prompt.
        Up to three passes, because some updates are only offered once others are installed;
        stops early when a reboot is required, since further updates usually wait for it.
    #>
    $criteria = @(
        "IsInstalled=0 and IsHidden=0 and Type='Driver'",
        "IsInstalled=0 and IsHidden=0 and Type='Software'"
    )

    try {
        $session  = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $totalInstalled = 0
        $totalFailed = 0

        for ($pass = 1; $pass -le 3; $pass++) {
            Write-Log "Searching Windows Update (pass $pass)..."
            $toInstall = New-Object -ComObject Microsoft.Update.UpdateColl
            $seen = @{}
            foreach ($query in $criteria) {
                foreach ($update in $searcher.Search($query).Updates) {
                    $id = $update.Identity.UpdateID
                    if ($seen.ContainsKey($id)) { continue }
                    $seen[$id] = $true
                    # Anything that may prompt would block the unattended run
                    if ($update.InstallationBehavior.CanRequestUserInput) {
                        Write-Log "  Skipping (needs user input): $($update.Title)"
                        continue
                    }
                    if (-not $update.EulaAccepted) { $update.AcceptEula() }
                    Write-Log "  Found: $($update.Title)"
                    $null = $toInstall.Add($update)
                }
            }

            if ($toInstall.Count -eq 0) {
                Write-Log "No more updates available" -Level Success
                break
            }

            Write-Log "Downloading $($toInstall.Count) update(s)..."
            $downloader = $session.CreateUpdateDownloader()
            $downloader.Updates = $toInstall
            $null = $downloader.Download()

            Write-Log "Installing $($toInstall.Count) update(s) - cumulative updates can take 20-40 min..."
            $installer = $session.CreateUpdateInstaller()
            $installer.Updates = $toInstall
            $result = $installer.Install()

            # OperationResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
            for ($i = 0; $i -lt $toInstall.Count; $i++) {
                $code = $result.GetUpdateResult($i).ResultCode
                $title = $toInstall.Item($i).Title
                if ($code -eq 2) {
                    $totalInstalled++
                    Write-Log "  Installed: $title" -Level Success
                } else {
                    $totalFailed++
                    Write-Log "  Update failed (result $code): $title" -Level Warning -Key warn.updateFailed -KeyArgs $code, $title
                }
            }
            if ($result.RebootRequired) {
                $script:RebootRequired = $true
                Write-Log "Updates need a reboot to finish - remaining updates will follow after it"
                break
            }
        }
        Write-Log "Windows Update done: $totalInstalled installed, $totalFailed failed"
    }
    catch {
        Write-Log "Windows Update failed: $_" -Level Warning -Key warn.updatesError -KeyArgs "$_"
    }
}

Function Initialize-Winget {
    <#
    .SYNOPSIS
        Make sure winget is usable; register App Installer if it isn't yet
    .DESCRIPTION
        Microsoft documents that winget may be unavailable right after the first logon until
        the Store has registered App Installer in the background.
    #>
    if (Get-Command winget -ErrorAction SilentlyContinue) { return $true }
    Write-Log "winget not found - registering App Installer..."
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    }
    catch {
        Write-Log "  App Installer registration failed: $_"
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ($env:Path -notlike "*$windowsApps*") { $env:Path = "$env:Path;$windowsApps" }
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Log "winget is ready" -Level Success
        return $true
    }
    Write-Log "winget is not available - winget-based steps will be skipped" -Level Warning -Key warn.wingetMissing
    return $false
}

Function Update-InstalledApps {
    <#
    .SYNOPSIS
        Bring installed apps up to date with winget (vendor installers, hash-checked)
    .DESCRIPTION
        Covers apps that don't update themselves (e.g. 7-Zip, VLC) and anything the OEM image
        shipped outdated. Limited to the winget source; Store apps update through the Store.
        Runs with a timeout so a stuck installer can't hold the unattended run.
    #>
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        Write-Log "winget not available - skipping app updates"
        return
    }
    Write-Log "Updating installed apps with winget..."
    $arguments = 'upgrade --all --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity'
    $proc = Start-Process -FilePath $winget.Source -ArgumentList $arguments -NoNewWindow -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit(30 * 60 * 1000)) {
        $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
        Write-Log "App updates still running after 30 min - stopped" -Level Warning -Key warn.appUpdatesTimeout
        return
    }
    # Non-zero is common (an app without an applicable upgrade, a self-updating app that
    # refuses); details are in the console output, so this stays informational
    Write-Log "App updates finished (winget exit code $($proc.ExitCode))"
}

Function Protect-InstallFolder {
    <#
    .SYNOPSIS
        Restrict the install folder to Administrators/SYSTEM (full) and Users (read/execute)
    .DESCRIPTION
        A new folder under C:\ inherits "Authenticated Users: Modify", so any user could
        replace the Helpdesk exe behind the Public Desktop link. SIDs keep this locale-neutral.
    #>
    param([Parameter(Mandatory)][string]$Path)
    $null = Invoke-NativeCommand icacls.exe @(
        $Path, '/inheritance:r', '/grant:r',
        '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX'
    )
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Could not restrict permissions on $Path (icacls exit $LASTEXITCODE)" -Level Warning -Key warn.installAcl -KeyArgs $Path
    } else {
        Write-Log "Restricted permissions on $Path"
    }
}

Function Set-DefaultUserProfile {
    <#
    .SYNOPSIS
        Apply per-user (HKCU) settings to the Default user profile, so accounts created
        later - typically the customer's - start with them too
    .DESCRIPTION
        Loads C:\Users\Default\NTUSER.DAT under HKU, imports the given .reg files with their
        HKEY_CURRENT_USER sections redirected to that hive, sets the given values, unloads.
        Microsoft's only *supported* way is CopyProfile via Sysprep, which doesn't fit an
        already set-up OEM machine; loading the hive is the established alternative.
    .PARAMETER Values
        Same shape as Set-RegistrySettings' -RegistryValues, with HKCU:\ paths
    #>
    param(
        [string[]]$RegFiles = @(),
        [hashtable]$Values = @{}
    )

    $hiveName = 'GKDefaultUser'
    $ntuser = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    if (-not (Test-Path $ntuser)) {
        Write-Log "Default user profile not found ($ntuser)" -Level Warning -Key warn.defaultProfile -KeyArgs "NTUSER.DAT not found"
        return
    }

    $null = Invoke-NativeCommand reg.exe @('load', "HKU\$hiveName", $ntuser)
    if ($LASTEXITCODE -ne 0) {
        Write-Log "Could not load the Default user profile (reg load exit $LASTEXITCODE)" -Level Warning -Key warn.defaultProfile -KeyArgs "reg load $LASTEXITCODE"
        return
    }

    try {
        foreach ($regFile in $RegFiles) {
            if (-not (Test-Path $regFile)) { continue }
            # Get-Content detects the UTF-16 BOM of exported .reg files; ANSI files read as-is
            $content = Get-Content $regFile -Raw
            $redirected = $content -replace '\[(-?)HKEY_CURRENT_USER', "[`$1HKEY_USERS\$hiveName"
            $temp = Join-Path $env:TEMP ("gk-default-" + (Split-Path $regFile -Leaf))
            [System.IO.File]::WriteAllText($temp, $redirected, [System.Text.Encoding]::Unicode)
            $null = Invoke-NativeCommand reg.exe @('import', $temp)
            if ($LASTEXITCODE -ne 0) {
                Write-Log "  Default profile: $(Split-Path $regFile -Leaf) import returned $LASTEXITCODE" -Level Warning -Key warn.defaultProfile -KeyArgs (Split-Path $regFile -Leaf)
            } else {
                Write-Log "  Default profile: applied $(Split-Path $regFile -Leaf)"
            }
            Remove-Item $temp -Force -ErrorAction SilentlyContinue
        }

        foreach ($path in $Values.Keys) {
            $hivePath = $path -replace '^HKCU:\\', "Registry::HKEY_USERS\$hiveName\"
            if (-not (Test-Path $hivePath)) { $null = New-Item -Path $hivePath -Force }
            foreach ($item in @($Values[$path])) {
                Set-ItemProperty -Path $hivePath -Name $item.Name -Value $item.Value -Type $item.Type -Force
            }
        }
        Write-Log "Default user profile updated" -Level Success
    }
    catch {
        Write-Log "Default user profile update failed: $_" -Level Warning -Key warn.defaultProfile -KeyArgs "$_"
    }
    finally {
        # Open handles from the registry provider keep the hive loaded; release them first
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        for ($try = 1; $try -le 5; $try++) {
            $null = Invoke-NativeCommand reg.exe @('unload', "HKU\$hiveName")
            if ($LASTEXITCODE -eq 0) { break }
            Start-Sleep -Seconds 1
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Could not unload the Default user profile hive" -Level Warning -Key warn.defaultProfile -KeyArgs "reg unload $LASTEXITCODE"
        }
    }
}

Function Set-NewUserDefaultApps {
    <#
    .SYNOPSIS
        Default apps for accounts created later, via DISM's supported default-associations XML
    .DESCRIPTION
        SetUserFTA can't change protected defaults on current Windows 11 Home/Pro (UCPD driver,
        UserChoiceLatest). Windows itself applies an imported association XML to every new
        profile at first logon. Built from assoc.txt; only ProgIds that actually exist on this
        PC are written. VLC registers "VLC.<ext>" (not "VLC.<ext>.Document" as in assoc.txt),
        and .url stays with Windows (Chrome does not handle Internet Shortcuts).
    #>
    param([Parameter(Mandatory)][string]$AssocFile, [Parameter(Mandatory)][string]$OutputFolder)

    if (-not (Test-Path $AssocFile)) { return }
    $entries = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    foreach ($line in Get-Content $AssocFile) {
        $parts = $line.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if (@($parts).Count -lt 2) { continue }
        $identifier = $parts[0]; $progId = $parts[1]
        if ($identifier -eq '.url') { continue }

        $candidates = @($progId)
        if ($progId -match '^VLC\..+\.Document$') { $candidates = @(($progId -replace '\.Document$', ''), $progId) }
        $found = $candidates | Where-Object { Test-Path "Registry::HKEY_CLASSES_ROOT\$_" } | Select-Object -First 1
        if (-not $found) { $skipped++; continue }

        $appName = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$found\Application" -ErrorAction SilentlyContinue).ApplicationName
        if (-not $appName) { $appName = (Get-ItemProperty "Registry::HKEY_CLASSES_ROOT\$found" -ErrorAction SilentlyContinue).'(default)' }
        if (-not $appName) { $appName = $found }
        $entries.Add([pscustomobject]@{ Identifier = $identifier; ProgId = $found; ApplicationName = $appName })
    }

    if ($entries.Count -eq 0) {
        Write-Log "No default app associations to set for new users ($skipped skipped)"
        return
    }

    $xmlPath = Join-Path $OutputFolder 'DefaultAppAssociations.xml'
    $settings = New-Object System.Xml.XmlWriterSettings
    $settings.Indent = $true
    $writer = [System.Xml.XmlWriter]::Create($xmlPath, $settings)
    try {
        $writer.WriteStartElement('DefaultAssociations')
        foreach ($entry in $entries) {
            $writer.WriteStartElement('Association')
            $writer.WriteAttributeString('Identifier', $entry.Identifier)
            $writer.WriteAttributeString('ProgId', $entry.ProgId)
            $writer.WriteAttributeString('ApplicationName', $entry.ApplicationName)
            $writer.WriteEndElement()
        }
        $writer.WriteEndElement()
    }
    finally {
        $writer.Close()
    }

    $null = Invoke-NativeCommand dism.exe @('/Online', "/Import-DefaultAppAssociations:$xmlPath")
    if ($LASTEXITCODE -ne 0) {
        Write-Log "DISM default app associations failed (exit $LASTEXITCODE)" -Level Warning -Key warn.newUserApps -KeyArgs $LASTEXITCODE
    } else {
        Write-Log "Default apps for new accounts set ($($entries.Count) associations, $skipped skipped - apps not installed)" -Level Success
    }
}

Function Remove-TrialAntivirus {
    <#
    .SYNOPSIS
        Remove preinstalled third-party antivirus trials so Microsoft Defender takes over
    .DESCRIPTION
        Detects products via Security Center and the uninstall registry. Only silent paths are
        used (msiexec /x /qn, or the vendor's QuietUninstallString), each with a timeout -
        an interactive uninstaller would block the unattended run. Products without a silent
        path (McAfee consumer suites, Norton) are reported for manual removal with the vendor
        tool. HP Wolf Security must go in order, or its update service reinstalls it.
    #>
    $vendorPattern = '^(McAfee|Norton|Avast|AVG|Avira|Trend Micro|Bitdefender|Kaspersky|ESET|HP Wolf Security|HP Security Update Service|HP Sure Sense|HP Sure Click)'

    $securityCenter = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -notmatch 'Defender' })
    foreach ($product in $securityCenter) { Write-Log "  Security Center reports: $($product.displayName)" }

    $entries = @(Get-UninstallEntries | Where-Object { $_.DisplayName -match $vendorPattern })
    if ($entries.Count -eq 0 -and $securityCenter.Count -eq 0) {
        Write-Log "No third-party antivirus found" -Level Success
        return
    }

    # HP Wolf: product first, then console, then the update service
    $order = { param($name)
        if ($name -match '^HP Wolf Security$') { 0 }
        elseif ($name -match '^HP Wolf Security') { 1 }
        elseif ($name -match '^HP Security Update Service') { 9 }
        else { 5 }
    }
    $entries = $entries | Sort-Object { & $order $_.DisplayName }

    $manual = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $entries) {
        $name = $entry.DisplayName
        Write-Log "  Removing $name..."
        switch (Invoke-SilentUninstall -Entry $entry) {
            'removed' { Write-Log "  Removed: $name" -Level Success }
            'reboot'  { $script:RebootRequired = $true; Write-Log "  Removed (reboot required): $name" -Level Success }
            'manual'  { $manual.Add($name) }
            'timeout' { Write-Log "  $name uninstaller still running after 15 min - stopped" -Level Warning -Key warn.avFailed -KeyArgs $name }
            default   { Write-Log "  $name uninstall failed" -Level Warning -Key warn.avFailed -KeyArgs $name }
        }
    }

    # Whatever Security Center still reports, or had no silent uninstaller, needs the technician
    $remaining = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction SilentlyContinue |
        Where-Object { $_.displayName -notmatch 'Defender' } | ForEach-Object { $_.displayName })
    foreach ($name in @($manual) + $remaining | Select-Object -Unique) {
        $script:ThirdPartyAvRemains = $true
        Write-Log "$name needs manual removal (vendor removal tool, e.g. McAfee MCPR / Norton Remove and Reinstall)" -Level Warning -Key warn.avManual -KeyArgs $name
    }
}

Function Test-SetupHealth {
    <#
    .SYNOPSIS
        Final checks shown in the result window: activation, Defender, edition vs. profile
    #>
    param([string]$DeploymentType)

    # Windows activation (ApplicationID = Windows)
    try {
        $license = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Select-Object -First 1
        if ($license -and $license.LicenseStatus -eq 1) {
            Write-Log "Windows is activated" -Level Success
        } else {
            Write-Log "Windows is not activated" -Level Warning -Key warn.notActivated
        }
    }
    catch {
        Write-Log "Could not check activation: $_"
    }

    # Defender: fresh signatures and real-time protection on (skip if a third-party AV is
    # known to remain - that is already reported and Defender is passive by design then)
    try { Update-MpSignature -ErrorAction Stop; Write-Log "Defender signatures updated" }
    catch { Write-Log "Defender signature update: $_" }
    if (-not $script:ThirdPartyAvRemains) {
        try {
            $mp = Get-MpComputerStatus -ErrorAction Stop
            if ($mp.AMRunningMode -eq 'Normal' -and $mp.RealTimeProtectionEnabled) {
                Write-Log "Microsoft Defender is active" -Level Success
            } else {
                Write-Log "Microsoft Defender is not fully active (mode $($mp.AMRunningMode), real-time $($mp.RealTimeProtectionEnabled))" -Level Warning -Key warn.defenderInactive -KeyArgs $mp.AMRunningMode
            }
        }
        catch {
            Write-Log "Could not check Microsoft Defender: $_"
        }
    }

    # Business profile on a Home edition (no BitLocker, no domain/Entra join, no policies)
    $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    if ($DeploymentType -eq 'business' -and $edition -match '^Core') {
        Write-Log "Business profile on Windows edition $edition (Home)" -Level Warning -Key warn.editionHome -KeyArgs $edition
    }
}

Function Test-PendingReboot {
    <#
    .SYNOPSIS
        True when Windows reports a pending restart (servicing, Windows Update, file renames)
    #>
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    $renames = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
    return [bool]$renames
}

Function Install-WingetPackage {
    <#
    .SYNOPSIS
        Install one package with winget; verify it afterwards
    .DESCRIPTION
        Returns 'installed', 'notfound' (the ID doesn't exist, e.g. no Firefox build for this
        language - the caller tries the next ID) or 'failed'. Each attempt has a timeout so a
        stuck installer can't hold the unattended run; success is confirmed with winget list,
        independent of installer exit codes.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$Source = 'winget',
        [string]$ExtraArgs = ''
    )
    $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
    if (-not $winget) { return 'failed' }

    $listArgs = @('list', '--id', $Id, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
    $null = Invoke-NativeCommand winget $listArgs
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Already installed: $Id"
        return 'installed'
    }

    $arguments = "install --id $Id --exact --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity $ExtraArgs".Trim()
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        Write-Log "  winget install $Id (attempt $attempt/2)"
        $proc = Start-Process -FilePath $winget -ArgumentList $arguments -NoNewWindow -PassThru
        $null = $proc.Handle
        if (-not $proc.WaitForExit(20 * 60 * 1000)) {
            $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
            Write-Log "    $Id still installing after 20 min - stopped"
            $null = Wait-MsiIdle -TimeoutSeconds 120
            continue
        }
        # 0x8A150014: no package found for this ID
        if ($proc.ExitCode -eq -1978335212) { return 'notfound' }
        $null = Invoke-NativeCommand winget $listArgs
        if ($LASTEXITCODE -eq 0) {
            Write-Log "    Installed: $Id" -Level Success
            return 'installed'
        }
        Write-Log "    winget exit code $($proc.ExitCode) for $Id"
        Start-Sleep -Seconds 5
    }
    return 'failed'
}

Function Install-AppPackages {
    <#
    .SYNOPSIS
        Install profile packages: winget first, Chocolatey only as fallback
    .DESCRIPTION
        IDs come from config.json's packageCatalog. winget downloads from the vendor with hash
        checks (no --ignore-checksums for Chrome; Adobe keeps its auto-update; Firefox in the
        Windows display language). Chocolatey is installed on demand and removed at the end
        of the run (Remove-ChocolateyIfInstalledByUs).
    #>
    param([Parameter(Mandatory)][string[]]$Names)

    $uiLang = (Get-UICulture).TwoLetterISOLanguageName
    foreach ($name in $Names) {
        $entry = $script:config.packageCatalog[$name]
        $done = $false
        if ($entry -and $entry.winget -and $script:WingetReady) {
            $source = if ($entry.wingetSource) { $entry.wingetSource } else { 'winget' }
            foreach ($id in @($entry.winget)) {
                $result = Install-WingetPackage -Id $id.Replace('{uilang}', $uiLang) -Source $source -ExtraArgs "$($entry.wingetArgs)"
                if ($result -eq 'installed') { $done = $true; break }
                if ($result -eq 'failed') { break }
            }
        }
        if ($done) { continue }

        $chocoId = if ($entry -and $entry.choco) { $entry.choco } else { $name }
        Write-Log "  Falling back to Chocolatey for $name ($chocoId)"
        try {
            if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
                Install-PackageManager -Manager chocolatey
            }
            Install-Packages -PackageList @($chocoId) -Manager chocolatey -ChocoParams "$($entry.chocoParams)"
        }
        catch {
            Write-Log "Chocolatey fallback failed for ${name}: $_" -Level Warning -Key warn.pkgFailed -KeyArgs $name
        }
    }
}

Function Remove-ChocolateyIfInstalledByUs {
    <#
    .SYNOPSIS
        Remove Chocolatey again if this run installed it (as a fallback)
    .DESCRIPTION
        Nobody maintains a package manager left on a customer PC. Removing Chocolatey does not
        uninstall the apps it installed (Chocolatey docs: uninstallation).
    #>
    param([bool]$WasPresent)
    if ($WasPresent) { return }
    $root = [Environment]::GetEnvironmentVariable('ChocolateyInstall', 'Machine')
    if (-not $root) { $root = Join-Path $env:ProgramData 'chocolatey' }
    if (-not (Test-Path -LiteralPath $root)) { return }
    if ((Split-Path $root -Leaf) -ne 'chocolatey') {
        Write-Log "Chocolatey folder '$root' looks unusual - left in place"
        return
    }

    Write-Log "Removing Chocolatey (fallback only; installed apps stay)..."
    try {
        $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $kept = ($machinePath -split ';' | Where-Object { $_ -and $_ -notlike "$root*" }) -join ';'
        [Environment]::SetEnvironmentVariable('Path', $kept, 'Machine')
        foreach ($variable in 'ChocolateyInstall', 'ChocolateyToolsLocation', 'ChocolateyLastPathUpdate') {
            [Environment]::SetEnvironmentVariable($variable, $null, 'Machine')
            [Environment]::SetEnvironmentVariable($variable, $null, 'User')
        }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
        Write-Log "Chocolatey removed" -Level Success
    }
    catch {
        Write-Log "Chocolatey removal incomplete: $_"
    }
}

Function Set-NotebookPower {
    <#
    .SYNOPSIS
        On notebooks plugged in: no sleep, display off after 30 min, closing the lid does nothing
    .DESCRIPTION
        Battery settings stay at the Windows defaults. Skipped on machines without a battery.
    #>
    if (-not (Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)) {
        Write-Log "No battery found - power settings unchanged"
        return
    }
    $commands = @(
        @('/change', 'standby-timeout-ac', '0'),
        @('/change', 'monitor-timeout-ac', '30'),
        @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_BUTTONS', 'LIDACTION', '0'),
        @('/setactive', 'SCHEME_CURRENT')
    )
    foreach ($arguments in $commands) {
        $null = Invoke-NativeCommand powercfg.exe $arguments
        if ($LASTEXITCODE -ne 0) { Write-Log "  powercfg $($arguments -join ' ') returned $LASTEXITCODE" }
    }
    Write-Log "Notebook power settings applied (on AC: no sleep, display off after 30 min, lid = do nothing)" -Level Success
}

Function Set-StartPins {
    <#
    .SYNOPSIS
        Replace the preinstalled Start pins (promo apps, OEM links) with a clean list, once
    .DESCRIPTION
        Uses the "Configure Start Pins" policy (Windows 11 24H2 + KB5062660) with applyOnce:
        every account gets the list at its next sign-in and can change it freely afterwards.
        Only shortcuts that exist are pinned; Microsoft documents that pins for apps that
        aren't installed don't appear. Policy registry values from the local StartMenu.admx;
        per Microsoft Learn, the GPO value is the path to the JSON file.
    #>
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [bool]$IncludeLibreOffice,
        [string]$HelpdeskExe
    )
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'

    # Pins need a shortcut in a Start menu folder
    $helpdeskLink = Join-Path $programs 'Netixx Helpdesk.lnk'
    if ($HelpdeskExe -and (Test-Path -LiteralPath $HelpdeskExe)) {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($helpdeskLink)
        $shortcut.TargetPath = $HelpdeskExe
        $shortcut.WorkingDirectory = Split-Path $HelpdeskExe
        $shortcut.Save()
    }

    $findLink = { param($fileName)
        Get-ChildItem -LiteralPath $programs -Filter $fileName -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    }
    $pins = New-Object System.Collections.Generic.List[object]
    foreach ($linkName in 'Google Chrome.lnk', 'Firefox.lnk') {
        $path = & $findLink $linkName
        if ($path) { $pins.Add(@{ desktopAppLink = $path }) }
    }
    # Same per-user shortcut Microsoft's own example uses for File Explorer
    $pins.Add(@{ desktopAppLink = '%APPDATA%\Microsoft\Windows\Start Menu\Programs\File Explorer.lnk' })
    foreach ($appId in @(
        'windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel',
        'Microsoft.WindowsStore_8wekyb3d8bbwe!App',
        'Microsoft.Windows.Photos_8wekyb3d8bbwe!App',
        'Microsoft.WindowsCalculator_8wekyb3d8bbwe!App',
        'Microsoft.WindowsNotepad_8wekyb3d8bbwe!App',
        'Microsoft.ScreenSketch_8wekyb3d8bbwe!App'
    )) {
        $pins.Add(@{ packagedAppId = $appId })
    }
    if ($IncludeLibreOffice) {
        foreach ($linkName in 'LibreOffice Writer.lnk', 'LibreOffice Calc.lnk') {
            $path = & $findLink $linkName
            if ($path) { $pins.Add(@{ desktopAppLink = $path }) }
        }
    }
    if (Test-Path -LiteralPath $helpdeskLink) { $pins.Add(@{ desktopAppLink = $helpdeskLink }) }

    try {
        $json = @{ applyOnce = $true; pinnedList = $pins.ToArray() } | ConvertTo-Json -Depth 4 -Compress
        $jsonPath = Join-Path $OutputFolder 'StartPins.json'
        [System.IO.File]::WriteAllText($jsonPath, $json, (New-Object System.Text.UTF8Encoding $false))
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
        if (-not (Test-Path $key)) { $null = New-Item -Path $key -Force }
        Set-ItemProperty -Path $key -Name 'ConfigureStartPins' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $key -Name 'ConfigureStartPinsJSON' -Value $jsonPath -Type ExpandString -Force
        Write-Log "Start pins configured ($($pins.Count) pins, applied once per account at its next sign-in)" -Level Success
    }
    catch {
        Write-Log "Start pins could not be configured: $_" -Level Warning -Key warn.startPins -KeyArgs "$_"
    }
}

Function Register-BingWallpaper {
    <#
    .SYNOPSIS
        Daily Bing picture of the day as desktop wallpaper, for every account
    .DESCRIPTION
        Copies BingWallpaper.ps1 to the install folder (users can read, not change it) and
        registers a task for the Users group: at every sign-in and daily at 06:00, hidden
        (conhost --headless), only with network. Also runs it once now for this account.
    #>
    param([Parameter(Mandatory)][string]$InstallFolder)
    $target = Join-Path $InstallFolder 'BingWallpaper.ps1'
    try {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'BingWallpaper.ps1') -Destination $target -Force
        $usersGroup = ([System.Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([System.Security.Principal.NTAccount]).Value
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\conhost.exe" `
            -Argument "--headless powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$target`""
        $triggers = @((New-ScheduledTaskTrigger -AtLogOn), (New-ScheduledTaskTrigger -Daily -At '06:00'))
        $principal = New-ScheduledTaskPrincipal -GroupId $usersGroup -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName 'Bing Wallpaper' -TaskPath '\Netixx\' -Action $action -Trigger $triggers `
            -Principal $principal -Settings $settings -Force | Out-Null
        $null = Invoke-NativeCommand powershell.exe @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
        Write-Log "Daily Bing wallpaper set up for all accounts" -Level Success
    }
    catch {
        Write-Log "Bing wallpaper setup failed: $_" -Level Warning -Key warn.wallpaper -KeyArgs "$_"
    }
}

Function Invoke-ComponentCleanup {
    <#
    .SYNOPSIS
        Remove superseded update components (DISM StartComponentCleanup, no /ResetBase)
    .DESCRIPTION
        Frees space after the cumulative updates; installed updates stay uninstallable.
        With a restart pending DISM may defer the work - that is informational only.
    #>
    Write-Log "Cleaning up superseded update components (DISM)..."
    $proc = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/Quiet' -WindowStyle Hidden -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit(30 * 60 * 1000)) {
        $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
        Write-Log "Component cleanup still running after 30 min - stopped"
        return
    }
    Write-Log "Component cleanup finished (DISM exit $($proc.ExitCode))"
}

Function Invoke-FinalCleanup {
    <#
    .SYNOPSIS
        Leave no installation leftovers: temp folders, recycle bin, Delivery Optimization cache
    .PARAMETER SetupRoot
        The folder this run is executing from - never touched here
    #>
    param([string]$SetupRoot)
    foreach ($folder in @((Join-Path $env:SystemRoot 'Temp'), $env:TEMP)) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $SetupRoot -or $_.FullName.TrimEnd('\') -ine $SetupRoot.TrimEnd('\') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch { }
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
    Write-Log "Temporary files, recycle bin and Delivery Optimization cache cleaned" -Level Success
}

Function Register-SetupFolderCleanup {
    <#
    .SYNOPSIS
        Delete the extracted gk-script.exe folder at the next start (it's in use right now)
    .DESCRIPTION
        Only when running from the NSIS extract (%TEMP%\NetixxSetup) - never from a source
        checkout. A one-shot SYSTEM task deletes the folder and then itself.
    #>
    param([string]$SetupRoot)
    if (-not $SetupRoot -or (Split-Path $SetupRoot -Leaf) -ne 'NetixxSetup') {
        Write-Log "Not running from the gk-script.exe extract - no setup folder to remove"
        return
    }
    try {
        $command = "/c rd /s /q `"$SetupRoot`" & schtasks /delete /tn `"\Netixx\Setup Cleanup`" /f"
        Register-ScheduledTask -TaskName 'Setup Cleanup' -TaskPath '\Netixx\' `
            -Action (New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $command) `
            -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -Principal (New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest) -Force | Out-Null
        Write-Log "Setup files will be removed at the next start"
    }
    catch {
        Write-Log "Could not schedule removal of the setup files: $_"
    }
}

Function New-SetupRestorePoint {
    <#
    .SYNOPSIS
        Turn on System Protection for the system drive and create a restore point
    .DESCRIPTION
        System Protection is off by default. Windows allows one restore point per 24 h;
        if one already exists, this is informational only.
    #>
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Netixx Grundkonfiguration' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop -WarningAction SilentlyContinue
        Write-Log "Restore point created" -Level Success
    }
    catch {
        Write-Log "Restore point not created: $_"
    }
}

Function Enable-WindowsSudo {
    <#
    .SYNOPSIS
        Turn on "sudo" (Windows 11 24H2+) in Microsoft's default and recommended mode
    .DESCRIPTION
        forceNewWindow: the elevated command opens in a new window, so no other process can
        drive it (Microsoft Learn, Sudo for Windows). The mode is passed explicitly - in the
        sudo source, "--enable enable/default" selects the less safe inline mode.
    #>
    $sudo = Join-Path $env:SystemRoot 'System32\sudo.exe'
    if (-not (Test-Path $sudo)) {
        Write-Log "sudo is not available on this Windows build (needs 24H2 or later)"
        return
    }
    $null = Invoke-NativeCommand $sudo @('config', '--enable', 'forceNewWindow')
    if ($LASTEXITCODE -eq 0) {
        Write-Log "sudo enabled (mode: new window)" -Level Success
    } else {
        Write-Log "sudo could not be enabled (exit $LASTEXITCODE)"
    }
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

try {
    # Step 0: Trial antivirus first - it interferes with installers and keeps Defender passive
    Write-Log "Step 0: Removing preinstalled antivirus trials (2%)"
    $script:CurrentStep = 'av'
    try {
        Remove-TrialAntivirus
    }
    catch {
        Write-Log "Antivirus trial removal failed: $_" -Level Warning -Key warn.avFailed -KeyArgs "$_"
    }
    # Chocolatey is only a fallback; remember whether it was already there so the cleanup
    # at the end removes it only if this run installed it
    $script:ChocoWasPresent = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    $script:WingetReady = Initialize-Winget
    if ($SkipUpdates) { Write-Log "Updates skipped for this run (menu choice / -SkipUpdates)" }

    # Step 2: Install software packages - winget first, Chocolatey as fallback
    Write-Log "Step 2: Installing software packages (20%)"
    $script:CurrentStep = 'packages'
    Install-AppPackages -Names $deploymentConfig.packages

    # Step 3: GPU. Drivers for every vendor come from Windows Update (Step 3b); Intel's control
    # panel is installed from the Store by the Intel driver itself.
    if ($gpuInfo.IsAmd) {
        Write-Log "Step 3a: AMD GPU detected ($($gpuInfo.Name)) - driver comes from Windows Update"
    }

    # Step 3b: Every Windows update - drivers (GPU incl. AMD, chipset), security and quality
    # updates, optional and preview updates, feature upgrades, Defender definitions.
    # After the app installs, which share the MSI lock.
    if (-not $SkipUpdates) {
        Write-Log "Step 3b: Installing all Windows updates and drivers (35%)"
        $script:CurrentStep = 'updates'
        Install-WindowsUpdates
    }

    # Step 3c: NVIDIA App on every NVIDIA GPU - after Windows Update, because it needs an
    # installed driver
    if ($gpuInfo.IsNvidia) {
        Write-Log "Step 3c: Installing the NVIDIA App (38%)"
        $script:CurrentStep = 'gpu'
        Install-AppPackages -Names @('nvidia-app')
    }

    # Step 4: Apply registry and system settings
    Write-Log "Step 4: Applying registry and system settings (40%)"
    $script:CurrentStep = 'registry'
    $registryFiles = @()
    if ($deploymentConfig.branded) {
        $registryFiles += "$PSScriptRoot\Logo_Info.reg"
    }
    $registryFiles += "$PSScriptRoot\icons.reg"
    # Windows suggestions, ads, auto-installed "suggested" apps, lock-screen tips, End task (per user)
    $registryFiles += "$PSScriptRoot\user_settings.reg"
    # Widgets, Recall/Click to Do, Edge ads, Storage Sense, Fast Startup off (machine)
    $registryFiles += "$PSScriptRoot\machine_settings.reg"

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

    # Block potentially unwanted apps (adware bundled with free downloads) in Defender
    try {
        Set-MpPreference -PUAProtection Enabled -ErrorAction Stop
        Write-Log "Defender: potentially unwanted app blocking enabled" -Level Success
    }
    catch {
        Write-Log "Defender PUA protection could not be enabled: $_"
    }
    Set-NotebookPower
    Enable-WindowsSudo

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
    Protect-InstallFolder -Path $installFolder

    $helpdeskDest = "$installFolder\Netixx Helpdesk.exe"
    if ($deploymentConfig.branded) {
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

    # Re-apply OEM branding after debloat - Lenovo/HP/Dell services can reset
    # OEMInformation while their software is still running during earlier steps.
    if ($deploymentConfig.branded) {
        $brandingReg = "$PSScriptRoot\Logo_Info.reg"
        if (Test-Path $brandingReg) {
            Write-Log "Re-applying OEM branding registry..."
            # reg.exe reports success on stderr, so a plain 2>&1 under 'Stop' threw on every run
            $out = Invoke-NativeCommand "$env:SystemRoot\System32\reg.exe" @('import', $brandingReg)
            if ($LASTEXITCODE -eq 0) {
                Write-Log "OEM branding applied" -Level Success
            } else {
                Write-Log "OEM branding registry warning: $($out -join ' ')" -Level Warning -Key warn.branding -KeyArgs ($out -join ' ')
            }
        }
    }

    # Step 10b: App updates - after debloat, so apps about to be removed aren't updated first
    if (-not $SkipUpdates) {
        Write-Log "Step 10b: Updating installed apps (92%)"
        $script:CurrentStep = 'appUpdates'
        Update-InstalledApps
    }

    # Step 11: Accounts created later (typically the customer's own) get the same settings and
    # default apps; the Start menu gets a clean pin list; daily Bing wallpaper for everyone.
    # Default apps for the CURRENT account can't be set by a tool on Windows 11 Home/Pro
    # (UCPD driver, UserChoiceLatest) - the result window reminds the technician instead.
    Write-Log "Step 11: Applying settings for new user accounts, Start pins, wallpaper (95%)"
    $script:CurrentStep = 'newUsers'
    Set-DefaultUserProfile -RegFiles @("$PSScriptRoot\icons.reg", "$PSScriptRoot\user_settings.reg", "$PSScriptRoot\disable_telemetry.reg") `
        -Values $registryValues
    Set-NewUserDefaultApps -AssocFile "$PSScriptRoot\assoc.txt" -OutputFolder $installFolder
    Set-StartPins -OutputFolder $installFolder -IncludeLibreOffice ($deploymentConfig.packages -contains 'libreoffice') `
        -HelpdeskExe $helpdeskDest
    Register-BingWallpaper -InstallFolder $installFolder
    $script:ResultNotes = @(Get-UiText result.note.defaultApps)

    # Step 12: Health checks reported in the result window
    Write-Log "Step 12: Checking activation, Defender and edition (96%)"
    $script:CurrentStep = 'health'
    Test-SetupHealth -DeploymentType $DeploymentType

    # Step 13: Leave a clean system - update leftovers, Chocolatey (if this run installed it),
    # temp files, recycle bin; setup files are deleted at the next start; then a restore point
    Write-Log "Step 13: Cleaning up (97%)"
    $script:CurrentStep = 'cleanup'
    if (-not $SkipUpdates) { Invoke-ComponentCleanup }
    Remove-ChocolateyIfInstalledByUs -WasPresent $script:ChocoWasPresent
    $setupRoot = Split-Path $PSScriptRoot -Parent
    Invoke-FinalCleanup -SetupRoot $setupRoot
    Register-SetupFolderCleanup -SetupRoot $setupRoot
    New-SetupRestorePoint

    # Final: Stop Explorer, write icon layout to registry, then restart Explorer.
    # The registry write MUST happen while Explorer is dead - otherwise Explorer
    # overwrites IconLayouts with the current layout on shutdown.
    Write-Log "Finalizing... (98%)"
    $script:CurrentStep = 'finalize'
    $explorerKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $originalShell = (Get-ItemProperty -Path $explorerKey -Name Shell -ErrorAction SilentlyContinue).Shell
    $shellBlanked = $false
    try {
        # Prevent Windows from auto-restarting Explorer after we kill it
        Set-ItemProperty -Path $explorerKey -Name Shell -Value '' -Force
        $shellBlanked = $true

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
    }
    catch {
        Write-Log "Explorer restart failed: $_" -Level Warning -Key warn.explorer -KeyArgs "$_"
    }
    finally {
        # Always restore the shell, whatever happened above: an empty Shell value leaves
        # every user without a desktop at the next logon
        if ($shellBlanked) {
            try {
                $shellValue = if ($originalShell) { $originalShell } else { 'explorer.exe' }
                Set-ItemProperty -Path $explorerKey -Name Shell -Value $shellValue -Force
            }
            catch {
                Write-Log "Could not restore the Winlogon Shell value: $_" -Level Error -Key warn.explorer -KeyArgs "$_"
            }
        }

        # Start Explorer as the logged-in user (not elevated) so it properly becomes the shell.
        # Start-Process from an admin session would launch it elevated, which Windows rejects as shell.
        try {
            $shellUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
            if ($shellUser) {
                $explorerAction    = New-ScheduledTaskAction -Execute 'C:\Windows\explorer.exe'
                $explorerPrincipal = New-ScheduledTaskPrincipal -UserId $shellUser -LogonType Interactive -RunLevel Limited
                $explorerSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -Priority 4
                try {
                    Register-ScheduledTask -TaskName 'GKScript-StartExplorer' -Action $explorerAction `
                        -Settings $explorerSettings -Principal $explorerPrincipal -Force | Out-Null
                    Start-ScheduledTask -TaskName 'GKScript-StartExplorer'
                    Start-Sleep -Seconds 2
                }
                finally {
                    Unregister-ScheduledTask -TaskName 'GKScript-StartExplorer' -Confirm:$false -ErrorAction SilentlyContinue
                }
            } elseif (-not (Get-Process explorer -ErrorAction SilentlyContinue)) {
                Start-Process explorer.exe
            }
        }
        catch {
            Write-Log "Explorer restart failed: $_" -Level Warning -Key warn.explorer -KeyArgs "$_"
        }
    }

    # Any pending restart (updates, removed antivirus, servicing) is offered in the result window
    if (Test-PendingReboot) { $script:RebootRequired = $true }

    # Shown last: the technician has usually walked away, and a window before the
    # Explorer step would hold back the desktop layout until someone clicks
    $issues = Get-LogIssues
    if ($issues.Count -eq 0) {
        Write-Log "=== Setup Completed Successfully ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        Show-SetupResult -Status Success -Title (Get-UiText result.success.title) -Subtitle (Get-RunSummary) `
            -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired) -Notes @($script:ResultNotes)
    } else {
        Write-Log "=== Setup Finished With $($issues.Count) Warning(s) ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        $warningTitle = if ($issues.Count -eq 1) { Get-UiText result.warning.title.one } else { Get-UiText result.warning.title.many $issues.Count }
        Show-SetupResult -Status Warning -Title $warningTitle -Subtitle (Get-RunSummary) `
            -Items $issues -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired) -Notes @($script:ResultNotes)
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

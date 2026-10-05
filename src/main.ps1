param(
    [Parameter(Mandatory)]
    [ValidateSet('business', 'consumer', 'consumer-nolo')]
    [string]$DeploymentType,
    
    [Parameter()]
    [switch]$SkipBloatwareRemoval,
    
    [Parameter()]
    [string]$ConfigPath = "$PSScriptRoot\config.json",

    # UI language of the result window (the log stays English); the menu passes its choice
    [Parameter()]
    [ValidateSet('de', 'en', 'it')]
    [string]$Language = 'de',

    # No Windows Update and no app updates (menu: "install all updates" switched off)
    [Parameter()]
    [switch]$SkipUpdates,

    # For a PC already in use: install and configure, remove nothing (menu: "install only").
    # Skips antivirus/Office/OneDrive removal, debloat, desktop cleanup and layout, BitLocker,
    # Start pins, theme colors, power settings and emptying the recycle bin.
    [Parameter()]
    [switch]$InstallOnly
)

# Stop on first error
$ErrorActionPreference = 'Stop'

# Import utility functions
Import-Module "$PSScriptRoot\lib\PSSetupUtility.psm1" -Force

# Started from the exe's 32-bit stub (or any 32-bit process): run again in 64-bit PowerShell
$relaunchExit = Restart-In64BitPowerShell -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
if ($null -ne $relaunchExit) { exit $relaunchExit }

# Functions for the setup steps (src\steps), in this script's scope
foreach ($stepFile in 'Packages', 'Updates', 'Antivirus', 'Settings', 'Desktop', 'Checks', 'Cleanup', 'Report', 'Firmware') {
    . (Join-Path $PSScriptRoot "steps\$stepFile.ps1")
}
Set-UiLanguage $Language

$script:StartTime = Get-Date
$script:CurrentStep = 'start'
Set-KeepAwake -Enable   # released in the final 'finally' block (or when the process exits)

# Subline for the result window: profile, machine, elapsed time
Function Get-RunSummary {
    $minutes = [int][math]::Floor(((Get-Date) - $script:StartTime).TotalMinutes)
    $duration = if ($minutes -lt 1) { Get-UiText duration.lessThanMinute } else { Get-UiText duration.minutes $minutes }
    $profileName = Get-UiText "profile.$DeploymentType"
    $parts = @($profileName)
    if ($InstallOnly) { $parts += Get-UiText summary.installOnly }
    return ($parts + @($env:COMPUTERNAME, $duration)) -join " $([char]0xB7) "
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
# MAIN EXECUTION (the step functions live in src\steps)
# ============================================================================

# The full setup removes Office, OneDrive and desktop shortcuts and turns off BitLocker -
# on a PC that is already in use, ask first and offer the install-only run instead
if (-not $InstallOnly) {
    $usedSigns = @(Get-UsedPcSigns)
    if ($usedSigns.Count -gt 0) {
        Write-Log "This PC looks used: $($usedSigns -join '; ')"
        $choice = Show-SetupResult -Status Warning -Title (Get-UiText used.title) -Subtitle (Get-UiText used.subtitle) `
            -Heading (Get-UiText used.heading) -Items $usedSigns -Choices @(
                @{ Key = 'full'; Text = (Get-UiText used.button.full); Fallback = 'No' }
                @{ Key = 'installOnly'; Text = (Get-UiText used.button.installOnly); Accent = $true; Fallback = 'Yes' }
                @{ Key = 'cancel'; Text = (Get-UiText used.button.cancel); Cancel = $true; Fallback = 'Cancel' }
            )
        switch ($choice) {
            'installOnly' { $InstallOnly = [switch]$true; Write-Log "Technician chose the install-only run" }
            'full'        { Write-Log "Technician confirmed the full setup on a PC in use" }
            default       { Write-Log "Cancelled by the technician - nothing changed"; exit 0 }
        }
    }
}
Write-Log "Mode: $(if ($InstallOnly) { 'install only (nothing is removed)' } else { 'full setup' })"

try {
    # Install only: the restore point comes first, so the customer's state can be restored
    if ($InstallOnly) {
        Write-Log "Creating a restore point before any change..."
        New-SetupRestorePoint
    }

    # Step 0: Trial antivirus first - it interferes with installers and keeps Defender passive
    if (-not $InstallOnly) {
        Write-Log "Step 0: Removing preinstalled antivirus trials (2%)"
        $script:CurrentStep = 'av'
        try {
            Remove-TrialAntivirus
        }
        catch {
            Write-Log "Antivirus trial removal failed: $_" -Level Warning -Key warn.avFailed -KeyArgs "$_"
        }
    }
    # Chocolatey is only a fallback; remember whether it was already there so the cleanup
    # at the end removes it only if this run installed it
    $script:ChocoWasPresent = [bool](Get-Command choco -ErrorAction SilentlyContinue)
    $script:WingetReady = Initialize-Winget
    if ($SkipUpdates) { Write-Log "Updates skipped for this run (menu choice / -SkipUpdates)" }

    # Install only: remember the desktop, so Step 5 removes only the installers' new shortcuts
    if ($InstallOnly) { $desktopBefore = @(Get-DesktopShortcuts | ForEach-Object { $_.FullName }) }

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
    # Telemetry and ad ID off - the full run imports it with debloat.ps1, which install only skips
    if ($InstallOnly) { $registryFiles += "$PSScriptRoot\disable_telemetry.reg" }

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

    # The theme colors are the customer's own choice on a PC in use; new accounts still get them (Step 11)
    $currentUserValues = if ($InstallOnly) { @{} } else { $registryValues }
    Set-RegistrySettings -RegistryFiles $registryFiles -RegistryValues $currentUserValues

    # Block potentially unwanted apps (adware bundled with free downloads) in Defender
    try {
        Set-MpPreference -PUAProtection Enabled -ErrorAction Stop
        Write-Log "Defender: potentially unwanted app blocking enabled" -Level Success
    }
    catch {
        Write-Log "Defender PUA protection could not be enabled: $_"
    }
    if (-not $InstallOnly) { Set-NotebookPower }
    Enable-WindowsSudo

    # Chrome and Firefox go to the taskbar (Step 11) instead of the desktop - if this Windows
    # can pin them; otherwise their desktop shortcuts stay
    $taskbarApps = @($script:config.windows.taskbarPins)
    $taskbarPinsOk = Test-TaskbarPinSupport
    $keepOnDesktop = if ($taskbarPinsOk) { @() } else { $taskbarApps }

    # Step 5: Remove bloatware shortcuts. Install only: just the shortcuts this run's installers
    # added to the desktop (not whitelisted); everything the customer had stays
    if (-not $SkipBloatwareRemoval) {
        $script:CurrentStep = 'bloat'
        if ($InstallOnly) {
            Write-Log "Step 5: Removing desktop shortcuts added by the installers (50%)"
            Clear-DesktopIcons -WhitelistPath "$PSScriptRoot\whitelist.txt" -Keep $desktopBefore -ExtraWhitelist $keepOnDesktop
        } else {
            Write-Log "Step 5: Removing bloatware (50%)"
            Remove-BloatwareShortcuts -ShortcutPaths $script:config.windows.shortcuts
            Clear-DesktopIcons -WhitelistPath "$PSScriptRoot\whitelist.txt" -ExtraWhitelist $keepOnDesktop
        }
    }

    # Step 6: Disable BitLocker if needed (never on a PC in use)
    if (-not $InstallOnly) {
        # Windows 11 24H2+ turns device encryption on by itself on more PCs (also once a
        # Microsoft account signs in); this documented value stops the automatic part -
        # turning BitLocker on by hand stays possible (Microsoft Learn, BitLocker for OEMs)
        try {
            $null = New-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' -Name PreventDeviceEncryption `
                -PropertyType DWord -Value 1 -Force -ErrorAction Stop
            Write-Log "Automatic device encryption prevented"
        }
        catch {
            Write-Log "PreventDeviceEncryption could not be set: $_"
        }
    }
    if ($bitlockerStatus.IsEncrypted -and $InstallOnly) {
        Write-Log "BitLocker stays on (install only)"
    } elseif ($bitlockerStatus.IsEncrypted) {
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

    # Steps 9-10 remove things - full run only
    if (-not $InstallOnly) {
        # Step 9: Uninstall Office
        Write-Log "Step 9: Uninstalling Office (80%)"
        $script:CurrentStep = 'office'
        Uninstall-Microsoft365 -SetupUrl $script:config.office.setupUrl

        # Step 10: Run debloat script
        Write-Log "Step 10: Running debloat script (90%)"
        $script:CurrentStep = 'debloat'
        if (Test-Path "$PSScriptRoot\debloat.ps1") {
            try {
                # Store apps the profile installs on purpose (e.g. new Outlook) are not removed
                $keepApps = @($deploymentConfig.packages | ForEach-Object { $script:config.packageCatalog[$_].appx } | Where-Object { $_ })
                & "$PSScriptRoot\debloat.ps1" -KeepApps $keepApps
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
    $defaultProfileFiles = @("$PSScriptRoot\icons.reg", "$PSScriptRoot\user_settings.reg", "$PSScriptRoot\disable_telemetry.reg")
    # OneDrive was uninstalled (debloat) - keep new accounts from installing it again
    if (-not $InstallOnly) { $defaultProfileFiles += "$PSScriptRoot\onedrive_setup_off.reg" }
    Set-DefaultUserProfile -RegFiles $defaultProfileFiles -Values $registryValues
    Set-NewUserDefaultApps -AssocFile "$PSScriptRoot\assoc.txt" -OutputFolder $installFolder
    # The pin policy applies to every account once - on a PC in use it would replace the customer's pins
    if (-not $InstallOnly) {
        Set-StartPins -OutputFolder $installFolder -IncludeLibreOffice ($deploymentConfig.packages -contains 'libreoffice') `
            -HelpdeskExe $helpdeskDest
        $script:ResultNotes = @(Get-UiText result.note.defaultApps)
    }
    if ($taskbarPinsOk) {
        Set-TaskbarPins -OutputFolder $installFolder -LinkNames $taskbarApps
    } else {
        Write-Log "Taskbar pins need Windows 11 24H2 build 26100.4484 or later - skipped; $($taskbarApps -join ', ') stay on the desktop"
    }
    Register-BingWallpaper -InstallFolder $installFolder

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
    Invoke-FinalCleanup -SetupRoot $setupRoot -KeepRecycleBin:$InstallOnly
    Register-SetupFolderCleanup -SetupRoot $setupRoot
    if (-not $InstallOnly) { New-SetupRestorePoint }

    # Final: restart Explorer so the taskbar, desktop-icon and Start settings show right away.
    # Install only leaves Explorer alone (the settings apply at the next sign-in).
    if (-not $InstallOnly) {
        Write-Log "Finalizing: restarting Explorer (98%)"
        $script:CurrentStep = 'finalize'
        Restart-Explorer
    }

    # Any pending restart (updates, removed antivirus, servicing) is offered in the result window
    if (Test-PendingReboot) { $script:RebootRequired = $true }

    # More updates usually follow the restart (always after a feature update): one more pass
    # at the technician's next sign-in
    # BIOS/firmware from the maker's tool (profiles with "oemFirmware"): in that follow-up, when
    # BitLocker is off and no restart is pending; without a pending restart, right here
    $script:ResultNotes = @($script:ResultNotes)
    $oemFirmware = [bool]$deploymentConfig.oemFirmware -and -not $InstallOnly -and -not $SkipUpdates
    $reportPath = Join-Path $installFolder "$(Get-UiText report.title).html"
    if (-not $SkipUpdates -and $script:RebootRequired) {
        if (Register-UpdateFollowUp -SourceRoot $PSScriptRoot -InstallFolder $installFolder -Language $Language `
                -ReportFile $reportPath -Firmware:$oemFirmware) {
            $script:ResultNotes += Get-UiText result.note.followUp
        }
    } elseif ($oemFirmware) {
        Write-Log "BIOS/firmware updates from the maker's tool..."
        $script:CurrentStep = 'firmware'
        $script:FirmwareResult = Invoke-OemFirmwareUpdate
        if ($script:RebootRequired) { $script:ResultNotes += Get-UiText result.note.firmware }
    }

    # Handover report for the customer file (C:\Install)
    $reportPackages = @($deploymentConfig.packages) + $(if ($gpuInfo.IsNvidia) { 'nvidia-app' })
    try {
        $script:ReportFile = New-SetupReport -Folder $installFolder -DeploymentType $DeploymentType `
            -Packages $reportPackages -Notes @($script:ResultNotes | Where-Object { $_ })
    }
    catch {
        Write-Log "Setup report could not be written: $_"
    }

    # Shown last: the technician has usually walked away, and a window before the
    # Explorer restart would hold it back until someone clicks
    $issues = Get-LogIssues
    if ($issues.Count -eq 0) {
        Write-Log "=== Setup Completed Successfully ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        $successTitle = if ($InstallOnly) { Get-UiText result.installOnly.title } else { Get-UiText result.success.title }
        Show-SetupResult -Status Success -Title $successTitle -Subtitle (Get-RunSummary) `
            -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired) -Notes @($script:ResultNotes | Where-Object { $_ }) -ReportFile $script:ReportFile
    } else {
        Write-Log "=== Setup Finished With $($issues.Count) Warning(s) ===" -Level Success
        Write-Log "Log file: $($script:LogFile)"
        $warningTitle = if ($issues.Count -eq 1) { Get-UiText result.warning.title.one } else { Get-UiText result.warning.title.many $issues.Count }
        Show-SetupResult -Status Warning -Title $warningTitle -Subtitle (Get-RunSummary) `
            -Items $issues -LogFile $script:LogFile -RebootRequired:([bool]$script:RebootRequired) -Notes @($script:ResultNotes | Where-Object { $_ }) -ReportFile $script:ReportFile
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

# Signs of a PC in use (before Step 0), health checks (Step 12).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
Function Get-UsedPcSigns {
    <#
    .SYNOPSIS
        Signs that this PC is already in use, as texts for the question before a full setup
    .DESCRIPTION
        A log from an earlier run of this tool; 10 or more personal files in an account
        (Desktop, Documents, Pictures, Videos, Music and OneDrive folders - shortcuts and
        hidden files don't count); a Windows installation older than 30 days (a feature
        update resets that date, so it can only add to the other signs).
    #>
    # Each sign on its own: one unreadable profile must not hide the others. Directory.Exists,
    # not Test-Path: under 'Stop', Test-Path throws on a folder this account can't read.
    $signs = @()
    $culture = [cultureinfo]::GetCultureInfo(@{ de = 'de-DE'; en = 'en-GB'; it = 'it-IT' }[(Get-UiLanguage)])
    try {
        $previous = Get-ChildItem -Path $script:config.logging.logPath -Filter 'setup_*.log' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -ne $script:LogFile } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($previous) { $signs += Get-UiText used.previousRun $previous.LastWriteTime.ToString('d', $culture) }
    }
    catch { Write-Log "Used-PC check (earlier runs) skipped: $_" }

    $minFiles = 10
    $profiles = @(Get-CimInstance Win32_UserProfile -Filter 'Special = FALSE' -ErrorAction SilentlyContinue |
        Where-Object { $_.LocalPath -and [IO.Directory]::Exists($_.LocalPath) })
    foreach ($userProfile in $profiles) {
        try {
            $folders = @('Desktop', 'Documents', 'Pictures', 'Videos', 'Music' | ForEach-Object { Join-Path $userProfile.LocalPath $_ })
            $folders += @(Get-ChildItem -LiteralPath $userProfile.LocalPath -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue).FullName
            $found = @($folders | Where-Object { $_ -and [IO.Directory]::Exists($_) } |
                ForEach-Object { Get-ChildItem -LiteralPath $_ -File -Recurse -ErrorAction SilentlyContinue } |
                Where-Object { $_.Extension -notin '.lnk', '.url' } | Select-Object -First $minFiles).Count
            if ($found -ge $minFiles) { $signs += Get-UiText used.files @((Split-Path $userProfile.LocalPath -Leaf), $minFiles) }
        }
        catch { Write-Log "Used-PC check skipped $($userProfile.LocalPath): $_" }
    }

    try {
        $installDate = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).InstallDate
        $days = [int]((Get-Date) - $installDate).TotalDays
        if ($days -gt 30) { $signs += Get-UiText used.installDate @($installDate.ToString('d', $culture), $days) }
    }
    catch { Write-Log "Used-PC check (install date) skipped: $_" }
    return $signs
}

Function Test-SetupHealth {
    <#
    .SYNOPSIS
        Final checks shown in the result window: activation, Defender, edition vs. profile
    #>
    param([string]$DeploymentType)

    # What the setup report shows: Activated $true/$false, Defender 'active'/'inactive'
    $script:Health = @{ Activated = $null; Defender = $null }

    # Windows activation (ApplicationID = Windows)
    try {
        $license = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop |
            Select-Object -First 1
        $script:Health.Activated = [bool]($license -and $license.LicenseStatus -eq 1)
        if ($script:Health.Activated) {
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
            $script:Health.Defender = if ($mp.AMRunningMode -eq 'Normal' -and $mp.RealTimeProtectionEnabled) { 'active' } else { 'inactive' }
            if ($script:Health.Defender -eq 'active') {
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

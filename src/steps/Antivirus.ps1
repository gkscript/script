# Preinstalled antivirus trials (Step 0).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
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

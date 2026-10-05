# Update follow-up after the restart at the end of a setup run. Started by the one-shot task
# "\Netixx\Update-Nachlauf" one minute after the technician signs in again (Register-UpdateFollowUp
# copies this script with what it needs to C:\Install\gk-script). Installs the updates that only
# appear after the restart (always after a feature update), updates apps, adds the result to the
# setup report and shows the result window. Keep this file ASCII (Windows PowerShell 5.1).
param(
    [ValidateSet('de', 'en', 'it')]
    [string]$Language = 'de',

    # 1-3; another restart with more updates registers the next pass
    [int]$Pass = 1,

    # Setup report (HTML) to append this pass to
    [string]$ReportFile,

    # BIOS/firmware from the maker's tool first (profiles with "oemFirmware"; first pass only)
    [switch]$Firmware
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\PSSetupUtility.psm1" -Force
$relaunchExit = Restart-In64BitPowerShell -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
if ($null -ne $relaunchExit) { exit $relaunchExit }
foreach ($stepFile in 'Updates', 'Packages', 'Report', 'Firmware') {
    . (Join-Path $PSScriptRoot "steps\$stepFile.ps1")
}
Set-UiLanguage $Language

# One shot: the task goes first, so a crash can't make it run at every sign-in
Unregister-ScheduledTask -TaskPath '\Netixx\' -TaskName 'Update-Nachlauf' -Confirm:$false -ErrorAction SilentlyContinue

$startTime = Get-Date
$script:LogFile = Initialize-Logging -Name 'update'
$version = (Get-Content "$PSScriptRoot\version.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s'
Write-Log "=== Update follow-up (pass $Pass, v$version) ===" -Level Success
Set-KeepAwake -Enable
$again = $false

Function Get-FollowUpSummary([int]$Count) {
    $minutes = [int][math]::Floor(((Get-Date) - $startTime).TotalMinutes)
    $duration = if ($minutes -lt 1) { Get-UiText duration.lessThanMinute } else { Get-UiText duration.minutes $minutes }
    $updates = if ($Count -eq 1) { Get-UiText followup.summary.one } else { Get-UiText followup.summary $Count }
    return ($updates, $env:COMPUTERNAME, $duration) -join " $([char]0xB7) "
}

try {
    # Wi-Fi tied to this account connects only after the sign-in: wait up to 5 minutes
    for ($i = 0; $i -lt 30; $i++) {
        try { $null = [System.Net.Dns]::GetHostAddresses('download.windowsupdate.com'); break } catch { Start-Sleep -Seconds 10 }
    }

    $firmwareResult = $null
    if ($Firmware) {
        Write-Log "BIOS/firmware updates from the maker's tool..."
        $firmwareResult = Invoke-OemFirmwareUpdate
    }
    Install-WindowsUpdates
    Update-InstalledApps
    if (Test-PendingReboot) { $script:RebootRequired = $true }
    $installed = @($script:InstalledUpdates)

    # Another restart that brings more updates: one more pass (at most 3)
    $notes = @()
    if ($firmwareResult -and $script:RebootRequired) { $notes += Get-UiText result.note.firmware }
    if ($script:RebootRequired -and $installed.Count -gt 0 -and $Pass -lt 3) {
        $installFolder = Split-Path $PSScriptRoot -Parent
        $again = Register-UpdateFollowUp -SourceRoot $PSScriptRoot -InstallFolder $installFolder -Language $Language `
            -Pass ($Pass + 1) -ReportFile $ReportFile
        if ($again) { $notes += Get-UiText followup.note.again }
    }

    $issues = Get-LogIssues
    if ($ReportFile) {
        $culture = [cultureinfo]::GetCultureInfo(@{ de = 'de-DE'; en = 'en-GB'; it = 'it-IT' }[$Language])
        Add-SetupReportSection -Path $ReportFile -Heading (Get-UiText report.followUp (Get-Date).ToString('g', $culture)) `
            -Items (@($firmwareResult | Where-Object { $_ }) + $installed) -Attention $issues
    }

    $summary = Get-FollowUpSummary $installed.Count
    if ($issues.Count -eq 0) {
        Show-SetupResult -Status Success -Title (Get-UiText followup.title) -Subtitle $summary -LogFile $script:LogFile `
            -RebootRequired:([bool]$script:RebootRequired) -Notes $notes -ReportFile $ReportFile
    } else {
        $warningTitle = if ($issues.Count -eq 1) { Get-UiText result.warning.title.one } else { Get-UiText result.warning.title.many $issues.Count }
        Show-SetupResult -Status Warning -Title $warningTitle -Subtitle $summary -Items $issues -LogFile $script:LogFile `
            -RebootRequired:([bool]$script:RebootRequired) -Notes $notes -ReportFile $ReportFile
    }
}
catch {
    Write-Log "Update follow-up failed: $_" -Level Error
    Show-SetupResult -Status Failed -Title (Get-UiText followup.failed.title) -Subtitle (Get-FollowUpSummary 0) `
        -Items @("$_") -LogFile $script:LogFile
}
finally {
    Set-KeepAwake
    Write-Log "Update follow-up ended at $(Get-Date)"
    # The last pass removes its copy from C:\Install once this process has exited - only that
    # copy, never a source folder this script was started from by hand
    $isInstalledCopy = (Split-Path $PSScriptRoot -Leaf) -eq 'gk-script' -and (Test-Path (Join-Path $PSScriptRoot 'postupdate.ps1')) -and
        -not (Test-Path (Join-Path $PSScriptRoot 'main.ps1'))
    if (-not $again -and $isInstalledCopy) {
        Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -WindowStyle Hidden `
            -ArgumentList '/c', "ping -n 6 127.0.0.1 >nul & rd /s /q `"$PSScriptRoot`""
    }
}

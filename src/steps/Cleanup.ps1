# Cleanup and restore point (Step 13).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
Function Invoke-FinalCleanup {
    <#
    .SYNOPSIS
        Leave no installation leftovers: temp folders, recycle bin, Delivery Optimization cache
    .PARAMETER SetupRoot
        The folder this run is executing from - never touched here
    .PARAMETER KeepRecycleBin
        Install-only run: the recycle bin holds the customer's deleted files
    #>
    param([string]$SetupRoot, [switch]$KeepRecycleBin)
    foreach ($folder in @((Join-Path $env:SystemRoot 'Temp'), $env:TEMP)) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue |
            Where-Object { -not $SetupRoot -or $_.FullName.TrimEnd('\') -ine $SetupRoot.TrimEnd('\') } |
            ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
    }
    if (-not $KeepRecycleBin) { try { Clear-RecycleBin -Force -ErrorAction Stop } catch { } }
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop } catch { }
    $what = if ($KeepRecycleBin) { 'Temporary files and Delivery Optimization cache' } else { 'Temporary files, recycle bin and Delivery Optimization cache' }
    Write-Log "$what cleaned" -Level Success
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

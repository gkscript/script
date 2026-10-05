# BIOS, firmware and drivers from the PC maker's own tool (profiles with "oemFirmware": true).
# Runs in the update follow-up after the restart: BitLocker is off then and no restart is
# pending - both make the tools skip the BIOS or refuse to run. Windows Update already delivers
# the UEFI capsules a maker publishes there; the tools add BIOS versions not (yet) offered there,
# non-capsule firmware and newer drivers. Only Dell (Command Update) and HP business models
# (Image Assistant) have a silent, documented command line; consumer lines aren't supported by
# them, Lenovo System Update reaches end of maintenance 2026-10-31. Dot-sourced. Keep ASCII.

Function Invoke-OemFirmwareUpdate {
    <#
    .SYNOPSIS
        Dell / HP: install BIOS, firmware and driver updates with the maker's tool, then remove it
    .DESCRIPTION
        Returns a result line for the report (in the UI language), or $null when nothing applies.
        Sets $script:RebootRequired when a BIOS/firmware update is staged for the restart.
        Command lines and exit codes from Dell's DCU CLI reference and HP's HPIA user guide.
    #>
    $maker = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).Manufacturer
    # A BIOS flash needs mains power (Dell, HP, Lenovo all say so); on battery only drivers/firmware
    Add-Type -AssemblyName System.Windows.Forms
    $onAc = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus -ne 'Offline'
    if (-not $onAc) {
        Write-Log "On battery - BIOS updates skipped this time" -Level Warning -Key warn.firmwareBattery
    }
    $logFolder = Split-Path $script:LogFile -Parent

    if ($maker -match '^Dell') {
        if ((Install-WingetPackage -Id 'Dell.CommandUpdate.Universal' -Source 'winget') -ne 'installed') {
            Write-Log "Dell Command Update could not be installed" -Level Warning -Key warn.firmware -KeyArgs 'Dell Command Update', '-'
            return Get-UiText firmware.notInstalled 'Dell Command Update'
        }
        $cli = @("$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe", "${env:ProgramFiles(x86)}\Dell\CommandUpdate\dcu-cli.exe") |
            Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $cli) {
            Write-Log "dcu-cli.exe not found after the install" -Level Warning -Key warn.firmware -KeyArgs 'Dell Command Update', '-'
            return Get-UiText firmware.notInstalled 'Dell Command Update'
        }
        $types = if ($onAc) { 'bios,firmware,driver' } else { 'firmware,driver' }
        # -autoSuspendBitLocker=enable would restart the PC on its own right after a BIOS update
        $arguments = "/applyUpdates -silent -reboot=disable -updateType=$types -autoSuspendBitLocker=disable -outputLog=`"$logFolder\dcu.log`""
        Write-Log "Dell Command Update: $types..."
        $code = Invoke-FirmwareTool -FilePath $cli -Arguments $arguments
        # 0 done, 1 restart needed, 5 restart pending, 7 model not supported, 500 nothing to do
        $state = switch ($code) {
            0       { 'installed' }
            1       { $script:RebootRequired = $true; 'staged' }
            5       { $script:RebootRequired = $true; 'pending' }
            7       { 'unsupported' }
            500     { 'upToDate' }
            default { Write-Log "Dell Command Update finished with code $code" -Level Warning -Key warn.firmware -KeyArgs 'Dell Command Update', $code; 'error' }
        }
        Write-Log "Dell Command Update: $state (exit $code)"
        $null = Invoke-NativeCommand winget @('uninstall', '--id', 'Dell.CommandUpdate.Universal', '--exact', '--silent', '--accept-source-agreements', '--disable-interactivity')
        return Get-UiText "firmware.$state" @('Dell Command Update', $code)
    }

    if ($maker -match '^(HP|Hewlett)') {
        $folder = Join-Path $env:SystemDrive 'SWSetup\HPImageAssistant'
        $downloads = Join-Path $env:SystemDrive 'SWSetup\HPIA'
        if ((Install-WingetPackage -Id 'HP.ImageAssistant' -Source 'winget') -ne 'installed' -or -not (Test-Path "$folder\HPImageAssistant.exe")) {
            Write-Log "HP Image Assistant could not be installed" -Level Warning -Key warn.firmware -KeyArgs 'HP Image Assistant', '-'
            return Get-UiText firmware.notInstalled 'HP Image Assistant'
        }
        $categories = if ($onAc) { 'BIOS,Drivers,Firmware' } else { 'Drivers,Firmware' }
        $arguments = "/Operation:Analyze /Action:Install /Category:$categories /Selection:All /Silent /AutoCleanup /ReportFolder:`"$logFolder\HPIA`" /SoftpaqDownloadFolder:`"$downloads`""
        Write-Log "HP Image Assistant: $categories..."
        $code = Invoke-FirmwareTool -FilePath "$folder\HPImageAssistant.exe" -Arguments $arguments
        # 0 done, 256/257 nothing to do, 3010 restart needed, 3011 some need a manual install,
        # 4096 platform not supported (consumer models)
        $state = switch ($code) {
            0       { 'installed' }
            { $_ -in 256, 257 } { 'upToDate' }
            3010    { $script:RebootRequired = $true; 'staged' }
            3011    { 'manual' }
            4096    { 'unsupported' }
            default { Write-Log "HP Image Assistant finished with code $code" -Level Warning -Key warn.firmware -KeyArgs 'HP Image Assistant', $code; 'error' }
        }
        Write-Log "HP Image Assistant: $state (exit $code)"
        foreach ($path in $folder, $downloads) { Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue }
        return Get-UiText "firmware.$state" @('HP Image Assistant', $code)
    }

    Write-Log "BIOS/firmware for '$maker' comes from Windows Update (no supported maker tool)"
    return $null
}

Function Invoke-FirmwareTool {
    # Start a maker tool and wait (60 min at most - a stuck tool can't hold the run); its exit code
    param([string]$FilePath, [string]$Arguments)
    $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit(60 * 60 * 1000)) {
        $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
        return -1
    }
    return $proc.ExitCode
}

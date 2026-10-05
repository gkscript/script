# Windows Update, pending restart, component cleanup (Step 3b, 13; also postupdate.ps1).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
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

    # Titles of what got installed - the setup report lists them
    if ($null -eq $script:InstalledUpdates) { $script:InstalledUpdates = @() }

    # Windows Update busy, or no network yet (right after a sign-in): wait and try again.
    # 0x80240009 operation in progress, 0x80240016 install not allowed (another install or a
    # pending mandatory restart), 0x80242014 post-reboot work still running, 0x8024402C name
    # not resolved, 0x8024001F no connection, 0x80246005 no network (Windows Update error reference)
    $transient = @(0x80240009, 0x80240016, 0x80242014, 0x8024402C, 0x8024001F, 0x80246005) | ForEach-Object { [int]$_ }
    for ($attempt = 1; $attempt -le 10; $attempt++) {
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
            # IsBusy: another installation is running (e.g. Windows' own right after a feature update)
            for ($wait = 0; $installer.IsBusy -and $wait -lt 90; $wait++) { Start-Sleep -Seconds 10 }
            $installer.Updates = $toInstall
            $result = $installer.Install()

            # OperationResultCode: 2 = Succeeded, 3 = SucceededWithErrors, 4 = Failed, 5 = Aborted
            for ($i = 0; $i -lt $toInstall.Count; $i++) {
                $code = $result.GetUpdateResult($i).ResultCode
                $title = $toInstall.Item($i).Title
                if ($code -eq 2) {
                    $totalInstalled++
                    $script:InstalledUpdates += $title
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
        break
    }
    catch {
        # COM errors arrive wrapped (MethodInvocationException); the code is on the innermost one
        $inner = $_.Exception
        while ($inner.InnerException) { $inner = $inner.InnerException }
        $hresult = $inner.HResult
        if ($hresult -in $transient -and $attempt -lt 10) {
            Write-Log ("Windows Update busy or offline (0x{0:X8}) - retrying in 90 s ({1}/10)" -f $hresult, $attempt)
            Start-Sleep -Seconds 90
            continue
        }
        Write-Log "Windows Update failed: $_" -Level Warning -Key warn.updatesError -KeyArgs "$_"
        break
    }
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

Function Register-UpdateFollowUp {
    <#
    .SYNOPSIS
        Run Windows Update once more after the restart, at the technician's next sign-in
    .DESCRIPTION
        A feature update completes during the restart, and more updates usually follow it.
        postupdate.ps1 and what it needs are copied to C:\Install\gk-script (the setup folder
        in %TEMP% is deleted at the next start); a one-shot task runs it one minute after this
        account signs in again, elevated and visible. It removes its task when it starts and
        registers the next pass itself if another restart brings more updates (at most 3).
    #>
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$InstallFolder,
        [string]$Language = 'de',
        [int]$Pass = 1,
        [string]$ReportFile,
        # Run the maker's BIOS/firmware tool first (Invoke-OemFirmwareUpdate)
        [switch]$Firmware
    )
    try {
        $user = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if (-not $user) { throw 'no signed-in user' }
        # RunLevel Highest only elevates an administrator; a standard account (elevated with
        # other credentials) would get a token that can't install updates
        $self = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        if ($self -ine $user) {
            $admins = @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
            if ($admins.Count -and $admins -notcontains $user) { throw "$user is not an administrator" }
        }

        $target = Join-Path $InstallFolder 'gk-script'
        if ($SourceRoot.TrimEnd('\') -ine $target.TrimEnd('\')) {
            foreach ($folder in 'lib', 'steps', 'lang') { $null = New-Item -ItemType Directory -Force -Path (Join-Path $target $folder) }
            Copy-Item -Path (Join-Path $SourceRoot 'lib\*') -Destination (Join-Path $target 'lib') -Recurse -Force
            Copy-Item -Path (Join-Path $SourceRoot 'lang\*') -Destination (Join-Path $target 'lang') -Force
            foreach ($stepFile in 'Updates.ps1', 'Packages.ps1', 'Report.ps1', 'Firmware.ps1') {
                Copy-Item -Path (Join-Path $SourceRoot "steps\$stepFile") -Destination (Join-Path $target 'steps') -Force
            }
            foreach ($file in 'postupdate.ps1', 'version.txt', 'netixx.ico') {
                Copy-Item -Path (Join-Path $SourceRoot $file) -Destination $target -Force
            }
        }

        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$target\postupdate.ps1`" -Language $Language -Pass $Pass"
        if ($ReportFile) { $arguments += " -ReportFile `"$ReportFile`"" }
        if ($Firmware) { $arguments += ' -Firmware' }
        $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument $arguments
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT1M'
        # Never signed in again within a week: the task expires and deletes itself
        $trigger.EndBoundary = (Get-Date).AddDays(7).ToString('s')
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
            -StartWhenAvailable -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)
        Register-ScheduledTask -TaskPath '\Netixx\' -TaskName 'Update-Nachlauf' -Action $action -Trigger $trigger `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
        Write-Log "Update follow-up registered (pass $Pass) - runs one minute after $user signs in again" -Level Success
        return $true
    }
    catch {
        Write-Log "Update follow-up could not be registered: $_" -Level Warning -Key warn.followUp -KeyArgs "$_"
        return $false
    }
}

# Desktop, Start and taskbar pins, wallpaper, Explorer (Step 5, 11, final).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
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

Function Get-DesktopShortcuts {
    <#
    .SYNOPSIS
        Shortcut files (.lnk/.url) on the desktops this tool may clean
    .DESCRIPTION
        The Public Desktop (where installers put their shortcuts) and the user's desktop only
        while it is the local folder: with OneDrive backup it holds the customer's synced
        files, and deletions there would sync to the cloud. Never recursive.
    #>
    $folders = @([Environment]::GetFolderPath('CommonDesktopDirectory'))
    $userDesktop = [Environment]::GetFolderPath('Desktop')
    if ($userDesktop.TrimEnd('\') -ieq (Join-Path $env:USERPROFILE 'Desktop').TrimEnd('\')) {
        $folders += $userDesktop
    } else {
        Write-Log "  User desktop is redirected ($userDesktop) - left untouched"
    }
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        Get-ChildItem -LiteralPath $folder -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in '.lnk', '.url' }
    }
}

Function Clear-DesktopIcons {
    <#
    .SYNOPSIS
        Remove desktop shortcuts that are not on the whitelist
    .DESCRIPTION
        Only shortcut files are removed - never folders or documents (Get-DesktopShortcuts).
        Whitelist entries may use wildcards (e.g. LibreOffice*.lnk).
    .PARAMETER Keep
        Full paths left alone: the install-only run passes the shortcuts that were there
        before it installed anything, so only the installers' new ones go
    .PARAMETER ExtraWhitelist
        Names kept in addition to whitelist.txt (the taskbar apps when Windows can't pin them)
    #>
    param(
        [string]$WhitelistPath,
        [string[]]$Keep = @(),
        [string[]]$ExtraWhitelist = @()
    )

    Write-Log "Cleaning desktop icons..."

    try {
        if (-not (Test-Path $WhitelistPath)) {
            Write-Log "Whitelist not found: $WhitelistPath" -Level Warning -Key warn.whitelistMissing -KeyArgs $WhitelistPath
            return
        }

        $whitelist = @(Get-Content $WhitelistPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() }) + @($ExtraWhitelist)
        $isWhitelisted = { param($name) [bool]($whitelist | Where-Object { $name -like $_ }) }

        $removedCount = 0
        foreach ($item in Get-DesktopShortcuts) {
            if ((& $isWhitelisted $item.Name) -or $Keep -contains $item.FullName) { continue }
            Write-Log "  Removing: $($item.FullName)"
            Remove-Item -LiteralPath $item.FullName -Force -ErrorAction Continue
            $removedCount++
        }

        Write-Log "Removed $removedCount desktop shortcuts" -Level Success
    }
    catch {
        Write-Log "Desktop cleanup failed: $_" -Level Error -Key warn.desktopFatal -KeyArgs "$_"
        throw
    }
}

Function Test-TaskbarPinSupport {
    <#
    .SYNOPSIS
        Whether Windows applies taskbar pins with PinGeneration (24H2 build 26100.4484 or later)
    .DESCRIPTION
        Microsoft: assign PinGeneration only to patched devices, "otherwise the taskbar pins
        don't apply". A run that installs all updates ends on a current build after its restart.
    #>
    $version = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $build = [int]$version.CurrentBuildNumber
    return ($build -ge 26200) -or ($build -eq 26100 -and [int]$version.UBR -ge 4484) -or (-not $SkipUpdates)
}

Function Set-TaskbarPins {
    <#
    .SYNOPSIS
        Pin apps to the taskbar once, after the Windows default pins
    .DESCRIPTION
        "Start Layout" policy with a taskbar layout XML (Microsoft Learn, taskbar/pinned-apps):
        applies to the current and every later account at its next sign-in. Without
        PinListPlacement="Replace" the default pins (Edge, Store, File Explorer) stay and these
        follow them; PinGeneration="1" applies each pin once, so one the user removes stays
        removed. Policy values from the local StartMenu.admx. The XML must stay in place and
        must not contain comments.
    #>
    param(
        [Parameter(Mandatory)][string]$OutputFolder,
        [string[]]$LinkNames = @()
    )
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $links = @(foreach ($linkName in $LinkNames) {
        Get-ChildItem -LiteralPath $programs -Filter $linkName -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
    })
    if ($links.Count -eq 0) {
        Write-Log "Taskbar pins: none of $($LinkNames -join ', ') found in the Start menu - skipped"
        return
    }
    try {
        $pins = @($links | ForEach-Object {
            "        <taskbar:DesktopApp DesktopApplicationLinkPath=`"$([System.Security.SecurityElement]::Escape($_))`" PinGeneration=`"1`"/>"
        })
        $xml = @(
            '<?xml version="1.0" encoding="utf-8"?>'
            '<LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1">'
            '  <CustomTaskbarLayoutCollection>'
            '    <defaultlayout:TaskbarLayout>'
            '      <taskbar:TaskbarPinList>'
        ) + $pins + @(
            '      </taskbar:TaskbarPinList>'
            '    </defaultlayout:TaskbarLayout>'
            '  </CustomTaskbarLayoutCollection>'
            '</LayoutModificationTemplate>'
        )
        $xmlPath = Join-Path $OutputFolder 'TaskbarLayout.xml'
        [System.IO.File]::WriteAllText($xmlPath, ($xml -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
        $key = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
        if (-not (Test-Path $key)) { $null = New-Item -Path $key -Force }
        Set-ItemProperty -Path $key -Name 'LockedStartLayout' -Value 1 -Type DWord -Force
        Set-ItemProperty -Path $key -Name 'StartLayoutFile' -Value $xmlPath -Type ExpandString -Force
        Write-Log "Taskbar pins configured ($(($links | ForEach-Object { Split-Path $_ -Leaf }) -join ', '); once per account at its next sign-in)" -Level Success
    }
    catch {
        Write-Log "Taskbar pins could not be configured: $_" -Level Warning -Key warn.taskbarPins -KeyArgs "$_"
    }
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
        # This file is in src\steps; the wallpaper script sits in src
        Copy-Item -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'BingWallpaper.ps1') -Destination $target -Force
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

Function Restart-Explorer {
    <#
    .SYNOPSIS
        Restart Explorer so settings written to the registry show without a sign-out
    .DESCRIPTION
        Windows restarts the shell by itself (AutoRestartShell) as the signed-in user. If it
        isn't back within 15 s, it is started as that user through a short-lived scheduled
        task - an Explorer started from this elevated session would be rejected as the shell.
    .PARAMETER LayoutFile
        Desktop icon layout (.reg export of HKCU\Software\Microsoft\Windows\Shell\Bags\1\Desktop)
        to write while Explorer is down - a running Explorer overwrites IconLayouts when it
        exits. Only for that moment AutoRestartShell is 0 (restored in finally); unlike the old
        blanked Winlogon Shell value, a value left behind could not cost anyone the desktop.
    #>
    param([string]$LayoutFile)
    try {
        $winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        if ($LayoutFile -and (Test-Path -LiteralPath $LayoutFile)) {
            $autoRestart = (Get-ItemProperty -Path $winlogon -Name AutoRestartShell -ErrorAction SilentlyContinue).AutoRestartShell
            try {
                Set-ItemProperty -Path $winlogon -Name AutoRestartShell -Value 0 -Type DWord -Force
                Stop-ProcessWithTimeout -Name 'explorer' -TimeoutSeconds 15
                $null = Invoke-NativeCommand "$env:SystemRoot\System32\reg.exe" @('import', $LayoutFile)
                if ($LASTEXITCODE -eq 0) { Write-Log "Desktop icon layout applied ($(Split-Path $LayoutFile -Leaf))" -Level Success }
                else { Write-Log "Desktop icon layout import returned $LASTEXITCODE" -Level Warning -Key warn.regImport -KeyArgs (Split-Path $LayoutFile -Leaf), $LASTEXITCODE }
            }
            finally {
                $restore = if ($null -ne $autoRestart) { $autoRestart } else { 1 }
                Set-ItemProperty -Path $winlogon -Name AutoRestartShell -Value $restore -Type DWord -Force
            }
        } else {
            Stop-ProcessWithTimeout -Name 'explorer' -TimeoutSeconds 10
        }
        for ($i = 0; $i -lt 15 -and -not (Get-Process explorer -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 1 }
        if (Get-Process explorer -ErrorAction SilentlyContinue) {
            Write-Log "Explorer restarted" -Level Success
            return
        }
        $shellUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
        if (-not $shellUser) { Start-Process explorer.exe; return }
        $explorerAction    = New-ScheduledTaskAction -Execute "$env:SystemRoot\explorer.exe"
        $explorerPrincipal = New-ScheduledTaskPrincipal -UserId $shellUser -LogonType Interactive -RunLevel Limited
        $explorerSettings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -Priority 4
        try {
            Register-ScheduledTask -TaskName 'GKScript-StartExplorer' -Action $explorerAction `
                -Settings $explorerSettings -Principal $explorerPrincipal -Force | Out-Null
            Start-ScheduledTask -TaskName 'GKScript-StartExplorer'
            Start-Sleep -Seconds 2
            Write-Log "Explorer started as $shellUser" -Level Success
        }
        finally {
            Unregister-ScheduledTask -TaskName 'GKScript-StartExplorer' -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log "Explorer restart failed: $_" -Level Warning -Key warn.explorer -KeyArgs "$_"
    }
}

Function Add-DesktopShortcuts {
    <#
    .SYNOPSIS
        Copy Start-menu shortcuts to the Public Desktop (config "desktopShortcuts")
    .DESCRIPTION
        The fixed desktop layouts show icons no installer puts there: LibreOffice Writer, Calc and
        Impress (its installer adds only a Start Center icon) and Word, Excel, PowerPoint (Office
        adds none). A shortcut that isn't in the Start menu is skipped.
    #>
    param([string[]]$Names = @())
    $programs = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'
    $desktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    foreach ($name in $Names) {
        $source = Get-ChildItem -LiteralPath $programs -Filter $name -Recurse -File -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        if (-not $source) { Write-Log "  Desktop shortcut: $name not in the Start menu - skipped"; continue }
        Copy-Item -LiteralPath $source -Destination (Join-Path $desktop $name) -Force
        Write-Log "  Desktop shortcut: $name"
    }
}

Function Test-DesktopIsOurs {
    <#
    .SYNOPSIS
        True while the desktop holds only what this tool puts there (whitelisted shortcuts)
    .DESCRIPTION
        office.ps1 runs on its own, also on a PC in use: a fixed layout may only replace an icon
        arrangement this tool made, never one the customer set up. Any other shortcut, or any
        file on the user's desktop, means the desktop is the customer's.
    #>
    param([Parameter(Mandatory)][string]$WhitelistPath)
    $whitelist = @(Get-Content $WhitelistPath | Where-Object { $_.Trim() } | ForEach-Object { $_.Trim() })
    $folders = @([Environment]::GetFolderPath('CommonDesktopDirectory'), [Environment]::GetFolderPath('Desktop'))
    foreach ($folder in $folders) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $folder -Force -ErrorAction SilentlyContinue) {
            if ($item.Name -ieq 'desktop.ini') { continue }
            if (-not ($whitelist | Where-Object { $item.Name -like $_ })) { return $false }
        }
    }
    return $true
}

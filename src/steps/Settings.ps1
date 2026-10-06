# Registry and system settings, accounts created later (Step 4, 7, 11).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
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
        Firefox "FirefoxHTML-<hash>" / "FirefoxURL-<hash>" (assoc.txt names the base), and .url
        stays with Windows (a browser does not handle Internet Shortcuts).
    #>
    param([Parameter(Mandatory)][string]$AssocFile, [Parameter(Mandatory)][string]$OutputFolder)

    if (-not (Test-Path $AssocFile)) { return }
    $entries = New-Object System.Collections.Generic.List[object]
    $skipped = 0
    $firefoxProgIds = $null
    foreach ($line in Get-Content $AssocFile) {
        $parts = $line.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        if (@($parts).Count -lt 2) { continue }
        $identifier = $parts[0]; $progId = $parts[1]
        if ($identifier -eq '.url') { continue }

        $candidates = @($progId)
        if ($progId -match '^VLC\..+\.Document$') { $candidates = @(($progId -replace '\.Document$', ''), $progId) }
        # Firefox registers FirefoxHTML-<hash>/FirefoxURL-<hash>, the hash depending on its install folder
        if ($progId -match '^Firefox(HTML|URL|PDF)$') {
            if ($null -eq $firefoxProgIds) {
                $firefoxProgIds = @([Microsoft.Win32.Registry]::ClassesRoot.GetSubKeyNames() | Where-Object { $_ -like 'Firefox*-*' })
            }
            $candidates = @($firefoxProgIds | Where-Object { $_ -like "$progId-*" })
        }
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

# Software: winget first, Chocolatey as fallback (Step 2, 3c, 10b, 13).
# Dot-sourced into main.ps1's scope (not a module), so these functions read its state -
# $script:config, $SkipUpdates, $InstallOnly - directly. Keep this file ASCII (Windows PowerShell 5.1).
Function Install-Chocolatey {
    <#
    .SYNOPSIS
        Install Chocolatey (fallback package source) - script downloaded to a file, not piped to iex
    #>
    Write-Log "Installing Chocolatey..."
    try {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Log "Chocolatey is already installed" -Level Success
            return
        }
        $chocoScriptPath = Join-Path $env:TEMP "install-choco.ps1"
        Write-Log "Downloading Chocolatey installation script..."
        try {
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri "https://community.chocolatey.org/install.ps1" -OutFile $chocoScriptPath -ErrorAction Stop
            Write-Log "Executing Chocolatey installation script..."
            # The script unpacks with Expand-Archive. Without the Archive module's resources for the
            # display language (e.g. a language pack on another base image; Windows Sandbox), its
            # import only reports a missing ArchiveResources.psd1 - but under 'Stop' that error
            # makes the module "could not be loaded". The module reads the global preference, so load
            # it once under a global 'Continue' (verified in Windows Sandbox, de-DE without resources).
            $savedPreference = $global:ErrorActionPreference
            try {
                $global:ErrorActionPreference = 'Continue'
                Import-Module Microsoft.PowerShell.Archive -ErrorAction SilentlyContinue
            }
            finally {
                $global:ErrorActionPreference = $savedPreference
            }
            [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
            & $chocoScriptPath
            Remove-Item $chocoScriptPath -Force
            if (-not (Get-Command choco -ErrorAction SilentlyContinue)) { throw "Chocolatey installation failed" }
            Write-Log "Chocolatey installed successfully" -Level Success
        } finally {
            $ProgressPreference = 'Continue'
        }
    }
    catch {
        Write-Log "Failed to install Chocolatey: $_" -Level Error -Key warn.chocoFailed -KeyArgs "$_"
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
    'outlook'            = 'Outlook'
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

Function Install-ChocolateyPackages {
    <#
    .SYNOPSIS
        Install packages with Chocolatey (the fallback when winget fails)
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$PackageList,

        # Package parameters passed as --params (e.g. Adobe's update mode)
        [string]$ChocoParams
    )
    
    if ($PackageList.Count -eq 0) {
        Write-Log "No packages to install"
        return
    }
    
    Write-Log "Installing packages: $($PackageList -join ', ')"
    
    try {
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
    catch {
        Write-Log "Package installation failed: $_" -Level Error -Key warn.pkgFatal -KeyArgs "$_"
        throw
    }
}

Function Test-WingetUsable {
    # True when winget actually runs (prints its version), not just when the alias exists
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { return $false }
    try {
        $version = Invoke-NativeCommand winget @('--version')
        return ($LASTEXITCODE -eq 0 -and "$version" -match 'v?\d+\.\d+')
    }
    catch {
        return $false
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
    # The winget.exe alias exists before App Installer is registered for this account; only a real
    # call tells (on a fresh PC it fails with "... must be registered first")
    if (Test-WingetUsable) { return $true }
    Write-Log "winget not usable yet - registering App Installer..."
    try {
        Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop
    }
    catch {
        Write-Log "  App Installer registration failed: $_"
    }
    $windowsApps = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps'
    if ($env:Path -notlike "*$windowsApps*") { $env:Path = "$env:Path;$windowsApps" }
    # The Store may still be finishing the registration in the background: up to 2 minutes
    for ($i = 0; $i -lt 12; $i++) {
        if (Test-WingetUsable) {
            Write-Log "winget is ready" -Level Success
            return $true
        }
        Start-Sleep -Seconds 10
    }
    Write-Log "winget is not available - winget-based steps will be skipped" -Level Warning -Key warn.wingetMissing
    return $false
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
        [string]$ExtraArgs = '',
        # Already installed: update it (a PC in use, new Outlook preinstalled by Windows)
        [switch]$Upgrade
    )
    try {
        $winget = (Get-Command winget -ErrorAction SilentlyContinue).Source
        if (-not $winget) { return 'failed' }

        $listArgs = @('list', '--id', $Id, '--exact', '--source', $Source, '--accept-source-agreements', '--disable-interactivity')
        $null = Invoke-NativeCommand winget $listArgs
        if ($LASTEXITCODE -eq 0) {
            if (-not $Upgrade) {
                Write-Log "  Already installed: $Id"
                return 'installed'
            }
            $upgradeArgs = "upgrade --id $Id --exact --source $Source --silent --accept-package-agreements --accept-source-agreements --disable-interactivity"
            $proc = Start-Process -FilePath $winget -ArgumentList $upgradeArgs -NoNewWindow -PassThru
            $null = $proc.Handle
            if (-not $proc.WaitForExit(20 * 60 * 1000)) {
                $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
                Write-Log "  Already installed: $Id (update still running after 20 min - stopped)"
            } elseif ($proc.ExitCode -eq 0) {
                Write-Log "  Updated: $Id" -Level Success
            } else {
                # 0x8A15002B (-1978335189): no newer version
                Write-Log "  Already installed: $Id (no update applied, winget exit $($proc.ExitCode))"
            }
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
    catch {
        # winget that cannot start (e.g. App Installer not registered) must not end the run:
        # no more winget for this run, the caller falls back to Chocolatey
        Write-Log "  winget could not run ($_) - falling back to Chocolatey"
        $script:WingetReady = $false
        return 'failed'
    }
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
                $result = Install-WingetPackage -Id $id.Replace('{uilang}', $uiLang) -Source $source -ExtraArgs "$($entry.wingetArgs)" -Upgrade:(-not $SkipUpdates)
                if ($result -eq 'installed') { $done = $true; break }
                if ($result -eq 'failed') { break }
            }
        }
        if ($done) { continue }
        if ($entry -and -not $entry.choco) {
            # Store-only apps (e.g. new Outlook) have no Chocolatey package
            Write-Log "'$name' could not be installed with winget" -Level Warning -Key warn.pkgFailed -KeyArgs $name
            continue
        }

        $chocoId = if ($entry -and $entry.choco) { $entry.choco } else { $name }
        # One failed Chocolatey install is enough: retrying per package only gets the download
        # rate-limited (HTTP 429) and repeats the same warning
        if ($script:ChocolateyUnavailable) {
            Write-Log "'$name' could not be installed (winget and Chocolatey unavailable)" -Level Warning -Key warn.pkgFailed -KeyArgs $name
            continue
        }
        Write-Log "  Falling back to Chocolatey for $name ($chocoId)"
        try {
            if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
                try { Install-Chocolatey } catch { $script:ChocolateyUnavailable = $true; throw }
            }
            Install-ChocolateyPackages -PackageList @($chocoId) -ChocoParams "$($entry.chocoParams)"
        }
        catch {
            Write-Log "Chocolatey fallback failed for ${name}: $_" -Level Warning -Key warn.pkgFailed -KeyArgs $name
        }
    }
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
    if (-not $winget -or -not (Test-WingetUsable)) {
        Write-Log "winget not available - skipping app updates"
        return
    }
    Write-Log "Updating installed apps with winget..."
    $arguments = 'upgrade --all --silent --source winget --accept-package-agreements --accept-source-agreements --disable-interactivity'
    try {
        $proc = Start-Process -FilePath $winget.Source -ArgumentList $arguments -NoNewWindow -PassThru
    }
    catch {
        Write-Log "winget could not run ($_) - app updates skipped"
        return
    }
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

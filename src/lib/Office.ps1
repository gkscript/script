# Microsoft Office: removal (main.ps1 Step 9, office.ps1) and installation (office.ps1).
# Dot-sourced by PSSetupUtility; $PSScriptRoot is src\lib, the Office files sit in src.
# Keep this file ASCII (Windows PowerShell 5.1 reads it as ANSI).

$script:OfficeC2RKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'

Function Get-OfficeProductIds {
    <#
    .SYNOPSIS
        Click-to-Run products installed now (e.g. O365BusinessRetail, ProofingTools)
    #>
    $ids = (Get-ItemProperty -Path $script:OfficeC2RKey -Name ProductReleaseIds -ErrorAction SilentlyContinue).ProductReleaseIds
    if ([string]::IsNullOrWhiteSpace($ids)) { return @() }
    return @($ids -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

Function Get-OfficeSetup {
    <#
    .SYNOPSIS
        The current Click-to-Run setup.exe from Microsoft's CDN, or $null if it can't be had
    .DESCRIPTION
        The CDN file is the setup.exe of the current Office Deployment Tool (byte-identical,
        checked 2026-10; also what Microsoft's own winget manifest installs from). Used only if
        it carries a valid Microsoft signature. Nothing is bundled: the run needs internet
        anyway, and the Office files themselves always come from the CDN.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Folder
    )
    $target = Join-Path $Folder 'setup.exe'
    try {
        $null = New-Item -ItemType Directory -Force -Path $Folder
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $target -UseBasicParsing -TimeoutSec 120
        $sig = Get-AuthenticodeSignature -FilePath $target
        if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '^CN=Microsoft Corporation,') {
            Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
            throw "signature check failed ($($sig.Status), $($sig.SignerCertificate.Subject))"
        }
        Write-Log "Current Office setup downloaded (version $((Get-Item -LiteralPath $target).VersionInfo.FileVersion))"
        return $target
    }
    catch {
        Write-Log "Office setup could not be downloaded: $_"
        return $null
    }
}

Function New-OfficeConfiguration {
    <#
    .SYNOPSIS
        Write the Office Deployment Tool XML for one product
    .DESCRIPTION
        64-bit, Current Channel (retail 2024 and Microsoft 365 alike - PerpetualVL2024 is for
        volume editions only), the Windows display language, proofing tools for the other
        languages, silent with the EULA accepted, updates on, MSI Office removed. Options from
        Microsoft Learn "Configuration options for the Office Deployment Tool".
    #>
    param(
        [Parameter(Mandatory)][string]$ProductId,
        [string[]]$ExcludeApps = @(),
        [string[]]$ProofingLanguages = @(),
        [Parameter(Mandatory)][string]$Path
    )
    $lines = @(
        '<Configuration>'
        '  <Add OfficeClientEdition="64" Channel="Current">'
        "    <Product ID=`"$ProductId`">"
        '      <Language ID="MatchOS" Fallback="en-us"/>'
    )
    $lines += @($ExcludeApps | Where-Object { $_ } | ForEach-Object { "      <ExcludeApp ID=`"$_`"/>" })
    $lines += '    </Product>'
    if (@($ProofingLanguages).Count -gt 0) {
        $lines += '    <Product ID="ProofingTools">'
        $lines += @($ProofingLanguages | ForEach-Object { "      <Language ID=`"$_`"/>" })
        $lines += '    </Product>'
    }
    $lines += @(
        '  </Add>'
        '  <RemoveMSI/>'
        '  <Updates Enabled="TRUE"/>'
        '  <Property Name="FORCEAPPSHUTDOWN" Value="TRUE"/>'
        '  <Display Level="None" AcceptEULA="TRUE"/>'
        '</Configuration>'
    )
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $Path -Parent)
    [System.IO.File]::WriteAllText($Path, ($lines -join "`r`n"), (New-Object System.Text.UTF8Encoding $false))
}

Function Uninstall-Microsoft365 {
    <#
    .SYNOPSIS
        Remove every Office product silently: ODT, then winget, then silent registry uninstalls
    .PARAMETER SetupExe
        Click-to-Run setup.exe to use (office.ps1 passes the one it downloaded)
    .PARAMETER SetupUrl
        Without -SetupExe: where to download it, once Office has actually been found
    #>
    param([string]$SetupExe, [string]$SetupUrl)
    Write-Log "Uninstalling Microsoft 365..."

    $clickToRunKey = 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )

    function Get-OfficeUninstallEntries {
        Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match '^(Microsoft 365|Microsoft Office)' -and -not $_.SystemComponent }
    }

    # Covers Click-to-Run (ProductReleaseIds) and MSI-based Office (uninstall entries)
    function Test-OfficeStillInstalled {
        if (Test-Path $clickToRunKey) {
            $ids = (Get-ItemProperty -Path $clickToRunKey -Name ProductReleaseIds -ErrorAction SilentlyContinue).ProductReleaseIds
            if (-not [string]::IsNullOrWhiteSpace($ids)) { return $true }
        }
        return [bool](Get-OfficeUninstallEntries)
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 not detected - skipping" -Level Info
        return
    }

    # Pass 1: Office Deployment Tool - silent by design (Display Level=None), removes
    # every Click-to-Run product/language and MSI Office in one go
    $odtPath = $SetupExe
    if (-not $odtPath -and $SetupUrl) { $odtPath = Get-OfficeSetup -Url $SetupUrl -Folder (Join-Path $env:TEMP 'NetixxOffice') }
    $odtXml  = Join-Path (Split-Path $PSScriptRoot -Parent) "office.xml"
    if ($odtPath -and (Test-Path $odtPath -PathType Leaf) -and (Test-Path $odtXml -PathType Leaf)) {
        Write-Log "Attempting Office removal via Office Deployment Tool..." -Level Info
        try {
            $odt = Start-Process -FilePath $odtPath -ArgumentList @('/configure', "`"$odtXml`"") -NoNewWindow -PassThru
            $null = $odt.Handle
            if ($odt.WaitForExit(20 * 60 * 1000)) {
                Write-Log "  Office Deployment Tool exit code: $($odt.ExitCode)"
            } else {
                Write-Log "  Office Deployment Tool still running after 20 min - continuing" -Level Info
            }
        }
        catch {
            Write-Log "  Office Deployment Tool failed: $_" -Level Info
        }
    } else {
        Write-Log "  Office setup or office.xml not available - skipping ODT removal" -Level Info
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 removed successfully" -Level Success
        return
    }

    # Pass 2: winget (handles locale variants by display name)
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Log "Attempting Office removal via winget..." -Level Info
        $null = Invoke-NativeCommand winget @('source', 'update', '--disable-interactivity')

        $officeNames = @('Microsoft 365', 'Microsoft Office 365', 'Microsoft Office')

        $wingetListOutput = Invoke-NativeCommand winget @('list', '--name', 'Microsoft 365 - ', '--accept-source-agreements', '--source', 'winget')
        foreach ($line in $wingetListOutput) {
            if ($line -match '^\s*(Microsoft 365\s*-\s*[A-Za-z]{2,3}-[A-Za-z]{2,3})\s{2,}') {
                $variant = $Matches[1].Trim()
                if ($variant -notin $officeNames) { $officeNames += $variant }
            }
        }

        foreach ($officeName in $officeNames) {
            $null = Invoke-NativeCommand winget @('uninstall', '--name', $officeName, '--silent', '--disable-interactivity', '--accept-source-agreements', '--all-versions')
            if ($LASTEXITCODE -eq 0) {
                Write-Log "  Removed '$officeName' via winget" -Level Success
            }
        }
    }

    if (-not (Test-OfficeStillInstalled)) {
        Write-Log "Microsoft 365 removed successfully" -Level Success
        return
    }

    # Pass 3: registry uninstall strings - only ever run silently. A bare Click-to-Run
    # UninstallString opens Office's interactive wizard and would block the unattended run.
    Write-Log "Attempting registry-based Office uninstall..." -Level Info
    foreach ($entry in Get-OfficeUninstallEntries) {
        $uninst = if ($entry.QuietUninstallString) { $entry.QuietUninstallString } else { $entry.UninstallString }
        if (-not $uninst) { continue }
        try {
            if ($uninst -match '(?i)msiexec') {
                $guid = [regex]::Match($uninst, '\{[^}]+\}').Value
                if (-not $guid) { continue }
                Write-Log "  Running msiexec /x for '$($entry.DisplayName)'"
                $null = Invoke-NativeCommand msiexec.exe @('/x', $guid, '/quiet', '/norestart')
            }
            elseif ($uninst -match '(?i)OfficeClickToRun\.exe') {
                Write-Log "  Running silent Click-to-Run removal for '$($entry.DisplayName)'"
                $silent = if ($uninst -match '(?i)DisplayLevel=') { $uninst } else { "$uninst DisplayLevel=False" }
                $null = Invoke-NativeCommand cmd.exe @('/c', $silent)
            }
            else {
                Write-Log "  No silent uninstall available for '$($entry.DisplayName)' - skipped" -Level Info
            }
        }
        catch {
            Write-Log "  Uninstaller failed for '$($entry.DisplayName)': $_" -Level Info
        }
    }

    if (Test-OfficeStillInstalled) {
        Write-Log "Microsoft 365 may still be partially installed - manual removal may be needed" -Level Warning -Key warn.officeRemains
    } else {
        Write-Log "Microsoft 365 removed successfully" -Level Success
    }
}

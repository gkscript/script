# Installs one Microsoft Office product - its own menu item, separate from the setup profiles.
# The technician picks the product that matches the customer's licence (Microsoft: "If you use
# the wrong product ID, you can't activate Office"); the customer signs in afterwards to
# activate. Products, proofing languages and exclusions come from config.json "office".
# Keep this file ASCII (Windows PowerShell 5.1 reads scripts without BOM as ANSI).
param(
    # UI language of the windows (the log stays English); the menu passes its choice
    [ValidateSet('de', 'en', 'it')]
    [string]$Language = 'de',

    [string]$ConfigPath = "$PSScriptRoot\config.json",

    # Product key from config.json office.products - skips the choice window
    [string]$Product
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot\lib\PSSetupUtility.psm1" -Force
. (Join-Path $PSScriptRoot 'steps\Desktop.ps1')

# Started from the exe's 32-bit stub (or any 32-bit process): run again in 64-bit PowerShell
$relaunchExit = Restart-In64BitPowerShell -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters
if ($null -ne $relaunchExit) { exit $relaunchExit }

Set-UiLanguage $Language
$startTime = Get-Date
$script:CurrentStep = 'start'

Function Get-OfficeRunSummary([string]$ProductName) {
    $minutes = [int][math]::Floor(((Get-Date) - $startTime).TotalMinutes)
    $duration = if ($minutes -lt 1) { Get-UiText duration.lessThanMinute } else { Get-UiText duration.minutes $minutes }
    return (@($ProductName, $env:COMPUTERNAME, $duration) | Where-Object { $_ }) -join " $([char]0xB7) "
}

try {
    $config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
}
catch {
    Show-SetupResult -Status Failed -Title (Get-UiText result.notStarted.title) -Subtitle (Get-UiText result.nothingChanged) `
        -Items @((Get-UiText preflight.config $ConfigPath), "$_")
    exit 1
}

# office_*.log: an Office run must not count as an earlier setup for the used-PC check
$logFile = Initialize-Logging -logPath $config.logging.logPath -Name 'office'
$version = (Get-Content "$PSScriptRoot\version.txt" -Raw -ErrorAction SilentlyContinue) -replace '\s'
Write-Log "=== Office install starting (v$version) ===" -Level Success

try {
    $preflightCheck = 'admin'
    Test-PrerequisiteAdmin
    $preflightCheck = 'internet'
    Test-PrerequisiteInternet
    $preflightCheck = 'disk'
    Test-PrerequisiteDiskSpace -requiredBytes $config.validation.minDiskSpace
}
catch {
    Write-Log "Pre-flight checks failed: $_" -Level Error
    $reason = switch ($preflightCheck) {
        'admin'    { Get-UiText preflight.admin }
        'internet' { Get-UiText preflight.internet }
        default    { Get-UiText preflight.other "$_" }
    }
    Show-SetupResult -Status Failed -Title (Get-UiText result.notStarted.title) -Subtitle (Get-UiText result.nothingChanged) `
        -Items @($reason) -LogFile $logFile
    exit 1
}

# Which product: the customer's licence decides
$products = @($config.office.products)
$selected = $products | Where-Object { $_.key -eq $Product } | Select-Object -First 1
if (-not $selected) {
    $choices = @(foreach ($item in $products) {
        @{ Key = $item.key; Text = (Get-UiText "office.product.$($item.key)"); Description = (Get-UiText "office.product.$($item.key).desc") }
    })
    $choices += @{ Key = 'cancel'; Text = (Get-UiText office.button.cancel); Cancel = $true }
    $picked = Show-SetupResult -Status Question -Title (Get-UiText office.choose.title) `
        -Subtitle (Get-UiText office.choose.subtitle) -Choices $choices
    $selected = $products | Where-Object { $_.key -eq $picked } | Select-Object -First 1
    if (-not $selected) {
        Write-Log "Cancelled by the technician - nothing changed"
        exit 0
    }
}
$productName = Get-UiText "office.product.$($selected.key)"
Write-Log "Product: $($selected.productId) ($($selected.key))"

Set-KeepAwake -Enable
try {
    $workFolder = Join-Path $env:TEMP 'NetixxOffice'
    $setup = Get-OfficeSetup -Url $config.office.setupUrl -Folder $workFolder
    if (-not $setup) {
        Write-Log "The Office installer could not be downloaded from Microsoft" -Level Warning -Key warn.officeDownload
        throw "Office setup not available"
    }

    # Two Office suites side by side aren't supported: remove any other one first. Add-ons
    # (proofing tools, language packs) don't count; the same product is just updated.
    $others = @(Get-OfficeProductIds | Where-Object { $_ -ne $selected.productId -and $_ -notin 'ProofingTools', 'LanguagePack' })
    if ($others.Count -gt 0) {
        $script:CurrentStep = 'officeRemove'
        Write-Log "Removing the installed Office first: $($others -join ', ')"
        Uninstall-Microsoft365 -SetupExe $setup
    }

    $script:CurrentStep = 'officeInstall'
    # Proofing tools for the configured languages other than the Windows display language,
    # which Office gets anyway (MatchOS)
    $displayLanguage = (Get-UICulture).Name.ToLowerInvariant()
    $proofing = @($config.office.proofingLanguages | Where-Object { $_ -ne $displayLanguage })
    $exclude = @($config.office.excludeApps)
    if (-not $selected.oneDrive) { $exclude += 'OneDrive' }
    $xmlPath = Join-Path $workFolder 'install.xml'
    New-OfficeConfiguration -ProductId $selected.productId -ExcludeApps $exclude -ProofingLanguages $proofing -Path $xmlPath
    Write-Log "Installing $($selected.productId) (proofing: $($proofing -join ', '); excluded: $($exclude -join ', '))..."

    $proc = Start-Process -FilePath $setup -ArgumentList @('/configure', "`"$xmlPath`"") -NoNewWindow -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit(60 * 60 * 1000)) {
        $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
        Write-Log "Office setup still running after 60 minutes - stopped" -Level Warning -Key warn.officeTimeout
    } else {
        Write-Log "  Office setup exit code: $($proc.ExitCode)"
    }

    # Success means the product is registered and Word is there, whatever the exit code said
    $word = Join-Path $env:ProgramFiles 'Microsoft Office\root\Office16\WINWORD.EXE'
    if ((Get-OfficeProductIds) -notcontains $selected.productId -or -not (Test-Path -LiteralPath $word)) {
        throw "$($selected.productId) is not installed after setup (exit code $($proc.ExitCode))"
    }
    Write-Log "$($selected.productId) installed" -Level Success

    # Word, Excel, PowerPoint on the desktop; the "with Office" layout only while the desktop is
    # still the one this tool set up (checked first - the new icons would not count as ours yet)
    $desktopIsOurs = Test-DesktopIsOurs -WhitelistPath (Join-Path $PSScriptRoot 'whitelist.txt')
    Add-DesktopShortcuts -Names @($config.office.desktopShortcuts)
    if ($desktopIsOurs -and $config.office.desktopLayout) {
        Restart-Explorer -LayoutFile (Join-Path $PSScriptRoot $config.office.desktopLayout)
    } else {
        Write-Log "The desktop has the customer's own icons or files - layout left as it is"
    }
    Remove-Item -LiteralPath $workFolder -Recurse -Force -ErrorAction SilentlyContinue

    # Activation is the customer's sign-in: subscription account, or the account the key was redeemed to
    $note = if ($selected.productId -like 'O365*') { Get-UiText office.note.m365 } else { Get-UiText office.note.retail }
    $issues = Get-LogIssues
    if ($issues.Count -eq 0) {
        Show-SetupResult -Status Success -Title (Get-UiText office.success.title) -Subtitle (Get-OfficeRunSummary $productName) `
            -LogFile $logFile -Notes @($note)
    } else {
        $warningTitle = if ($issues.Count -eq 1) { Get-UiText result.warning.title.one } else { Get-UiText result.warning.title.many $issues.Count }
        Show-SetupResult -Status Warning -Title $warningTitle -Subtitle (Get-OfficeRunSummary $productName) `
            -Items $issues -LogFile $logFile -Notes @($note)
    }
}
catch {
    $earlier = Get-LogIssues
    Write-Log "=== Office install failed ===" -Level Error
    Write-Log "Error: $_" -Level Error
    $items = @(Get-UiText failed.duringStep (Get-UiText "step.$script:CurrentStep")) + $earlier
    $items += Get-UiText warn.officeInstall @($productName, $(if ($proc) { $proc.ExitCode } else { '-' }))
    Show-SetupResult -Status Failed -Title (Get-UiText office.failed.title) -Subtitle (Get-OfficeRunSummary $productName) `
        -Items $items -LogFile $logFile
    exit 1
}
finally {
    Set-KeepAwake
    Write-Log "Office install ended at $(Get-Date)"
}

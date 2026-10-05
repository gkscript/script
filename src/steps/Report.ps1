# Handover report: C:\Install\<report.title>.html for the customer file (end of main.ps1;
# postupdate.ps1 appends its follow-up pass). Texts come from src\lang, so the report is in the
# menu's language. Dot-sourced into the calling script's scope. Keep this file ASCII.

Function ConvertTo-ReportHtml([string]$Text) { [System.Net.WebUtility]::HtmlEncode("$Text") }

Function Get-ReportTable {
    # Rows as ordered (label, value) pairs -> <table>
    param([System.Collections.Specialized.OrderedDictionary]$Rows)
    $lines = foreach ($key in $Rows.Keys) {
        "<tr><th>$(ConvertTo-ReportHtml $key)</th><td>$(ConvertTo-ReportHtml $Rows[$key])</td></tr>"
    }
    return "<table>$($lines -join '')</table>"
}

Function Get-ReportList {
    param([string[]]$Items, [string]$Class = '')
    if (-not $Items -or $Items.Count -eq 0) { return "<p>$(ConvertTo-ReportHtml (Get-UiText report.none))</p>" }
    $classAttr = if ($Class) { " class=`"$Class`"" } else { '' }
    return "<ul$classAttr>" + (($Items | ForEach-Object { "<li>$(ConvertTo-ReportHtml $_)</li>" }) -join '') + '</ul>'
}

Function Get-InstalledAppInfo {
    <#
    .SYNOPSIS
        Name and version of a catalog package as installed now (uninstall registry or Store app)
    #>
    param([string]$Key)
    $entry = $script:config.packageCatalog[$Key]
    $display = $script:PackageDisplayNames[$Key]
    if ($entry -and $entry.appx) {
        # -AllUsers needs elevation (the setup run has it); otherwise this account's package
        $appx = try { Get-AppxPackage -AllUsers -Name $entry.appx -ErrorAction Stop } catch { Get-AppxPackage -Name $entry.appx -ErrorAction SilentlyContinue }
        $appx = $appx | Sort-Object Version -Descending | Select-Object -First 1
        if ($appx) { return @{ Name = $display; Version = "$($appx.Version)" } }
    }
    if ($display) {
        $installed = Get-UninstallEntries | Where-Object { $_.DisplayName -like "$display*" } | Select-Object -First 1
        if ($installed) { return @{ Name = $installed.DisplayName; Version = "$($installed.DisplayVersion)" } }
    }
    return @{ Name = $(if ($display) { $display } else { $Key }); Version = (Get-UiText report.notFound) }
}

Function New-SetupReport {
    <#
    .SYNOPSIS
        Write the handover report and return its path
    .DESCRIPTION
        Device, Windows, what this run did (profile, mode, updates, apps with versions) and what
        still needs attention. Uses what the run collected: $script:Health (Test-SetupHealth),
        $script:InstalledUpdates (Install-WindowsUpdates), Get-LogIssues.
    #>
    param(
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)][string]$DeploymentType,
        [string[]]$Packages = @(),
        [string[]]$Notes = @()
    )
    $culture = [cultureinfo]::GetCultureInfo(@{ de = 'de-DE'; en = 'en-GB'; it = 'it-IT' }[(Get-UiLanguage)])
    $now = Get-Date
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

    $device = [ordered]@{}
    $device[(Get-UiText report.manufacturer)] = $cs.Manufacturer
    $device[(Get-UiText report.model)] = $cs.Model
    $device[(Get-UiText report.serial)] = $bios.SerialNumber
    $device[(Get-UiText report.bios)] = $bios.SMBIOSBIOSVersion
    $device[(Get-UiText report.computerName)] = $env:COMPUTERNAME

    $windows = [ordered]@{}
    $windows[(Get-UiText report.edition)] = $os.Caption
    $windows[(Get-UiText report.version)] = "$($cv.DisplayVersion) (Build $($cv.CurrentBuildNumber).$($cv.UBR))"
    if ($script:Health) {
        if ($null -ne $script:Health.Activated) {
            $windows[(Get-UiText report.activation)] = if ($script:Health.Activated) { Get-UiText report.activated } else { Get-UiText report.notActivated }
        }
        if ($script:Health.Defender) { $windows['Microsoft Defender'] = Get-UiText "report.defender.$($script:Health.Defender)" }
    }

    $minutes = [int][math]::Floor(($now - $script:StartTime).TotalMinutes)
    $setup = [ordered]@{}
    $setup[(Get-UiText report.date)] = $now.ToString('g', $culture)
    $setup[(Get-UiText report.duration)] = if ($minutes -lt 1) { Get-UiText duration.lessThanMinute } else { Get-UiText duration.minutes $minutes }
    $setup[(Get-UiText report.profile)] = Get-UiText "profile.$DeploymentType"
    $setup[(Get-UiText report.mode)] = if ($InstallOnly) { Get-UiText report.mode.installOnly } else { Get-UiText report.mode.full }
    $setup[(Get-UiText report.technician)] = $cs.UserName
    $setup[(Get-UiText report.updates)] = if ($SkipUpdates) { Get-UiText report.updatesSkipped } else { Get-UiText report.updatesCount @($script:InstalledUpdates).Count }
    if ($script:FirmwareResult) { $setup['BIOS/Firmware'] = $script:FirmwareResult }
    $setup['gk-script'] = "v$script:Version"

    $apps = [ordered]@{}
    foreach ($key in $Packages) {
        $info = Get-InstalledAppInfo -Key $key
        $apps[$info.Name] = $info.Version
    }

    $issues = @(Get-LogIssues)
    if ($script:RebootRequired) { $Notes = @(Get-UiText result.restartLine) + $Notes }

    $title = Get-UiText report.title
    $html = @"
<!doctype html>
<html lang="$(Get-UiLanguage)">
<head>
<meta charset="utf-8">
<title>$(ConvertTo-ReportHtml "$title - $env:COMPUTERNAME")</title>
<style>
body { margin: 0; font-family: "Segoe UI Variable Text", "Segoe UI", sans-serif; color: #1A1A1A; background: #FFFFFF; }
header { background: #2955BC; color: #FFFFFF; padding: 28px 40px; print-color-adjust: exact; -webkit-print-color-adjust: exact; }
header h1 { margin: 0; font: 600 28px "Segoe UI Variable Display", "Segoe UI", sans-serif; }
header p { margin: 6px 0 0; color: #DCE6FF; }
main { padding: 4px 40px 24px; max-width: 920px; }
h2 { margin: 28px 0 6px; font-size: 16px; color: #2955BC; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; vertical-align: top; padding: 6px 12px 6px 0; border-bottom: 1px solid #E5E5E5; font-size: 14px; }
th { width: 240px; font-weight: 400; color: #5C5C5C; }
ul { margin: 4px 0; padding-left: 20px; font-size: 14px; }
li { margin: 3px 0; }
ul.attention li { color: #9D5D00; }
footer { padding: 0 40px 32px; font-size: 12px; color: #5C5C5C; }
</style>
</head>
<body>
<header><h1>$(ConvertTo-ReportHtml $title)</h1><p>$(ConvertTo-ReportHtml "Netixx Grundkonfiguration v$script:Version") &#183; $(ConvertTo-ReportHtml $env:COMPUTERNAME) &#183; $(ConvertTo-ReportHtml $now.ToString('g', $culture))</p></header>
<main>
<h2>$(ConvertTo-ReportHtml (Get-UiText report.device))</h2>
$(Get-ReportTable $device)
<h2>Windows</h2>
$(Get-ReportTable $windows)
<h2>$(ConvertTo-ReportHtml (Get-UiText report.setup))</h2>
$(Get-ReportTable $setup)
<h2>$(ConvertTo-ReportHtml (Get-UiText report.apps))</h2>
$(Get-ReportTable $apps)
<h2>$(ConvertTo-ReportHtml (Get-UiText report.updateList))</h2>
$(Get-ReportList @($script:InstalledUpdates))
<h2>$(ConvertTo-ReportHtml (Get-UiText report.attention))</h2>
$(Get-ReportList $issues 'attention')
<h2>$(ConvertTo-ReportHtml (Get-UiText report.notes))</h2>
$(Get-ReportList $Notes)
<!--FOLLOW-UP-->
</main>
<footer>$(ConvertTo-ReportHtml (Get-UiText result.logFile $script:LogFile))</footer>
</body>
</html>
"@
    $path = Join-Path $Folder "$title.html"
    [System.IO.File]::WriteAllText($path, $html, (New-Object System.Text.UTF8Encoding $true))
    Write-Log "Setup report written: $path" -Level Success
    return $path
}

Function Add-SetupReportSection {
    <#
    .SYNOPSIS
        Append a section (e.g. the update follow-up) to an existing report
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Heading,
        [string[]]$Items = @(),
        [string[]]$Attention = @()
    )
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $html = [System.IO.File]::ReadAllText($Path)
    $section = "<h2>$(ConvertTo-ReportHtml $Heading)</h2>`r`n$(Get-ReportList $Items)"
    if ($Attention.Count) { $section += "`r`n$(Get-ReportList $Attention 'attention')" }
    $html = $html.Replace('<!--FOLLOW-UP-->', "$section`r`n<!--FOLLOW-UP-->")
    [System.IO.File]::WriteAllText($Path, $html, (New-Object System.Text.UTF8Encoding $true))
}

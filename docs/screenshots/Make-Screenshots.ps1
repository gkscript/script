# Screenshots for README and release notes, with demo data (no real device, user or serial number).
# Windows are rendered from their own visuals (no screen capture) on the light Mica fallback color;
# the report is rendered by Edge headless. Run after UI changes:
#   powershell -STA -ExecutionPolicy Bypass -File docs\screenshots\Make-Screenshots.ps1
# Keep this file ASCII.
param(
    [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
    [string]$Out = $PSScriptRoot,
    [string]$Work = (Join-Path $env:TEMP 'gk-screenshots')
)
$ErrorActionPreference = 'Stop'
Set-Location $Root
New-Item -ItemType Directory -Force $Out, $Work | Out-Null
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$dot = [char]0xB7

function Save-WindowContent([System.Windows.Window]$Window, [string]$Path) {
    $content = $Window.Content
    $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($Window)
    $rect = New-Object System.Windows.Rect 0, 0, $content.ActualWidth, $content.ActualHeight
    $visual = New-Object System.Windows.Media.DrawingVisual
    $dc = $visual.RenderOpen()
    $dc.DrawRectangle([System.Windows.Media.BrushConverter]::new().ConvertFromString('#F3F3F3'), $null, $rect)
    # Map the layout area 1:1 (a plain VisualBrush would stretch the drawn bounds and lose the margins)
    $brush = New-Object System.Windows.Media.VisualBrush $content
    $brush.ViewboxUnits = 'Absolute'
    $brush.Viewbox = $rect
    $dc.DrawRectangle($brush, $null, $rect)
    $dc.Close()
    $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]($rect.Width * $dpi.DpiScaleX)), ([int]($rect.Height * $dpi.DpiScaleY)), (96 * $dpi.DpiScaleX), (96 * $dpi.DpiScaleY), ([System.Windows.Media.PixelFormats]::Pbgra32)
    $bmp.Render($visual)
    $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
    $enc.Frames.Add([System.Windows.Media.Imaging.BitmapFrame]::Create($bmp))
    $fs = [IO.File]::Create($Path); $enc.Save($fs); $fs.Close()
}
function Start-CaptureTimer([string]$Path) {
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(1500)
    $timer.Add_Tick({
        $this.Stop()
        foreach ($src in [System.Windows.PresentationSource]::CurrentSources) {
            $w = $src.RootVisual
            if ($w -is [System.Windows.Window] -and $w.IsVisible) { Save-WindowContent $w $Path; $w.Close(); break }
        }
    }.GetNewClosure())
    $timer.Start()
}

Import-Module "$Root\src\lib\PSSetupUtility.psm1" -Force
foreach ($f in 'Packages', 'Updates', 'Report', 'Firmware') { . "$Root\src\steps\$f.ps1" }
Set-UiLanguage de

# --- Demo setup state for the report
$configObject = Get-Content "$Root\src\config.json" -Raw | ConvertFrom-Json
$script:config = @{}
$configObject.PSObject.Properties | ForEach-Object {
    if ($_.Value -is [PSCustomObject]) { $n = @{}; $_.Value.PSObject.Properties | Where-Object { $_.Name -notlike '_*' } | ForEach-Object { $n[$_.Name] = $_.Value }; $script:config[$_.Name] = $n }
    else { $script:config[$_.Name] = $_.Value }
}
$script:LogFile = Initialize-Logging -logPath (Join-Path $Work 'logs')
$script:StartTime = (Get-Date).AddMinutes(-42)
$script:Version = (Get-Content "$Root\src\version.txt" -Raw).Trim()
$InstallOnly = $false; $SkipUpdates = $false
$script:Health = @{ Activated = $true; Defender = 'active' }
$ue = [char]0xFC
$script:InstalledUpdates = @(
    "2026-10 Kumulatives Update f${ue}r Windows 11 Version 25H2 f${ue}r x64-basierte Systeme (KB5070001)"
    'HP Inc. - Firmware - 1.7.0.0'
    'Intel Corporation - Display - 32.0.101.7026'
    "Update f${ue}r Microsoft Defender Antivirus-Antischadsoftwareplattform - KB4052623"
)
$script:RebootRequired = $true
function Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName, $Filter)
    switch ($ClassName) {
        'Win32_ComputerSystem' { [pscustomobject]@{ Manufacturer = 'HP'; Model = 'HP EliteBook 840 14 inch G11 Notebook PC'; UserName = 'NETIXX-PC01\Techniker' } }
        'Win32_BIOS'           { [pscustomobject]@{ SerialNumber = '5CD4123XYZ'; SMBIOSBIOSVersion = 'W70 Ver. 01.07.00' } }
        'Win32_OperatingSystem' { [pscustomobject]@{ Caption = 'Microsoft Windows 11 Pro' } }
    }
}
$demoApps = @{
    vlc = @('VLC media player', '3.0.21'); firefox = @('Mozilla Firefox (x64 de)', '143.0.4'); googlechrome = @('Google Chrome', '141.0.7390.66')
    '7zip' = @('7-Zip 25.01 (x64)', '25.01'); adobereader = @('Adobe Acrobat (64-bit)', '25.001.20756'); powertoys = @('PowerToys (Preview) x64', '0.94.2')
}
function Get-InstalledAppInfo { param([string]$Key) @{ Name = $demoApps[$Key][0]; Version = $demoApps[$Key][1] } }
$env:COMPUTERNAME = 'NETIXX-PC01'
$script:FirmwareResult = $null
Write-Log 'demo' -Level Warning -Key warn.notActivated
$script:Health.Activated = $true
$null = Get-LogIssues   # (the demo warning only feeds the warning window below)
Remove-Variable -Name LogIssues -Scope Script -ErrorAction SilentlyContinue

$report = New-SetupReport -Folder $Work -DeploymentType business -Packages @('vlc', 'firefox', 'googlechrome', '7zip', 'adobereader', 'powertoys') `
    -Notes @((Get-UiText result.note.defaultApps), (Get-UiText result.note.followUp))
# The report should not list the demo warning above; show the follow-up section instead
$html = [IO.File]::ReadAllText($report)
$html = [regex]::Replace($html, '(?s)<ul class="attention">.*?</ul>', "<p>$([System.Net.WebUtility]::HtmlEncode((Get-UiText report.none)))</p>")
$html = $html.Replace($script:LogFile, 'C:\Logs\PSScriptSetup\setup_20261005_101500.log')
[IO.File]::WriteAllText($report, $html, (New-Object System.Text.UTF8Encoding $true))
Add-SetupReportSection -Path $report -Heading (Get-UiText report.followUp '05.10.2026 11:12') `
    -Items @((Get-UiText firmware.staged @('HP Image Assistant', 3010)), "2026-10 .NET 9.0.10 Sicherheitsupdate f${ue}r x64 (KB5070100)")
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
Start-Process -FilePath $edge -ArgumentList '--headless', '--disable-gpu', '--hide-scrollbars', "--screenshot=$Out\report.png", '--window-size=1000,1560', "file:///$($report -replace '\\','/')" -Wait
"report.png"

# --- Windows (demo texts)
$log = 'C:\Logs\PSScriptSetup\setup_20261005_101500.log'
Start-CaptureTimer "$Out\result-success.png"
Show-SetupResult -Status Success -Title (Get-UiText result.success.title) -Subtitle "Business $dot NETIXX-PC01 $dot 42 Min." `
    -LogFile $log -RebootRequired -Notes @((Get-UiText result.note.defaultApps), (Get-UiText result.note.followUp)) -ReportFile $report
"result-success.png"

Start-CaptureTimer "$Out\result-warning.png"
Show-SetupResult -Status Warning -Title (Get-UiText result.warning.title.many 2) -Subtitle "Consumer $dot NETIXX-PC02 $dot 51 Min." `
    -Items @((Get-UiText warn.avManual 'McAfee LiveSafe'), (Get-UiText warn.notActivated)) -LogFile $log -RebootRequired -ReportFile $report
"result-warning.png"

Start-CaptureTimer "$Out\question-used-pc.png"
$null = Show-SetupResult -Status Warning -Title (Get-UiText used.title) -Subtitle (Get-UiText used.subtitle) -Heading (Get-UiText used.heading) `
    -Items @((Get-UiText used.files @('Kunde', 10)), (Get-UiText used.installDate @('12.03.2025', 207))) -Choices @(
        @{ Key = 'full'; Text = (Get-UiText used.button.full); Fallback = 'No' }
        @{ Key = 'installOnly'; Text = (Get-UiText used.button.installOnly); Accent = $true; Fallback = 'Yes' }
        @{ Key = 'cancel'; Text = (Get-UiText used.button.cancel); Cancel = $true; Fallback = 'Cancel' }
    )
"question-used-pc.png"

Start-CaptureTimer "$Out\office-choice.png"
$choices = @(foreach ($item in $configObject.office.products) {
    @{ Key = $item.key; Text = (Get-UiText "office.product.$($item.key)"); Description = (Get-UiText "office.product.$($item.key).desc") }
})
$choices += @{ Key = 'cancel'; Text = (Get-UiText office.button.cancel); Cancel = $true }
$null = Show-SetupResult -Status Question -Title (Get-UiText office.choose.title) -Subtitle (Get-UiText office.choose.subtitle) -Choices $choices
"office-choice.png"

Import-Module "$Root\src\PSScriptMenuGui\PSScriptMenuGui.psm1" -Force
Start-CaptureTimer "$Out\menu.png"
Show-ScriptMenuGui -csvPath "$Root\src\gui.csv"
"menu.png"

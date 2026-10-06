# Runs a setup profile end to end in Windows Sandbox: a fresh Windows every time, discarded when
# the sandbox closes. The repository is mapped read-only; logs, the setup report and a screenshot
# of the sandbox desktop every 20 s go to an output folder on the host.
#   powershell -ExecutionPolicy Bypass -File tests\sandbox\Start-SandboxTest.ps1 -DeploymentType business
# Like the exe, main.ps1 is started from a 32-bit PowerShell (tests the 64-bit relaunch).
# Windows Sandbox has no Store/App Installer, so winget is unusable there - the Chocolatey
# fallback gets exercised. Not testable here: Windows Update, restarts (the follow-up pass),
# BitLocker, OEM firmware, Home edition, Store apps. Keep this file ASCII.
param(
    [ValidateSet('business', 'consumer', 'consumer-nolo')]
    [string]$DeploymentType = 'business',
    [switch]$InstallOnly,
    # Windows Update isn't available in Windows Sandbox, so updates are off unless asked for
    [switch]$WithUpdates,
    [string]$Output = (Join-Path $env:TEMP ("gk-sandbox\" + (Get-Date -Format 'yyyyMMdd_HHmmss')))
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$sandbox = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not (Test-Path $sandbox)) { throw 'Windows Sandbox is not installed (optional feature "Windows Sandbox").' }
New-Item -ItemType Directory -Force -Path $Output, "$Output\logs", "$Output\shots" | Out-Null

$arguments = "-DeploymentType $DeploymentType -Language de -ConfigPath C:\Output\config.json"
if (-not $WithUpdates) { $arguments += ' -SkipUpdates' }
if ($InstallOnly) { $arguments += ' -InstallOnly' }

# Config copy: logs to the mapped output folder
$config = Get-Content (Join-Path $repo 'src\config.json') -Raw | ConvertFrom-Json
$config.logging.logPath = 'C:\Output\logs'
$config | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $Output 'config.json') -Encoding UTF8

# Inside the sandbox: screenshots + report copy in the background, then the run as the exe does it
$watch = @'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
for ($i = 1; $i -le 240; $i++) {
    Start-Sleep -Seconds 20
    try {
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
        $bmp.Save(('C:\Output\shots\{0:D3}.png' -f $i), [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
    } catch { }
    Copy-Item 'C:\Install\*.html' 'C:\Output\' -Force -ErrorAction SilentlyContinue
}
'@
Set-Content (Join-Path $Output 'watch.ps1') -Value $watch -Encoding Ascii
$run = @"
`$setup = Join-Path `$env:TEMP 'NetixxSetup'
New-Item -ItemType Directory -Force `$setup | Out-Null
Copy-Item 'C:\gk\src' `$setup -Recurse -Force
Copy-Item 'C:\gk\launch.bat' `$setup -Force
Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File C:\Output\watch.ps1'
'started ' + (Get-Date) | Set-Content C:\Output\status.txt
& "`$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "`$setup\src\main.ps1" $arguments
'ended ' + (Get-Date) + ' exit ' + `$LASTEXITCODE | Add-Content C:\Output\status.txt
"@
Set-Content (Join-Path $Output 'run.ps1') -Value $run -Encoding Ascii

$wsb = @"
<Configuration>
  <Networking>Enable</Networking>
  <MappedFolders>
    <MappedFolder><HostFolder>$repo</HostFolder><SandboxFolder>C:\gk</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$Output</HostFolder><SandboxFolder>C:\Output</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Output\run.ps1</Command></LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $Output 'test.wsb'
Set-Content $wsbPath -Value $wsb -Encoding UTF8
# Only one sandbox at a time: a still running one would swallow this start (its LogonCommand
# never runs). The wsb CLI comes with the Store version of Windows Sandbox.
if (Get-Command wsb -ErrorAction SilentlyContinue) {
    foreach ($running in @(wsb list 2>$null | Where-Object { $_ -match '^[0-9a-f-]{36}$' })) { wsb stop --id $running | Out-Null }
    Start-Sleep -Seconds 5
}
Start-Process -FilePath $sandbox -ArgumentList "`"$wsbPath`""
"Sandbox started. Output: $Output"

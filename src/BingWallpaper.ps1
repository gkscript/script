# Daily Bing picture of the day as desktop wallpaper (per user).
#
# Registered by gk-script (main.ps1, Register-BingWallpaper) as the scheduled task
# "\Netixx\Bing Wallpaper" for the Users group: at every sign-in and daily at 06:00, hidden.
# It runs in the user's own session. It uses the newest picture of the last 8 days that Bing
# allows as wallpaper ("wp" not false); offline, the current wallpaper simply stays.
# Market follows the Windows display language: it-IT for Italian, otherwise de-DE.
# Keep this file ASCII (Windows PowerShell 5.1 reads scripts without BOM as ANSI).

$ErrorActionPreference = 'Stop'
$folder = Join-Path $env:LOCALAPPDATA 'Netixx\Wallpaper'
$log = Join-Path $folder 'wallpaper.log'

function Write-WallpaperLog([string]$Text) {
    try {
        if ((Test-Path $log) -and (Get-Item $log).Length -gt 100KB) { Remove-Item $log -Force }
        Add-Content -Path $log -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Text)
    } catch { }
}

try {
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    $market = if ((Get-UICulture).TwoLetterISOLanguageName -eq 'it') { 'it-IT' } else { 'de-DE' }

    # The last 8 days, newest first; use the newest picture Bing allows as wallpaper. Some days'
    # pictures are marked "wp": false - skipping only those keeps a fresh PC from starting with
    # no Bing picture at all.
    $info = Invoke-RestMethod -Uri "https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=8&mkt=$market" `
        -UseBasicParsing -TimeoutSec 30
    $image = @($info.images) | Where-Object { $_.wp -ne $false } | Select-Object -First 1
    if (-not $image) {
        Write-WallpaperLog "${market}: no picture of the last 8 days is available as wallpaper - keeping the current one"
        return
    }

    $file = Join-Path $folder ('bing-{0}-{1}.jpg' -f $image.startdate, $market)
    if (-not (Test-Path $file)) {
        $downloaded = $false
        # _UHD is the largest picture Bing serves (3840x2160, verified 2026-10); 1920x1080 only as fallback
        foreach ($suffix in '_UHD.jpg', '_1920x1080.jpg') {
            try {
                Invoke-WebRequest -Uri ('https://www.bing.com{0}{1}' -f $image.urlbase, $suffix) -OutFile $file `
                    -UseBasicParsing -TimeoutSec 60
                $downloaded = $true
                break
            } catch {
                Remove-Item $file -Force -ErrorAction SilentlyContinue
            }
        }
        if (-not $downloaded) { throw 'picture download failed' }
    }

    # Picture mode (not Spotlight), filling the screen
    $spotlight = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\DesktopSpotlight\Settings'
    if (Test-Path $spotlight) { Set-ItemProperty -Path $spotlight -Name EnabledState -Value 0 -Type DWord }
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name WallpaperStyle -Value '10'
    Set-ItemProperty -Path 'HKCU:\Control Panel\Desktop' -Name TileWallpaper -Value '0'

    if (-not ('Netixx.Wallpaper' -as [type])) {
        Add-Type -Namespace Netixx -Name Wallpaper -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern bool SystemParametersInfo(int action, int param, string value, int flags);
'@
    }
    # SPI_SETDESKWALLPAPER = 20; SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
    if (-not [Netixx.Wallpaper]::SystemParametersInfo(20, 0, $file, 3)) { throw 'SystemParametersInfo failed' }
    Write-WallpaperLog "$($image.startdate) ${market}: wallpaper set"

    # Keep the last 7 pictures
    Get-ChildItem -Path $folder -Filter 'bing-*.jpg' | Sort-Object LastWriteTime -Descending |
        Select-Object -Skip 7 | Remove-Item -Force -ErrorAction SilentlyContinue
}
catch {
    Write-WallpaperLog "failed: $_"
}

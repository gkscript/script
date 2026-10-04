# Shared window plumbing for every gk-script WPF window (profile menu + result window):
# the common theme (Theme.xaml), Windows 11 Mica + rounded corners, and title-bar color.
# Dot-sourced by PSSetupUtility (result window) and PSScriptMenuGui (menu), which run in
# separate PowerShell processes.

Function Get-ThemedXaml {
    <#
    .SYNOPSIS
        Insert the shared resources from Theme.xaml at a window's <!--THEME--> placeholder
    .DESCRIPTION
        Done as text before parsing so the window can use StaticResource for shared styles,
        and so one file defines the look of all windows.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Xaml
    )
    [xml]$theme = Get-Content (Join-Path $PSScriptRoot 'Theme.xaml') -Raw -Encoding UTF8
    if ($Xaml -notmatch '<!--THEME-->') { throw 'Window XAML has no <!--THEME--> placeholder' }
    return $Xaml.Replace('<!--THEME-->', $theme.DocumentElement.InnerXml)
}

if (-not ('GkScript.Dwm' -as [type])) {
    Add-Type -Namespace GkScript -Name Dwm -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct MARGINS { public int Left; public int Right; public int Top; public int Bottom; }

[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

[System.Runtime.InteropServices.DllImport("dwmapi.dll")]
public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
'@
}

Function Set-WindowCaptionColor {
    <#
    .SYNOPSIS
        Paint a window's title bar and border in a solid color (Windows 11 only; ignored elsewhere)
    #>
    param(
        [Parameter(Mandatory)][System.Windows.Window]$Window,
        [Parameter(Mandatory)][string]$Background,   # '#RRGGBB'
        [Parameter(Mandatory)][string]$Foreground
    )

    # DWM wants COLORREF (0x00BBGGRR)
    $toColorRef = {
        param($hex)
        $h = $hex.TrimStart('#')
        [Convert]::ToInt32($h.Substring(0, 2), 16) -bor ([Convert]::ToInt32($h.Substring(2, 2), 16) -shl 8) -bor ([Convert]::ToInt32($h.Substring(4, 2), 16) -shl 16)
    }
    $script:captionColors = @{ Back = (& $toColorRef $Background); Text = (& $toColorRef $Foreground) }

    $Window.Add_SourceInitialized({
        param($source)
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $source).Handle
            $back = $script:captionColors.Back; $text = $script:captionColors.Text
            $null = [GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 35, [ref]$back, 4)   # DWMWA_CAPTION_COLOR
            $null = [GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 34, [ref]$back, 4)   # DWMWA_BORDER_COLOR
            $null = [GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 36, [ref]$text, 4)   # DWMWA_TEXT_COLOR
        }
        catch {
            # Cosmetic only
        }
    })
}

Function Enable-WindowBackdrop {
    <#
    .SYNOPSIS
        Give a WPF window rounded corners and, on Windows 11 22H2+, the Mica backdrop
    .DESCRIPTION
        The window keeps its own solid Background until Mica is confirmed, so older
        builds (or a failed DWM call) never end up with a black, transparent window.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Windows.Window]$Window
    )

    $Window.Add_SourceInitialized({
        param($source)
        try {
            $hwnd = (New-Object System.Windows.Interop.WindowInteropHelper $source).Handle

            $cornerRound = 2    # DWMWA_WINDOW_CORNER_PREFERENCE (33) = DWMWCP_ROUND
            $null = [GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 33, [ref]$cornerRound, 4)

            # Mica needs build 22621+. OSVersion is unreliable under .NET Framework, read the registry.
            $build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
            if ($build -lt 22621) { return }

            $lightMode = 0      # DWMWA_USE_IMMERSIVE_DARK_MODE (20): the windows are designed light
            $null = [GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$lightMode, 4)

            $mica = 2           # DWMWA_SYSTEMBACKDROP_TYPE (38) = DWMSBT_MAINWINDOW (Mica)
            if ([GkScript.Dwm]::DwmSetWindowAttribute($hwnd, 38, [ref]$mica, 4) -ne 0) { return }

            $margins = New-Object GkScript.Dwm+MARGINS
            $margins.Left = -1; $margins.Right = -1; $margins.Top = -1; $margins.Bottom = -1
            if ([GkScript.Dwm]::DwmExtendFrameIntoClientArea($hwnd, [ref]$margins) -ne 0) { return }

            # Only now let the backdrop show through
            [System.Windows.Interop.HwndSource]::FromHwnd($hwnd).CompositionTarget.BackgroundColor = [System.Windows.Media.Colors]::Transparent
            $source.Background = [System.Windows.Media.Brushes]::Transparent
        }
        catch {
            # Cosmetic only - keep the solid background
        }
    })
}

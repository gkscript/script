Function Show-ScriptMenuGui {
    <#
    .SYNOPSIS
        Use a CSV file to make a graphical menu of PowerShell scripts. Easy to customise and fast to launch.
    .DESCRIPTION
        Do you have favourite scripts that go forgotten?

        Does your organisation have scripts that would be useful to frontline staff who are not comfortable with the command line?

        This module uses a CSV file to make a graphical menu of PowerShell scripts.

        You can also add Windows programs and files to the menu.
    .PARAMETER csvPath
        Path to CSV file that defines the menu.

        See CSV reference: https://github.com/weebsnore/PowerShell-Script-Menu-Gui
    .PARAMETER windowTitle
        Custom title for the menu window.
    .PARAMETER buttonForegroundColor
        Custom button foreground (text) color.

        Hex codes (e.g. #C00077) and color names (e.g. Azure) are valid.

        See .NET Color Class: https://docs.microsoft.com/en-us/dotnet/api/system.windows.media.colors
    .PARAMETER buttonBackgroundColor
        Custom button background color.
    .PARAMETER iconPath
        Path to .ico file for use in menu.
    .PARAMETER hideConsole
        Hide the PowerShell console that the menu is called from.

        Note: This means you won't be able to see any errors from button clicks. If things aren't working, this should be the first thing you stop using.
    .PARAMETER noExit
        Start all PowerShell instances with -NoExit ("Does not exit after running startup commands.")

        Note: You can set -NoExit on individual menu items by using the Arguments column.

        See CSV reference: https://github.com/weebsnore/PowerShell-Script-Menu-Gui
    .EXAMPLE
        Show-ScriptMenuGui -csvPath '.\example_data.csv' -Verbose
    .NOTES
        Run New-ScriptMenuGuiExample to get some example files
    .LINK
        https://github.com/weebsnore/PowerShell-Script-Menu-Gui
    #>
    [CmdletBinding()]
    param(
        [string][Parameter(Mandatory)]$csvPath,
        [string]$windowTitle = 'Netixx Grundkonfiguration',
        [string]$buttonForegroundColor = 'White',
        [string]$buttonBackgroundColor = '#366EE8',
        [string]$iconPath = './src/netixx.ico',
        [switch]$hideConsole,
        [switch]$noExit,
        # Initial UI language (de, en, it); switchable in the menu, passed to scripts via {lang}
        [string]$language = 'de'
    )
    Write-Verbose 'Show-ScriptMenuGui started'

    # Read version and append to window title
    $versionPath = Join-Path (Split-Path $csvPath -Parent) 'version.txt'
    if (Test-Path $versionPath) {
        $version = Get-Content $versionPath | Select-Object -First 1
        $windowTitle = "$windowTitle (v$version)"
    }

    # -Verbose value, to pass to select cmdlets
    $verbose = $false
    try {
        if ($PSBoundParameters['Verbose'].ToString() -eq 'True') {
            $verbose = $true
        }
    }
    catch {}

    $csvData = Import-CSV -Path $csvPath -ErrorAction Stop
    Write-Verbose "Got $($csvData.Count) CSV rows"

    # Warn about any file-based entries pointing to missing scripts
    $csvData | Where-Object { $_.Method -in @('powershell_file', 'pwsh_file') } | ForEach-Object {
        if (-not (Test-Path $_.Command)) {
            Write-Warning "CSV entry '$($_.Name)': script not found at '$($_.Command)'"
        }
    }

    # Store CSV data in script scope so it's accessible to button click handlers
    $script:csvData = $csvData
    
    # Store noExit flag in script scope
    $script:noExit = $noExit

    # Add unique Reference to each item
    # Used as button Tag and to look up action on click
    $i = 0
    $csvData | ForEach-Object {
        $_ | Add-Member -Name Reference -MemberType NoteProperty -Value "button$i"
        $i++
    }

    # Build complete XAML from template files, with the shared gk-script theme injected
    $xamlStart = Get-Content "$moduleRoot\xaml\start.xaml" -Raw -Encoding UTF8
    $xamlEnd = Get-Content "$moduleRoot\xaml\end.xaml" -Raw -Encoding UTF8
    $xaml = Get-ThemedXaml ($xamlStart + $xamlEnd)

    Write-Verbose 'Creating XAML objects...'
    $form = New-GuiForm -inputXml $xaml
    Enable-WindowBackdrop -Window $form
    # Same band-into-title-bar treatment as the result window, in Netixx blue
    Set-WindowCaptionColor -Window $form -Background '#2955BC' -Foreground '#FFFFFF'

    # Everything the window binds to, in the current UI language. Rebuilt (and re-assigned)
    # when the language changes, since these PSObjects don't raise change notifications.
    $script:menuState = @{
        WindowTitle = $windowTitle
        Version = $version
        IconPath = if ($iconPath) { (Resolve-Path $iconPath).Path } else { $null }
        ButtonBackgroundColor = $buttonBackgroundColor
        ButtonForegroundColor = $buttonForegroundColor
    }
    Set-UiLanguage $language
    $form.DataContext = Get-MenuDataContext

    # One window-level handler for every click: profile rows and language chips. Rows are
    # regenerated when the language changes, so per-button handlers would be lost.
    $form.AddHandler([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, [System.Windows.RoutedEventHandler]{
        param($origin, $routed)
        $control = $routed.OriginalSource

        if ($control -is [System.Windows.Controls.RadioButton]) {
            # Language chip: Tag is the language code
            Set-UiLanguage $control.Tag
            $form.DataContext = Get-MenuDataContext
            return
        }
        if ($control -isnot [System.Windows.Controls.Button] -or -not $control.Tag) { return }

        Write-Verbose "Button clicked with tag: $($control.Tag)"
        # Disable all buttons to prevent double-launching
        foreach ($btn in (Get-VisualChildren -parent $form -childType ([System.Windows.Controls.Button]))) {
            $btn.IsEnabled = $false
        }
        $control.Content = Get-UiText menu.starting
        Invoke-ButtonAction $control.Tag
        $form.Close()
    })

    if ($hideConsole) {
        if ($global:error[0].Exception.CommandInvocation.MyCommand.ModuleName -ne 'PSScriptMenuGui') {
            # Do not hide console if there have been errors
            Hide-Console | Out-Null
        }
    }

    Write-Verbose 'Showing dialog...'
    $Form.ShowDialog() | Out-Null
}

Function New-ScriptMenuGuiExample {
    <#
    .SYNOPSIS
        Creates an example set of files for PSScriptMenuGui
    .PARAMETER path
        Path of output folder
    .EXAMPLE
        New-ScriptMenuGuiExample -path 'PSScriptMenuGui_example'
    .LINK
        https://github.com/weebsnore/PowerShell-Script-Menu-Gui
    #>
    [CmdletBinding()]
    param (
        [string]$path = 'PSScriptMenuGui_example'
    )

    # Ensure folder exists
    if (-not (Test-Path -Path $path -PathType Container) ) {
        New-Item -Path $path -ItemType 'directory' -Verbose | Out-Null
    }

    Write-Verbose "Copying example files to $path..." -Verbose
    Copy-Item -Path "$moduleRoot\examples\*" -Destination $path
}
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
        [switch]$noExit
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

    # Build complete XAML from template files
    $xamlStart = Get-Content "$moduleRoot\xaml\start.xaml" -Raw
    $xamlEnd = Get-Content "$moduleRoot\xaml\end.xaml" -Raw
    $xaml = $xamlStart + $xamlEnd

    Write-Verbose 'Creating XAML objects...'
    $form = New-GuiForm -inputXml $xaml

    # Create data context object
    $dataContext = New-Object PSObject -Property @{
        WindowTitle = $windowTitle
        IconPath = if ($iconPath) { (Resolve-Path $iconPath).Path } else { $null }
        MenuItems = @()
    }
    
    # Build menu items with proper formatting
    ForEach ($item in $csvData) {
        $menuItem = New-Object PSObject -Property @{
            Reference = $item.Reference
            ButtonText = Get-XamlSafeString $item.Name
            Description = if ($item.Description) { Get-XamlSafeString $item.Description } else { '' }
            BackgroundColor = $buttonBackgroundColor
            ForegroundColor = $buttonForegroundColor
            OriginalData = $item  # Store original CSV data for action lookup
        }
        $dataContext.MenuItems += $menuItem
    }

    # Set DataContext for binding
    $form.DataContext = $dataContext

    Write-Verbose "Created $($dataContext.MenuItems.Count) menu items"

    # Attach click handlers after window is loaded
    $form.Add_Loaded( {
        Write-Verbose 'Window loaded, adding click actions...'
        
        # Force layout update and wait on dispatcher to ensure all rendering is complete
        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke({
            $this.UpdateLayout()
            [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke({
                Start-Sleep -Milliseconds 300
                $this.UpdateLayout()
            }, [System.Windows.Threading.DispatcherPriority]::Render)
        }, [System.Windows.Threading.DispatcherPriority]::Render)
        
        $buttons = Get-VisualChildren -parent $this -childType ([System.Windows.Controls.Button])
        
        ForEach ($button in $buttons) {
            $button.Add_Click( {
                param($sender, $eventArgs)
                Write-Verbose "Button clicked with tag: $($sender.Tag)"
                if ($sender.Tag) {
                    Invoke-ButtonAction $sender.Tag
                } else {
                    Write-Error "Button Tag is empty!"
                }
            } )
        }
        Write-Verbose "Attached click handlers to $($buttons.Count) buttons"
    } )

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
function Hide-Console {
    Write-Verbose 'Hiding PowerShell console...'
    # .NET method for hiding the PowerShell console window
    # https://stackoverflow.com/questions/40617800/opening-powershell-script-and-hide-command-prompt-but-not-the-gui
    Add-Type -Name Window -Namespace Console -MemberDefinition '
    [DllImport("Kernel32.dll")]
    public static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, Int32 nCmdShow);
    '
    $consolePtr = [Console.Window]::GetConsoleWindow()
    [Console.Window]::ShowWindow($consolePtr, 0) # 0 = hide
}

Function Get-VisualChildren {
    <#
    .SYNOPSIS
        Recursively find all visual children of a given type in a WPF control tree
    #>
    param(
        [Parameter(Mandatory)][System.Windows.DependencyObject]$parent,
        [Parameter(Mandatory)][type]$childType
    )
    
    $children = @()
    
    for ($i = 0; $i -lt [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($parent); $i++) {
        $child = [System.Windows.Media.VisualTreeHelper]::GetChild($parent, $i)
        
        if ($child -is $childType) {
            $children += $child
        }
        
        # Recursively search child's children
        $children += Get-VisualChildren -parent $child -childType $childType
    }
    
    return $children
}

Function New-GuiForm {
    # Based on: https://foxdeploy.com/2015/05/14/part-iii-using-advanced-gui-elements-in-powershell/
    param (
        [Parameter(Mandatory)][string]$inputXml # XAML as string
    )
    # Read XAML
    [void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
    [xml]$xaml = $inputXml
    $reader = (New-Object System.Xml.XmlNodeReader $xaml)
    try {
        $form = [Windows.Markup.XamlReader]::Load($reader)
    }
    catch {
        Write-Warning "Unable to parse XML!
Ensure that there are NO SelectionChanged or TextChanged properties in your textboxes (PowerShell cannot process them).
Note that this module does not currently work with PowerShell 7-preview and the VS Code integrated console."
        throw
    }

    return $form
}

Function Get-MenuDataContext {
    <#
    .SYNOPSIS
        Build the object the menu window binds to, in the current UI language
    #>
    $state = $script:menuState
    $lang = Get-UiLanguage

    $subtitle = Get-UiText menu.subtitle
    if ($state.Version) { $subtitle = "$subtitle $([char]0xB7) v$($state.Version)" }

    $items = foreach ($item in $script:csvData) {
        # NameKey column: translated name from src/lang; falls back to the CSV Name
        $name = if ($item.NameKey) { Get-UiText $item.NameKey } else { $item.Name }
        New-Object PSObject -Property @{
            Reference = $item.Reference
            ButtonText = $name
            # Screen-reader name without any leading symbol/emoji
            AccessibleName = ($name -replace '^[^\p{L}\p{N}]+', '')
            # Optional Icon column: Segoe Fluent Icons code point in hex (e.g. E821)
            IconGlyph = if ($item.Icon) { [string][char][Convert]::ToInt32($item.Icon, 16) } else { '' }
            IconVisibility = if ($item.Icon) { 'Visible' } else { 'Collapsed' }
            Description = if ($item.Description) { $item.Description } else { '' }
            BackgroundColor = $state.ButtonBackgroundColor
            ForegroundColor = $state.ButtonForegroundColor
            OriginalData = $item
        }
    }

    New-Object PSObject -Property @{
        WindowTitle = $state.WindowTitle
        Subtitle = $subtitle
        Footer = Get-UiText menu.footer
        UpdatesEnabled = [bool]$state.UpdatesEnabled
        UpdatesLabel = Get-UiText menu.updates
        UpdatesHint = Get-UiText menu.updatesHint
        InstallOnly = [bool]$state.InstallOnly
        UpdateText = if ($state.NewVersion) { Get-UiText menu.updateAvailable $state.NewVersion } else { '' }
        UpdateVisibility = if ($state.NewVersion) { 'Visible' } else { 'Collapsed' }
        DownloadUrl = $state.DownloadUrl
        InstallOnlyLabel = Get-UiText menu.installOnly
        InstallOnlyHint = Get-UiText menu.installOnlyHint
        IconPath = $state.IconPath
        MenuItems = @($items)
        IsDe = $lang -eq 'de'
        IsEn = $lang -eq 'en'
        IsIt = $lang -eq 'it'
    }
}

Function Invoke-ButtonAction {
    param(
        [Parameter(Mandatory)][string]$buttonName
    )
    Write-Verbose "$buttonName clicked"

    # Get relevant CSV row (a copy: the placeholders are filled per launch)
    $csvMatch = $script:csvData | Where-Object {$_.Reference -eq $buttonName} | Select-Object *
    $updatesSwitch = if ($script:menuState.UpdatesEnabled) { '' } else { '-SkipUpdates' }
    $modeSwitch = if ($script:menuState.InstallOnly) { '-InstallOnly' } else { '' }
    $command = $csvMatch.Command.Replace('{lang}', (Get-UiLanguage)).Replace('{updates}', $updatesSwitch)
    $csvMatch.Command = $command.Replace('{mode}', $modeSwitch).Trim() -replace '\s{2,}', ' '
    Write-Verbose $csvMatch

    # Pipe match to Start-Script function
    # Lets us check CSV data via parameter validation
    try {
        $csvMatch | Start-Script -ErrorAction Stop
    }
    catch {
        Write-Error $_
    }
}

Function Start-Script {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipelineByPropertyName)]
        [ValidateSet('cmd','powershell_file','powershell_inline','pwsh_file','pwsh_inline')]
        [string]$method,

        [Parameter(Mandatory,ValueFromPipelineByPropertyName)][string]$command,

        [Parameter(ValueFromPipelineByPropertyName)][string]$arguments
    )

    # Handle cmd first
    if ($method -eq 'cmd') {
        if ($arguments) {
            # Using .NET directly, as Start-Process adds a trailing space to arguments
            # https://social.technet.microsoft.com/Forums/en-US/97be1de5-f31e-416e-9752-ed60c39c0383/powershell-40-startprocess-adds-extra-space-to-commandline
            $process = New-Object System.Diagnostics.Process
            $process.StartInfo.FileName = $command
            $process.StartInfo.Arguments = $arguments
            # Set process working directory to PowerShell working directory
            # Mimics behaviour of exe called from cmd prompt
            $process.StartInfo.WorkingDirectory = $PWD
            $process.Start()
        }
        else {
            Start-Process -FilePath $command -Verbose:$verbose
        }
        return
    }

    # Begin constructing PowerShell arguments
    $psArguments = @()
    $psArguments += '-ExecutionPolicy Bypass'
    $psArguments += '-NoLogo'
    if ($script:noExit -or $noExit) {
        $psArguments += '-NoExit'
    }
    if ($arguments) {
        # Additional PS arguments from CSV
        # PowerShell doesn't seem to care if it gets the same argument twice
        $psArguments += $arguments
    }

    # Set Start-Process params according to CSV method
    $splitMethod = $method.Split('_')
    $encodedCommand = [Convert]::ToBase64String( [System.Text.Encoding]::Unicode.GetBytes($command) )
    switch ($splitMethod[0]) {
        powershell {
            $filePath = 'powershell.exe'
        }
        pwsh {
            $filePath = 'pwsh.exe'
        }
    }
    switch ($splitMethod[1]) {
        file {
            $psArguments += "-File `"$command`""
        }
        inline {
            $psArguments += "-EncodedCommand `"$encodedCommand`""
        }
    }

    # Launch process
    $psArguments | ForEach-Object { Write-Verbose $_ }
    Start-Process -FilePath $filePath -ArgumentList $psArguments -Verbose:$verbose
}
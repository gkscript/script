# Logging and utility functions for main setup script

# Windows PowerShell 5.1 does not load WinForms by default; every MessageBox in
# main.ps1 and this module throws "type not found" without it.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'WindowTheme.ps1')
. (Join-Path $PSScriptRoot 'Language.ps1')
. (Join-Path $PSScriptRoot 'Office.ps1')

$script:LogIssues = [System.Collections.Generic.List[string]]::new()

Function Get-LogIssues {
    <#
    .SYNOPSIS
        Return every Warning/Error message logged so far, in order
    #>
    return , $script:LogIssues.ToArray()
}

Function Initialize-Logging {
    <#
    .SYNOPSIS
        Initialize logging infrastructure
    .PARAMETER logPath
        Path where logs should be stored
    .PARAMETER Name
        File name prefix: setup_ for the setup runs (the used-PC check looks for these),
        office_ for office.ps1
    #>
    param(
        [string]$logPath = "C:\Logs\PSScriptSetup",
        [string]$Name = 'setup'
    )
    
    if (-not (Test-Path $logPath)) {
        $null = New-Item -Path $logPath -ItemType Directory -Force
    }
    
    $script:LogPath = $logPath
    $script:LogFile = Join-Path $logPath "${Name}_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    Write-Log "Logging initialized at $($script:LogFile)"
    return $script:LogFile
}

Function Write-Log {
    <#
    .SYNOPSIS
        Write to log file and console with timestamp
    .PARAMETER Key
        Translation key (src/lang/*.json) for the text the result window shows for this
        Warning/Error. The log always gets the English -Message.
    .PARAMETER KeyArgs
        Values for the {0}, {1} placeholders of -Key
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info',

        [string]$Key,

        [object[]]$KeyArgs = @()
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"

    # Collected for the end-of-run summary (Get-LogIssues), in the UI language when keyed
    if ($Level -in 'Warning', 'Error') {
        $shown = if ($Key) { Get-UiText -Key $Key -Arguments $KeyArgs } else { $Message }
        $script:LogIssues.Add($shown.Trim())
    }
    
    # Write to file
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logMessage
    }
    
    # Write to console with color
    switch ($Level) {
        'Error' { Write-Host $logMessage -ForegroundColor Red }
        'Warning' { Write-Host $logMessage -ForegroundColor Yellow }
        'Success' { Write-Host $logMessage -ForegroundColor Green }
        default { Write-Host $logMessage -ForegroundColor Cyan }
    }
}

Function Test-PrerequisiteAdmin {
    <#
    .SYNOPSIS
        Verify script is running with administrator privileges
    #>
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentUser)
    $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    
    if (-not $isAdmin) {
        # main.ps1's pre-flight catch logs this and shows the result window
        throw "Administrator rights are required. Start gk-script.exe again and accept the UAC prompt."
    }
    
    Write-Log "Administrator privileges confirmed" -Level Success
}

Function Test-PrerequisiteInternet {
    <#
    .SYNOPSIS
        Verify internet connectivity
    #>
    Write-Log "Checking internet connectivity..."
    
    try {
        $testConnection = Test-Connection 8.8.8.8 -Quiet -ErrorAction Stop
        if (-not $testConnection) {
            throw "No response from connectivity test"
        }
        Write-Log "Internet connectivity confirmed" -Level Success
    }
    catch {
        # main.ps1's pre-flight catch logs this and shows the result window
        throw "No internet connection. Connect the PC to the network and run setup again."
    }
}

Function Sync-SystemTimeWithInternet {
    <#
    .SYNOPSIS
        Sync local system time using Windows Time service
    #>
    Write-Log "Synchronizing system time with internet time source..."

    try {
        $timeService = Get-Service -Name 'w32time' -ErrorAction Stop

        if ($timeService.StartType -eq 'Disabled') {
            Set-Service -Name 'w32time' -StartupType Manual -ErrorAction Stop
        }

        if ($timeService.Status -ne 'Running') {
            Start-Service -Name 'w32time' -ErrorAction Stop
        }

        $syncOutput = & w32tm /resync 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw "w32tm returned exit code $LASTEXITCODE. Output: $($syncOutput -join ' ')"
        }

        Write-Log "System time synchronization completed" -Level Success
    }
    catch {
        Write-Log "System time synchronization failed: $_" -Level Warning -Key warn.timeSync -KeyArgs "$_"
    }
}

Function Test-PrerequisiteDiskSpace {
    <#
    .SYNOPSIS
        Verify sufficient disk space
    #>
    param(
        [int64]$requiredBytes = 5000000000  # 5GB default
    )
    
    Write-Log "Checking disk space (required: $('{0:N0}' -f $requiredBytes) bytes)..."
    
    try {
        $systemDrive = $env:SystemDrive
        $diskInfo = Get-Volume -DriveLetter ($systemDrive[0]) -ErrorAction Stop
        $freespace = $diskInfo.SizeRemaining
        
        if ($freespace -lt $requiredBytes) {
            throw "Insufficient disk space. Required: $('{0:N2}' -f ($requiredBytes/1GB))GB, Available: $('{0:N2}' -f ($freespace/1GB))GB"
        }
        
        Write-Log "Disk space check passed. Available: $('{0:N2}' -f ($freespace/1GB))GB" -Level Success
    }
    catch {
        Write-Log "Disk space check failed: $_" -Level Error
        throw
    }
}

Function Test-WindowsVersion {
    <#
    .SYNOPSIS
        Get Windows version information
    #>
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $systemInfo = @{
            OSCaption = $os.Caption
            Version = $os.Version
            BuildNumber = $os.BuildNumber
            Is11 = $os.Caption -match "Windows 11"
            Arch = $env:PROCESSOR_ARCHITECTURE
        }
        Write-Log "Windows version: $($systemInfo.OSCaption) (Build $($systemInfo.BuildNumber))"
        return $systemInfo
    }
    catch {
        Write-Log "Failed to retrieve Windows version: $_" -Level Error
        throw
    }
}

Function Get-SystemGPU {
    <#
    .SYNOPSIS
        Get GPU information
    #>
    try {
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop |
            Sort-Object -Property AdapterRAM -Descending |
            Select-Object -First 1
        $gpuInfo = @{
            Name = $gpu.Name
            IsNvidia = $gpu.Name -match 'nvidia'
            IsAmd = $gpu.Name -match 'amd'
            IsIntel = $gpu.Name -match 'intel'
        }
        Write-Log "Detected GPU: $($gpuInfo.Name)"
        return $gpuInfo
    }
    catch {
        Write-Log "Failed to retrieve GPU information: $_" -Level Warning -Key warn.gpuDetect -KeyArgs "$_"
        return @{ Name = "Unknown"; IsNvidia = $false; IsAmd = $false; IsIntel = $false }
    }
}

Function Get-BitlockerStatus {
    <#
    .SYNOPSIS
        Check BitLocker encryption status
    #>
    try {
        $bitlockerInfo = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop | Select-Object -First 1
        
        if ($bitlockerInfo) {
            $status = @{
                IsEncrypted = $bitlockerInfo.EncryptionPercentage -gt 0
                EncryptionPercentage = $bitlockerInfo.EncryptionPercentage
            }
            
            if ($status.IsEncrypted) {
                Write-Log "BitLocker is enabled ($($status.EncryptionPercentage)% encrypted)"
            } else {
                Write-Log "BitLocker is not enabled"
            }
            
            return $status
        }
    }
    catch {
        Write-Log "BitLocker status check failed: $_" -Level Warning -Key warn.bitlockerStatus -KeyArgs "$_"
    }
    
    return @{ IsEncrypted = $false; EncryptionPercentage = 0 }
}

Function Stop-ProcessWithTimeout {
    param(
        [Parameter(Mandatory)][string]$Name,
        [int]$TimeoutSeconds = 15
    )
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $procs = Get-Process $Name -ErrorAction SilentlyContinue
        if ($procs) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
    } until (-not (Get-Process $Name -ErrorAction SilentlyContinue) -or [datetime]::UtcNow -gt $deadline)
}

Function Set-KeepAwake {
    <#
    .SYNOPSIS
        Keep the PC and display awake during an unattended run (-Enable), or release it
    .DESCRIPTION
        Without this, a 15-40 min run ends with the monitor off or the PC asleep (and
        installs paused) - the result window would greet nobody.
    #>
    param([switch]$Enable)

    if (-not ('GkScript.Power' -as [type])) {
        Add-Type -Namespace GkScript -Name Power -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern uint SetThreadExecutionState(uint flags);
'@
    }
    # ES_CONTINUOUS (0x80000000) | ES_SYSTEM_REQUIRED (0x1) | ES_DISPLAY_REQUIRED (0x2)
    $flags = if ($Enable) { [uint32]2147483651 } else { [uint32]2147483648 }
    $null = [GkScript.Power]::SetThreadExecutionState($flags)
}

Function Show-SetupResult {
    <#
    .SYNOPSIS
        Show the end-of-run result window (src/lib/SetupResult.xaml)
    .DESCRIPTION
        Built to be read from across the room: the status color fills the top of the
        window. Falls back to a MessageBox if the window cannot be created, since this
        is the only result signal a technician who walked away will see.
    .PARAMETER Items
        Warnings (Status Warning) or error details (Status Failed). Ignored for Success.
    .PARAMETER Choices
        Turns the window into a question: one button per choice instead of Open log /
        Restart / Close, in order; returns the Key of the clicked choice. Each choice is
        @{ Key; Text; Description (makes it a row like the menu's profile rows, for longer
        lists); Accent (the recommended one); Cancel (Esc and the close box);
        Fallback = 'Yes' | 'No' | 'Cancel' (its button in the MessageBox fallback) }.
    .PARAMETER Heading
        Replaces the status heading above the items (e.g. for a question)
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Warning', 'Failed', 'Question')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Subtitle = '',

        [string[]]$Items = @(),

        # Steps left to the technician that are not problems (shown with an info icon)
        [string[]]$Notes = @(),

        [string]$LogFile,

        [switch]$RebootRequired,

        [hashtable[]]$Choices = @(),

        [string]$Heading
    )

    # Per status: band, headline, subline, item glyph color; solid glyphs from Segoe Fluent
    # Icons so all three carry the same weight at distance; taskbar progress color.
    # Every text color holds >= 4.5:1 on its band.
    $themes = @{
        Success = @{ Band = '#107C10'; Fg = '#FFFFFF'; Sub = '#DFF6DD'; Item = '#107C10'; Glyph = 0xEC61; Heading = '';                        Taskbar = 'Normal' }
        Warning = @{ Band = '#FFC83D'; Fg = '#241B00'; Sub = '#4A3A00'; Item = '#9D5D00'; Glyph = 0xE814; Heading = 'result.heading.attention'; Taskbar = 'Paused' }
        Failed  = @{ Band = '#C42B1C'; Fg = '#FFFFFF'; Sub = '#FDE7E9'; Item = '#C42B1C'; Glyph = 0xEB90; Heading = 'result.heading.failed';    Taskbar = 'Error' }
        # A choice, not an outcome: the menu's Netixx blue
        Question = @{ Band = '#2955BC'; Fg = '#FFFFFF'; Sub = '#DCE6FF'; Item = '#2955BC'; Glyph = 0xE8A5; Heading = '';                    Taskbar = 'None' }
    }
    $theme = $themes[$Status]

    try {
        [xml]$xaml = Get-ThemedXaml (Get-Content (Join-Path $PSScriptRoot 'SetupResult.xaml') -Raw -Encoding UTF8)
        $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
        $find = { param($name) $window.FindName($name) }
        $brush = { param($hex) [System.Windows.Media.BrushConverter]::new().ConvertFromString($hex) }

        $window.Title = "Netixx Grundkonfiguration - $Title"
        $icon = Join-Path (Split-Path $PSScriptRoot -Parent) 'netixx.ico'
        if (Test-Path $icon) {
            $window.Icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([uri](Resolve-Path $icon).Path)
        }
        # A full green/yellow/red taskbar button: still visible when the window is covered
        $window.TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo -Property @{
            ProgressState = $theme.Taskbar; ProgressValue = 1.0
        }
        # A pending restart is part of the outcome, so it joins the band
        if ($RebootRequired -and $Status -ne 'Failed') {
            $Subtitle = (@($Subtitle, (Get-UiText result.restartRequired)) | Where-Object { $_ }) -join " $([char]0xB7) "
        }
        (& $find 'Band').Background = & $brush $theme.Band
        (& $find 'Glyph').Text = [string][char]$theme.Glyph
        (& $find 'Glyph').Foreground = & $brush $theme.Fg
        (& $find 'TitleText').Text = $Title
        (& $find 'TitleText').Foreground = & $brush $theme.Fg
        (& $find 'SubtitleText').Text = $Subtitle
        (& $find 'SubtitleText').Foreground = & $brush $theme.Sub
        if (-not $Subtitle) { (& $find 'SubtitleText').Visibility = 'Collapsed' }

        $sectionHeading = & $find 'SectionHeading'
        $list = & $find 'ItemsList'
        $nothingListed = $Status -eq 'Success' -or $Items.Count -eq 0
        if ($Choices.Count -gt 0 -and $Items.Count -eq 0) {
            # A question without items: only the heading, if one was given
            if ($Heading) { $sectionHeading.Text = $Heading } else { $sectionHeading.Visibility = 'Collapsed' }
            (& $find 'ItemsScroll').Visibility = 'Collapsed'
        } elseif ($nothingListed -and $RebootRequired) {
            # The restart is the one thing left; say it as the heading, not under "nothing"
            $sectionHeading.Text = Get-UiText result.restartLine
            (& $find 'ItemsScroll').Visibility = 'Collapsed'
        } elseif ($nothingListed) {
            # Notes alone (e.g. "sign in to activate Office") would contradict "nothing to do"
            if ($Notes.Count -gt 0) { $sectionHeading.Visibility = 'Collapsed' }
            $sectionHeading.Text = Get-UiText result.nothingToDo
            $sectionHeading.FontWeight = [System.Windows.FontWeights]::Normal
            (& $find 'ItemsScroll').Visibility = 'Collapsed'
        } else {
            $sectionHeading.Text = if ($Heading) { $Heading } else { Get-UiText $theme.Heading }
            $list.Tag = & $brush $theme.Item
            $list.ItemsSource = $Items
        }

        if ($LogFile) {
            (& $find 'LogPath').Text = $LogFile
        } else {
            (& $find 'LogRow').Visibility = 'Collapsed'
            (& $find 'OpenLogButton').Visibility = 'Collapsed'
        }

        $restartButton = & $find 'RestartButton'
        $closeButton = & $find 'CloseButton'

        # Fixed texts in the UI language (src/lang)
        (& $find 'OpenLogButton').Content = Get-UiText result.button.openLog
        $restartButton.Content = Get-UiText result.button.restart
        $closeButton.Content = Get-UiText result.button.close
        (& $find 'RestartText').Text = Get-UiText result.restartLine
        (& $find 'LogLabel').Text = Get-UiText result.log
        if ($Notes.Count -gt 0) {
            (& $find 'NotesList').ItemsSource = $Notes
            (& $find 'NotesList').Visibility = 'Visible'
        }
        [System.Windows.Automation.AutomationProperties]::SetName((& $find 'LogPath'), (Get-UiText result.logPathName))
        if ($RebootRequired) {
            if (-not $nothingListed) { (& $find 'RestartRow').Visibility = 'Visible' }
            $restartButton.Visibility = 'Visible'
        } else {
            $closeButton.IsDefault = $true
        }

        (& $find 'OpenLogButton').Add_Click({ Start-Process notepad.exe -ArgumentList "`"$LogFile`"" })
        $restartButton.Add_Click({ $script:ResultRestart = $true; $window.Close() })
        $closeButton.Add_Click({ $window.Close() })

        # A question: the choices replace the result buttons; the clicked Key is returned
        $answer = @{ Key = $null }
        if ($Choices.Count -gt 0) {
            $actions = & $find 'ActionsPanel'
            $actions.Children.Clear()
            (& $find 'LogRow').Visibility = 'Collapsed'
            $rows = & $find 'ChoiceRows'
            foreach ($choice in $Choices) {
                $button = New-Object System.Windows.Controls.Button
                if ($choice.Description) {
                    # Same anatomy as a menu profile row: title, caption, chevron
                    $button.Style = $window.FindResource('ProfileRow')
                    $grid = New-Object System.Windows.Controls.Grid
                    foreach ($width in '*', 'Auto') {
                        $column = New-Object System.Windows.Controls.ColumnDefinition
                        $column.Width = [System.Windows.GridLengthConverter]::new().ConvertFromString($width)
                        $grid.ColumnDefinitions.Add($column)
                    }
                    $texts = New-Object System.Windows.Controls.StackPanel
                    $texts.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $rowTitle = New-Object System.Windows.Controls.TextBlock
                    $rowTitle.Text = $choice.Text
                    $rowTitle.FontSize = 15
                    $rowTitle.FontWeight = [System.Windows.FontWeights]::SemiBold
                    $rowCaption = New-Object System.Windows.Controls.TextBlock
                    $rowCaption.Style = $window.FindResource('Caption')
                    $rowCaption.Text = $choice.Description
                    $rowCaption.TextWrapping = [System.Windows.TextWrapping]::Wrap
                    $rowCaption.Margin = New-Object System.Windows.Thickness 0, 2, 0, 0
                    $null = $texts.Children.Add($rowTitle)
                    $null = $texts.Children.Add($rowCaption)
                    $chevron = New-Object System.Windows.Controls.TextBlock
                    $chevron.Style = $window.FindResource('InlineIcon')
                    $chevron.Text = [string][char]0xE76C
                    $chevron.FontSize = 12
                    $chevron.Foreground = $window.FindResource('TextSecondary')
                    $chevron.VerticalAlignment = [System.Windows.VerticalAlignment]::Center
                    $chevron.Margin = New-Object System.Windows.Thickness 16, 0, 0, 0
                    [System.Windows.Controls.Grid]::SetColumn($chevron, 1)
                    $null = $grid.Children.Add($texts)
                    $null = $grid.Children.Add($chevron)
                    $button.Content = $grid
                    [System.Windows.Automation.AutomationProperties]::SetName($button, $choice.Text)
                    [System.Windows.Automation.AutomationProperties]::SetHelpText($button, $choice.Description)
                    $null = $rows.Children.Add($button)
                    $rows.Visibility = 'Visible'
                } else {
                    $button.Content = $choice.Text
                    $button.Style = $window.FindResource($(if ($choice.Accent) { 'AccentButton' } else { 'ActionButton' }))
                    $null = $actions.Children.Add($button)
                }
                $button.IsDefault = [bool]$choice.Accent
                $button.IsCancel = [bool]$choice.Cancel
                [System.Windows.Automation.AutomationProperties]::SetAutomationId($button, "Choice-$($choice.Key)")
                $key = $choice.Key
                $button.Add_Click({ $answer.Key = $key; $window.Close() }.GetNewClosure())
            }
        }

        Enable-WindowBackdrop -Window $window
        # The status color runs up through the title bar to the window's top edge
        Set-WindowCaptionColor -Window $window -Background $theme.Band -Foreground $theme.Fg
        $script:ResultRestart = $false
        $null = $window.ShowDialog()
        if ($Choices.Count -gt 0) {
            # Closed without a choice (close box): same as the cancel choice
            if (-not $answer.Key) { $answer.Key = ($Choices | Where-Object { $_.Cancel } | Select-Object -First 1).Key }
            return $answer.Key
        }

        # Restart after the window is gone, never from inside its event handler
        if ($script:ResultRestart) {
            Write-Log "Restart requested from result window"
            Restart-Computer -Force
        }
    }
    catch {
        Write-Log "Result window failed, falling back to MessageBox: $_" -Level Warning
        $icon = @{ Success = 'Information'; Warning = 'Warning'; Failed = 'Error'; Question = 'Question' }[$Status]
        $text = (@($Title, $Subtitle) + @($Items) + @($(if ($RebootRequired) { Get-UiText result.restartLine }), $(if ($LogFile) { Get-UiText result.logFile $LogFile }))) |
            Where-Object { $_ } | Out-String
        if ($Choices.Count -gt 0 -and @($Choices | Where-Object { -not $_.Fallback }).Count -gt 0) {
            # More choices than a MessageBox has buttons: say so and cancel
            $null = [System.Windows.Forms.MessageBox]::Show($text.Trim(), 'Netixx Grundkonfiguration', 'OK', $icon)
            return ($Choices | Where-Object { $_.Cancel } | Select-Object -First 1).Key
        }
        if ($Choices.Count -gt 0) {
            $byButton = @{}
            foreach ($choice in $Choices) { $byButton[$choice.Fallback] = $choice }
            $mapping = Get-UiText used.fallback @($byButton.Yes.Text, $byButton.No.Text, $byButton.Cancel.Text)
            $clicked = [System.Windows.Forms.MessageBox]::Show("$($text.Trim())`n`n$mapping", 'Netixx Grundkonfiguration', 'YesNoCancel', $icon)
            return $byButton["$clicked"].Key
        }
        $null = [System.Windows.Forms.MessageBox]::Show($text.Trim(), 'Netixx Grundkonfiguration', 'OK', $icon)
    }
}

Function Invoke-NativeCommand {
    <#
    .SYNOPSIS
        Run a native executable and return its merged stdout/stderr as strings
    .DESCRIPTION
        Under $ErrorActionPreference = 'Stop', stderr captured with 2>&1 becomes a
        terminating error. This runs the command with a local 'Continue' preference
        so stderr output never aborts the caller. $LASTEXITCODE is preserved.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,

        [string[]]$ArgumentList = @()
    )

    $ErrorActionPreference = 'Continue'
    & $FilePath @ArgumentList 2>&1 | ForEach-Object { "$_" }
}

Function Restart-In64BitPowerShell {
    <#
    .SYNOPSIS
        Re-run a script in the native 64-bit Windows PowerShell when started from a 32-bit one
    .DESCRIPTION
        gk-script.exe's NSIS stub is a 32-bit process, and everything it starts inherits that. A
        32-bit PowerShell writes HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion (OEMInformation)
        and Winlogon to WOW6432Node, sees only 32-bit programs in the uninstall registry and gets
        the 32-bit DISM. launch.bat starts the 64-bit PowerShell; this catches any other caller.
        Returns the 64-bit run's exit code, or $null when this process is already 64-bit.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{}
    )
    if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::Is64BitProcess) { return $null }
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    foreach ($parameter in $BoundParameters.GetEnumerator()) {
        if ($parameter.Value -is [System.Management.Automation.SwitchParameter]) {
            if ($parameter.Value.IsPresent) { $arguments += "-$($parameter.Key)" }
        } else {
            $arguments += "-$($parameter.Key)", "`"$($parameter.Value)`""
        }
    }
    $native = Start-Process -FilePath "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    return $native.ExitCode
}

Function Invoke-SilentUninstall {
    <#
    .SYNOPSIS
        Uninstall a program from its uninstall-registry entry - silently only, with a timeout
    .DESCRIPTION
        Uses msiexec /x {GUID} /qn for MSI products, else the vendor's QuietUninstallString.
        A plain UninstallString is never run: it usually opens a wizard, which would block an
        unattended run. Returns 'removed', 'reboot', 'manual' (no silent path), 'failed' or
        'timeout'; the caller decides how loudly to report it.
    .PARAMETER Entry
        An uninstall-registry entry (Get-ItemProperty of ...\Uninstall\*)
    .PARAMETER UninstallStringIsSilent
        The vendor documents the plain UninstallString as silent (OneDriveSetup.exe /uninstall)
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [int]$TimeoutMinutes = 15,
        [switch]$UninstallStringIsSilent
    )

    $command = $null
    if ($Entry.UninstallString -match '(?i)msiexec') {
        $guid = [regex]::Match($Entry.UninstallString, '\{[0-9A-Fa-f\-]+\}').Value
        if ($guid) { $command = "msiexec.exe /x $guid /qn /norestart" }
    }
    elseif ($Entry.QuietUninstallString) {
        $command = $Entry.QuietUninstallString
    }
    elseif ($UninstallStringIsSilent -and $Entry.UninstallString) {
        $command = $Entry.UninstallString
    }
    if (-not $command) { return 'manual' }

    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $command -WindowStyle Hidden -PassThru
    $null = $proc.Handle
    if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        $null = Invoke-NativeCommand taskkill @('/T', '/F', '/PID', $proc.Id)
        return 'timeout'
    }
    switch ($proc.ExitCode) {
        { $_ -in 0, 1605 } { return 'removed' }      # 1605 = already gone
        { $_ -in 1641, 3010 } { return 'reboot' }
        default { return 'failed' }
    }
}

Function Get-UninstallEntries {
    <#
    .SYNOPSIS
        Visible (non-system-component) uninstall-registry entries, 64- and 32-bit
    #>
    $regPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty $regPaths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -and -not $_.SystemComponent }
}

Function Invoke-SafeProcess {
    <#
    .SYNOPSIS
        Safely execute a process with error handling and logging
    #>
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        
        [string[]]$ArgumentList,
        
        [string]$Description = "Process execution"
    )
    
    try {
        Write-Log "Starting: $Description"
        Write-Verbose "FilePath: $FilePath"
        Write-Verbose "Arguments: $($ArgumentList -join ' ')"
        
        $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -ErrorAction Stop
        
        if ($process.ExitCode -eq 0) {
            Write-Log "$Description completed successfully" -Level Success
            return $true
        } else {
            Write-Log "$Description failed with exit code $($process.ExitCode)" -Level Error
            return $false
        }
    }
    catch {
        Write-Log "Failed to execute $Description : $_" -Level Error
        throw
    }
}

Export-ModuleMember -Function @(
    'Initialize-Logging'
    'Write-Log'
    'Get-LogIssues'
    'Show-SetupResult'
    'Set-KeepAwake'
    'Set-UiLanguage'
    'Get-UiLanguage'
    'Get-UiText'
    'Test-PrerequisiteAdmin'
    'Test-PrerequisiteInternet'
    'Sync-SystemTimeWithInternet'
    'Test-PrerequisiteDiskSpace'
    'Test-WindowsVersion'
    'Get-SystemGPU'
    'Get-BitlockerStatus'
    'Invoke-SafeProcess'
    'Invoke-NativeCommand'
    'Invoke-SilentUninstall'
    'Restart-In64BitPowerShell'
    'Get-OfficeProductIds'
    'Get-OfficeSetup'
    'New-OfficeConfiguration'
    'Uninstall-Microsoft365'
    'Get-UninstallEntries'
    'Stop-ProcessWithTimeout'
)

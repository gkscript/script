# Logging and utility functions for main setup script

# Windows PowerShell 5.1 does not load WinForms by default; every MessageBox in
# main.ps1 and this module throws "type not found" without it.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
. (Join-Path $PSScriptRoot 'WindowTheme.ps1')

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
    #>
    param(
        [string]$logPath = "C:\Logs\PSScriptSetup"
    )
    
    if (-not (Test-Path $logPath)) {
        $null = New-Item -Path $logPath -ItemType Directory -Force
    }
    
    $script:LogPath = $logPath
    $script:LogFile = Join-Path $logPath "setup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    
    Write-Log "Logging initialized at $($script:LogFile)"
    return $script:LogFile
}

Function Write-Log {
    <#
    .SYNOPSIS
        Write to log file and console with timestamp
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logMessage = "[$timestamp] [$Level] $Message"

    # Collected for the end-of-run summary (Get-LogIssues)
    if ($Level -in 'Warning', 'Error') {
        $script:LogIssues.Add($Message.Trim())
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
        Write-Log "System time synchronization failed: $_" -Level Warning
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
        Write-Log "Failed to retrieve GPU information: $_" -Level Warning
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
        Write-Log "BitLocker status check failed: $_" -Level Warning
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
    #>
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Success', 'Warning', 'Failed')]
        [string]$Status,

        [Parameter(Mandatory)]
        [string]$Title,

        [string]$Subtitle = '',

        [string[]]$Items = @(),

        [string]$LogFile,

        [switch]$RebootRequired
    )

    # Per status: band, headline, subline, item glyph color; solid glyphs from Segoe Fluent
    # Icons so all three carry the same weight at distance; taskbar progress color.
    # Every text color holds >= 4.5:1 on its band.
    $themes = @{
        Success = @{ Band = '#107C10'; Fg = '#FFFFFF'; Sub = '#DFF6DD'; Item = '#107C10'; Glyph = 0xEC61; Heading = '';                Taskbar = 'Normal' }
        Warning = @{ Band = '#FFC83D'; Fg = '#241B00'; Sub = '#4A3A00'; Item = '#9D5D00'; Glyph = 0xE814; Heading = 'Needs attention'; Taskbar = 'Paused' }
        Failed  = @{ Band = '#C42B1C'; Fg = '#FFFFFF'; Sub = '#FDE7E9'; Item = '#C42B1C'; Glyph = 0xEB90; Heading = 'What went wrong'; Taskbar = 'Error' }
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
            $Subtitle = (@($Subtitle, 'Restart required') | Where-Object { $_ }) -join " $([char]0xB7) "
        }
        (& $find 'Band').Background = & $brush $theme.Band
        (& $find 'Glyph').Text = [string][char]$theme.Glyph
        (& $find 'Glyph').Foreground = & $brush $theme.Fg
        (& $find 'TitleText').Text = $Title
        (& $find 'TitleText').Foreground = & $brush $theme.Fg
        (& $find 'SubtitleText').Text = $Subtitle
        (& $find 'SubtitleText').Foreground = & $brush $theme.Sub
        if (-not $Subtitle) { (& $find 'SubtitleText').Visibility = 'Collapsed' }

        $heading = & $find 'SectionHeading'
        $list = & $find 'ItemsList'
        $nothingListed = $Status -eq 'Success' -or $Items.Count -eq 0
        if ($nothingListed -and $RebootRequired) {
            # The restart is the one thing left; say it as the heading, not under "nothing"
            $heading.Text = 'Restart the PC to finish installing drivers.'
            (& $find 'ItemsScroll').Visibility = 'Collapsed'
        } elseif ($nothingListed) {
            $heading.Text = 'Nothing needs attention.'
            $heading.FontWeight = [System.Windows.FontWeights]::Normal
            (& $find 'ItemsScroll').Visibility = 'Collapsed'
        } else {
            $heading.Text = $theme.Heading
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
        if ($RebootRequired) {
            if (-not $nothingListed) { (& $find 'RestartRow').Visibility = 'Visible' }
            $restartButton.Visibility = 'Visible'
        } else {
            $closeButton.IsDefault = $true
        }

        (& $find 'OpenLogButton').Add_Click({ Start-Process notepad.exe -ArgumentList "`"$LogFile`"" })
        $restartButton.Add_Click({ $script:ResultRestart = $true; $window.Close() })
        $closeButton.Add_Click({ $window.Close() })

        Enable-WindowBackdrop -Window $window
        # The status color runs up through the title bar to the window's top edge
        Set-WindowCaptionColor -Window $window -Background $theme.Band -Foreground $theme.Fg
        $script:ResultRestart = $false
        $null = $window.ShowDialog()

        # Restart after the window is gone, never from inside its event handler
        if ($script:ResultRestart) {
            Write-Log "Restart requested from result window"
            Restart-Computer -Force
        }
    }
    catch {
        Write-Log "Result window failed, falling back to MessageBox: $_" -Level Warning
        $icon = @{ Success = 'Information'; Warning = 'Warning'; Failed = 'Error' }[$Status]
        $text = (@($Title, $Subtitle) + @($Items) + @($(if ($RebootRequired) { 'Restart the PC to finish installing drivers.' }), $(if ($LogFile) { "Log file: $LogFile" }))) |
            Where-Object { $_ } | Out-String
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
    'Test-PrerequisiteAdmin'
    'Test-PrerequisiteInternet'
    'Sync-SystemTimeWithInternet'
    'Test-PrerequisiteDiskSpace'
    'Test-WindowsVersion'
    'Get-SystemGPU'
    'Get-BitlockerStatus'
    'Invoke-SafeProcess'
    'Invoke-NativeCommand'
    'Stop-ProcessWithTimeout'
)

# Logging and utility functions for main setup script

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
        Write-Log "This script requires administrator privileges" -Level Error
        $null = [System.Windows.Forms.MessageBox]::Show("This script requires administrator privileges. Please run as administrator.", "Administrator Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        exit 1
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
        Write-Log "Internet connectivity check failed: $_" -Level Error
        $null = [System.Windows.Forms.MessageBox]::Show("Please check your Internet connection!", "No Internet", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        exit 1
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
        $gpu = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        $gpuInfo = @{
            Name = $gpu.Name
            IsNvidia = $gpu.Name -match [regex]::Escape("nvidia")
            IsAmd = $gpu.Name -match [regex]::Escape("amd")
        }
        Write-Log "Detected GPU: $($gpuInfo.Name)"
        return $gpuInfo
    }
    catch {
        Write-Log "Failed to retrieve GPU information: $_" -Level Warning
        return @{ Name = "Unknown"; IsNvidia = $false; IsAmd = $false }
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
    'Test-PrerequisiteAdmin'
    'Test-PrerequisiteInternet'
    'Test-PrerequisiteDiskSpace'
    'Test-WindowsVersion'
    'Get-SystemGPU'
    'Get-BitlockerStatus'
    'Invoke-SafeProcess'
)

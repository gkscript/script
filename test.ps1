param(
    [Parameter()]
    [string]$TestPath = '.',
    
    [Parameter()]
    [switch]$Verbose
)

# Test configuration
function Test-Configuration {
    Write-Host "`n=== Configuration Tests ===" -ForegroundColor Cyan
    
    $configPath = Join-Path $TestPath "src/config.json"
    
    if (-not (Test-Path $configPath)) {
        Write-Host "❌ Configuration file not found: $configPath" -ForegroundColor Red
        return $false
    }
    
    try {
        $config = Get-Content $configPath -Raw | ConvertFrom-Json
        Write-Host "✅ Configuration loads successfully" -ForegroundColor Green
        
        # Validate structure
        if (-not $config.logging) { throw "Missing 'logging' section" }
        if (-not $config.deployment) { throw "Missing 'deployment' section" }
        if (-not $config.paths) { throw "Missing 'paths' section" }
        if (-not $config.windows) { throw "Missing 'windows' section" }
        if (-not $config.validation) { throw "Missing 'validation' section" }
        
        Write-Host "✅ Configuration structure is valid" -ForegroundColor Green
        
        # Validate deployment types
        $requiredTypes = @('business', 'consumer')
        foreach ($type in $requiredTypes) {
            if (-not $config.deployment.$type) {
                throw "Missing deployment type: $type"
            }
        }
        Write-Host "✅ All required deployment types present" -ForegroundColor Green
        
        return $true
    }
    catch {
        Write-Host "❌ Configuration validation failed: $_" -ForegroundColor Red
        return $false
    }
}

# Test module loading
function Test-ModuleLoading {
    Write-Host "`n=== Module Loading Tests ===" -ForegroundColor Cyan
    
    $tests = @(
        @{ Path = "src/PSScriptMenuGui/PSScriptMenuGui.psd1"; Name = "PSScriptMenuGui Manifest" }
        @{ Path = "src/PSScriptMenuGui/PSScriptMenuGui.psm1"; Name = "PSScriptMenuGui Module" }
        @{ Path = "src/lib/PSSetupUtility.psm1"; Name = "PSSetupUtility Module" }
    )
    
    $allPassed = $true
    
    foreach ($test in $tests) {
        $fullPath = Join-Path $TestPath $test.Path
        
        if (-not (Test-Path $fullPath)) {
            Write-Host "❌ $($test.Name) not found: $fullPath" -ForegroundColor Red
            $allPassed = $false
            continue
        }
        
        Write-Host "✅ $($test.Name) found" -ForegroundColor Green
    }
    
    return $allPassed
}

# Test XAML syntax
function Test-XamlSyntax {
    Write-Host "`n=== XAML Syntax Tests ===" -ForegroundColor Cyan
    
    $xamlFiles = @(
        "src/PSScriptMenuGui/xaml/start.xaml"
        "src/PSScriptMenuGui/xaml/end.xaml"
    )
    
    $allPassed = $true
    
    foreach ($file in $xamlFiles) {
        $fullPath = Join-Path $TestPath $file
        
        if (-not (Test-Path $fullPath)) {
            Write-Host "❌ XAML file not found: $fullPath" -ForegroundColor Red
            $allPassed = $false
            continue
        }
        
        try {
            $content = Get-Content $fullPath -Raw
            [xml]$xaml = $content
            Write-Host "✅ $file - Valid XML syntax" -ForegroundColor Green
        }
        catch {
            Write-Host "❌ $file - Invalid XML: $_" -ForegroundColor Red
            $allPassed = $false
        }
    }
    
    return $allPassed
}

# Test CSV format
function Test-CsvFormat {
    Write-Host "`n=== CSV Format Tests ===" -ForegroundColor Cyan
    
    # Create sample CSV for testing
    $sampleCsv = Join-Path $TestPath "src/test-menu.csv"
    
    if (Test-Path $sampleCsv) {
        try {
            $csv = Import-Csv $sampleCsv
            Write-Host "✅ Sample CSV loads successfully" -ForegroundColor Green
            Write-Host "   Item count: $($csv.Count)" -ForegroundColor Cyan
            
            # Validate required columns
            $requiredColumns = @('Name', 'Method', 'Command')
            foreach ($col in $requiredColumns) {
                if ($csv[0].$col) {
                    Write-Host "   ✅ Column '$col' present" -ForegroundColor Green
                } else {
                    Write-Host "   ❌ Column '$col' missing" -ForegroundColor Red
                    return $false
                }
            }
            return $true
        }
        catch {
            Write-Host "❌ CSV validation failed: $_" -ForegroundColor Red
            return $false
        }
    } else {
        Write-Host "⚠️  No test CSV found at $sampleCsv (skipping test)" -ForegroundColor Yellow
        return $true
    }
}

# Test file structure
function Test-FileStructure {
    Write-Host "`n=== File Structure Tests ===" -ForegroundColor Cyan
    
    $requiredFiles = @(
        "README.md"
        "src/config.json"
        "src/main.ps1"
        "src/main.legacy.ps1"
        "src/PSScriptMenuGui/PSScriptMenuGui.psd1"
    )
    
    $allPassed = $true
    
    foreach ($file in $requiredFiles) {
        $fullPath = Join-Path $TestPath $file
        
        if (Test-Path $fullPath) {
            $size = (Get-Item $fullPath).Length
            Write-Host "✅ $file ($('{0:N0}' -f $size) bytes)" -ForegroundColor Green
        } else {
            Write-Host "❌ Missing: $file" -ForegroundColor Red
            $allPassed = $false
        }
    }
    
    return $allPassed
}

# Test utility functions (if PSSetupUtility is available)
function Test-UtilityFunctions {
    Write-Host "`n=== Utility Function Tests ===" -ForegroundColor Cyan
    
    $utilPath = Join-Path $TestPath "src/lib/PSSetupUtility.psm1"
    
    if (-not (Test-Path $utilPath)) {
        Write-Host "⚠️  PSSetupUtility module not found (skipping)" -ForegroundColor Yellow
        return $true
    }
    
    try {
        Import-Module $utilPath -Force -ErrorAction Stop
        
        $functionsToTest = @(
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
        
        foreach ($func in $functionsToTest) {
            if (Get-Command $func -ErrorAction SilentlyContinue) {
                Write-Host "✅ $func - Available" -ForegroundColor Green
            } else {
                Write-Host "❌ $func - Not found" -ForegroundColor Red
                return $false
            }
        }
        
        return $true
    }
    catch {
        Write-Host "❌ Failed to load PSSetupUtility: $_" -ForegroundColor Red
        return $false
    }
}

# Test documentation
function Test-Documentation {
    Write-Host "`n=== Documentation Tests ===" -ForegroundColor Cyan
    
    $docs = @(
        @{ Path = "README.md"; Name = "README" }
        @{ Path = "IMPROVEMENTS.md"; Name = "Improvements" }
    )
    
    $allPassed = $true
    
    foreach ($doc in $docs) {
        $fullPath = Join-Path $TestPath $doc.Path
        
        if (Test-Path $fullPath) {
            $size = (Get-Item $fullPath).Length
            $lines = @(Get-Content $fullPath).Count
            Write-Host "✅ $($doc.Name) - $('{0:N0}' -f $lines) lines" -ForegroundColor Green
        } else {
            Write-Host "❌ Missing: $($doc.Path)" -ForegroundColor Red
            $allPassed = $false
        }
    }
    
    return $allPassed
}

# ============================================================================
# MAIN EXECUTION
# ============================================================================

Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
Write-Host "PSScript Repository Test Suite" -ForegroundColor Cyan
Write-Host ("=" * 50) + "`n" -ForegroundColor Cyan

$results = @()

# Run all tests
$results += @{ Name = "Configuration"; Result = Test-Configuration }
$results += @{ Name = "Module Loading"; Result = Test-ModuleLoading }
$results += @{ Name = "XAML Syntax"; Result = Test-XamlSyntax }
$results += @{ Name = "CSV Format"; Result = Test-CsvFormat }
$results += @{ Name = "File Structure"; Result = Test-FileStructure }
$results += @{ Name = "Documentation"; Result = Test-Documentation }
$results += @{ Name = "Utility Functions"; Result = Test-UtilityFunctions }

# Summary
Write-Host "`n" + ("=" * 50) -ForegroundColor Cyan
Write-Host "Test Summary" -ForegroundColor Cyan
Write-Host ("=" * 50) -ForegroundColor Cyan

$passed = ($results | Where-Object { $_.Result -eq $true } | Measure-Object).Count
$failed = ($results | Where-Object { $_.Result -eq $false } | Measure-Object).Count
$total = $results.Count

foreach ($test in $results) {
    $icon = if ($test.Result) { "✅" } else { "❌" }
    Write-Host "$icon $($test.Name)" -ForegroundColor $(if ($test.Result) { "Green" } else { "Red" })
}

Write-Host "`n" -ForegroundColor Cyan
Write-Host "Results: $passed/$total passed, $failed/$total failed" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Red" })
Write-Host ("=" * 50) + "`n" -ForegroundColor Cyan

exit $failed

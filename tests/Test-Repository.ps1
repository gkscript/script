# Static checks for gk-script - the bugs that have bitten before, caught before a release.
# Runs on every push (GitHub Actions, Windows PowerShell 5.1) and in release.ps1; locally:
#   powershell -ExecutionPolicy Bypass -File tests\Test-Repository.ps1
# Exit code 0 = all checks passed. Keep this file ASCII.
param([string]$Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
$failures = New-Object System.Collections.Generic.List[string]
function Fail([string]$Message) { $failures.Add($Message); Write-Host "  FAIL $Message" -ForegroundColor Red }
function Pass([string]$Message) { Write-Host "  ok   $Message" -ForegroundColor Green }

$src = Join-Path $Root 'src'
$scripts = @(Get-ChildItem -Path $src -Recurse -Include *.ps1, *.psm1 -File) +
    @(Get-ChildItem -Path $Root -File -Include *.ps1 -Recurse -Depth 1 | Where-Object { $_.DirectoryName -notlike "$src*" })

Write-Host "PowerShell scripts ($($scripts.Count))"
$allCode = New-Object System.Text.StringBuilder
foreach ($file in $scripts) {
    $tokens = $null; $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    $name = $file.FullName.Substring($Root.Length + 1)
    if ($errors.Count) { Fail "$name does not parse: $($errors[0].Message) (line $($errors[0].Extent.StartLineNumber))"; continue }
    # Windows PowerShell 5.1 reads scripts without BOM as ANSI: non-ASCII inside a string breaks it
    $bad = @($tokens | Where-Object {
        $_.Kind -in 'StringLiteral', 'StringExpandable', 'HereStringLiteral', 'HereStringExpandable' -and $_.Text -match '[^\x00-\x7F]'
    })
    if ($bad.Count) { Fail "$name has non-ASCII characters in a string (line $($bad[0].Extent.StartLineNumber))" }
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { Fail "$name has a UTF-8 BOM" }
    $null = $allCode.AppendLine([System.IO.File]::ReadAllText($file.FullName))
}
$code = $allCode.ToString()
if (-not $failures.Count) { Pass 'parse in Windows PowerShell, ASCII-only strings, no BOM' }

Write-Host 'XAML'
foreach ($xaml in Get-ChildItem -Path $src -Recurse -Filter *.xaml) {
    try { [xml]([System.IO.File]::ReadAllText($xaml.FullName)) | Out-Null; Pass $xaml.Name }
    catch { Fail "$($xaml.Name) is not well-formed: $_" }
}

Write-Host 'Languages'
$langs = @{}
foreach ($code2 in 'de', 'en', 'it') {
    $path = Join-Path $src "lang\$code2.json"
    try { $langs[$code2] = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Fail "lang\$code2.json is not valid JSON: $_" }
}
if ($langs.Count -eq 3) {
    $keys = @{}
    foreach ($l in $langs.Keys) { $keys[$l] = @($langs[$l].PSObject.Properties.Name) }
    foreach ($l in 'en', 'it') {
        $missing = @($keys['de'] | Where-Object { $_ -notin $keys[$l] }) + @($keys[$l] | Where-Object { $_ -notin $keys['de'] })
        if ($missing.Count) { Fail "lang\$l.json and de.json differ: $($missing -join ', ')" }
    }
    # Every literal key the code asks for must exist
    $used = [regex]::Matches($code, "(?:Get-UiText|-Key)\s+'?([a-z]+\.[A-Za-z0-9.]+)") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
    $unknown = @($used | Where-Object { $_ -notin $keys['en'] })
    if ($unknown.Count) { Fail "keys used in code but missing in lang: $($unknown -join ', ')" }
    if (-not $failures.Count) { Pass "$($keys['de'].Count) keys, same in de/en/it, all used keys exist" }
}

Write-Host 'config.json and gui.csv'
try {
    $config = Get-Content (Join-Path $src 'config.json') -Raw | ConvertFrom-Json
    foreach ($profileEntry in $config.deployment.PSObject.Properties) {
        foreach ($package in $profileEntry.Value.packages) {
            if (-not $config.packageCatalog.$package) { Fail "profile $($profileEntry.Name): package '$package' is not in packageCatalog" }
        }
    }
    Pass 'config.json valid, every profile package is in the catalog'
}
catch { Fail "config.json is not valid JSON: $_" }
$rows = Import-Csv (Join-Path $src 'gui.csv') -Encoding UTF8
foreach ($row in $rows) {
    $script = ($row.Command -split ' ')[0] -replace '^\.\\', ''
    if (-not (Test-Path (Join-Path $Root $script))) { Fail "gui.csv '$($row.Name)': $script not found" }
    if ($row.NameKey -and $langs['en'] -and -not $langs['en'].($row.NameKey)) { Fail "gui.csv '$($row.Name)': NameKey $($row.NameKey) missing in lang" }
}
Pass "gui.csv: $($rows.Count) rows point to existing scripts"

Write-Host '.reg files'
foreach ($reg in Get-ChildItem -Path $src -Filter *.reg) {
    $bytes = [System.IO.File]::ReadAllBytes($reg.FullName)
    $utf16 = $bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE
    $ascii = -not ($bytes | Where-Object { $_ -gt 127 })
    # reg.exe import accepts UTF-16 LE with BOM or ANSI - never UTF-8 with BOM
    if (-not ($utf16 -or $ascii)) { Fail "$($reg.Name) must be UTF-16 LE (BOM) or ASCII" }
}
Pass 'all .reg files are UTF-16 LE or ASCII'

Write-Host ''
if ($failures.Count) {
    Write-Host "$($failures.Count) check(s) failed" -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed' -ForegroundColor Green
exit 0

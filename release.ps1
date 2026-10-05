#Requires -Version 5.1
<#
.SYNOPSIS
    Release gk-script in one step: version, changelog date, checks, build, commit, push, GitHub Release
.DESCRIPTION
    1. Sets src\version.txt, turns README's "### Unreleased" into "### vX.Y.Z - <date>" and
       updates the version shown in DESIGN.md / .impeccable\design.json.
    2. Runs tests\Test-Repository.ps1 and build.ps1 - stops on any failure.
    3. Commits everything (including gk-script.exe), pushes master, and publishes a GitHub
       Release with the changelog entry as notes and gk-script.exe attached (marked Latest).
    Needs git, NSIS and the GitHub CLI (gh, signed in).
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File release.ps1 -Version 2.2.0 -Summary "update follow-up, setup report"
#>
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    # Short description for the commit title: "release: vX.Y.Z - <Summary>"
    [string]$Summary,

    # Stop after the local commit: no push, no GitHub Release
    [switch]$NoPublish,

    # Lines appended to the commit message (e.g. a Co-Authored-By trailer)
    [string[]]$Trailer = @()
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
$utf8 = New-Object System.Text.UTF8Encoding $false

function Invoke-Git {
    # git reports progress on stderr; only the exit code counts
    $ErrorActionPreference = 'Continue'
    $output = & git @args 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed: $($output -join ' ')" }
    return $output
}

# --- Preconditions
$tag = "v$Version"
if ((Invoke-Git rev-parse --abbrev-ref HEAD) -ne 'master') { throw 'Releases are made from master.' }
if (Invoke-Git tag --list $tag) { throw "Tag $tag already exists." }
$untracked = @(Invoke-Git status --porcelain | Where-Object { $_ -like '[?][?]*' })
if ($untracked.Count) { throw "Untracked files - add them to git or .gitignore first:`n$($untracked -join "`n")" }
$gh = (Get-Command gh -ErrorAction SilentlyContinue).Source
if (-not $gh -and (Test-Path "$env:ProgramFiles\GitHub CLI\gh.exe")) { $gh = "$env:ProgramFiles\GitHub CLI\gh.exe" }
if (-not $NoPublish -and -not $gh) { throw 'GitHub CLI (gh) not found - install it (winget install GitHub.cli) and run gh auth login.' }

# --- Version and changelog
$readmePath = Join-Path $PSScriptRoot 'README.md'
$readme = [System.IO.File]::ReadAllText($readmePath)
$match = [regex]::Match($readme, '(?ms)^### Unreleased\s*\r?\n(.*?)(?=^### )')
if (-not $match.Success -or -not $match.Groups[1].Value.Trim()) { throw 'README.md has no "### Unreleased" section with entries.' }
$changes = $match.Groups[1].Value.Trim()
$heading = "### $tag $([char]0x2014) $(Get-Date -Format 'yyyy-MM-dd')"
$readme = $readme.Substring(0, $match.Index) + [regex]::Replace($readme.Substring($match.Index), '^### Unreleased', $heading, 'Multiline')
[System.IO.File]::WriteAllText($readmePath, $readme, $utf8)

$versionPath = Join-Path $PSScriptRoot 'src\version.txt'
$previous = ([System.IO.File]::ReadAllText($versionPath)).Trim()
[System.IO.File]::WriteAllText($versionPath, $Version, $utf8)
foreach ($file in 'DESIGN.md', '.impeccable\design.json') {
    $path = Join-Path $PSScriptRoot $file
    if (-not (Test-Path $path)) { continue }
    $text = [System.IO.File]::ReadAllText($path)
    [System.IO.File]::WriteAllText($path, ($text -replace "v$([regex]::Escape($previous))\b", $tag), $utf8)
}
Write-Host "Version $previous -> $Version, changelog dated" -ForegroundColor Cyan

# --- Checks and build
& "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'tests\Test-Repository.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Repository checks failed - nothing committed (version files are already updated).' }
& (Join-Path $PSScriptRoot 'build.ps1')

# --- Commit, push, GitHub Release
$title = if ($Summary) { "release: $tag - $Summary" } else { "release: $tag" }
$messageFile = Join-Path $env:TEMP "gk-release-$Version.txt"
$message = "$title`n`n$changes`n"
if ($Trailer.Count) { $message += "`n$($Trailer -join "`n")`n" }
[System.IO.File]::WriteAllText($messageFile, $message, $utf8)
$null = Invoke-Git add -A
$null = Invoke-Git commit -q -F $messageFile
$sha = (Invoke-Git rev-parse HEAD) | Select-Object -Last 1
Write-Host "Committed $($sha.Substring(0, 7)): $title" -ForegroundColor Green
if ($NoPublish) { Write-Host 'Not published (-NoPublish).'; return }

$null = Invoke-Git push origin master
$notesFile = Join-Path $env:TEMP "gk-release-notes-$Version.md"
$notes = "$changes`n`n**Download:** ``gk-script.exe`` below. Copy it to the new PC and run it (admin rights required).`n"
# Screenshots from docs\screenshots at this release's tag (Make-Screenshots.ps1 renders them)
$remoteForImages = (Invoke-Git remote get-url origin) -replace '\.git$', '' -replace '^https://github\.com/', ''
$shots = @('menu', 'result-success', 'office-choice', 'report') | Where-Object { Test-Path (Join-Path $PSScriptRoot "docs\screenshots\$_.png") }
if ($shots) {
    $images = $shots | ForEach-Object { "<img src=`"https://raw.githubusercontent.com/$remoteForImages/$tag/docs/screenshots/$_.png`" width=`"49%`" alt=`"$_`">" }
    $notes += "`n### Screenshots`n`n$($images -join ' ')`n"
}
[System.IO.File]::WriteAllText($notesFile, $notes, $utf8)
$remote = (Invoke-Git remote get-url origin) -replace '\.git$', '' -replace '^https://github\.com/', ''
& $gh release create $tag (Join-Path $PSScriptRoot 'gk-script.exe') --repo $remote --target $sha --title $tag --notes-file $notesFile --latest
if ($LASTEXITCODE -ne 0) { throw 'gh release create failed - the commit is pushed; create the release by hand.' }
Remove-Item $messageFile, $notesFile -Force -ErrorAction SilentlyContinue
Write-Host "Released $tag" -ForegroundColor Green

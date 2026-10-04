# UI language for every gk-script window (menu + result window).
# Strings live in src/lang/<code>.json (UTF-8), so .ps1 files stay ASCII-only.
# Dot-sourced by PSSetupUtility and PSScriptMenuGui (separate PowerShell processes).
# The log file stays English; only what the technician sees is translated.

$script:UiLanguages = @('de', 'en', 'it')
$script:UiLanguage = 'de'
$script:UiStrings = @{}
$script:UiFallback = @{}

Function Read-UiStringFile {
    param([string]$Code)
    $path = Join-Path (Join-Path (Split-Path $PSScriptRoot -Parent) 'lang') "$Code.json"
    $table = @{}
    if (Test-Path $path) {
        $json = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
        $json.PSObject.Properties | ForEach-Object { $table[$_.Name] = $_.Value }
    }
    return $table
}

Function Set-UiLanguage {
    <#
    .SYNOPSIS
        Select the UI language (de, en, it); unknown codes fall back to German
    #>
    param([string]$Language = 'de')

    if ($Language -notin $script:UiLanguages) { $Language = 'de' }
    $script:UiLanguage = $Language
    $script:UiStrings = Read-UiStringFile $Language
    $script:UiFallback = if ($Language -eq 'en') { $script:UiStrings } else { Read-UiStringFile 'en' }
}

Function Get-UiLanguage { return $script:UiLanguage }

Function Get-UiText {
    <#
    .SYNOPSIS
        Translated text for a key, formatted with -f; falls back to English, then the key
    #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments = @()
    )
    $template = $script:UiStrings[$Key]
    if (-not $template) { $template = $script:UiFallback[$Key] }
    if (-not $template) { $template = $Key }
    if ($Arguments.Count -gt 0) { return ($template -f $Arguments) }
    return $template
}

Set-UiLanguage 'de'

<#
.SYNOPSIS
    Generates docs/what-this-changes.md from bloat-patterns.json, apps-catalog.json and
    tweaks.json.

.DESCRIPTION
    A single reference table of every registry path/value, service, scheduled task and
    AppX/Win32 pattern this tool can touch, and whether each is reversible. Run this by
    hand after editing any of the three source JSON files to keep the generated reference
    in sync. Not yet wired into an automated release workflow (planned as part of a future
    CI/release pipeline) - this is a manual step for now.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of this script's own directory
    (debloat\..).

.PARAMETER OutputPath
    Where to write the generated Markdown file. Defaults to docs\what-this-changes.md
    under RepoRoot.

.EXAMPLE
    .\Generate-ChangesReference.ps1
#>

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'docs\what-this-changes.md')
)

$bloatPatternsPath = Join-Path $RepoRoot 'debloat\bloat-patterns.json'
$appsCatalogPath = Join-Path $RepoRoot 'debloat\apps-catalog.json'
$tweaksPath = Join-Path $RepoRoot 'debloat\tweaks.json'

foreach ($p in @($bloatPatternsPath, $appsCatalogPath, $tweaksPath)) {
    if (-not (Test-Path $p)) {
        Write-Error "Required source file not found: $p"
        exit 1
    }
}

$bloatPatterns = Get-Content -Path $bloatPatternsPath -Raw | ConvertFrom-Json
$appsCatalog = Get-Content -Path $appsCatalogPath -Raw | ConvertFrom-Json
$tweaksData = Get-Content -Path $tweaksPath -Raw | ConvertFrom-Json

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# What This Changes')
$lines.Add('')
$lines.Add('Generated from `debloat/bloat-patterns.json`, `debloat/apps-catalog.json` and')
$lines.Add('`debloat/tweaks.json` by `debloat/Generate-ChangesReference.ps1`. Regenerate after')
$lines.Add('editing any of those files - this is not yet run automatically in CI.')
$lines.Add('')

$lines.Add('## OEM Bloatware Removal')
$lines.Add('')
$lines.Add('One-way - not covered by Revert Last Run. Applied only when the matching OEM is')
$lines.Add('detected (or explicitly selected) and the tool looks like commercial hardware.')
$lines.Add('')
foreach ($oemName in $bloatPatterns.PSObject.Properties.Name) {
    $oem = $bloatPatterns.$oemName
    $lines.Add("### $oemName")
    $lines.Add('')
    if ($oem.appxPatterns -and $oem.appxPatterns.Count -gt 0) {
        $lines.Add('**AppX packages removed:**')
        $lines.Add('')
        foreach ($pattern in $oem.appxPatterns) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
    if ($oem.win32Patterns -and $oem.win32Patterns.Count -gt 0) {
        $lines.Add('**Win32 programs uninstalled:**')
        $lines.Add('')
        foreach ($pattern in $oem.win32Patterns) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
    if ($oem.servicePatterns -and $oem.servicePatterns.Count -gt 0) {
        $lines.Add('**Services disabled (if orphaned after removal):**')
        $lines.Add('')
        foreach ($pattern in $oem.servicePatterns) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
    if ($oem.scheduledTaskFolders -and $oem.scheduledTaskFolders.Count -gt 0) {
        $lines.Add('**Scheduled task folders disabled (if orphaned after removal):**')
        $lines.Add('')
        foreach ($pattern in $oem.scheduledTaskFolders) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
    if ($oem.scheduledTaskKeepPatterns -and $oem.scheduledTaskKeepPatterns.Count -gt 0) {
        $lines.Add('**Explicitly kept even inside a disabled folder above:**')
        $lines.Add('')
        foreach ($pattern in $oem.scheduledTaskKeepPatterns) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
}

$lines.Add('## Registry Tweaks')
$lines.Add('')
$lines.Add('Opt-in, off by default, and reversible unless noted - unchecking a tweak in the')
$lines.Add('Customize Preferences panel writes back the Off column exactly.')
$lines.Add('')
$lines.Add('| Tweak | Scope | Registry Path | Value Name | On | Off |')
$lines.Add('| --- | --- | --- | --- | --- | --- |')
foreach ($t in ($tweaksData.tweaks | Sort-Object key)) {
    if (-not $t.entries -or $t.entries.Count -eq 0) {
        $lines.Add("| ``$($t.key)`` | $($t.scope) | *(special-cased - see source code, not a plain registry entry)* | - | - | - |")
    } else {
        foreach ($e in $t.entries) {
            $lines.Add("| ``$($t.key)`` | $($t.scope) | ``$($e.path)`` | ``$($e.name)`` | ``$($e.onValue)`` | ``$($e.offValue)`` |")
        }
    }
}
$lines.Add('')

$lines.Add('## Install Apps Catalog')
$lines.Add('')
$lines.Add('| App | Category | Winget ID | SAC Risk |')
$lines.Add('| --- | --- | --- | --- |')
foreach ($app in ($appsCatalog.apps | Sort-Object category, name)) {
    $id = if ($app.wingetId) { "``$($app.wingetId)``" } else { '*(direct download, no winget package)*' }
    $risk = if ($app.sacRisk) { 'Yes' } else { '' }
    $lines.Add("| $($app.name) | $($app.category) | $id | $risk |")
}
$lines.Add('')

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
($lines -join "`n") | Set-Content -Path $OutputPath -Encoding UTF8 -NoNewline
Write-Host "Generated $OutputPath ($($lines.Count) lines)"

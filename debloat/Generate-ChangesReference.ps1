<#
.SYNOPSIS
    Generates docs/what-this-changes.md from bloat-patterns.json, apps-catalog.json and
    tweaks.json.

.DESCRIPTION
    A single reference table of every registry path/value, service, scheduled task and
    AppX/Win32 pattern this tool can touch, and whether each is reversible. CI
    (.github/workflows/ci.yml) runs this on every push to main and commits the result
    back, so day-to-day edits to the three source JSON files don't need a manual
    regeneration - only run this by hand if you want to preview the output first.

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
$lines.Add('`debloat/tweaks.json` by `debloat/Generate-ChangesReference.ps1`. Regenerated')
$lines.Add('automatically by CI (`.github/workflows/ci.yml`) on every push to main and committed')
$lines.Add('back - no manual step needed for a day-to-day edit to those files.')
$lines.Add('')

$lines.Add('## OEM Bloatware Removal')
$lines.Add('')
$lines.Add('One-way - not covered by Revert Last Run. Applied for each OEM that is ticked in the GUI (Dell')
$lines.Add('and Lenovo both start ticked) or passed as `-Dell` / `-Lenovo`. If neither is passed - which is')
$lines.Add('also what unticking BOTH GUI boxes does - the worker takes it as both; tick Skip debloat to run no')
$lines.Add('OEM removal at all. The generic list below (McAfee, Dropbox and WildTangent promos, the consumer')
$lines.Add('Teams/Chat package, the Web Experience pack) applies on every Phase 1 run. The machine''s')
$lines.Add('manufacturer and model are NOT checked. (The "commercial hardware" check applies only to')
$lines.Add('installing Dell Command | Update / Lenovo System Update.)')
$lines.Add('')
$lines.Add('**Judgement calls.** These are removed by default, whatever the organisation uses; delete the')
$lines.Add('pattern from `debloat/bloat-patterns.json` to keep one. `Dell SupportAssist*` and the service')
$lines.Add('pattern `*SupportAssist*` also match Dell SupportAssist for Business PCs and its service.')
$lines.Add('`Waves MaxxAudio*` and `MaxxAudioPro*` are audio software: users report that removing it can cost')
$lines.Add('headphone-jack and microphone detection. `Dell Core Services` is a shared Dell component (Dell''s')
$lines.Add('own knowledge base says other Dell agents can go into an Unknown State when it is removed): it is')
$lines.Add('removed without `IGNOREDEPENDENCIES`, so that a dependency check in its installer, where it has')
$lines.Add('one, can keep it while other software depends on it (not verified for this package, and it then')
$lines.Add('ends as a NOT REMOVED warning). `McAfee*` matches every McAfee program, trial, paid or centrally')
$lines.Add('managed. Dell Command | Update is kept.')
$lines.Add('')
$lines.Add('**How a program is removed.** Its own uninstaller is run and the result is checked against the')
$lines.Add('Apps list; a program counts as removed only when it has really left that list.')
$lines.Add('')
$lines.Add('- A Windows Installer product is removed with `msiexec /x <product code> IGNOREDEPENDENCIES=ALL')
$lines.Add('  /qn /norestart`, a WiX Burn bundle with its own `/uninstall /quiet /norestart`. (A Burn bundle')
$lines.Add('  passes `IGNOREDEPENDENCIES=ALL` to its MSIs itself, but only after checking what depends on')
$lines.Add('  them; this tool makes no such check, so a product marked as shared keeps the check on.)')
$lines.Add('- Before the uninstaller runs, the services and processes listed under "Per-program hints" below are')
$lines.Add('  stopped - the services are also set to Disabled, and the log says what each was before - and')
$lines.Add('  anything running from the program''s own folder (when its Apps entry registers one) is ended;')
$lines.Add('  never Dell Command Update, the Windows folder, a PowerShell host or the installer itself.')
$lines.Add('- An installer that has not finished after its time limit - 10 minutes for a Windows Installer')
$lines.Add('  product or a bundle, 4 for an InstallShield wrapper, 5 for any other uninstaller, or the limit')
$lines.Add('  named below - is stopped together with its child processes, and the program is reported as NOT')
$lines.Add('  REMOVED. What Windows Installer does with an interrupted transaction is not known.')
$lines.Add('- An Apps entry is deleted only when it is a proven leftover: its uninstaller file is gone, or an MSI')
$lines.Add('  or InstallShield-wrapper layer answers "not installed" (a bundle that does is reported, not cleared),')
$lines.Add('  AND the entry declares something that can be looked at - an install folder, the folder its uninstaller')
$lines.Add('  sat in, an icon file that is not a Windows file, a service named in the hints - AND none of it is')
$lines.Add('  found (a folder counts only if it holds something; a network share or a drive this session cannot see')
$lines.Add('  cannot be checked and counts as "still there"). An entry that declares nothing to look at is kept and')
$lines.Add('  reported, with its registry key, so that it can be removed by hand. A cleared entry is counted as')
$lines.Add('  "leftover Apps entry cleared", not as a removed program - unless an uninstaller of the program ran')
$lines.Add('  successfully. A .reg backup of the deleted entry is saved first in')
$lines.Add('  `C:\ProgramData\DellOfficeDeploy` and is never deleted by the tool.')
$lines.Add('- A program that stays is listed as NOT REMOVED with the exit code and, where there is one, the')
$lines.Add('  installer''s own message or log. Its services that were set to Disabled stay Disabled; the line')
$lines.Add('  says which, and how to undo it. A dry run lists the programs, the command of each uninstaller and')
$lines.Add('  the services and processes it would stop, and changes nothing.')
$lines.Add('- The finish banner counts warning lines, not programs: a run in which every program was removed')
$lines.Add('  can still end "with N warnings" (a failed first attempt counts). The "Phase 1 result" line says')
$lines.Add('  how many programs are really gone, and a "Nothing that was targeted is left" line says so when')
$lines.Add('  that is all the warnings were.')
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
    $stopHints = @($oem.productHints | Where-Object { $_ -and ($_.services -or $_.processes -or $_.silentArgs -or $_.timeoutSec) })
    if ($stopHints.Count -gt 0) {
        $lines.Add('**Per-program hints: the services and processes are stopped before the matching program is uninstalled (the services are also set to Disabled, so that they should not restart in the middle of it); a silent switch and a time limit apply to the uninstaller itself:**')
        $lines.Add('')
        foreach ($hint in $stopHints) {
            $parts = New-Object System.Collections.Generic.List[string]
            if ($hint.services) { $parts.Add('services ' + ((@($hint.services) | ForEach-Object { "``$_``" }) -join ', ')) }
            if ($hint.processes) { $parts.Add('processes ' + ((@($hint.processes) | ForEach-Object { "``$_``" }) -join ', ')) }
            if ($hint.silentArgs) { $parts.Add("its uninstaller is run with ``$($hint.silentArgs)``") }
            if ($hint.timeoutSec) { $parts.Add("its own uninstallers (not the Windows Installer product) get a time limit of $([int]([int]$hint.timeoutSec / 60)) minutes") }
            $lines.Add("- ``$($hint.match)``: " + ($parts -join '; '))
        }
        $lines.Add('')
    }
    $keptHints = @($oem.productHints | Where-Object { $_ -and $_.respectDependencies -eq $true })
    if ($keptHints.Count -gt 0) {
        $lines.Add('**Kept while other software depends on them (uninstalled without `IGNOREDEPENDENCIES`; reported as NOT REMOVED when that stops the uninstall):**')
        $lines.Add('')
        foreach ($hint in $keptHints) { $lines.Add("- ``$($hint.match)``") }
        $lines.Add('')
    }
    if ($oem.servicePatterns -and $oem.servicePatterns.Count -gt 0) {
        $lines.Add('**Services stopped and disabled (every match, whether or not its program was removed - a program that could not be uninstalled stays installed with its service Disabled; undo with `Set-Service -Name <name> -StartupType <the type it had before - the log says which>`):**')
        $lines.Add('')
        foreach ($pattern in $oem.servicePatterns) { $lines.Add("- ``$pattern``") }
        $lines.Add('')
    }
    if ($oem.scheduledTaskFolders -and $oem.scheduledTaskFolders.Count -gt 0) {
        $lines.Add('**Scheduled task folders disabled (every task in them except the ones kept below, whether or not its program was removed; they are disabled, not deleted - undo in Task Scheduler):**')
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
    $id = if ($app.wingetId) { "``$($app.wingetId)``" }
          elseif ($app.downloadUrl) { '*(direct download, no winget package)*' }
          else { '*(manual install only - no automated download)*' }
    $risk = if ($app.sacRisk) { 'Yes' } else { '' }
    $lines.Add("| $($app.name) | $($app.category) | $id | $risk |")
}
$lines.Add('')

$outputDir = Split-Path -Parent $OutputPath
if (-not (Test-Path $outputDir)) { New-Item -ItemType Directory -Path $outputDir -Force | Out-Null }
# ASCII, not UTF8 - Windows PowerShell 5.1's -Encoding UTF8 writes a BOM, and every
# source field this table pulls from (app/category/tweak names, registry paths) is
# ASCII already, so there's no reason to risk it (same fix already applied to
# latest.json in release.yml after a real BOM shipped in the v1.0.0 release).
($lines -join "`n") | Set-Content -Path $OutputPath -Encoding ASCII -NoNewline
Write-Host "Generated $OutputPath ($($lines.Count) lines)"

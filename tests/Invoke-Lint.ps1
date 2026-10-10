<#
.SYNOPSIS
    Static validation for Gr3y-Tools: PSScriptAnalyzer compatibility checks, ASCII/line-
    ending enforcement, JSON schema checks, wildcard pattern validation, and an XAML parse.

.DESCRIPTION
    Runs locally (during development) and in CI (.github/workflows/ci.yml) - both call
    this same script so there's one source of truth for what "passing" means.

    PSUseCompatibleSyntax (does this script's LANGUAGE syntax parse under both PS 5.1 and
    7.4) is a hard failure - it's a pure AST check with no false-positive risk from a
    script's own locally-defined functions.

    PSUseCompatibleCommands (are the COMMANDS this script calls available in PS 5.1) is
    reported, not hard-failed. Confirmed by hand that raw findings are dominated by false
    positives: every locally-defined function (Write-Log, Invoke-Step, etc.) gets flagged
    as "not available" since the rule only knows about published module/cmdlet compat
    data, not a script's own functions - this script filters those out by name. What's
    left can still include real false positives from gaps in the bundled compatibility
    profile data (e.g. Set-ItemProperty's long-standing -Type parameter was flagged as
    unavailable in 5.1, which is incorrect). Hard-failing on unfiltered noise trains
    everyone to ignore a permanently-red check, so the remainder is surfaced for a human
    to read, not used to fail the build.

.PARAMETER RepoRoot
    Path to the repository root. Defaults to the parent of this script's own directory.

.EXAMPLE
    .\tests\Invoke-Lint.ps1
#>

param(
    [string]$RepoRoot = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$hadFailure = $false

function Write-LintError {
    param([string]$Message)
    Write-Host "FAIL: $Message" -ForegroundColor Red
    $script:hadFailure = $true
}

function Write-LintOk {
    param([string]$Message)
    Write-Host "OK: $Message" -ForegroundColor Green
}

$debloatDir = Join-Path $RepoRoot 'debloat'
$psFiles = Get-ChildItem -Path $debloatDir -Filter '*.ps1' -Recurse
$jsonFiles = Get-ChildItem -Path $debloatDir -Filter '*.json' -Recurse
$rootPs1 = Join-Path $RepoRoot 'debloat.ps1'
if (Test-Path $rootPs1) { $psFiles = @($psFiles) + (Get-Item $rootPs1) }

Write-Host '--- Pure-ASCII and LF-only line ending check ---'
foreach ($f in ($psFiles + $jsonFiles)) {
    $raw = Get-Content -Path $f.FullName -Raw
    if (-not $raw) { continue }
    $nonAscii = [regex]::Matches($raw, '[^\x00-\x7F]')
    if ($nonAscii.Count -gt 0) {
        Write-LintError "$($f.Name): $($nonAscii.Count) non-ASCII byte(s) found (first at index $($nonAscii[0].Index): '$($nonAscii[0].Value)')"
    }
    if ($raw -match "`r`n") {
        Write-LintError "$($f.Name): contains CRLF line endings - this repo is LF-only"
    }
}
if (-not $hadFailure) { Write-LintOk "$($psFiles.Count + $jsonFiles.Count) file(s) are pure ASCII with LF-only line endings" }

Write-Host '--- JSON validity and schema checks ---'
foreach ($f in $jsonFiles) {
    try {
        $null = Get-Content -Path $f.FullName -Raw | ConvertFrom-Json -ErrorAction Stop
        Write-LintOk "$($f.Name) parses as valid JSON"
    } catch {
        Write-LintError "$($f.Name) failed to parse: $($_.Exception.Message)"
    }
}

$appsCatalogPath = Join-Path $debloatDir 'apps-catalog.json'
if (Test-Path $appsCatalogPath) {
    $catalog = Get-Content -Path $appsCatalogPath -Raw | ConvertFrom-Json
    $dupeIds = $catalog.apps.wingetId | Where-Object { $_ } | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupeIds) {
        Write-LintError "apps-catalog.json has duplicate wingetId value(s): $($dupeIds.Name -join ', ')"
    } else {
        Write-LintOk 'apps-catalog.json has no duplicate wingetId values'
    }
    # "Manual Install Only" is the one category allowed to have neither - these are apps
    # with no public silent/direct installer at all (tenant login, license key, or a
    # vendor email required), where a verified product/download page url is the best
    # this tool can offer. Every other category still needs a real wingetId or downloadUrl.
    $missingIdentifier = $catalog.apps | Where-Object { -not $_.wingetId -and -not $_.downloadUrl -and $_.category -ne 'Manual Install Only' }
    if ($missingIdentifier) {
        Write-LintError "apps-catalog.json has entr(y/ies) with neither wingetId nor downloadUrl: $($missingIdentifier.name -join ', ')"
    } else {
        Write-LintOk 'every apps-catalog.json entry has a wingetId or a downloadUrl (or is Manual Install Only with a url)'
    }
    $manualOnlyMissingUrl = $catalog.apps | Where-Object { $_.category -eq 'Manual Install Only' -and -not $_.url }
    if ($manualOnlyMissingUrl) {
        Write-LintError "apps-catalog.json has Manual Install Only entr(y/ies) with no url: $($manualOnlyMissingUrl.name -join ', ')"
    } else {
        Write-LintOk 'every Manual Install Only entry has a url'
    }
}

$tweaksPath = Join-Path $debloatDir 'tweaks.json'
if (Test-Path $tweaksPath) {
    $tweaksData = Get-Content -Path $tweaksPath -Raw | ConvertFrom-Json
    $dupeKeys = $tweaksData.tweaks.key | Group-Object | Where-Object { $_.Count -gt 1 }
    if ($dupeKeys) {
        Write-LintError "tweaks.json has duplicate key value(s): $($dupeKeys.Name -join ', ')"
    } else {
        Write-LintOk 'tweaks.json has no duplicate key values'
    }
}

Write-Host '--- Wildcard (-like) pattern validity check ---'
$bloatPatternsPath = Join-Path $debloatDir 'bloat-patterns.json'
if (Test-Path $bloatPatternsPath) {
    $bloatPatterns = Get-Content -Path $bloatPatternsPath -Raw | ConvertFrom-Json
    $patternCount = 0
    foreach ($oemName in $bloatPatterns.PSObject.Properties.Name) {
        $oem = $bloatPatterns.$oemName
        foreach ($propName in @('appxPatterns', 'win32Patterns', 'scheduledTaskFolders', 'scheduledTaskKeepPatterns', 'servicePatterns')) {
            foreach ($pattern in ($oem.$propName)) {
                $patternCount++
                try {
                    $null = [System.Management.Automation.WildcardPattern]::new($pattern)
                } catch {
                    Write-LintError "bloat-patterns.json: '$oemName.$propName' pattern '$pattern' is not a valid wildcard: $($_.Exception.Message)"
                }
            }
        }
    }
    if (-not $hadFailure) { Write-LintOk "$patternCount wildcard pattern(s) in bloat-patterns.json are all valid" }

    # "productHints" is per-product knowledge for the removal engine: which services and processes keep a product busy, and the
    # silent switches to use when the vendor's own uninstall string would open a wizard. A typo in a property name would silently
    # switch a hint off, so every property is checked.
    $hintProblems = 0
    $hintCount = 0
    foreach ($oemName in $bloatPatterns.PSObject.Properties.Name) {
        $hints = $bloatPatterns.$oemName.productHints
        if ($null -eq $hints) { continue }
        foreach ($hint in @($hints)) {
            $hintCount++
            $label = "bloat-patterns.json: '$oemName.productHints' entry #$hintCount"
            $unknown = @($hint.PSObject.Properties.Name | Where-Object { $_ -notin @('match', 'services', 'processes', 'silentArgs', 'timeoutSec', 'respectDependencies') })
            if ($unknown.Count -gt 0) { Write-LintError "$label has unknown propert(y/ies): $($unknown -join ', ')"; $hintProblems++ }
            if (-not ($hint.match -is [string]) -or -not $hint.match.Trim()) { Write-LintError "$label has no 'match' text"; $hintProblems++ }
            foreach ($listName in @('match', 'services', 'processes')) {
                foreach ($item in @($hint.$listName)) {
                    if ($null -eq $item) { continue }
                    if (-not ($item -is [string]) -or -not $item.Trim()) { Write-LintError "$label has an empty or non-text item in '$listName'"; $hintProblems++; continue }
                    try { $null = [System.Management.Automation.WildcardPattern]::new($item) } catch { Write-LintError "$label '$listName' item '$item' is not a valid wildcard: $($_.Exception.Message)"; $hintProblems++ }
                    # A pattern is executed against every service / process / program on the PC: one that is mostly wildcard ('*', '?*')
                    # would stop or disable things that have nothing to do with the product.
                    if ($item -match '[\*\?\[]' -and ($item -replace '[\*\?\[\]]', '').Length -lt 6) { Write-LintError "$label '$listName' item '$item' is too broad: a wildcard pattern needs at least 6 literal characters"; $hintProblems++ }
                }
            }
            if ($null -ne $hint.silentArgs -and (-not ($hint.silentArgs -is [string]) -or -not $hint.silentArgs.Trim())) { Write-LintError "$label has an empty 'silentArgs'"; $hintProblems++ }
            if ($null -ne $hint.timeoutSec -and (-not ($hint.timeoutSec -is [int] -or $hint.timeoutSec -is [long]) -or $hint.timeoutSec -lt 30 -or $hint.timeoutSec -gt 3600)) { Write-LintError "$label 'timeoutSec' must be a whole number from 30 to 3600"; $hintProblems++ }
            if ($null -ne $hint.respectDependencies -and -not ($hint.respectDependencies -is [bool])) { Write-LintError "$label 'respectDependencies' must be true or false"; $hintProblems++ }
            if ($hint.match -and -not $hint.services -and -not $hint.processes -and -not $hint.silentArgs -and -not $hint.timeoutSec -and $hint.respectDependencies -ne $true) { Write-LintError "$label says nothing: no services, processes, silentArgs, timeoutSec or respectDependencies"; $hintProblems++ }
        }
    }
    if ($hintProblems -eq 0) { Write-LintOk "$hintCount productHints entr(y/ies) in bloat-patterns.json are well-formed" }
}

Write-Host '--- XAML here-string parse check (Gr3ysUtilities.ps1) ---'
$guiPath = Join-Path $debloatDir 'Gr3ysUtilities.ps1'
if (Test-Path $guiPath) {
    $lines = Get-Content -Path $guiPath
    $startIdx = -1
    $endIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq "[xml]`$xamlDoc = @'") { $startIdx = $i; continue }
        if ($startIdx -ge 0 -and $lines[$i] -eq "'@") { $endIdx = $i; break }
    }
    if ($startIdx -lt 0 -or $endIdx -le $startIdx) {
        Write-LintError 'Could not locate the [xml]$xamlDoc = @''...''@ here-string block in Gr3ysUtilities.ps1 (script structure may have changed - update this check)'
    } else {
        $xamlText = ($lines[($startIdx + 1)..($endIdx - 1)]) -join "`n"
        try {
            $null = [xml]$xamlText
            Write-LintOk "Gr3ysUtilities.ps1's embedded XAML is well-formed XML ($($endIdx - $startIdx - 1) lines)"
        } catch {
            Write-LintError "Gr3ysUtilities.ps1's embedded XAML failed to parse: $($_.Exception.Message)"
        }
    }

    # Each dialog (Compare chooser, pairing, access-code prompt, Manage Access Codes) has its
    # own $dialogXaml here-string. Parse every one, so a broken dialog fails here instead of
    # only surfacing when someone clicks its button.
    $guiTokens = $null
    $guiParseErrors = $null
    $guiAst = [System.Management.Automation.Language.Parser]::ParseFile($guiPath, [ref]$guiTokens, [ref]$guiParseErrors)
    $dialogAssigns = @($guiAst.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$dialogXaml'
    }, $true))
    $badDialogs = 0
    foreach ($a in $dialogAssigns) {
        $line = $a.Extent.StartLineNumber
        $value = $null
        if ($a.Right.Expression -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $value = $a.Right.Expression.Value
        }
        if (-not $value) {
            Write-LintError "Gr3ysUtilities.ps1 line ${line}: `$dialogXaml is not a plain here-string"
            $badDialogs++
            continue
        }
        try {
            $null = [xml]$value
        } catch {
            # The [xml] cast wraps the real XmlException; its message names the bad tag and the
            # line/position inside the XAML, where the outer message just echoes the whole string.
            $xmlErr = $_.Exception
            while ($xmlErr.InnerException) { $xmlErr = $xmlErr.InnerException }
            Write-LintError "Gr3ysUtilities.ps1 line ${line} (dialog XAML): $($xmlErr.Message)"
            $badDialogs++
        }
    }
    if ($dialogAssigns.Count -eq 0) {
        Write-LintError 'Could not find any $dialogXaml here-strings in Gr3ysUtilities.ps1 (script structure may have changed - update this check)'
    } elseif ($badDialogs -eq 0) {
        Write-LintOk "$($dialogAssigns.Count) dialog XAML here-string(s) in Gr3ysUtilities.ps1 are well-formed XML"
    }
}

Write-Host '--- PowerShell syntax parse (PSParser) ---'
foreach ($f in $psFiles) {
    $tokens = $null
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        foreach ($e in $parseErrors) {
            Write-LintError "$($f.Name): $($e.Message) at line $($e.Extent.StartLineNumber)"
        }
    }
}
if (-not $hadFailure) { Write-LintOk "$($psFiles.Count) PowerShell file(s) parse with 0 syntax errors" }

# PowerShell lets a later definition silently replace an earlier one, so a function pasted in twice (or twice with small
# differences) runs whichever copy comes last and nothing complains. Only top-level definitions are compared: the same name
# inside two different branches or scriptblocks is legitimate.
Write-Host '--- Duplicate top-level function definitions ---'
$dupeFunctionCount = 0
foreach ($f in $psFiles) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
    $topLevel = @($ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.FunctionDefinitionAst] })
    foreach ($group in ($topLevel | Group-Object { $_.Name.ToLowerInvariant() } | Where-Object { $_.Count -gt 1 })) {
        $dupeFunctionCount++
        $where = ($group.Group | ForEach-Object { $_.Extent.StartLineNumber }) -join ', '
        Write-LintError "$($f.Name): function '$($group.Group[0].Name)' is defined $($group.Count) times (lines $where) - only the last copy would run"
    }
}
if ($dupeFunctionCount -eq 0) { Write-LintOk 'no function is defined twice at the top level of any PowerShell file' }

Write-Host '--- PSScriptAnalyzer: PSUseCompatibleSyntax (hard fail) + PSUseCompatibleCommands (reported) ---'
if (Get-Module -ListAvailable -Name PSScriptAnalyzer) {
    Import-Module PSScriptAnalyzer -ErrorAction Stop
    $settings = @{
        Rules = @{
            PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.4') }
            PSUseCompatibleCommands = @{
                Enable         = $true
                TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
            }
        }
    }
    foreach ($f in $psFiles) {
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
        $localFunctionNames = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true) | ForEach-Object { $_.Name })

        $results = Invoke-ScriptAnalyzer -Path $f.FullName -Settings $settings

        $syntaxFindings = @($results | Where-Object { $_.RuleName -eq 'PSUseCompatibleSyntax' })
        foreach ($finding in $syntaxFindings) {
            Write-LintError "$($f.Name):$($finding.Line): [$($finding.RuleName)] $($finding.Message)"
        }

        $commandFindings = @($results | Where-Object { $_.RuleName -eq 'PSUseCompatibleCommands' })
        $reportable = @($commandFindings | Where-Object {
            $msg = $_.Message
            -not ($localFunctionNames | Where-Object { $msg -match [regex]::Escape("'$_'") })
        })
        if ($reportable.Count -gt 0) {
            Write-Host "REPORT ($($f.Name)): $($reportable.Count) PSUseCompatibleCommands finding(s) not explained by a locally-defined function - not build-breaking, but worth a human read:" -ForegroundColor Yellow
            foreach ($finding in $reportable) {
                Write-Host "  Line $($finding.Line): $($finding.Message)" -ForegroundColor Yellow
            }
        }
    }
    if (-not ($psFiles | Where-Object { $_ })) { Write-LintOk 'No PowerShell files to analyze' }
} else {
    Write-Host 'PSScriptAnalyzer module not available - skipping (install with: Install-Module PSScriptAnalyzer)' -ForegroundColor Yellow
}

Write-Host ''
if ($hadFailure) {
    Write-Host 'Lint FAILED - see FAIL lines above.' -ForegroundColor Red
    exit 1
} else {
    Write-Host 'Lint PASSED.' -ForegroundColor Green
    exit 0
}

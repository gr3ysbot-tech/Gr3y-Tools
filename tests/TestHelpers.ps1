<#
.SYNOPSIS
    Shared Pester test helpers for Gr3y-Tools.

.DESCRIPTION
    Deploy-DellOfficeSetup.ps1 and Gr3ysUtilities.ps1 are monolithic scripts with
    top-level executing code (they start a real transcript, query real hardware,
    build/load a real WPF window, and Deploy-DellOfficeSetup.ps1 is #Requires
    -RunAsAdministrator) - dot-sourcing either file directly would run all of that,
    which is unsafe and wrong in a CI test run.

    Get-FunctionSource pulls just one named function's source text out of a script
    file via the PowerShell AST, without parsing or executing anything else in that
    file. A test's BeforeAll block dot-sources the returned text into its own scope,
    giving it the real function under test with none of the surrounding script's
    side effects.
#>

function Get-FunctionSource {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [string]$FunctionName
    )
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        throw "Parse errors in $ScriptPath - $($parseErrors -join '; ')"
    }
    $funcAst = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $FunctionName
    }, $true)
    if (-not $funcAst) {
        throw "Function '$FunctionName' not found in $ScriptPath"
    }
    return $funcAst.Extent.Text
}

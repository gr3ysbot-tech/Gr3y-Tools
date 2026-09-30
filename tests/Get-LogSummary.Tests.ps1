BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $scriptPath = Join-Path $PSScriptRoot '..\debloat\Gr3ysUtilities.ps1'
    . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $scriptPath -FunctionName 'Get-LogSummary')))
}

Describe 'Get-LogSummary' {
    It 'returns the Idle default for an empty LogPath' {
        $result = Get-LogSummary -LogPath ''
        $result.phase | Should -Be 'Idle'
        $result.completed | Should -Be $false
        $result.hasWarnings | Should -Be $false
        $result.warningCount | Should -Be 0
    }

    It 'returns the Idle default when the log file does not exist' {
        $result = Get-LogSummary -LogPath (Join-Path $TestDrive 'does-not-exist.log')
        $result.phase | Should -Be 'Idle'
        $result.completed | Should -Be $false
    }

    It 'returns Starting... for an existing but empty log file' {
        $logPath = Join-Path $TestDrive 'empty.log'
        Set-Content -Path $logPath -Value '' -NoNewline
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'Starting...'
        $result.completed | Should -Be $false
    }

    It 'picks up a single phase header' {
        $logPath = Join-Path $TestDrive 'onephase.log'
        Set-Content -Path $logPath -Value "some output`r`n--- Phase 1: Removing bloatware ---`r`nmore output"
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'Phase 1: Removing bloatware'
    }

    It 'picks up the LAST phase header when the log has several' {
        $logPath = Join-Path $TestDrive 'multiphase.log'
        Set-Content -Path $logPath -Value @"
--- Phase 1: Removing bloatware ---
line
--- Phase 2: Installing Office ---
line
--- Phase 3: Applying tweaks ---
line
"@
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'Phase 3: Applying tweaks'
    }

    It 'correctly captures a phase header whose own text contains a hyphen (e.g. en-us)' {
        $logPath = Join-Path $TestDrive 'hyphenphase.log'
        Set-Content -Path $logPath -Value '--- Phase 3: Installing Microsoft 365 Apps for business (en-us, MonthlyEnterprise channel) ---'
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'Phase 3: Installing Microsoft 365 Apps for business (en-us, MonthlyEnterprise channel)'
    }

    It 'marks completed with no warnings for a clean "Run complete." line' {
        $logPath = Join-Path $TestDrive 'cleanrun.log'
        Set-Content -Path $logPath -Value "--- Phase 1: Removing bloatware ---`r`nRun complete."
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'All phases complete'
        $result.completed | Should -Be $true
        $result.hasWarnings | Should -Be $false
        $result.warningCount | Should -Be 0
    }

    It 'marks completed with warnings and the correct count for "Run complete with N warning(s)"' {
        $logPath = Join-Path $TestDrive 'warnrun.log'
        Set-Content -Path $logPath -Value "--- Phase 1: Removing bloatware ---`r`nRun complete with 3 warnings."
        $result = Get-LogSummary -LogPath $logPath
        $result.phase | Should -Be 'All phases complete'
        $result.completed | Should -Be $true
        $result.hasWarnings | Should -Be $true
        $result.warningCount | Should -Be 3
    }
}

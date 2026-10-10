# End-to-end tests: the whole of Phase 1 (Remove-OemBloatware) with the REAL engine, the REAL shipped bloat-patterns.json and the
# registry shapes measured on the owner's Dell Vostro (MSI entries written as "MsiExec.exe /I{GUID}", Burn bundles with a two-space
# UninstallString + a QuietUninstallString + BundleCachePath, an InstallShield wrapper, an unquoted NSIS path with spaces). Only the outside
# world is scripted: the Uninstall list, the installers' behaviour and the clock. Ported from a research replay script.
# ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $deployScript = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($fn in 'Get-UninstallEntries', 'Start-ProcessLowPriority', 'ConvertFrom-UninstallString', 'Test-PathQuiet', 'Resolve-UninstallExecutable', 'Test-OemProgramFolderPresent', 'Get-OemProgramEvidence', 'Stop-ServiceBounded', 'Test-OemProcessMayBeStopped', 'ConvertTo-MsiUninstallArguments', 'Get-PendingRestartReasons', 'Test-OemResultRetryable', 'Remove-OemBloatware', 'Get-OemProductHint', 'Get-UninstallExitClass', 'ConvertTo-BurnUninstallArguments', 'Get-OemUninstallLayer', 'Group-OemProductEntries',
        'Get-OemRemovalSummaryLines', 'Get-OemAttemptLines', 'Format-OemFailureDetail', 'Format-OemLayerCommand', 'ConvertTo-OemFolderPath', 'Get-OemUninstallerFolder', 'Get-RunWarningCount', 'Get-OemHangGuess', 'Get-OemAppxIdentity', 'Test-OemFolderHasContent', 'Get-OemIconFilePath', 'Get-OemProgramFootprints', 'Format-OemNothingToCheck', 'Test-OemProductPresent', 'Wait-OemProductGone', 'Stop-OemProductActivity', 'Invoke-OemUninstallLayer',
        'Remove-StaleUninstallEntry', 'Remove-OemUninstallLogs', 'Remove-OemWin32Product', 'Test-WindowsInstallerBusy', 'Wait-WindowsInstallerIdle',
        'Get-MsiLogFailureSummary', 'Get-OemMsiEventSummary', 'Remove-OemAppxPackages', 'Invoke-ThrottledSteps', 'Test-IsWorkSchoolTeams') {
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName $fn)))
    }
    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $global:OemTestLog.Add("[$Level] $Message")
    }
    function New-Fake {
        param([string]$Rel)
        $p = Join-Path $TestDrive $Rel
        $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
        Set-Content -LiteralPath $p -Value 'x'
        $p
    }
    function New-Entry {
        param([string]$Name, [string]$Key, [string]$Uninstall, [string]$Quiet = '', [string]$Ver = '1.0', [int]$Msi = 0, [string]$Bundle = '')
        $e = [PSCustomObject]@{
            DisplayName = $Name; DisplayVersion = $Ver; PSChildName = $Key; UninstallString = $Uninstall; QuietUninstallString = $Quiet
            WindowsInstaller = $Msi; InstallLocation = ''
            PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$Key"
        }
        if ($Bundle) {
            $e | Add-Member -NotePropertyName BundleCachePath -NotePropertyValue $Bundle
            $e | Add-Member -NotePropertyName BundleProviderKey -NotePropertyValue $Key
        }
        $e
    }
    function Remove-Names {
        param([string[]]$Names)
        $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $Names -notcontains $_.DisplayName })
    }
    # An msiexec command line removes the product whose GUID it names (all the entries that carry that product name, like a real removal).
    function Remove-ByGuidInCommand {
        param([string]$Command)
        $m = [regex]::Match($Command, '/x (\{[0-9A-Fa-f-]{36}\})')
        if (-not $m.Success) { return }
        $hit = @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq $m.Groups[1].Value } | Select-Object -First 1)
        if ($hit.Count -gt 0) { Remove-Names $hit[0].DisplayName }
    }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestInstalled, OemTestCalls, OemScenario, OemPendingReasons, OemDdTries -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Phase 1 replayed on the owner''s Dell Vostro products (real engine and shipped hints; scripted installers)' {
    BeforeAll {
        $script:patterns = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\debloat\bloat-patterns.json') -Raw | ConvertFrom-Json
    }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemPendingReasons = @()
        $global:OemDdTries = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        $workDir = $TestDrive
        $Win32BloatPatterns = @($script:patterns.generic.win32Patterns) + @($script:patterns.dell.win32Patterns)
        $OemProductHints = @($script:patterns.dell.productHints)

        $remediationExe = New-Fake 'ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\DellSupportAssistRemediationServiceInstaller.exe'
        $pluginExe = New-Fake 'ProgramData\Package Cache\{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}\DellUpdateSupportAssistPlugin.exe'
        $optimizerExe = New-Fake 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\DellOptimizer_MyDell.exe'
        $pairExe = New-Fake 'Program Files\Dell\Dell Pair\Uninstall.exe'
        $global:OemTestInstalled = @(
            (New-Entry 'Dell SupportAssist Remediation' '{2FF8590E-7853-4A49-8AAF-594975FD2B6C}' 'MsiExec.exe /I{2FF8590E-7853-4A49-8AAF-594975FD2B6C}' -Ver '5.5.16.3' -Msi 1)
            (New-Entry 'Dell SupportAssist Remediation' '{400b816d-1b36-426f-9595-5742bfd07ec4}' ('"' + $remediationExe + '"  /uninstall') ('"' + $remediationExe + '" /uninstall /quiet') -Ver '5.5.16.3' -Bundle $remediationExe)
            (New-Entry 'Dell SupportAssist' '{65043213-393F-49BF-B658-5B06C5F713FF}' 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Ver '4.4' -Msi 1)
            (New-Entry 'Dell SupportAssist OS Recovery Plugin for Dell Update' '{BE92A615-4964-403F-B965-827881C7CE4D}' 'MsiExec.exe /I{BE92A615-4964-403F-B965-827881C7CE4D}' -Ver '5.5.16.3' -Msi 1)
            (New-Entry 'Dell SupportAssist OS Recovery Plugin for Dell Update' '{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}' ('"' + $pluginExe + '"  /uninstall') ('"' + $pluginExe + '" /uninstall /quiet') -Ver '5.5.16.3' -Bundle $pluginExe)
            (New-Entry 'Dell Optimizer' '{1344E072-D68B-48FF-BD2A-C1CCCC511A50}' 'MsiExec.exe /X{1344E072-D68B-48FF-BD2A-C1CCCC511A50}' -Ver '4.1' -Msi 1)
            (New-Entry 'Dell Optimizer' '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' ('"' + $optimizerExe + '" -remove -runfromtemp') -Ver '4.1')
            (New-Entry 'Dell Digital Delivery Services' '{87310396-FD49-4108-BBBB-28E1C3EA85E9}' 'MsiExec.exe /X{87310396-FD49-4108-BBBB-28E1C3EA85E9}' -Ver '5.6.3' -Msi 1)
            (New-Entry 'Dell Pair' 'DellPair' $pairExe -Ver '2.1')
        )
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-Service { }
        Mock Get-Process { }
        Mock Get-WinEvent { throw 'No events were found that match the specified selection criteria.' }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 4; Failed = 0; FailedNames = @() } }
        Mock Get-PendingRestartReasons { $global:OemPendingReasons }
        Mock Remove-StaleUninstallEntry { $true }
        Mock Start-ProcessLowPriority {
            $cmd = "$FilePath $ArgumentList"
            $global:OemTestCalls.Add($cmd)
            $r = [PSCustomObject]@{ Started = $true; ExitCode = 0; TimedOut = $false; Seconds = 4; Error = $null }
            & $global:OemScenario $cmd $r
        }
    }

    It 'removes all six programs when the bundles refuse and a plain MSI removal is a silent no-op (the dependency trap)' {
        $global:OemScenario = {
            param($cmd, $r)
            if ($cmd -like '*Installer.exe*' -or $cmd -like '*Plugin.exe*') { $r.ExitCode = -2147023293 }
            elseif ($cmd -like 'msiexec.exe*') { if ($cmd -like '*IGNOREDEPENDENCIES=ALL*') { Remove-ByGuidInCommand $cmd } }
            elseif ($cmd -like '*Dell Pair*Uninstall.exe*') { Remove-Names 'Dell Pair' }
            $r
        }
        Remove-OemBloatware
        @($global:OemTestInstalled).Count | Should -Be 0
        $log = $global:OemTestLog -join "`n"
        $log | Should -BeLike '*programs: 6 removed, 0 NOT removed*'
        $log | Should -BeLike "*Bundle uninstaller for 'Dell SupportAssist Remediation': exit 1603*"
        @($global:OemTestCalls | Where-Object { $_ -like 'msiexec.exe*' -and $_ -notlike '*IGNOREDEPENDENCIES=ALL /qn /norestart*' }).Count | Should -Be 0
        @($global:OemTestCalls | Where-Object { $_ -like '*Installer.exe /uninstall /quiet /norestart*' }).Count | Should -BeGreaterThan 0
    }

    It 'removes everything when the bundles and the Optimizer suite wrapper work and take their MSIs with them, running those first and each MSI only if needed' {
        $global:OemScenario = {
            param($cmd, $r)
            if ($cmd -like '*DellSupportAssistRemediationServiceInstaller*') { Remove-Names 'Dell SupportAssist Remediation' }
            elseif ($cmd -like '*DellUpdateSupportAssistPlugin*') { Remove-Names 'Dell SupportAssist OS Recovery Plugin for Dell Update' }
            elseif ($cmd -like '*DellOptimizer_MyDell*') { Remove-Names 'Dell Optimizer' }
            elseif ($cmd -like 'msiexec.exe*') { Remove-ByGuidInCommand $cmd }
            elseif ($cmd -like '*Dell Pair*Uninstall.exe*') { Remove-Names 'Dell Pair' }
            $r
        }
        Remove-OemBloatware
        @($global:OemTestInstalled).Count | Should -Be 0
        ($global:OemTestLog -join "`n") | Should -BeLike '*programs: 6 removed, 0 NOT removed*'
        # the two bundles took their MSIs with them: no msiexec for Remediation (2FF8590E) or the Plugin (BE92A615)
        @($global:OemTestCalls | Where-Object { $_ -like '*2FF8590E*' -or $_ -like '*BE92A615*' }).Count | Should -Be 0
        $global:OemTestCalls.Count | Should -Be 6
        # a clean run must not raise warnings: the real Write-Log counts every WARN/ERROR line into "Run complete with N warning(s)"
        @($global:OemTestLog | Where-Object { $_ -like '`[WARN`]*' -or $_ -like '`[ERROR`]*' }).Count | Should -Be 0
    }

    It 'reports one program as NOT removed, with the reason, when everything else worked (hang, busy installer, failing MSI)' {
        $global:OemScenario = {
            param($cmd, $r)
            if ($cmd -like '*DellSupportAssistRemediationServiceInstaller*') { Remove-Names 'Dell SupportAssist Remediation' }
            elseif ($cmd -like '*DellUpdateSupportAssistPlugin*') { $r.ExitCode = $null; $r.TimedOut = $true; $r.Seconds = 900 }
            elseif ($cmd -like '*BE92A615*') { Remove-Names 'Dell SupportAssist OS Recovery Plugin for Dell Update' }
            elseif ($cmd -like '*65043213*') { $r.ExitCode = 1603 }
            elseif ($cmd -like '*1344E072*') { Remove-Names 'Dell Optimizer' }
            elseif ($cmd -like '*87310396*') {
                $global:OemDdTries++
                if ($global:OemDdTries -le 2) { $r.ExitCode = 1618 } else { Remove-Names 'Dell Digital Delivery Services' }
            }
            elseif ($cmd -like '*Dell Pair*Uninstall.exe*') { Remove-Names 'Dell Pair' }
            $r
        }
        Remove-OemBloatware
        $log = $global:OemTestLog -join "`n"
        $log | Should -BeLike '*programs: 5 removed, 1 NOT removed*'
        $log | Should -BeLike "*[[]WARN] *NOT REMOVED: 'Dell SupportAssist' 4.4 - Msi: exit 1603 (fatal error during the uninstall)*"
        @($global:OemTestInstalled | ForEach-Object { $_.DisplayName } | Select-Object -Unique) | Should -BeExactly @('Dell SupportAssist')
        @($global:OemTestCalls | Where-Object { $_ -like '*DellUpdateSupportAssistPlugin*' }).Count | Should -Be 1 -Because 'a bundle that hung is not started a second time in the same pass'
        @($global:OemTestCalls | Where-Object { $_ -like '*87310396*' }).Count | Should -Be 3 -Because 'busy twice, then it worked'
        @($global:OemTestCalls | Where-Object { $_ -like '*65043213*' }).Count | Should -Be 3 -Because 'two passes, plus the one second look after other programs were removed'
        Should -Invoke Start-Sleep -Times 2 -Exactly -ParameterFilter { $Seconds -eq 20 }
    }

    It 'with a restart pending: warns first, runs each bundle once (and takes no second look, which would hit the same wall), says to restart, and still removes what a restart is not needed for (Dell Pair)' {
        $global:OemPendingReasons = @('an installer ({400b816d-1b36-426f-9595-5742bfd07ec4}) is waiting for a restart')
        $global:OemScenario = {
            param($cmd, $r)
            if ($cmd -like '*Installer.exe*' -or $cmd -like '*Plugin.exe*') { $r.ExitCode = -2147024546 }
            elseif ($cmd -like 'msiexec.exe*') { $r.ExitCode = 1603 }
            elseif ($cmd -like '*Dell Pair*Uninstall.exe*') { Remove-Names 'Dell Pair' }
            $r
        }
        Remove-OemBloatware
        $log = $global:OemTestLog -join "`n"
        $log | Should -BeLike '*[[]WARN] A restart is pending on this PC*'
        $log | Should -BeLike '*programs: 1 removed, 5 NOT removed*'
        $log | Should -BeLike '*exit 350 (0x8007015E) (no action was taken: a restart from an earlier installation is pending)*'
        $log | Should -BeLike '*restart the PC and run the clean-up again*'
        # each bundle once: the second pass skips it, and no second look follows although Dell Pair WAS removed (a restart-first answer stops it)
        @($global:OemTestCalls | Where-Object { $_ -like '*DellSupportAssistRemediationServiceInstaller*' }).Count | Should -Be 1
        $log | Should -Not -BeLike '*taking a second look at them*'
    }

    It 'in a dry run starts nothing and prints no result report' {
        $DryRun = $true
        $global:OemScenario = { param($cmd, $r) $r }
        Remove-OemBloatware
        $global:OemTestCalls.Count | Should -Be 0
        @($global:OemTestInstalled).Count | Should -Be 9
        ($global:OemTestLog -join "`n") | Should -Not -BeLike '*Phase 1 result*'
    }
}

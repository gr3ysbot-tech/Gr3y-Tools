# More Pester tests for the Phase 1 removal engine, from the third review round: an independent set of 40 one-line bugs ("mutants") of the
# engine was run against the first OEM test files and 24 of them survived. Each test here is named after the mutant ([R..]) it kills, or
# after the finding ([F1], [L2], [L3], [L5]) it pins, and fails on it. Same scaffolding as the other OEM files: the real functions are cut
# out of the script with the PowerShell parser, the registry / installers / services / processes / clock are stood in for. ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $deployScript = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($fn in 'Get-UninstallEntries', 'Start-ProcessLowPriority', 'ConvertFrom-UninstallString', 'Test-PathQuiet', 'ConvertTo-OemFolderPath', 'Get-OemUninstallerFolder', 'Resolve-UninstallExecutable', 'Test-OemProgramFolderPresent', 'Get-OemProgramEvidence', 'Stop-ServiceBounded', 'Test-OemProcessMayBeStopped', 'ConvertTo-MsiUninstallArguments', 'Get-PendingRestartReasons', 'Test-OemResultRetryable', 'Remove-OemBloatware', 'Get-OemProductHint', 'Get-UninstallExitClass', 'ConvertTo-BurnUninstallArguments', 'Get-OemUninstallLayer', 'Group-OemProductEntries',
        'Get-OemRemovalSummaryLines', 'Get-OemAttemptLines', 'Format-OemFailureDetail', 'Format-OemLayerCommand', 'Get-RunWarningCount', 'Get-OemHangGuess', 'Get-OemAppxIdentity', 'Test-OemFolderHasContent', 'Get-OemIconFilePath', 'Get-OemProgramFootprints', 'Format-OemNothingToCheck', 'Test-OemProductPresent', 'Wait-OemProductGone', 'Stop-OemProductActivity', 'Invoke-OemUninstallLayer',
        'Remove-StaleUninstallEntry', 'Remove-OemUninstallLogs', 'Remove-OemWin32Product', 'Test-WindowsInstallerBusy', 'Wait-WindowsInstallerIdle',
        'Get-MsiLogFailureSummary', 'Get-OemMsiEventSummary', 'Remove-OemAppxPackages', 'Invoke-ThrottledSteps', 'Test-IsWorkSchoolTeams', 'Disable-OemScheduledTasksAndServices', 'Invoke-Step') {
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName $fn)))
    }

    function Write-Log {
        param([string]$Message, [string]$Level = 'INFO')
        $global:OemTestLog.Add("[$Level] $Message")
        if ($Level -eq 'WARN' -or $Level -eq 'ERROR') { $global:OemTestWarnCount++ }
    }
    function New-TestEntry {
        param([string]$Name, [string]$Key, [string]$Uninstall, [string]$Quiet = '', [string]$Version = '1.0', [int]$WindowsInstaller = 0, [string]$Location = '')
        [PSCustomObject]@{
            DisplayName = $Name; DisplayVersion = $Version; PSChildName = $Key; UninstallString = $Uninstall; QuietUninstallString = $Quiet
            WindowsInstaller = $WindowsInstaller; InstallLocation = $Location
            PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$Key"
        }
    }
    function New-TestFile {
        param([string]$Rel)
        $p = Join-Path $TestDrive $Rel
        $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
        Set-Content -LiteralPath $p -Value 'x'
        $p
    }
    function New-TestRun {
        param($ExitCode = 0, [bool]$TimedOut = $false, [bool]$Started = $true, [string]$ErrorText = $null)
        [PSCustomObject]@{ Started = $Started; ExitCode = $ExitCode; TimedOut = $TimedOut; Seconds = 2; Error = $ErrorText }
    }
    function New-TestProduct {
        param([object[]]$Entries)
        [PSCustomObject]@{ Name = $Entries[0].DisplayName; Version = $Entries[0].DisplayVersion; Entries = $Entries }
    }
    function Add-TestRun { param($Run, [bool]$Removes = $false) $global:OemTestRuns.Enqueue([PSCustomObject]@{ Run = $Run; Removes = $Removes }) }
    # A run with a side effect on the stand-in registry: the entry with this key goes away, and/or these entries appear.
    function Add-TestRunEffect { param($Run, [string]$RemoveKey = '', [object[]]$Adds = @()) $global:OemTestRuns.Enqueue([PSCustomObject]@{ Run = $Run; Removes = $false; RemoveKey = $RemoveKey; Adds = $Adds }) }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestCalls, OemTestRuns, OemTestInstalled, OemTestWarnCount -Scope Global -ErrorAction SilentlyContinue
}

Describe 'R02 R03: Stop-OemProductActivity and the install-folder rule (dry run, network share)' {
    AfterEach { $env:windir = $script:savedWindir }
    BeforeEach {
        # (when the tests run as SYSTEM, $TestDrive is under C:\WINDOWS\Temp and the "never from the Windows folder" rule would protect the fake process)
        $script:savedWindir = $env:windir
        $env:windir = 'Z:\OemNoSuchWindowsFolder'
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $OemProductHints = @()
        Mock Get-Service {}
        Mock Set-Service { $global:OemTestCalls.Add("set-service $Name") }
        Mock Stop-ServiceBounded { $global:OemTestCalls.Add("stop-service $Name"); $true }
        Mock Stop-Process { $global:OemTestCalls.Add("stop-process $Id") }
    }

    It '[R02] only says which process it would end in the product folder, in a dry run, and ends nothing' {
        $DryRun = $true
        $folder = Split-Path (New-TestFile 'Program Files\Dell\Dell Pair\a.dll') -Parent
        Mock Get-Process { [PSCustomObject]@{ Id = 4343; ProcessName = 'helper'; Path = (Join-Path $folder 'helper.exe') } }
        @(Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation $folder).Count | Should -Be 0
        $global:OemTestCalls.Count | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike "*DRYRUN: Would stop 'helper' (PID 4343), running from the install folder of 'Dell Pair'*"
    }

    It '[R02 control] a real run does end it' {
        $folder = Split-Path (New-TestFile 'Program Files\Dell\Dell Pair\a.dll') -Parent
        Mock Get-Process { [PSCustomObject]@{ Id = 4343; ProcessName = 'helper'; Path = (Join-Path $folder 'helper.exe') } }
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation $folder
        @($global:OemTestCalls) | Should -Contain 'stop-process 4343'
    }

    It '[R03] never ends a process on the strength of a folder on a network share' {
        # (Test-PathQuiet is told the share exists, so that only the "never a network share" rule can keep the process alive)
        Mock Test-PathQuiet { $true }
        Mock Get-Process { [PSCustomObject]@{ Id = 4444; ProcessName = 'agent'; Path = '\\fileserver\share\Dell\SupportAssist\App\agent.exe' } }
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '\\fileserver\share\Dell\SupportAssist\App'
        $global:OemTestCalls.Count | Should -Be 0
    }
}

Describe 'R05: a bare program name is taken from the Windows folder only' {
    It '[R05] does not take a program from a folder whose name merely starts like the Windows folder' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'oem-sibling.exe'; Source = ($env:SystemRoot.TrimEnd('\') + '.old\System32\oem-sibling.exe') } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'oem-sibling.exe /S') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be 'oem-sibling.exe'
    }

    It '[R26] looking up a bare program name that is not on PATH writes nothing to the error stream' {
        $out = @(Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'oem-no-such-uninstaller-7f3a91.exe /S') -LogPath (Join-Path $TestDrive 'x.log') 2>&1)
        @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
    }
    It '[R06] resolves a bare .cmd / .bat / .com name from the Windows folder as well' -ForEach @(
        @{ Name = 'oem-tool.cmd' }
        @{ Name = 'oem-tool.bat' }
        @{ Name = 'oem-tool.com' }
    ) {
        Mock Get-Command { [PSCustomObject]@{ Name = $Name; Source = (Join-Path $env:SystemRoot ('System32\' + $Name)) } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall ('"' + $Name + '" /S')) -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be (Join-Path $env:SystemRoot ('System32\' + $Name))
    }
}

Describe 'R07 R21 R08: the warning count and the all-clear line' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        $workDir = $TestDrive
        $OemProductHints = @()
        $Win32BloatPatterns = @('Dell A*')
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity {}
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-Service {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
        Mock Remove-StaleUninstallEntry { $true }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $ArgumentList -notlike "*$($_.PSChildName)*" }) }
            $next.Run
        }
    }


    It '[R21] the all-clear line counts only the warnings of Phase 1 itself, not those of the phases before it' {
        $global:OemTestWarnCount = 5          # warnings the run had already raised before Phase 1 started
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 1 removed, 0 NOT removed*'
        $text | Should -BeLike '*The 1 warning line(s) above are failed first attempts*'
    }

    It '[R08] the all-clear line is also said when only Store apps were targeted' {
        $appx = [PSCustomObject]@{ Removed = 2; Failed = 0; FailedNames = @(); Unverified = 0 }
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $appx -ProductResults @() -WarningsRaised 1)
        @($lines | Where-Object { $_.Message -like '*Nothing that was targeted is left*' }).Count | Should -Be 1
    }
}

Describe 'R10 R09: the second look keeps the first look''s story (services) and announces only what it looks at' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        $workDir = $TestDrive
        $OemProductHints = @()
        $Win32BloatPatterns = @('Dell A*', 'Dell B*', 'Dell C*', 'Dell Optimizer*')
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-Service {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
        Mock Remove-StaleUninstallEntry {
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $ArgumentList -notlike "*$($_.PSChildName)*" }) }
            if ($next.RemoveKey) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -ne $next.RemoveKey }) }
            if ($next.Adds) { $global:OemTestInstalled = @($global:OemTestInstalled) + @($next.Adds) }
            $next.Run
        }
    }

    It '[R10] still names the service the FIRST look disabled when the program stays after the second look' {
        # (the real Stop-OemProductActivity reports a service only when it sets it to Disabled; in the second look it is Disabled already)
        $script:activityCalls = 0
        Mock Stop-OemProductActivity {
            if ($ProductName -eq 'Dell A One') {
                $script:activityCalls++
                if ($script:activityCalls -eq 1) { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic' } }
            }
        }
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a, $b)
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, pass 1
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, pass 2
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true            # B is removed: progress, which gives A its second look
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell A One''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike "*its service(s) 'SupportAssistAgent' (was Automatic) were set to Disabled before the uninstall and stay Disabled*"
    }

    It '[R22] says what is wrong with another entry of the program once, although both looks found it' {
        Mock Stop-OemProductActivity {}
        $a1 = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $a2 = New-TestEntry -Name 'Dell A One' -Key 'DellAOneExe' -Uninstall ('"' + (Join-Path $TestDrive 'gone\uninst.exe') + '" /S')
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a1, $a2, $b)
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, pass 1
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, pass 2
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true            # B is removed: progress, which gives A its second look
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell A One''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*another entry of this program: its uninstaller file is missing (*uninst.exe)*'
        ([regex]::Matches($line[0], 'another entry of this program')).Count | Should -Be 1
    }
    It '[R23 R24] the "shared with other software" note is still in the NOT REMOVED line after a second look' {
        Mock Stop-OemProductActivity {}
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Core Services'; respectDependencies = $true })
        $Win32BloatPatterns = @('Dell Core Services', 'Dell B*')
        $core = New-TestEntry -Name 'Dell Core Services' -Key '{CCCCCCCC-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{CCCCCCCC-1111-2222-3333-444444444444}'
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($core, $b)
        Add-TestRun (New-TestRun -ExitCode 1603)                        # Core Services, pass 1
        Add-TestRun (New-TestRun -ExitCode 1603)                        # Core Services, pass 2
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true            # B is removed: progress, which gives Core Services its second look
        Add-TestRun (New-TestRun -ExitCode 1603)                        # Core Services, second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell Core Services''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*(tried 3 times)*this program may be shared with other Dell software: its installer can refuse to remove it while other software depends on it*'
        @($global:OemTestCalls | Where-Object { $_ -like '*{CCCCCCCC-*' }).Count | Should -Be 3
        @($global:OemTestCalls | Where-Object { $_ -like '*{CCCCCCCC-*' -and $_ -like '*IGNOREDEPENDENCIES*' }).Count | Should -Be 0 -Because 'Dell Core Services is removed with its dependency check on'
    }

    It '[L2 R09] takes no second look at a program whose only runnable layer hit a wall, although another entry of it cannot be run' {
        # (Optimizer as on the laptop: an InstallShield wrapper that hangs and an MSI that works and takes its own entry along, plus an entry
        # nothing can be run for. The program is retryable and has an entry that did not hit a wall, yet there is nothing to start: it is
        # neither announced in the second sweep nor are its services and processes stopped a second time.)
        $Win32BloatPatterns = @('Dell Optimizer*', 'Dell B*')
        $script:activity = New-Object System.Collections.Generic.List[string]
        Mock Stop-OemProductActivity { $script:activity.Add($ProductName) }
        $wrapper = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe'
        $w = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove')
        $m = New-TestEntry -Name 'Dell Optimizer' -Key '{11111111-2222-3333-4444-555555555555}' -Uninstall 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
        $x = New-TestEntry -Name 'Dell Optimizer' -Key 'OptimizerNoCommand' -Uninstall ''
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($w, $m, $x, $b)
        Add-TestRun (New-TestRun -ExitCode $null -TimedOut $true)                                          # the wrapper hangs: a wall
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{11111111-2222-3333-4444-555555555555}'   # the MSI works, the wrapper's entry stays
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true                                               # B is removed: progress, which gives the others a second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        @($script:activity | Where-Object { $_ -eq 'Dell Optimizer' }).Count | Should -Be 1
        @($global:OemTestLog | Where-Object { $_ -like '*Uninstalling: Dell Optimizer*' }).Count | Should -Be 1
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell Optimizer''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*Wrapper: the uninstaller did not finish in time and was stopped*'
        $line[0] | Should -BeLike '*another entry of this program: it has no uninstall command registered*'
    }
}

Describe 'R12 R13: a dead entry cleared in a second look, after an uninstaller of the first look worked' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Stop-OemProductActivity {}
        Mock Get-Service {}
        Mock Remove-StaleUninstallEntry {
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
    }

    It '[R12 R13] is "Removed" (or "RemovedRestartNeeded") when an earlier look had a working uninstaller, "StaleEntryCleared" when it had none' {
        $e = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + (Join-Path $TestDrive 'gone\Uninstall.exe') + '" /S')
        $global:OemTestInstalled = @($e)
        (Remove-OemWin32Product -Product (New-TestProduct @($e)) -EarlierAttempts @([PSCustomObject]@{ Class = 'Success' })).Status | Should -Be 'Removed'
        $global:OemTestInstalled = @($e)
        (Remove-OemWin32Product -Product (New-TestProduct @($e)) -EarlierAttempts @([PSCustomObject]@{ Class = 'RebootRequired' })).Status | Should -Be 'RemovedRestartNeeded'
        $global:OemTestInstalled = @($e)
        (Remove-OemWin32Product -Product (New-TestProduct @($e)) -EarlierAttempts @([PSCustomObject]@{ Class = 'Failed' })).Status | Should -Be 'StaleEntryCleared'
        $global:OemTestInstalled = @($e)
        (Remove-OemWin32Product -Product (New-TestProduct @($e))).Status | Should -Be 'StaleEntryCleared'
    }
}

Describe 'R14: the second pass is not announced for a layer that has nothing left to run' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Stop-OemProductActivity { $global:OemTestCalls.Add('activity') }
        Mock Get-Service {}
        Mock Remove-StaleUninstallEntry {
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
    }

    It '[R14] says nothing about trying once more, and stops nothing again, when the only layer has taken its own uninstaller file away' {
        $exe = New-TestFile 'Program Files\Dell\Dell Pair\uninst.exe'
        $e = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $exe + '" /S')
        $global:OemTestInstalled = @($e)
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add('start'); Remove-Item -LiteralPath $FilePath -Force; New-TestRun -ExitCode 1 }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($e))
        @($global:OemTestCalls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        @($global:OemTestCalls | Where-Object { $_ -eq 'activity' }).Count | Should -Be 1
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*trying once more*'
    }
}

Describe 'R16 R20: Stop-OemProductActivity (dry-run protection of the uninstaller, previous start type)' {
    AfterEach { $env:windir = $script:savedWindir }
    BeforeEach {
        $script:savedWindir = $env:windir
        $env:windir = 'Z:\OemNoSuchWindowsFolder'
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Get-Service {}
        Mock Set-Service { $global:OemTestCalls.Add("set-service $Name $StartupType") }
        Mock Stop-ServiceBounded { $global:OemTestCalls.Add("stop-service $Name"); $true }
        Mock Stop-Process { $global:OemTestCalls.Add("stop-process $Id") }
    }

    It '[R16] a dry run does not list the uninstaller''s own process as one it would end (and does list a process that is not protected)' {
        $DryRun = $true
        $exe = New-TestFile 'Program Files\Dell\Dell Pair\uninst.exe'
        $e = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $exe + '" /S')
        $global:OemTestInstalled = @($e)
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Pair*'; processes = @('uninst') })
        Mock Get-Process { [PSCustomObject]@{ Id = 77; ProcessName = 'uninst'; Path = $exe } }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $global:OemTestLog -join "`n" | Should -Not -BeLike "*Would stop 1 running 'uninst'*"
        $global:OemTestLog.Clear()
        Mock Get-Process { [PSCustomObject]@{ Id = 78; ProcessName = 'uninst'; Path = (Join-Path $TestDrive 'elsewhere\other.exe') } }
        $null = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $global:OemTestLog -join "`n" | Should -BeLike "*Would stop 1 running 'uninst'*"
        $global:OemTestCalls.Count | Should -Be 0
    }

    It '[R20] reports the start type the service really had (Manual stays Manual)' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('*SupportAssist*') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; StartType = 'Manual'; Status = 'Stopped' } }
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r.Count | Should -Be 1
        $r[0].Was | Should -Be 'Manual'
    }
}

Describe 'R18: ConvertTo-OemFolderPath takes blanks off inside the quotes as well' {
    It '[R18] gives the folder of a value that is quoted with blanks inside the quotes' {
        ConvertTo-OemFolderPath -Text '" C:\Program Files\Dell\Dell Pair "' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        ConvertTo-OemFolderPath -Text "  `" `t C:\Program Files\Dell `"  " | Should -BeExactly 'C:\Program Files\Dell'
    }
}

Describe 'R07: Get-RunWarningCount' {
    It '[R07] reads the counter that the REAL Write-Log keeps (WARN and ERROR count, INFO does not)' {
        $sb = [scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName 'Write-Log') + "`n" + (Get-FunctionSource -ScriptPath $deployScript -FunctionName 'Get-RunWarningCount') + "`n" +
            '$script:errorCount = 0; Write-Log ''a'' ''WARN''; Write-Log ''b'' ''ERROR''; Write-Log ''c'' ''INFO''; Get-RunWarningCount')
        @(& $sb 6>$null)[-1] | Should -Be 2
    }
}
Describe 'R25: the warning for an uninstaller that has not finished names the likely reason' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        # (a stand-in process that never ends; the kill is aimed at a process id that does not exist)
        Mock Start-Process {
            $proc = [PSCustomObject]@{ Id = 2147483000; Handle = 0; PriorityClass = 0; ExitCode = $null }
            $proc | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) $false }
            $proc
        }
        Mock Stop-Process {}
    }

    It '[R25] blames a dialog for an ordinary installer and not for an MSI (it has no window under /qn)' {
        $r = Start-ProcessLowPriority -FilePath 'C:\Program Files\Vendor\uninst.exe' -ArgumentList '/S' -TimeoutMs 1500
        $r.TimedOut | Should -BeTrue
        $global:OemTestLog -join "`n" | Should -BeLike "*did not exit within 1.5s (probably a dialog nobody can answer: is the silent switch right?) - killing it.*"
        $global:OemTestLog.Clear()
        $r = Start-ProcessLowPriority -FilePath 'msiexec.exe' -ArgumentList '/x {AAAAAAAA-1111-2222-3333-444444444444} /qn' -TimeoutMs 1500
        $r.TimedOut | Should -BeTrue
        $global:OemTestLog -join "`n" | Should -BeLike "*Uninstaller 'msiexec.exe' did not exit within 1.5s (a Windows Installer product has no window under /qn: a stuck custom action, or a file in use?) - killing it.*"
    }
}
Describe 'R27: the network-share evidence' {
    BeforeEach {
        Mock Get-Service {}
        Mock Test-PathQuiet { $false }
        Mock Test-OemProgramFolderPresent { $false }
    }

    It '[R27] names a network location once, even when both the install folder and the uninstaller are on a share' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = '\\oem-no-such-host-7f3a91\share\Dell\uninst.exe'; InstallLocation = '\\oem-no-such-host-7f3a91\share\Dell'; DisplayIcon = '' }
        $r = @(Get-OemProgramEvidence -Layer $layer -Hint ([PSCustomObject]@{ Services = @() }))
        @($r | Where-Object { $_ -like '*network share*' }).Count | Should -Be 1
    }
}
Describe 'R28 R29: a Store app is one app, whichever list names it and whichever version is left' {
    BeforeAll {
        $global:OemTestAppxStubs = @()
        foreach ($cmd in 'Get-AppxPackage', 'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage', 'Remove-AppxPackage') {
            if (-not (Get-Command -Name $cmd -ErrorAction SilentlyContinue)) {
                Set-Item -Path "Function:global:$cmd" -Value { param($AllUsers, $Online, $PackageName, $Package) }
                $global:OemTestAppxStubs += $cmd
            }
        }
    }
    AfterAll {
        foreach ($cmd in @($global:OemTestAppxStubs)) { Remove-Item -Path "Function:global:$cmd" -ErrorAction SilentlyContinue }
        Remove-Variable -Name OemTestAppxStubs, OemTestAppx, OemTestProvisioned -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $ProtectWorkTeams = $true
        $OemBloatAppxPatterns = @('DellInc.MyDell')
        $global:OemTestAppx = @([PSCustomObject]@{ Name = 'DellInc.MyDell'; PackageFullName = 'DellInc.MyDell_3.1.12.0_x64__htrsf667h5kn2' })
        $global:OemTestProvisioned = @([PSCustomObject]@{ DisplayName = 'DellInc.MyDell'; PackageName = 'DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2' })
        Mock Get-AppxPackage { $global:OemTestAppx }
        Mock Get-AppxProvisionedPackage { $global:OemTestProvisioned }
        Mock Remove-AppxProvisionedPackage { $global:OemTestProvisioned = @() }
        Mock Invoke-ThrottledSteps { foreach ($step in $Steps) { $splat = $step.Args; & $step.Action @splat } }
    }

    It '[R28] an app of which another version is still installed after the removal is not counted as removed' {
        # (the removal takes the version that was targeted; a copy of another version, e.g. of another account, is still there)
        Mock Remove-AppxPackage { $global:OemTestAppx = @([PSCustomObject]@{ Name = 'DellInc.MyDell'; PackageFullName = 'DellInc.MyDell_3.2.0.0_x64__htrsf667h5kn2' }) }
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 0
        $r.Failed | Should -Be 1
    }

    It '[L5] names the package that is LEFT, not the spelling that was targeted: the staged bundle when only the installed package went' {
        Mock Remove-AppxPackage { $global:OemTestAppx = @() }
        Mock Remove-AppxProvisionedPackage { }
        $r = Remove-OemAppxPackages
        $r.Failed | Should -Be 1
        @($r.FailedNames) | Should -BeExactly @('DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2')
    }

    It '[L5] names both spellings when the installed package and the staged bundle both stay' {
        Mock Remove-AppxPackage { }
        Mock Remove-AppxProvisionedPackage { }
        $r = Remove-OemAppxPackages
        $r.Failed | Should -Be 1
        @($r.FailedNames).Count | Should -Be 1
        $r.FailedNames[0] | Should -BeExactly 'DellInc.MyDell_3.1.12.0_x64__htrsf667h5kn2 + DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2'
    }

    It '[R29] an app that is gone as an installed package but still staged under the other spelling is not counted as removed' {
        Mock Remove-AppxPackage { $global:OemTestAppx = @() }
        Mock Remove-AppxProvisionedPackage { }
        Mock Get-AppxProvisionedPackage { @([PSCustomObject]@{ DisplayName = 'DellInc.MyDell'; PackageName = 'DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2' }) }
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 0
        $r.Failed | Should -Be 1
    }
}
Describe 'R36: the reason written for a layer whose uninstaller an earlier layer took away' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity {}
        Mock Get-Service {}
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Remove-StaleUninstallEntry {
            $global:OemTestCalls.Add("stale|$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
    }

    It '[R36] says that an earlier step removed the uninstaller (and not just that the file is missing)' {
        $exe = New-TestFile 'Program Files\Dell\Dell Foo\uninst.exe'
        $msi = New-TestEntry -Name 'Dell Foo' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $plain = New-TestEntry -Name 'Dell Foo' -Key 'DellFooExe' -Uninstall ('"' + $exe + '" /S')
        $global:OemTestInstalled = @($msi, $plain)
        $script:exeToDelete = $exe
        Mock Start-ProcessLowPriority {
            # the MSI works: it takes its own Apps entry and the uninstaller file of the EXE layer with it
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -ne '{AAAAAAAA-1111-2222-3333-444444444444}' })
            [System.IO.File]::Delete($script:exeToDelete)
            New-TestRun -ExitCode 0
        }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msi, $plain))
        $r.Status | Should -Be 'Removed'
        @($global:OemTestCalls) | Should -Contain 'stale|its uninstaller file was removed by an earlier step and nothing it registers (install folder, icon file, service) shows the program is still there'
    }
}

Describe 'R33: the last look at the Apps list also catches a cleared entry that is listed again' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        $Win32BloatPatterns = @('Dell A*')
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
    }

    It '[R33] reports a program whose stale entry was cleared but is listed in Apps again as NOT REMOVED' {
        $a = New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'
        $global:OemTestInstalled = @($a)
        Mock Remove-OemWin32Product { [PSCustomObject]@{ Name = $Product.Name; Version = ''; Status = 'StaleEntryCleared'; Detail = ''; RestartNeeded = $false; Attempts = @() } }
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 0 removed, 1 NOT removed*'
        $text | Should -BeLike '*NOT REMOVED: ''Dell A One''*it was removed, but it is listed in Apps again*'
    }
}

Describe 'M02 R30: Test-PathQuiet and a question that throws (the same on every host)' {
    It '[M02 R30] answers $false when Test-Path itself throws (a dead network server does that on some hosts, not on others)' {
        Mock Test-Path { throw [System.IO.IOException]::new('The network path was not found.') }
        { Test-PathQuiet -Path 'C:\Program Files\Dell\Dell Pair' -PathType Container } | Should -Not -Throw
        Test-PathQuiet -Path 'C:\Program Files\Dell\Dell Pair' -PathType Container | Should -BeFalse
        Test-OemProgramFolderPresent -UninstallerPath 'C:\Program Files\Dell\Dell Pair\uninst.exe' | Should -BeFalse
    }
}

Describe 'R37: the pointer to the McAfee removal tool' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
        Mock Remove-OemWin32Product { [PSCustomObject]@{ Name = $Product.Name; Version = ''; Status = 'Removed'; Detail = ''; RestartNeeded = $false; Attempts = @() } }
    }

    It '[R37] names the McAfee tool only when a product whose name STARTS with McAfee was part of the run' {
        $Win32BloatPatterns = @('Dell*')
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell McAfee Offer' -Key 'K1' -Uninstall 'x'))
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*mcpr*'
    }
}

Describe 'L3: a second look that finds nothing left to run says each fact once, and keeps the note about shared software' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $ProtectWorkTeams = $true
        $workDir = $TestDrive
        $OemRunDisabled = @{}
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity {}
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-Service {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
        Mock Remove-StaleUninstallEntry { $true }
    }

    It '[L3] reports the entry without a command and the missing uninstaller file once each, and the shared-software note, after two looks' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Core Services'; respectDependencies = $true })
        $Win32BloatPatterns = @('Dell Core Services', 'Dell B*')
        $script:coreExe = New-TestFile 'Program Files\Dell\Dell Core Services\uninst.exe'
        $core = New-TestEntry -Name 'Dell Core Services' -Key 'DellCoreExe' -Uninstall ('"' + $script:coreExe + '" /S')
        $nocmd = New-TestEntry -Name 'Dell Core Services' -Key 'DellCoreNoCommand' -Uninstall ''
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($core, $nocmd, $b)
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) {
                $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $ArgumentList -notlike "*$($_.PSChildName)*" })
                [System.IO.File]::Delete($script:coreExe)          # the uninstaller of B takes the EXE uninstaller of Core Services along
            }
            $next.Run
        }
        Add-TestRun (New-TestRun -ExitCode 1603)                    # Core Services, pass 1
        Add-TestRun (New-TestRun -ExitCode 1603)                    # Core Services, pass 2
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true        # B is removed: progress, which gives Core Services a second look - with nothing left to run
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell Core Services''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*Exe: exit 1603*(tried 2 times)*'
        ([regex]::Matches($line[0], [regex]::Escape('another entry of this program: it has no uninstall command registered'))).Count | Should -Be 1
        ([regex]::Matches($line[0], [regex]::Escape('another entry of this program: its uninstaller file is missing ('))).Count | Should -Be 1
        $line[0] | Should -BeLike '*this program may be shared with other Dell software*'
    }
}

Describe 'F1: an Apps entry that is listed again is not a leftover while its uninstaller file exists, and an MSI that just answered 1603 is never one' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity {}
        Mock Get-Service {}
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
    }

    It '[F1] keeps the Apps entry of a Burn bundle that vanished after its uninstaller ran and was registered again (its uninstaller file is still there)' {
        $bundleExe = New-TestFile 'ProgramData\Package Cache\{bbbbbbbb-1111-2222-3333-444444444444}\setup.exe'
        $wrapExe = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{WRAP}\setup.exe'
        $key = '{bbbbbbbb-1111-2222-3333-444444444444}'
        $bundle = [PSCustomObject]@{ DisplayName = 'Dell Fake Suite'; DisplayVersion = '1.0'; PSChildName = $key; UninstallString = ('"' + $bundleExe + '"  /uninstall'); QuietUninstallString = ''; InstallLocation = ''; DisplayIcon = ''
            BundleCachePath = $bundleExe; BundleProviderKey = $key; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$key" }
        $wrap = [PSCustomObject]@{ DisplayName = 'Dell Fake Suite'; DisplayVersion = '1.0'; PSChildName = '{WRAP}'; UninstallString = ('"' + $wrapExe + '" -remove -runfromtemp'); QuietUninstallString = ''; InstallLocation = ''; DisplayIcon = ''
            PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{WRAP}' }
        $global:OemTestInstalled = @($bundle, $wrap)
        $script:bundleEntry = $bundle
        $script:bundlePath = $bundleExe
        Mock Remove-StaleUninstallEntry {
            $global:OemTestCalls.Add("stale|$PsPath|$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath")
            if ($FilePath -eq $script:bundlePath) {
                # the bundle works and unregisters itself ...
                $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -ne $script:bundleEntry.PSChildName })
                return [PSCustomObject]@{ Started = $true; ExitCode = 0; TimedOut = $false; Seconds = 2; Error = $null }
            }
            # ... the wrapper fails; after its second failed run the bundle is registered again (a late installer, a repair, an update tool)
            if (@($global:OemTestCalls | Where-Object { $_ -like 'start|*' }).Count -ge 3) { $global:OemTestInstalled = @($script:bundleEntry) + @($global:OemTestInstalled) }
            [PSCustomObject]@{ Started = $true; ExitCode = 1603; TimedOut = $false; Seconds = 2; Error = $null }
        }
        $r = Remove-OemWin32Product -Product ([PSCustomObject]@{ Name = 'Dell Fake Suite'; Version = '1.0'; Entries = @($bundle, $wrap) })
        $r.Status | Should -Be 'Failed'
        @($global:OemTestCalls | Where-Object { $_ -like 'start|*' }).Count | Should -Be 3
        @($global:OemTestCalls | Where-Object { $_ -like 'stale|*' }).Count | Should -Be 0 -Because 'the bundle entry is registered again and its uninstaller file exists: nothing proves it is a leftover'
        @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq $key }).Count | Should -Be 1
    }

    It '[F1] keeps the Apps entry of an MSI whose uninstall just FAILED, although the entry had been gone when an earlier pass looked (the bundle removed it, then it was registered again)' {
        $bundleExe = New-TestFile 'ProgramData\Package Cache\{bbbbbbbb-1111-2222-3333-444444444444}\setup.exe'
        $wrapExe = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{WRAP}\setup.exe'
        $bkey = '{bbbbbbbb-1111-2222-3333-444444444444}'
        $mkey = '{aaaaaaaa-1111-2222-3333-444444444444}'
        $bundle = [PSCustomObject]@{ DisplayName = 'Dell Fake Suite'; DisplayVersion = '1.0'; PSChildName = $bkey; UninstallString = ('"' + $bundleExe + '"  /uninstall'); QuietUninstallString = ''; InstallLocation = ''; DisplayIcon = ''
            BundleCachePath = $bundleExe; BundleProviderKey = $bkey; PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$bkey" }
        $msi = [PSCustomObject]@{ DisplayName = 'Dell Fake Suite'; DisplayVersion = '1.0'; PSChildName = $mkey; UninstallString = "MsiExec.exe /X$mkey"; QuietUninstallString = ''; InstallLocation = ''; DisplayIcon = ''; WindowsInstaller = 1
            PSPath = "Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\$mkey" }
        $wrap = [PSCustomObject]@{ DisplayName = 'Dell Fake Suite'; DisplayVersion = '1.0'; PSChildName = '{WRAP}'; UninstallString = ('"' + $wrapExe + '" -remove -runfromtemp'); QuietUninstallString = ''; InstallLocation = ''; DisplayIcon = ''
            PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{WRAP}' }
        $global:OemTestInstalled = @($bundle, $msi, $wrap)
        $script:bundleEntry = $bundle; $script:msiEntry = $msi; $script:bundlePath = $bundleExe
        Mock Remove-StaleUninstallEntry {
            $global:OemTestCalls.Add("stale|$PsPath|$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            if ($FilePath -eq $script:bundlePath) {
                # the bundle works: it takes its own entry and the entry of the MSI it carries
                $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -notin $script:bundleEntry.PSChildName, $script:msiEntry.PSChildName })
                return [PSCustomObject]@{ Started = $true; ExitCode = 0; TimedOut = $false; Seconds = 2; Error = $null }
            }
            # the wrapper fails; after its second failed run both entries are registered again
            if (@($global:OemTestCalls | Where-Object { $_ -like 'start|*' }).Count -ge 3 -and @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq $script:bundleEntry.PSChildName }).Count -eq 0) {
                $global:OemTestInstalled = @($script:bundleEntry, $script:msiEntry) + @($global:OemTestInstalled)
            }
            [PSCustomObject]@{ Started = $true; ExitCode = 1603; TimedOut = $false; Seconds = 2; Error = $null }
        }
        $r = Remove-OemWin32Product -Product ([PSCustomObject]@{ Name = 'Dell Fake Suite'; Version = '1.0'; Entries = @($bundle, $msi, $wrap) })
        $r.Status | Should -Be 'Failed'
        @($r.Attempts | Where-Object { $_.Layer -eq 'Msi' -and $_.Class -eq 'Failed' }).Count | Should -Be 1 -Because 'msiexec was run and answered 1603: the product is certainly still known to Windows Installer'
        @($global:OemTestCalls | Where-Object { $_ -like 'stale|*' }).Count | Should -Be 0
        @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq $mkey }).Count | Should -Be 1
    }
}

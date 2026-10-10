# Pester tests for what Phase 1 of Deploy-DellOfficeSetup.ps1 TELLS the operator: the "why it stayed" text of a program (every try of every
# layer, counted over both looks at it), the services that were set to Disabled on the way, the all-clear line for a run whose warnings
# were failed first attempts, the dry run (which prints the commands and the services it would touch, and changes nothing), the reason
# written when a leftover Apps entry is cleared, and Phase 1b's log lines. The real functions are cut out of the script with the
# PowerShell parser; the registry, the services, the processes and the clock are stood in for. ASCII only.

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
    function New-TestFile {
        param([string]$Rel)
        $p = Join-Path $TestDrive $Rel
        $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
        Set-Content -LiteralPath $p -Value 'x'
        $p
    }
    function New-TestAttempt {
        param([string]$Layer = 'Msi', [string]$Class = 'Failed', $ExitCode = 1603, [string]$ExitDisplay = '1603', [string]$Text = 'fatal error during the uninstall', [string]$LogPath = '', [string]$Why = '')
        [PSCustomObject]@{ Layer = $Layer; Class = $Class; ExitCode = $ExitCode; ExitDisplay = $ExitDisplay; Text = $Text; LogPath = $LogPath; Why = $Why; Command = ''; Seconds = 1 }
    }
    function New-TestResult {
        param([string]$Name, [string]$Status, [string]$Detail = '')
        [PSCustomObject]@{ Name = $Name; Version = ''; Status = $Status; Detail = $Detail; RestartNeeded = $false; Attempts = @() }
    }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestInstalled, OemTestRuns, OemTestCalls, OemTestWarnCount -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Get-OemAttemptLines' {
    It 'says the same outcome of a layer once, with how often it came out that way' {
        $a = New-TestAttempt
        $lines = @(Get-OemAttemptLines -Attempts @($a, $a, $a))
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly 'Msi: exit 1603 (fatal error during the uninstall) (tried 3 times)'
    }

    It 'keeps different outcomes apart, in the order they first came' {
        $lines = @(Get-OemAttemptLines -Attempts @((New-TestAttempt -Layer 'Bundle' -Class 'RebootFirst' -ExitCode 350 -ExitDisplay '350 (0x8007015E)' -Text 'no action was taken'), (New-TestAttempt), (New-TestAttempt -Layer 'Bundle' -Class 'RebootFirst' -ExitCode 350 -ExitDisplay '350 (0x8007015E)' -Text 'no action was taken')))
        $lines.Count | Should -Be 2
        $lines[0] | Should -BeExactly 'Bundle: exit 350 (0x8007015E) (no action was taken); restart the PC, then run the clean-up again (tried 2 times)'
        $lines[1] | Should -BeExactly 'Msi: exit 1603 (fatal error during the uninstall)'
    }

    It 'names the installer log of the LATEST try, and counts the tries over different logs' {
        $first = New-TestFile 'uninstall_a_1.log'
        $second = New-TestFile 'uninstall_a_2.log'
        $lines = @(Get-OemAttemptLines -Attempts @((New-TestAttempt -LogPath $first), (New-TestAttempt -LogPath $first), (New-TestAttempt -LogPath $second)))
        $lines.Count | Should -Be 1
        $lines[0] | Should -BeExactly "Msi: exit 1603 (fatal error during the uninstall); verbose log $second (tried 3 times)"
    }

    It 'adds what Windows Installer said, and that a "success" left the program in the Apps list' {
        $lines = @(Get-OemAttemptLines -Attempts @((New-TestAttempt -Why 'Error 1920. Service failed to start'), (New-TestAttempt -Layer 'Exe' -Class 'Success' -ExitCode 0 -ExitDisplay '0' -Text 'success')))
        $lines[0] | Should -BeExactly 'Msi: exit 1603 (fatal error during the uninstall); Windows Installer says: Error 1920. Service failed to start'
        $lines[1] | Should -BeExactly 'Exe: exit 0 (success), yet the program is still listed in Apps'
    }

    It 'says nothing for no attempts, and reads a List that is held in an object''s property (iterated directly, as Windows PowerShell 5.1 needs)' {
        @(Get-OemAttemptLines -Attempts @()).Count | Should -Be 0
        @(Get-OemAttemptLines -Attempts $null).Count | Should -Be 0
        $holder = [PSCustomObject]@{ Attempts = (New-Object System.Collections.Generic.List[object]) }
        $holder.Attempts.Add((New-TestAttempt))
        $holder.Attempts.Add((New-TestAttempt))
        @(Get-OemAttemptLines -Attempts $holder.Attempts) | Should -BeExactly @('Msi: exit 1603 (fatal error during the uninstall) (tried 2 times)')
    }
}

Describe 'Format-OemFailureDetail' {
    It 'joins what the attempts said, the notes about other entries, and (for software that may be shared) a hedged note' {
        $text = Format-OemFailureDetail -AttemptLines @('Msi: exit 0 (success), yet the program is still listed in Apps (tried 2 times)') -Notes @('another entry of this program: its uninstaller file is missing (C:\x\u.exe)') -Shared $true
        $text | Should -BeExactly 'Msi: exit 0 (success), yet the program is still listed in Apps (tried 2 times) | another entry of this program: its uninstaller file is missing (C:\x\u.exe) | this program may be shared with other Dell software: its installer can refuse to remove it while other software depends on it (the exit code above says what happened)'
    }

    It 'does not present an ordinary failure of shared software as intentional' {
        $text = Format-OemFailureDetail -AttemptLines @('Msi: exit 1603 (fatal error during the uninstall) (tried 2 times)') -Shared $true
        $text | Should -Not -BeLike '*left in place*'
        $text | Should -BeLike '*may be shared*the exit code above says what happened*'
    }

    It 'names the services that were set to Disabled on the way, what each was, and how to undo it' {
        $services = @([PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic'; Stopped = $true }, [PSCustomObject]@{ Name = 'SupportAssistTray'; DisplayName = 'Tray'; Was = 'Manual'; Stopped = $true })
        $text = Format-OemFailureDetail -AttemptLines @('Msi: exit 1603 (fatal error during the uninstall)') -DisabledServices $services
        $text | Should -BeLike "*| its service(s) 'SupportAssistAgent' (was Automatic), 'SupportAssistTray' (was Manual) were set to Disabled before the uninstall and stay Disabled; to undo: Set-Service -Name <service name> -StartupType <what it was>"
    }

    It 'says plainly that a service which could not be stopped is still running' {
        $services = @([PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic'; Stopped = $false }, [PSCustomObject]@{ Name = 'SupportAssistTray'; DisplayName = 'Tray'; Was = 'Manual'; Stopped = $true })
        $text = Format-OemFailureDetail -AttemptLines @('Msi: exit 1603 (fatal error during the uninstall)') -DisabledServices $services
        $text | Should -BeLike "*'SupportAssistAgent' (was Automatic; could not be stopped and is still running), 'SupportAssistTray' (was Manual) were set to Disabled*"
        $text | Should -Not -BeLike '*were stopped*'
    }

    It 'says nothing about services or shared software when there is nothing else to say' {
        Format-OemFailureDetail -DisabledServices @([PSCustomObject]@{ Name = 'x'; Was = 'Automatic' }) -Shared $true | Should -BeExactly 'no uninstaller could be started'
        Format-OemFailureDetail | Should -BeExactly 'no uninstaller could be started'
    }
}

Describe 'Format-OemLayerCommand and Get-OemHangGuess' {
    It 'shows an MSI as the msiexec command it runs and anything else as its quoted path with the arguments' {
        Format-OemLayerCommand -Layer ([PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; ArgumentList = '/x {AAAA} /qn' }) | Should -BeExactly 'msiexec /x {AAAA} /qn'
        Format-OemLayerCommand -Layer ([PSCustomObject]@{ Kind = 'Wrapper'; FilePath = 'C:\Program Files\IS\setup.exe'; ArgumentList = '-remove /Silent' }) | Should -BeExactly '"C:\Program Files\IS\setup.exe" -remove /Silent'
    }

    It 'does not blame a dialog for an MSI that has not finished (it has no window under /qn)' {
        Get-OemHangGuess -FilePath 'msiexec.exe' | Should -BeLike '*no window under /qn*'
        Get-OemHangGuess -FilePath 'C:\Windows\System32\MsiExec.exe' | Should -BeLike '*no window under /qn*'
        Get-OemHangGuess -FilePath 'C:\Program Files\Dell\Optimizer\setup.exe' | Should -BeLike '*dialog*silent switch*'
        Get-OemHangGuess -FilePath 'C:\Program Files\Vendor\notmsiexec.exe' | Should -BeLike '*dialog*'
    }

    It 'gives a hung installer a neutral class text (the log line carries the guess)' {
        (Get-UninstallExitClass -ExitCode $null -TimedOut $true).Text | Should -BeExactly 'the uninstaller did not finish in time and was stopped'
    }
}

Describe 'Get-OemRemovalSummaryLines: the all-clear line' {
    BeforeEach {
        $removed = @((New-TestResult 'Dell A One' 'Removed'), (New-TestResult 'Dell B Two' 'Removed'))
        $appxClean = [PSCustomObject]@{ Removed = 2; Failed = 0; FailedNames = @(); Unverified = 0 }
    }

    It 'says that nothing is left, and that the banner counts warning lines, when everything is gone although warnings were raised' {
        $lines = @(Get-OemRemovalSummaryLines -AppxResult $appxClean -ProductResults $removed -WarningsRaised 2)
        $verdict = @($lines | Where-Object { $_.Message -like '*Nothing that was targeted is left*' })
        $verdict.Count | Should -Be 1
        $verdict[0].Level | Should -Be 'INFO'
        $verdict[0].Message | Should -BeLike '*The 2 warning line(s) above are failed first attempts, refusals and notices; the finish banner counts warning lines, not programs.'
    }

    It 'is silent when no warning was raised' {
        @(Get-OemRemovalSummaryLines -AppxResult $appxClean -ProductResults $removed -WarningsRaised 0 | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
        @(Get-OemRemovalSummaryLines -AppxResult $appxClean -ProductResults $removed | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
    }

    It 'is silent when anything stayed, or could not be checked' {
        $stayed = @((New-TestResult 'Dell A One' 'Removed'), (New-TestResult 'Dell B Two' 'Failed' 'Msi: exit 1603'))
        @(Get-OemRemovalSummaryLines -AppxResult $appxClean -ProductResults $stayed -WarningsRaised 3 | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
        $appxFailed = [PSCustomObject]@{ Removed = 1; Failed = 1; FailedNames = @('X_1.0'); Unverified = 0 }
        @(Get-OemRemovalSummaryLines -AppxResult $appxFailed -ProductResults $removed -WarningsRaised 3 | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
        $appxUnverified = [PSCustomObject]@{ Removed = 1; Failed = 0; FailedNames = @(); Unverified = 1 }
        @(Get-OemRemovalSummaryLines -AppxResult $appxUnverified -ProductResults $removed -WarningsRaised 3 | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
    }

    It 'does not say "nothing that was targeted is left" when nothing was targeted at all - it says nothing matched, once, when a warning was raised' {
        @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @() -WarningsRaised 1 | Where-Object { $_.Message -like '*Nothing that was targeted*' }).Count | Should -Be 0
        $matched = @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @() -WarningsRaised 1 | Where-Object { $_.Message -like '*Nothing matched the removal patterns*' })
        $matched.Count | Should -Be 1
        $matched[0].Level | Should -Be 'INFO'
        $matched[0].Message | Should -BeLike '*The 1 warning line(s) above are notices (for example a restart that is already pending)*'
        @(Get-OemRemovalSummaryLines -AppxResult $null -ProductResults @() -WarningsRaised 0 | Where-Object { $_.Message -like '*Nothing matched*' }).Count | Should -Be 0
    }
}

Describe 'Stop-OemProductActivity: what it returns, and a dry run that only says what it would do' {
    AfterEach { $env:windir = $script:savedWindir }
    BeforeEach {
        # (when the tests run as SYSTEM, $TestDrive is under C:\WINDOWS\Temp and the "never from the Windows folder" rule would protect the fake processes)
        $script:savedWindir = $env:windir
        $env:windir = 'Z:\OemNoSuchWindowsFolder'
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('*SupportAssist*'); processes = @('SupportAssist*') })
        $script:svcStart = 'Automatic'
        $script:svcStatus = 'Running'
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; StartType = $script:svcStart; Status = $script:svcStatus } }
        Mock Get-Process { [PSCustomObject]@{ Id = 4242; ProcessName = 'SupportAssistAgent'; Path = 'C:\Program Files\Dell\SupportAssist\agent.exe' } }
        Mock Set-Service { $global:OemTestCalls.Add("set-service $Name $StartupType") }
        Mock Stop-ServiceBounded { $global:OemTestCalls.Add("stop-service $Name"); $true }
        Mock Stop-Process { $global:OemTestCalls.Add("stop-process $Id") }
    }

    It 'disables, stops and ends what the hint names, and returns the service it disabled with what it was' {
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'SupportAssistAgent'
        $r[0].Was | Should -Be 'Automatic'
        @($global:OemTestCalls) | Should -Contain 'set-service SupportAssistAgent Disabled'
        @($global:OemTestCalls) | Should -Contain 'stop-service SupportAssistAgent'
        @($global:OemTestCalls) | Should -Contain 'stop-process 4242'
    }

    It 'does not report a service it could not disable, nor one that was disabled already' {
        Mock Set-Service { throw 'Access is denied' }
        @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '').Count | Should -Be 0
        $global:OemTestLog -join "`n" | Should -BeLike '*Could not disable service ''SupportAssistAgent'': Access is denied*'
        $script:svcStart = 'Disabled'
        $script:svcStatus = 'Stopped'
        Mock Set-Service { $global:OemTestCalls.Add("set-service $Name $StartupType") }
        $global:OemTestCalls.Clear()
        @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '').Count | Should -Be 0
        @($global:OemTestCalls | Where-Object { $_ -like 'set-service*' }).Count | Should -Be 0
    }

    It 'records whether the service really stopped, so that the report does not call a running service stopped' {
        Mock Stop-ServiceBounded { $false }
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r.Count | Should -Be 1
        $r[0].Stopped | Should -BeFalse
        Mock Stop-ServiceBounded { $true }
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r[0].Stopped | Should -BeTrue
        # a service that was not running to begin with counts as stopped
        $script:svcStatus = 'Stopped'
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r[0].Stopped | Should -BeTrue
    }

    It 'reports a service that an earlier program of the same run disabled, with what it was before the run, and sets nothing again' {
        $OemRunDisabled = @{}
        $first = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $first.Count | Should -Be 1
        # (the service is Disabled and stopped now, as the real one would be)
        $script:svcStart = 'Disabled'
        $script:svcStatus = 'Stopped'
        $global:OemTestCalls.Clear()
        $second = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist Remediation' -InstallLocation '')
        $second.Count | Should -Be 1
        $second[0].Name | Should -Be 'SupportAssistAgent'
        $second[0].Was | Should -Be 'Automatic'
        @($global:OemTestCalls | Where-Object { $_ -like 'set-service*' }).Count | Should -Be 0
    }

    It 'does not report a service that was Disabled before the run began, nor anything from the run''s table in a dry run' {
        $OemRunDisabled = @{}
        $script:svcStart = 'Disabled'
        $script:svcStatus = 'Stopped'
        @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '').Count | Should -Be 0
        $OemRunDisabled['SupportAssistAgent'] = [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic'; Stopped = $true }
        $DryRun = $true
        @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '').Count | Should -Be 0
    }

    It 'keeps one record per service: a later program that manages to stop what the first could not stop corrects it' {
        $OemRunDisabled = @{}
        Mock Stop-ServiceBounded { $false }
        $first = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $first[0].Stopped | Should -BeFalse
        $script:svcStart = 'Disabled'                    # (still running: the stop failed)
        Mock Stop-ServiceBounded { $true }
        $second = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist Remediation' -InstallLocation '')
        $second[0].Stopped | Should -BeTrue
        $first[0].Stopped | Should -BeTrue
    }

    It 'changes nothing in a dry run, and says what it would do' {
        $DryRun = $true
        $r = @(Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '')
        $r.Count | Should -Be 0
        $global:OemTestCalls.Count | Should -Be 0
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*DRYRUN: Would disable service ''Dell SupportAssist'' (SupportAssistAgent; it is set to Automatic and is Running)*'
        $text | Should -BeLike '*DRYRUN: Would stop service ''Dell SupportAssist'' (SupportAssistAgent)*'
        $text | Should -BeLike '*DRYRUN: Would stop 1 running ''SupportAssist*'' process(es)*'
    }

    It 'reads a quoted or %VARIABLE% install folder like a plain one, and never searches a network share for processes' {
        $folder = Split-Path (New-TestFile 'Program Files\Dell\SupportAssist\agent.exe') -Parent
        $running = [PSCustomObject]@{ Id = 4343; ProcessName = 'helper'; Path = (Join-Path $folder 'helper.exe') }
        Mock Get-Process { $running } -ParameterFilter { -not $Name }
        Mock Get-Process { @() } -ParameterFilter { $Name }
        $OemProductHints = @()
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ('"' + $folder + '"')
        @($global:OemTestCalls) | Should -Contain 'stop-process 4343'
        $global:OemTestCalls.Clear()
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation '\\fileserver\share\Dell\SupportAssist\App'
        $global:OemTestCalls.Count | Should -Be 0
    }
}

Describe 'Remove-OemWin32Product: dry run, and the services named in the report' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity { $global:OemTestCalls.Add("activity|$ProductName|$InstallLocation") }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-Service {}
        Mock Remove-StaleUninstallEntry { $true }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @() }
            $next.Run
        }
    }

    It 'prints the command of each layer and asks what it would stop, but starts nothing, in a dry run' {
        $DryRun = $true
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location 'C:\Program Files\Dell\SupportAssist'
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'DryRun'
        @($global:OemTestCalls | Where-Object { $_ -like 'start|*' }).Count | Should -Be 0
        @($global:OemTestCalls) | Should -Contain 'activity|Dell SupportAssist|C:\Program Files\Dell\SupportAssist'
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*DRYRUN: Uninstalling: Dell SupportAssist (1 usable installer layer(s): Msi)*'
        $text | Should -BeLike '*DRYRUN:   would run the Msi uninstaller: msiexec /x {65043213-393F-49BF-B658-5B06C5F713FF} IGNOREDEPENDENCIES=ALL /qn /norestart /L*v "*uninstall_Dell_SupportAssist_*"*'
    }

    It 'shows the silent switch a hint puts on a wrapper, so that it can be checked before a real run' {
        $DryRun = $true
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; silentArgs = '-remove -runfromtemp /Silent' })
        $wrapper = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe'
        $e = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove -runfromtemp')
        Remove-OemWin32Product -Product (New-TestProduct @($e)) | Out-Null
        $global:OemTestLog -join "`n" | Should -BeLike "*DRYRUN:   would run the Wrapper uninstaller: `"$wrapper`" -remove -runfromtemp /Silent*"
    }

    It 'says in a dry run that an entry which registers nothing to look at would be reported, and one whose places are gone would be cleared' {
        $DryRun = $true
        $cache = Join-Path $TestDrive 'Package Cache\{33333333-3333-3333-3333-333333333333}'
        $nothing = New-TestEntry -Name 'Dell Nothing' -Key '{33333333-3333-3333-3333-333333333333}' -Uninstall ('"' + (Join-Path $cache 'setup.exe') + '" /uninstall')
        $gone = New-TestEntry -Name 'Dell Gone' -Key '{44444444-4444-4444-4444-444444444444}' -Uninstall ('"' + (Join-Path $cache 'setup.exe') + '" /uninstall') -Location (Join-Path $TestDrive 'gone\Dell Gone')
        Remove-OemWin32Product -Product (New-TestProduct @($nothing)) | Out-Null
        Remove-OemWin32Product -Product (New-TestProduct @($gone)) | Out-Null
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*DRYRUN: Dell Nothing - no usable uninstaller; it would be reported as NOT REMOVED (*the entry registers nothing that could be checked)*'
        $text | Should -BeLike '*DRYRUN: Dell Gone - no usable uninstaller; its Apps entry would be cleared as a leftover (a .reg backup is saved first)*'
    }

    It 'names the services it disabled in the reason a program stayed, and in nothing else' {
        Mock Stop-OemProductActivity { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic' } }
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'Failed'
        @($r.DisabledServices).Count | Should -Be 1
        $r.Detail | Should -BeLike "*its service(s) 'SupportAssistAgent' (was Automatic) were set to Disabled before the uninstall and stay Disabled*"
        # a program that was removed has nothing to explain
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $ok = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $ok.Status | Should -Be 'Removed'
        $ok.Detail | Should -BeExactly ''
    }
}

Describe 'Remove-StaleUninstallEntry says why it cleared an entry' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        # (a work folder of its own for each test: the backups are counted, and the tests may run in any order)
        $workDir = Join-Path $TestDrive ('stale-' + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $workDir -Force
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' -Force
        New-ItemProperty -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' -Name 'DisplayName' -Value 'Stale One' -PropertyType String | Out-Null
        $item = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1'
    }

    It 'writes the reason it was given into the log line, next to the backup' {
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Stale One' -Reason 'the installer says the product is not installed' | Should -BeTrue
        Test-Path -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Stale1' | Should -BeFalse
        $global:OemTestLog -join "`n" | Should -BeLike '*Removed the stale Uninstall entry of ''Stale One'' (the installer says the product is not installed); backup: *removed-uninstall-entry_Stale_One_Stale1_*.reg*'
        @(Get-ChildItem -LiteralPath $workDir -Filter 'removed-uninstall-entry_Stale_One_Stale1_*.reg').Count | Should -Be 1
    }

    It 'says the uninstaller no longer exists when no other reason is given' {
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Stale One' | Should -BeTrue
        $global:OemTestLog -join "`n" | Should -BeLike '*Removed the stale Uninstall entry of ''Stale One'' (its uninstaller no longer exists); backup: *'
    }
}

Describe 'Remove-OemWin32Product gives the reason for each kind of leftover entry it clears' {
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
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity {}
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-Service {}
        Mock Remove-StaleUninstallEntry {
            $global:OemTestCalls.Add("$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        Mock Start-ProcessLowPriority { $next = $global:OemTestRuns.Dequeue(); $next.Run }
    }

    It 'says the uninstaller file is gone for an entry nothing can be run for' {
        $e = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + (Join-Path $TestDrive 'gone\Uninstall.exe') + '" /S')
        $global:OemTestInstalled = @($e)
        (Remove-OemWin32Product -Product (New-TestProduct @($e))).Status | Should -Be 'StaleEntryCleared'
        $global:OemTestCalls.Count | Should -Be 1
        $global:OemTestCalls[0] | Should -Be 'its uninstaller file is missing and nothing it registers (install folder, icon file, service) shows the program is still there'
    }
}

Describe 'Remove-OemBloatware: the report lines that are about the run, not about one program' {
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
        Mock Remove-OemWin32Product { [PSCustomObject]@{ Name = $Product.Name; Version = ''; Status = 'Removed'; Detail = ''; RestartNeeded = $false; Attempts = @() } }
    }

    It 'names McAfee software in the phase header (the pattern removes every McAfee program, trial or not)' {
        $Win32BloatPatterns = @('McAfee*')
        $global:OemTestInstalled = @((New-TestEntry -Name 'McAfee LiveSafe' -Key 'K1' -Uninstall 'x'))
        Remove-OemBloatware
        $global:OemTestLog[0] | Should -BeExactly '[INFO] --- Phase 1: Removing OEM (Dell/Lenovo) bloatware and McAfee software ---'
    }

    It 'does not refer to a result line, nor advise about McAfee remnants, in a dry run (nothing is removed, no result is printed)' {
        $DryRun = $true
        $Win32BloatPatterns = @('McAfee*')
        $global:OemTestInstalled = @((New-TestEntry -Name 'McAfee LiveSafe' -Key 'K1' -Uninstall 'x'))
        Mock Remove-OemWin32Product { [PSCustomObject]@{ Name = $Product.Name; Version = ''; Status = 'DryRun'; Detail = ''; RestartNeeded = $false; Attempts = @() } }
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*OEM bloatware / McAfee removal pass finished (dry run: nothing was changed).*'
        $text | Should -Not -BeLike '*result line above*'
        $text | Should -Not -BeLike '*mcpr*'
    }

    It 'points to the McAfee removal tool only when a McAfee program was part of the run' {
        $Win32BloatPatterns = @('McAfee*', 'Dell A*')
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K2' -Uninstall 'x'))
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*mcpr*'
        $global:OemTestLog -join "`n" | Should -BeLike '*OEM bloatware / McAfee removal pass finished (the result line above says what is gone and what is not).*'
        $global:OemTestLog.Clear()
        $global:OemTestInstalled = @((New-TestEntry -Name 'McAfee LiveSafe' -Key 'K1' -Uninstall 'x'))
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -BeLike '*McAfee software was part of this run: if remnants remain, download McAfee''s own removal tool from https://www.mcafee.com/en-us/consumer-support/mcpr.html*'
    }
}

Describe 'Disable-OemScheduledTasksAndServices (Phase 1b): what it logs and what it leaves alone' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $OemTaskFolders = @()
        $OemTaskKeepPatterns = @()
        $OemServicePatterns = @('*SupportAssist*')
        Mock Get-ScheduledTask {}
        Mock Stop-ServiceBounded { $true }
        Mock Set-Service {}
    }

    It 'logs what the service is set to now, so that it can be put back' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' } }
        Disable-OemScheduledTasksAndServices
        $global:OemTestLog -join "`n" | Should -BeLike '*Disabling service: Dell SupportAssist (SupportAssistAgent; currently set to Automatic, Running)*'
        Should -Invoke Set-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' -and $StartupType -eq 'Disabled' }
    }

    It 'says the same in a dry run, and changes nothing' {
        $DryRun = $true
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' } }
        Disable-OemScheduledTasksAndServices
        $global:OemTestLog -join "`n" | Should -BeLike '*DRYRUN: Disabling service: Dell SupportAssist (SupportAssistAgent; currently set to Automatic, Running)*'
        Should -Invoke Set-Service -Times 0 -Exactly
        Should -Invoke Stop-ServiceBounded -Times 0 -Exactly
    }

    It 'leaves a service that is stopped and disabled already (Phase 1 did it) alone, without a word' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Stopped'; StartType = 'Disabled' } }
        Disable-OemScheduledTasksAndServices
        Should -Invoke Set-Service -Times 0 -Exactly
        Should -Invoke Stop-ServiceBounded -Times 0 -Exactly
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*Disabling service*'
    }

    It 'still stops a service that is disabled but running' {
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Disabled' } }
        Disable-OemScheduledTasksAndServices
        Should -Invoke Stop-ServiceBounded -Times 1 -Exactly -ParameterFilter { $Name -eq 'SupportAssistAgent' }
    }
}

Describe 'Remove-OemBloatware: what the second look does, and what the report says about both looks' {
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
        $Win32BloatPatterns = @('Dell A*', 'Dell B*')
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity { $global:OemTestCalls.Add("activity|$ProductName") }
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

    It 'does not look again at a program whose every remaining entry belongs to a layer that hung, and its report still names the hang' {
        $Win32BloatPatterns = @('Dell Optimizer*', 'Dell Pair')
        $wrapper = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe'
        $w = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove')
        $m = New-TestEntry -Name 'Dell Optimizer' -Key '{11111111-2222-3333-4444-555555555555}' -Uninstall 'MsiExec.exe /X{11111111-2222-3333-4444-555555555555}'
        $p = New-TestEntry -Name 'Dell Pair' -Key '{99999999-2222-3333-4444-555555555555}' -Uninstall 'MsiExec.exe /X{99999999-2222-3333-4444-555555555555}'
        $global:OemTestInstalled = @($w, $m, $p)
        Add-TestRun (New-TestRun -ExitCode $null -TimedOut $true)         # the wrapper hangs and is stopped
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{11111111-2222-3333-4444-555555555555}'    # its MSI works, the wrapper's entry stays
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true                # Dell Pair is removed: progress, which would give Optimizer a second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        @($global:OemTestCalls | Where-Object { $_ -like 'activity|Dell Optimizer' }).Count | Should -Be 1
        $text = $global:OemTestLog -join "`n"
        $text | Should -Not -BeLike '*taking a second look at them*'
        $text | Should -Not -BeLike '*no uninstaller could be started*'
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell Optimizer''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*Wrapper: the uninstaller did not finish in time and was stopped*'
        $line[0] | Should -BeLike '*Msi: exit 0 (success), yet the program is still listed in Apps*'
    }

    It 'does not announce, nor stop the services of, a layer whose own Apps entry the first pass already took away' {
        $folder = Split-Path (New-TestFile 'Program Files\Dell\Dell A One\a.dll') -Parent
        $exe = New-TestFile 'Program Files\Dell\Dell A One\uninstall.exe'
        $msi = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}' -Location $folder
        $plain = New-TestEntry -Name 'Dell A One' -Key 'DellAOneExe' -Uninstall ('"' + $exe + '" /S')
        $global:OemTestInstalled = @($msi, $plain)
        Add-TestRun (New-TestRun -ExitCode 1605)                                   # the MSI says "not installed", yet its folder is there: a wall
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey 'DellAOneExe'       # the EXE uninstaller works and unregisters itself
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        @($global:OemTestCalls | Where-Object { $_ -like 'activity|*' }).Count | Should -Be 1
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*trying once more*'
        $global:OemTestLog -join "`n" | Should -BeLike '*NOT REMOVED: ''Dell A One''*'
    }

    It 'reports a program that is listed in Apps AGAIN at the end as not removed, and says what may have done it' {
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a, $b)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true                                  # A is removed
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{BBBBBBBB-1111-2222-3333-444444444444}' -Adds @($a)   # B is removed, and brings A back
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 1 removed, 1 NOT removed*'
        $text | Should -BeLike '*NOT REMOVED: ''Dell A One'' 1.0 - it was removed, but it is listed in Apps again - possibly installed back by Dell Command | Update, a Dell delivery service or another installer*'
    }

    It 'does not delete the Apps entry of a layer that vanished for a moment and was registered again (its uninstaller file is there)' {
        $bundleExe = New-TestFile 'Package Cache\{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}\setup.exe'
        $bundle = New-TestEntry -Name 'Dell A One' -Key '{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}' -Uninstall ('"' + $bundleExe + '" /uninstall')
        $msi = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($bundle, $msi)
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}'    # the bundle works and unregisters itself
        Add-TestRun (New-TestRun -ExitCode 1603)                                                         # the MSI fails
        Add-TestRunEffect (New-TestRun -ExitCode 1603) -Adds @($bundle)                                  # ... fails again, and the bundle is registered AGAIN meanwhile
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq '{ab1ff183-69f3-4a2e-8a62-dba1aacc18c9}' }).Count | Should -Be 1
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*Removed the stale Uninstall entry*'
        $global:OemTestLog -join "`n" | Should -BeLike '*NOT REMOVED: ''Dell A One''*'
    }

    It 'still clears an entry whose uninstaller FILE an earlier layer took away, naming that reason' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell A Gone'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $script:oemGoneExe = Join-Path $folder 'uninstall.exe'
        Set-Content -LiteralPath $script:oemGoneExe -Value 'x'
        $msi = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $plain = New-TestEntry -Name 'Dell A One' -Key 'DellAOneExe' -Uninstall ('"' + $script:oemGoneExe + '" /S')
        $global:OemTestInstalled = @($msi, $plain)
        Mock Remove-StaleUninstallEntry {
            $global:OemTestCalls.Add("stale|$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            Remove-Item -LiteralPath $script:oemGoneExe -Force -ErrorAction SilentlyContinue    # the MSI takes the EXE uninstaller with it
            $next.Run
        }
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Remove-OemBloatware
        @($global:OemTestCalls | Where-Object { $_ -like 'stale|*' }) | Should -BeExactly @('stale|its uninstaller file was removed by an earlier step and nothing it registers (install folder, icon file, service) shows the program is still there')
        $global:OemTestLog -join "`n" | Should -BeLike '*The Exe uninstaller of ''Dell A One'' is gone*'
    }

    It 'does not delete the entry of a gone uninstaller when its file is back by the time of the delete' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\Dell A Back'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $script:oemBackExe = Join-Path $folder 'uninstall.exe'
        Set-Content -LiteralPath $script:oemBackExe -Value 'x'
        $msi = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $plain = New-TestEntry -Name 'Dell A One' -Key 'DellAOneExe' -Uninstall ('"' + $script:oemBackExe + '" /S')
        $global:OemTestInstalled = @($msi, $plain)
        Mock Remove-StaleUninstallEntry { $global:OemTestCalls.Add("stale|$Reason"); $true }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("start|$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            Remove-Item -LiteralPath $script:oemBackExe -Force -ErrorAction SilentlyContinue
            $next.Run
        }
        # the evidence check is the last thing before the delete: a program that puts its uninstaller back at that moment is installed
        Mock Get-OemProgramEvidence { Set-Content -LiteralPath $script:oemBackExe -Value 'x'; @() }
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Remove-OemBloatware
        @($global:OemTestCalls | Where-Object { $_ -like 'stale|*' }).Count | Should -Be 0
    }

    It 'deletes the verbose installer logs of a program that is gone after the last look at the Apps list, and keeps those of a program that is listed again' {
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a, $b)
        # (the stand-in installer writes the verbose log the real msiexec would write)
        Mock Start-ProcessLowPriority {
            $logPath = [regex]::Match($ArgumentList, '/L\*v "([^"]+)"').Groups[1].Value
            if ($logPath) { Set-Content -LiteralPath $logPath -Value 'verbose log' }
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $ArgumentList -notlike "*$($_.PSChildName)*" }) }
            if ($next.RemoveKey) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSChildName -ne $next.RemoveKey }) }
            if ($next.Adds) { $global:OemTestInstalled = @($global:OemTestInstalled) + @($next.Adds) }
            $next.Run
        }
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true                                                              # A is removed
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{BBBBBBBB-1111-2222-3333-444444444444}' -Adds @($a)      # B is removed, and brings A back
        Remove-OemBloatware
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'uninstall_Dell_A_One_*.log').Count | Should -Be 1
        @(Get-ChildItem -LiteralPath $TestDrive -Filter 'uninstall_Dell_B_Two_*.log').Count | Should -Be 0
    }

    It 'keeps the sentence about the services it disabled when a removed program is listed again' {
        Mock Stop-OemProductActivity { if ($ProductName -eq 'Dell A One') { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Was = 'Automatic'; Stopped = $true } } }
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a, $b)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        Add-TestRunEffect (New-TestRun -ExitCode 0) -RemoveKey '{BBBBBBBB-1111-2222-3333-444444444444}' -Adds @($a)
        Remove-OemBloatware
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell A One''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*it was removed, but it is listed in Apps again*its service(s) ''SupportAssistAgent'' (was Automatic) were set to Disabled*'
    }

    It 'counts an uninstaller of the first look that worked, and its restart, when the second look only clears the dead entry' {
        # (the entry registers an install folder that is not there any more: that is what makes "not installed" believable)
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}' -Location (Join-Path $TestDrive 'gone\Dell A One')
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a, $b)
        Add-TestRun (New-TestRun -ExitCode 3010)                      # A: finished, a restart is needed, the entry stays
        Add-TestRun (New-TestRun -ExitCode 1603)                      # A: the second pass fails
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true          # B: removed, which gives A its second look
        Add-TestRun (New-TestRun -ExitCode 1614)                      # A, second look: "already uninstalled" - the dead entry is cleared
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 2 removed, 0 NOT removed*'
        $text | Should -Not -BeLike '*leftover Apps entr*'
        $text | Should -BeLike '*''Dell A One'' is removed; a restart finishes the clean-up.*'
    }
}

Describe 'Remove-OemBloatware: a service that one program disabled is named in the report of every program of the run that shares it and stays' {
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
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell A*'; services = @('SupportAssistAgent') })
        $Win32BloatPatterns = @('Dell A*')
        $script:svcStart = 'Automatic'
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @(); Unverified = 0 } }
        Mock Get-RunWarningCount { [int]$global:OemTestWarnCount }
        Mock Remove-StaleUninstallEntry { $true }
        Mock Get-Process { @() }
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; StartType = $script:svcStart; Status = 'Stopped' } }
        Mock Set-Service { $script:svcStart = 'Disabled' }
        Mock Stop-ServiceBounded { $true }
        Mock Start-ProcessLowPriority { $next = $global:OemTestRuns.Dequeue(); $next.Run }
    }

    It 'says so in the NOT REMOVED line of both programs, although only the first one set the service to Disabled' {
        $one = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $two = New-TestEntry -Name 'Dell A Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($one, $two)
        1..4 | ForEach-Object { Add-TestRun (New-TestRun -ExitCode 1603) }          # two passes for each program
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        @($global:OemTestLog | Where-Object { $_ -like '*Disabling service ''Dell SupportAssist''*' }).Count | Should -Be 1
        foreach ($name in 'Dell A One', 'Dell A Two') {
            $line = @($global:OemTestLog | Where-Object { $_ -like "*NOT REMOVED: '$name'*" })
            $line.Count | Should -Be 1 -Because $name
            $line[0] | Should -BeLike "*its service(s) 'SupportAssistAgent' (was Automatic) were set to Disabled before the uninstall and stay Disabled*" -Because $name
        }
    }
}

Describe 'Get-OemAppxIdentity and Remove-OemAppxPackages: one Store app is one app, whichever list names it' {
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
        # the staged package is named differently: a bundle ("neutral", "~"), as Get-AppxProvisionedPackage lists it
        $global:OemTestProvisioned = @([PSCustomObject]@{ DisplayName = 'DellInc.MyDell'; PackageName = 'DellInc.MyDell_3.1.12.0_neutral_~_htrsf667h5kn2' })
        Mock Get-AppxPackage { $global:OemTestAppx }
        Mock Get-AppxProvisionedPackage { $global:OemTestProvisioned }
        Mock Remove-AppxPackage { $global:OemTestAppx = @() }
        Mock Invoke-ThrottledSteps { foreach ($step in $Steps) { $splat = $step.Args; & $step.Action @splat } }
    }

    It 'identifies an app by its name and publisher id, in either spelling' {
        Get-OemAppxIdentity -PackageName 'DellInc.MyDell_3.1.12.0_x64__htrsf667h5kn2' | Should -BeExactly 'dellinc.mydell|htrsf667h5kn2'
        Get-OemAppxIdentity -PackageName 'DellInc.MyDell_2021.5.0.0_neutral_~_htrsf667h5kn2' | Should -BeExactly 'dellinc.mydell|htrsf667h5kn2'
        Get-OemAppxIdentity -PackageName 'Some.Odd.Name' | Should -BeExactly 'some.odd.name'
        Get-OemAppxIdentity -PackageName '' | Should -BeExactly ''
    }

    It 'counts an app that is both installed and provisioned once, and calls it removed when it is gone from both lists' {
        Mock Remove-AppxProvisionedPackage { $global:OemTestProvisioned = @() }
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 1
        $r.Failed | Should -Be 0
    }

    It 'reports an app that is still provisioned once, not once per spelling' {
        Mock Remove-AppxProvisionedPackage {}
        $r = Remove-OemAppxPackages
        $r.Removed | Should -Be 0
        $r.Failed | Should -Be 1
        @($r.FailedNames).Count | Should -Be 1
    }
}

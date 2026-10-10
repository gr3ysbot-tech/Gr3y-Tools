# More Pester tests for the Phase 1 removal engine, written by a mutation-testing review: the first suite was run against 101 deliberate
# one-line bugs ("mutants") of the engine and killed 54; each test here fails on at least one of the others, and with them 99 die. They
# use the same scaffolding as OemRemoval.Tests.ps1 (functions cut out of the script by the parser, registry / installers / clock stood in
# for). ASCII only. The Start-ProcessLowPriority tests start REAL but harmless processes (cmd.exe /c exit N, a short ping) and install nothing.

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
    function New-TestFile {
        param([string]$Rel)
        $p = Join-Path $TestDrive $Rel
        $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
        Set-Content -LiteralPath $p -Value 'x'
        $p
    }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestInstalled, OemTestRuns, OemTestCalls, OemTestStopCalls, OemTestSleeps, OemTestResults, OemTestAppx, OemTestProvisioned, OemTestExit, OemScenario, OemTestPolls -Scope Global -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Remove-OemWin32Product: layer order, scoping of the dead-registration clean-up, and what the engine hands on' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestStopCalls = 0
        $global:OemTestSleeps = 0
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $DryRun = $false
        $workDir = $TestDrive
        $OemProductHints = @()
        $bundleDir = Join-Path $TestDrive 'Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}'
        $null = New-Item -ItemType Directory -Path $bundleDir -Force
        $fakeExe = Join-Path $bundleDir 'bundle-setup.exe'
        Set-Content -LiteralPath $fakeExe -Value 'x'
        $msiEntry = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'

        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Stop-OemProductActivity { $global:OemTestStopCalls++ }
        Mock Get-MsiLogFailureSummary { '' }
        Mock Get-OemMsiEventSummary { @() }
        Mock Remove-StaleUninstallEntry { $true }
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @() }
            $next.Run
        }
    }

    It 'runs the layers of one product in the order bundle, InstallShield wrapper, MSI, plain EXE, whatever the order in the registry is' {
        $exe = New-TestFile 'Program Files\Vendor\Product\uninstall.exe'
        $wrapper = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe'
        $wrapEntry = New-TestEntry -Name 'Dell Foo' -Key 'K1' -Uninstall ('"' + $wrapper + '" -remove')
        $exeEntry = New-TestEntry -Name 'Dell Foo' -Key 'K2' -Uninstall ('"' + $exe + '" /S')
        $msi = New-TestEntry -Name 'Dell Foo' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $bundle = New-TestEntry -Name 'Dell Foo' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $all = @($wrapEntry, $exeEntry, $msi, $bundle)
        $global:OemTestInstalled = $all
        1..4 | ForEach-Object { Add-TestRun (New-TestRun -ExitCode 1603) }
        $r = Remove-OemWin32Product -Product (New-TestProduct $all) -Passes 1
        @($r.Attempts | ForEach-Object { $_.Layer }) | Should -BeExactly @('Bundle', 'Wrapper', 'Msi', 'Exe')
    }

    It 'does not clear the Uninstall entry of a BUNDLE that answered "not installed" - only an MSI entry is cleared that way' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\BundleDead' -Force
        $bundle = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        $bundle.PSPath = (Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\BundleDead').PSPath
        $global:OemTestInstalled = @($bundle)
        Add-TestRun (New-TestRun -ExitCode 1605)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($bundle))
        $r.Status | Should -BeExactly 'Failed'
        Should -Invoke Remove-StaleUninstallEntry -Times 0 -Exactly
    }

    It 'clears only the MSI entry that said "not installed" when the product has a second MSI entry that merely failed' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\MsiA' -Force
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\MsiB' -Force
        $pathA = (Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\MsiA').PSPath
        $pathB = (Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\MsiB').PSPath
        $a = New-TestEntry -Name 'Dell Foo' -Key '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}' -Location (Join-Path $TestDrive 'gone\Dell Foo')
        $b = New-TestEntry -Name 'Dell Foo' -Key '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}' -Location (Join-Path $TestDrive 'gone\Dell Foo')
        $a.PSPath = $pathA
        $b.PSPath = $pathB
        $global:OemTestInstalled = @($a, $b)
        # decided by the command line, not by the order of the runs, so that the test does not depend on how the two MSI layers are sorted
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add("$FilePath $ArgumentList"); New-TestRun -ExitCode $(if ($ArgumentList -like '*AAAAAAAA-*') { 1605 } else { 1603 }) }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($a, $b))
        $r.Status | Should -BeExactly 'Failed'
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly
        Should -Invoke Remove-StaleUninstallEntry -Times 1 -Exactly -ParameterFilter { $PsPath -eq $pathA }
    }

    It 'hands the time limit of a product hint on to the uninstaller run of its bundle / wrapper / EXE (the MSI keeps its own)' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; timeoutSec = 77 })
        $bundleForLimit = New-TestEntry -Name 'Dell SupportAssist' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall')
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add("$TimeoutMs"); New-TestRun -ExitCode 1603 }
        $global:OemTestInstalled = @($msiEntry, $bundleForLimit)
        $null = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry, $bundleForLimit)) -Passes 1
        @($global:OemTestCalls) | Should -BeExactly @('77000', '600000')
    }

    It 'hands the product''s install folder on to Stop-OemProductActivity' {
        $folder = 'C:\Program Files\Dell\Dell Pair'
        Mock Stop-OemProductActivity { $global:OemTestCalls.Add("stop|$ProductName|$InstallLocation") }
        $e = New-TestEntry -Name 'Dell Pair' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall 'MsiExec.exe /X{12345678-1234-1234-1234-123456789ABC}' -Location $folder
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $null = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $global:OemTestCalls[0] | Should -BeExactly "stop|Dell Pair|$folder"
    }

    It 'a product is gone when ITS name is gone - a program whose name merely starts the same does not keep it "installed"' {
        $sa = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $rem = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{2FF8590E-7853-4A49-8AAF-594975FD2B6C}' -Uninstall 'MsiExec.exe /X{2FF8590E-7853-4A49-8AAF-594975FD2B6C}'
        $global:OemTestInstalled = @($sa, $rem)
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.DisplayName -ne 'Dell SupportAssist' })
            New-TestRun -ExitCode 0
        }
        $r = Remove-OemWin32Product -Product (New-TestProduct @($sa))
        $r.Status | Should -BeExactly 'Removed'
        $global:OemTestCalls.Count | Should -Be 1
    }

    It 'an uninstaller that exits at once but whose Uninstall entry disappears a few seconds later (NSIS) is seen to have worked' {
        $uninstaller = New-TestFile 'Program Files\Dell\Dell Pair\Uninstall.exe'
        $pair = New-TestEntry -Name 'Dell Pair' -Key 'DellPair' -Uninstall ('"' + $uninstaller + '" /S')
        $global:OemTestInstalled = @($pair)
        # the entry is removed during the 2nd pause of the wait, as a copy of the uninstaller running from %TEMP% would do
        Mock Start-Sleep { $global:OemTestSleeps++; if ($global:OemTestSleeps -ge 2) { $global:OemTestInstalled = @() } }
        Add-TestRun (New-TestRun -ExitCode 0)      # the launcher exits at once; the entry is still listed
        $r = Remove-OemWin32Product -Product (New-TestProduct @($pair))
        $r.Status | Should -BeExactly 'Removed'
        $r.Attempts.Count | Should -Be 1 -Because 'it was not run a second time just because the entry took a moment to go'
    }

    It 'waits <Seconds> s for the entry to disappear after a <Kind> uninstaller' -ForEach @(
        @{ Kind = 'Msi'; Seconds = 30 }
        @{ Kind = 'Bundle'; Seconds = 30 }
        @{ Kind = 'Exe'; Seconds = 90 }
        @{ Kind = 'Wrapper'; Seconds = 90 }
    ) {
        $entry = switch ($Kind) {
            'Msi' { New-TestEntry -Name 'Dell Foo' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' }
            'Bundle' { New-TestEntry -Name 'Dell Foo' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $fakeExe + '" /uninstall') }
            'Exe' { New-TestEntry -Name 'Dell Foo' -Key 'K' -Uninstall ('"' + (New-TestFile 'Program Files\Vendor\Product\uninstall.exe') + '" /S') }
            'Wrapper' { New-TestEntry -Name 'Dell Foo' -Key 'K' -Uninstall ('"' + (New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe') + '" -remove') }
        }
        Mock Wait-OemProductGone { $true }
        $global:OemTestInstalled = @($entry)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $null = Remove-OemWin32Product -Product (New-TestProduct @($entry))
        Should -Invoke Wait-OemProductGone -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq $Seconds }
    }

    It 'also waits for the entry to disappear after an exit that means "restart needed" (<Code>)' -ForEach @(
        @{ Code = 3010 }
        @{ Code = 1641 }
    ) {
        Mock Wait-OemProductGone { $true }
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode $Code) -Removes $true
        $null = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        Should -Invoke Wait-OemProductGone -Times 1 -Exactly
    }

    It 'names what is wrong with the program''s OTHER entries as well when the runnable one fails' {
        $gone = New-TestEntry -Name 'Dell Foo' -Key 'KGone' -Uninstall ('"' + (Join-Path $TestDrive 'gone\Uninstall.exe') + '"')
        $msi = New-TestEntry -Name 'Dell Foo' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $global:OemTestInstalled = @($msi, $gone)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 1603)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msi, $gone))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*Msi: exit 1603*another entry of this program: its uninstaller file is missing*'
    }

    It 'does not say "still installed - trying once more" on the first pass' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        $null = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*still installed - stopping*'
    }

    It 'says "yet the program is still listed" after a restart-needed exit (3010) too' {
        $global:OemTestInstalled = @($msiEntry)
        Add-TestRun (New-TestRun -ExitCode 3010)
        Add-TestRun (New-TestRun -ExitCode 3010)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($msiEntry))
        $r.Status | Should -BeExactly 'Failed'
        $r.Detail | Should -BeLike '*exit 3010*yet the program is still listed in Apps*'
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Invoke-OemUninstallLayer: a busy installer, and the level of the log lines' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        Mock Start-Sleep {}
        Mock Wait-WindowsInstallerIdle { $true }
        Mock Get-MsiLogFailureSummary { 'failed in action X' }
        Mock Get-OemMsiEventSummary { @() }
        $layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; ArgumentList = '/x'; LogPath = '' }
    }

    It 'tries a busy Windows Installer four times in all, pausing 20 s between the tries, and then reports it as busy' {
        Mock Start-ProcessLowPriority { $global:OemTestCalls.Add('run'); New-TestRun -ExitCode 1618 }
        $a = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        $global:OemTestCalls.Count | Should -Be 4
        $a.Class | Should -BeExactly 'Busy'
        Should -Invoke Start-Sleep -ParameterFilter { $Seconds -eq 20 } -Times 3 -Exactly
    }

    It 'waits up to 120 s for the Windows Installer to be idle before it starts msiexec' {
        Mock Start-ProcessLowPriority { New-TestRun -ExitCode 0 }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        Should -Invoke Wait-WindowsInstallerIdle -Times 1 -Exactly -ParameterFilter { $TimeoutSec -eq 120 }
    }

    It 'logs a failed attempt as WARN (the run banner counts those) and a successful one as INFO' {
        Mock Start-ProcessLowPriority { New-TestRun -ExitCode 1603 }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        @($global:OemTestLog | Where-Object { $_ -like '`[WARN`]*exit 1603*' }).Count | Should -Be 1
        Mock Start-ProcessLowPriority { New-TestRun -ExitCode 0 }
        $null = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        @($global:OemTestLog | Where-Object { $_ -like '`[INFO`]*exit 0*' }).Count | Should -Be 1
    }

    It 'asks for the installer''s own explanation after an MSI uninstall that ended <Code> as well' -ForEach @(
        @{ Code = 1603 }
        @{ Code = 1612 }
        @{ Code = 1625 }
    ) {
        $global:OemTestExit = $Code
        Mock Start-ProcessLowPriority { New-TestRun -ExitCode $global:OemTestExit }
        $a = Invoke-OemUninstallLayer -Layer $layer -ProductName 'X'
        $a.Why | Should -BeExactly 'failed in action X'
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Wait-OemProductGone' {
    BeforeEach {
        $global:OemTestPolls = 0
        Mock Start-Sleep {}
    }

    It 'keeps polling when the entry disappears a little later' {
        Mock Test-OemProductPresent { $global:OemTestPolls++; $global:OemTestPolls -lt 4 }
        Wait-OemProductGone -Name 'X' -TimeoutSec 30 | Should -BeTrue
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 3 }
    }

    It 'gives up after the time limit when the entry stays, having paused once per 3 s' {
        Mock Test-OemProductPresent { $true }
        Wait-OemProductGone -Name 'X' -TimeoutSec 9 | Should -BeFalse
        Should -Invoke Start-Sleep -Times 3 -Exactly -ParameterFilter { $Seconds -eq 3 }
    }
}

Describe 'Test-OemProductPresent' {
    It 'matches the exact name only (not the start of a longer one), whatever the letter case' {
        Mock Get-UninstallEntries { @([PSCustomObject]@{ DisplayName = 'Dell SupportAssist Remediation' }) }
        Test-OemProductPresent -Name 'Dell SupportAssist' | Should -BeFalse
        Test-OemProductPresent -Name 'DELL SUPPORTASSIST REMEDIATION' | Should -BeTrue
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Stop-OemProductActivity: boundaries of the install-folder rule, and the service lookup' {
    AfterEach { $env:windir = $script:savedWindir }
    BeforeEach {
        # (when the tests run as SYSTEM, $TestDrive is under C:\WINDOWS\Temp and the "never from the Windows folder" rule would protect the fake processes)
        $script:savedWindir = $env:windir
        $env:windir = 'Z:\OemNoSuchWindowsFolder'
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        Mock Get-Process { @() }
        Mock Stop-Process {}
        $OemProductHints = @()
    }

    It 'stops what runs from a Dell product folder of the usual depth (C:\Program Files\Dell\Dell Pair), but not from the shared vendor folder (C:\Program Files\Dell)' {
        Mock Test-Path { $true } -ParameterFilter { $LiteralPath -like 'C:\Program Files\Dell*' }
        Mock Get-Process {
            @(
                [PSCustomObject]@{ Id = 11; ProcessName = 'pairhelper'; Path = 'C:\Program Files\Dell\Dell Pair\pairhelper.exe' }
                [PSCustomObject]@{ Id = 12; ProcessName = 'dcu'; Path = 'C:\Program Files\Dell\CommandUpdate\dcu.exe' }
            )
        }
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation 'C:\Program Files\Dell\Dell Pair'
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 11 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 12 }
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation 'C:\Program Files\Dell'
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 12 }
    }

    It 'stops the services and the processes a hint names with -Force' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent'); processes = @('SupportAssistAgent') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'SupportAssistAgent'; DisplayName = 'Dell SupportAssist'; Status = 'Running'; StartType = 'Automatic' } }
        Mock Stop-Service {}
        Mock Set-Service {}
        Mock Get-Process { [PSCustomObject]@{ Id = 4242; ProcessName = 'SupportAssistAgent'; Path = 'C:\x\SupportAssistAgent.exe' } } -ParameterFilter { $Name -eq 'SupportAssistAgent' }
        Stop-OemProductActivity -ProductName 'Dell SupportAssist' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Force }
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 4242 -and $Force }
    }

    It 'copes with an InstallLocation that ends in a backslash (26 % of the real ones on a normal PC do)' {
        $dir = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $null = New-Item -ItemType Directory -Path $dir -Force
        Mock Get-Process { @([PSCustomObject]@{ Id = 7; ProcessName = 'pairhelper'; Path = (Join-Path $dir 'helper.exe') }) }
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation ($dir + '\')
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 7 }
    }

    It 'does not stop a process of a sibling folder whose name merely starts with the product folder name' {
        $dir = Join-Path $TestDrive 'Program Files\Dell\Dell Pair'
        $sibling = Join-Path $TestDrive 'Program Files\Dell\Dell Pair Extras'
        $null = New-Item -ItemType Directory -Path $dir -Force
        $null = New-Item -ItemType Directory -Path $sibling -Force
        Mock Get-Process {
            @(
                [PSCustomObject]@{ Id = 7; ProcessName = 'pairhelper'; Path = (Join-Path $dir 'helper.exe') }
                [PSCustomObject]@{ Id = 8; ProcessName = 'extras'; Path = (Join-Path $sibling 'extras.exe') }
            )
        }
        Stop-OemProductActivity -ProductName 'Dell Pair' -InstallLocation $dir
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 7 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 8 }
    }

    It 'finds a hint service by its DISPLAY name when no service has that name (the shipped hints for Dell Optimizer and Digital Delivery are spelled that way)' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; services = @('Dell Optimizer*') })
        Mock Get-Service { } -ParameterFilter { $Name }
        Mock Get-Service { [PSCustomObject]@{ Name = 'DellOptimizer'; DisplayName = 'Dell Optimizer'; Status = 'Running'; StartType = 'Automatic' } } -ParameterFilter { $DisplayName -like 'Dell Optimizer*' }
        Mock Stop-Service {}
        Mock Set-Service {}
        Stop-OemProductActivity -ProductName 'Dell Optimizer' -InstallLocation ''
        Should -Invoke Stop-Service -Times 1 -Exactly -ParameterFilter { $Name -eq 'DellOptimizer' }
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Remove-OemBloatware: the bound on the second look, and what counts as progress' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestInstalled = @()
        $global:OemTestResults = @{}
        $DryRun = $false
        $ProtectWorkTeams = $true
        $Win32BloatPatterns = @('Dell A*', 'Dell B*')
        Mock Start-Sleep {}
        Mock Get-PendingRestartReasons { @() }
        Mock Remove-OemAppxPackages { [PSCustomObject]@{ Removed = 0; Failed = 0; FailedNames = @() } }
        Mock Get-UninstallEntries { $global:OemTestInstalled }
        Mock Test-Path { $false }
        Mock Remove-OemWin32Product {
            $global:OemTestCalls.Add("$($Product.Name)|passes=$Passes")
            $next = $global:OemTestResults[$Product.Name].Dequeue()
            if ($next.Status -in 'Removed', 'StaleEntryCleared') { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.DisplayName -ne $Product.Name }) }
            $next
        }
        function New-TestResult {
            param([string]$Name, [string]$Status, [string[]]$AttemptClasses = @())
            [PSCustomObject]@{ Name = $Name; Version = ''; Status = $Status; Detail = $(if ($Status -eq 'Failed') { 'it failed' } else { '' }); RestartNeeded = $false
                Attempts = @($AttemptClasses | ForEach-Object { [PSCustomObject]@{ Class = $_ } }) }
        }
        function Set-TestPlan {
            param([string]$Name, [object[]]$Results)
            $q = New-Object System.Collections.Generic.Queue[object]
            foreach ($r in $Results) { $q.Enqueue($r) }
            $global:OemTestResults[$Name] = $q
        }
    }

    It 'looks at a program that keeps failing at most twice in all - the second look is bounded' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Failed' @('Failed')))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'Removed')
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2', 'Dell A One|passes=1')
        $global:OemTestLog -join "`n" | Should -BeLike "*NOT REMOVED: 'Dell A One'*"
    }

    It 'counts a cleared stale Uninstall entry as progress, so that what is left gets its second look' {
        $global:OemTestInstalled = @((New-TestEntry -Name 'Dell A One' -Key 'K1' -Uninstall 'x'), (New-TestEntry -Name 'Dell B Two' -Key 'K2' -Uninstall 'x'))
        Set-TestPlan 'Dell A One' @((New-TestResult 'Dell A One' 'Failed' @('Failed')), (New-TestResult 'Dell A One' 'Removed'))
        Set-TestPlan 'Dell B Two' @(New-TestResult 'Dell B Two' 'StaleEntryCleared')
        Remove-OemBloatware
        @($global:OemTestCalls) | Should -BeExactly @('Dell A One|passes=2', 'Dell B Two|passes=2', 'Dell A One|passes=1')
        $global:OemTestLog -join "`n" | Should -BeLike '*programs: 1 removed, 1 leftover Apps entry cleared, 0 NOT removed*'
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Remove-OemAppxPackages: the removal action itself is run' {
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
        Remove-Variable -Name OemTestAppxStubs -Scope Global -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $DryRun = $false
        $ProtectWorkTeams = $true
        $OemBloatAppxPatterns = @('DellInc.DellSupportAssistforPCs')
        $global:OemTestAppx = @([PSCustomObject]@{ Name = 'DellInc.DellSupportAssistforPCs'; PackageFullName = 'DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2' })
        $global:OemTestProvisioned = @()
        Mock Get-AppxPackage { $global:OemTestAppx }
        Mock Get-AppxProvisionedPackage { $global:OemTestProvisioned }
        Mock Remove-AppxProvisionedPackage {}
    }

    It 'removes each package for ALL users - the action that Invoke-ThrottledSteps runs is executed here, not just counted' {
        Mock Remove-AppxPackage {
            $global:OemTestCalls.Add("remove-appx $Package allusers=$AllUsers")
            $global:OemTestAppx = @($global:OemTestAppx | Where-Object { $_.PackageFullName -ne $Package })
        }
        Mock Invoke-ThrottledSteps { foreach ($step in $Steps) { $splat = $step.Args; & $step.Action @splat } }
        $r = Remove-OemAppxPackages
        $global:OemTestCalls | Should -Contain 'remove-appx DellInc.DellSupportAssistforPCs_5.2.1.0_x64__htrsf667h5kn2 allusers=True'
        $r.Removed | Should -Be 1
        $r.Failed | Should -Be 0
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Remove-StaleUninstallEntry: never deletes a key it could not back up' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $workDir = $TestDrive
    }

    It 'leaves the key alone, and says so, when the .reg backup cannot be written' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep1' -Force
        New-ItemProperty -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep1' -Name 'DisplayName' -Value 'Keep One' -PropertyType String | Out-Null
        $item = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep1'
        $workDir = Join-Path $TestDrive 'no-such-folder\deeper'
        Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Keep One' | Should -BeFalse
        Test-Path -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep1' | Should -BeTrue
        $global:OemTestLog -join "`n" | Should -BeLike '*Could not back up*leaving it alone*'
    }

    It 'does not throw, whatever ErrorActionPreference its caller runs with (a CI step starts with Stop), when reg.exe fails: the exit code decides' {
        $null = New-Item -Path 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep2' -Force
        New-ItemProperty -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep2' -Name 'DisplayName' -Value 'Keep Two' -PropertyType String | Out-Null
        $item = Get-Item -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep2'
        $workDir = Join-Path $TestDrive 'no-such-folder\deeper'
        $ErrorActionPreference = 'Stop'
        $threw = $false
        $result = $true
        try { $result = Remove-StaleUninstallEntry -PsPath $item.PSPath -ProductName 'Keep Two' } catch { $threw = $true }
        $threw | Should -BeFalse
        $result | Should -BeFalse
        Test-Path -LiteralPath 'TestRegistry:\Microsoft\Windows\CurrentVersion\Uninstall\Keep2' | Should -BeTrue
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Pure helpers: boundaries the committed tests leave open' {
    BeforeEach { $global:OemTestLog = New-Object System.Collections.Generic.List[string] }

    It 'matches a product name to a hint whatever the letter case' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        @((Get-OemProductHint -ProductName 'DELL SUPPORTASSIST Remediation').Services) | Should -BeExactly @('SupportAssistAgent')
    }

    It 'drops <Switch> from the vendor arguments of a Burn bundle, whatever the case' -ForEach @(
        @{ Switch = '/layout' }
        @{ Switch = '-LAYOUT' }
        @{ Switch = '/promptrestart' }
        @{ Switch = '/q' }
        @{ Switch = '/qn' }
        @{ Switch = '/quiet' }
        @{ Switch = '/norestart' }
        @{ Switch = '/uninstall' }
    ) {
        ConvertTo-BurnUninstallArguments -ExistingArguments $Switch | Should -BeExactly '/uninstall /quiet /norestart'
    }

    It 'reads a .<Ext> file as the uninstaller too' -ForEach @(
        @{ Ext = 'bat' }
        @{ Ext = 'cmd' }
        @{ Ext = 'com' }
    ) {
        $result = ConvertFrom-UninstallString -UninstallString "C:\Program Files\Some Vendor\remove.$Ext /quiet"
        $result.Type | Should -Be 'Exe'
        $result.FilePath | Should -Be "C:\Program Files\Some Vendor\remove.$Ext"
        $result.ArgumentList | Should -Be '/quiet'
    }

    It 'reads an upper-case .EXE that is directly followed by its arguments (no blank), like the lower-case form' {
        $result = ConvertFrom-UninstallString -UninstallString 'C:\Vendor\UNINST.EXE/S'
        $result.Type | Should -Be 'Exe'
        $result.FilePath | Should -Be 'C:\Vendor\UNINST.EXE'
        $result.ArgumentList | Should -Be '/S'
    }

    It 'reads an msiexec command that carries a full path (quoted or not), and the /I form the real Dell MSI entries use' -ForEach @(
        @{ Text = '"C:\Windows\System32\msiexec.exe" /X{65043213-393F-49BF-B658-5B06C5F713FF}' }
        @{ Text = 'C:\Windows\System32\msiexec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' }
        @{ Text = 'MsiExec.exe /I{65043213-393F-49BF-B658-5B06C5F713FF}' }
    ) {
        $result = ConvertFrom-UninstallString -UninstallString $Text
        $result.Type | Should -Be 'Msi'
        $result.ProductCode | Should -Be '{65043213-393F-49BF-B658-5B06C5F713FF}'
    }

    It 'takes a lower-case product code (the id of a Burn bundle) out of an msiexec string' {
        (ConvertFrom-UninstallString -UninstallString 'MsiExec.exe /X{400b816d-1b36-426f-9595-5742bfd07ec4}').ProductCode | Should -Be '{400b816d-1b36-426f-9595-5742bfd07ec4}'
    }

    It 'recognises a Burn bundle by its BundleCachePath / BundleProviderKey even when the command is not in a Package Cache folder' -ForEach @(
        @{ Prop = 'BundleCachePath' }
        @{ Prop = 'BundleProviderKey' }
    ) {
        $e = New-TestEntry -Name 'Vendor Bundle' -Key 'K' -Uninstall '"C:\Program Files (x86)\Vendor\Bundle\setup.exe" /uninstall'
        $e | Add-Member -NotePropertyName $Prop -NotePropertyValue 'C:\Program Files (x86)\Vendor\Bundle\setup.exe'
        (Get-OemUninstallLayer -Entry $e).Kind | Should -BeExactly 'Bundle'
    }

    It 'does not take a GUID-named key without an uninstall string for an MSI product unless Windows Installer registered it' {
        $e = New-TestEntry -Name 'X' -Key '{12345678-1234-1234-1234-123456789ABC}' -Uninstall '' -WindowsInstaller 0
        (Get-OemUninstallLayer -Entry $e).Kind | Should -BeExactly 'None'
    }

    It 'groups two entries whose names differ only by surrounding blanks' {
        $a = New-TestEntry -Name 'Dell Optimizer' -Key 'K1' -Uninstall 'MsiExec.exe /X{11111111-1111-1111-1111-111111111111}'
        $b = New-TestEntry -Name 'Dell Optimizer ' -Key 'K2' -Uninstall '"C:\x\u.exe" /S'
        @(Group-OemProductEntries -Entries @($a, $b) -Patterns @('Dell Optimizer*')).Count | Should -Be 1
    }

    It 'uses the vendor''s QuietUninstallString when the entry has one (no committed fixture ever sets one, real Burn and many EXE entries do)' {
        $e = New-TestEntry -Name 'Vendor App' -Key 'K' -Uninstall '"C:\Program Files\Vendor\uninst.exe"' -Quiet '"C:\Program Files\Vendor\uninst.exe" -silent -norestart'
        (Get-OemUninstallLayer -Entry $e).ArgumentList | Should -BeExactly '-silent -norestart'
    }

    It 'reads the real Burn registry shape: UninstallString with two spaces (or /modify), QuietUninstallString with /quiet, BundleCachePath, no InstallLocation, no WindowsInstaller' {
        $exe = New-TestFile 'ProgramData\Package Cache\{400b816d-1b36-426f-9595-5742bfd07ec4}\DellSupportAssistRemediationServiceInstaller.exe'
        $e = New-TestEntry -Name 'Dell SupportAssist Remediation' -Key '{400b816d-1b36-426f-9595-5742bfd07ec4}' -Uninstall ('"' + $exe + '"  /modify') -Quiet ('"' + $exe + '" /uninstall /quiet')
        $e | Add-Member -NotePropertyName BundleCachePath -NotePropertyValue $exe
        $e | Add-Member -NotePropertyName BundleProviderKey -NotePropertyValue '{400b816d-1b36-426f-9595-5742bfd07ec4}'
        $l = Get-OemUninstallLayer -Entry $e -LogPath 'C:\Temp\b.log'
        $l.Kind | Should -BeExactly 'Bundle'
        $l.FilePath | Should -BeExactly $exe
        $l.ArgumentList | Should -BeExactly '/uninstall /quiet /norestart /log "C:\Temp\b.log"'
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Start-ProcessLowPriority with real, harmless processes (cmd.exe and ping only; nothing is installed)' {
    BeforeAll {
        $script:cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
    }

    It 'returns the exit code the process ended with: <Code>' -ForEach @(
        @{ Code = 0 }
        @{ Code = 3 }
        @{ Code = 350 }
        @{ Code = 1603 }
        @{ Code = 3010 }
    ) {
        $r = Start-ProcessLowPriority -FilePath $script:cmdExe -ArgumentList "/c exit $Code" -TimeoutMs 60000
        $r.Started | Should -BeTrue
        $r.TimedOut | Should -BeFalse
        $r.ExitCode | Should -Be $Code
        (Get-UninstallExitClass -ExitCode $r.ExitCode -TimedOut $r.TimedOut -Started $r.Started).Code | Should -Be $Code
    }

    It 'returns a negative exit code (a Burn bundle reports an HRESULT) unchanged and classifies it' {
        $r = Start-ProcessLowPriority -FilePath $script:cmdExe -ArgumentList '/c exit -2147024546' -TimeoutMs 60000
        $r.ExitCode | Should -Be -2147024546
        (Get-UninstallExitClass -ExitCode $r.ExitCode).Class | Should -BeExactly 'RebootFirst'
    }

    It 'starts a program that needs no arguments (Start-Process refuses an empty -ArgumentList)' {
        $r = Start-ProcessLowPriority -FilePath (Join-Path $env:SystemRoot 'System32\whoami.exe') -ArgumentList '' -TimeoutMs 60000
        $r.Started | Should -BeTrue
        $r.ExitCode | Should -Be 0
    }

    It 'reports a file that does not exist instead of throwing' {
        $r = Start-ProcessLowPriority -FilePath (Join-Path $TestDrive 'no-such-uninstaller.exe') -ArgumentList '/S' -TimeoutMs 60000
        $r.Started | Should -BeFalse
        $r.ExitCode | Should -BeNullOrEmpty
        $r.Error | Should -Not -BeNullOrEmpty
        $r.Error | Should -BeLike '*no-such-uninstaller.exe*' -Because 'the message Start-Process gives does not name the file'
        (Get-UninstallExitClass -ExitCode $r.ExitCode -TimedOut $r.TimedOut -Started $r.Started).Class | Should -BeExactly 'NotStarted'
    }

    It 'stops a process that does not finish in time - and what that process started'  {
        # A ping with a buffer size nobody else uses is found again by its command line, so that other pings (or other test runs in
        # parallel) cannot confuse the check.
        $size = Get-Random -Minimum 20001 -Maximum 60000
        $finder = { @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'PING.EXE'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*-l $size *" }) }
        # positive control: the finder does see such a ping while it runs (otherwise "0 left" below would prove nothing)
        $probe = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\PING.EXE') -ArgumentList "-n 60 -l $size 127.0.0.1" -PassThru -WindowStyle Hidden
        try {
            Start-Sleep -Milliseconds 700
            @(& $finder).Count | Should -BeGreaterThan 0 -Because 'the check must be able to see the ping at all'
        } finally {
            & taskkill.exe /PID $probe.Id /T /F 2>&1 | Out-Null
        }
        Start-Sleep -Milliseconds 700
        @(& $finder).Count | Should -Be 0 -Because 'the probe ping was removed'

        $r = Start-ProcessLowPriority -FilePath $script:cmdExe -ArgumentList "/c ping -n 60 -l $size 127.0.0.1 > nul" -TimeoutMs 2500
        $r.Started | Should -BeTrue
        $r.TimedOut | Should -BeTrue
        $r.ExitCode | Should -BeNullOrEmpty
        $r.Seconds | Should -BeLessThan 30
        $global:OemTestLog -join "`n" | Should -BeLike '*did not exit within*killing it*'
        Start-Sleep -Milliseconds 1500
        @(& $finder).Count | Should -Be 0 -Because 'taskkill /T must take the whole tree, not just the cmd.exe'
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'The shipped product hints (bloat-patterns.json) and the script body that loads them' {
    BeforeAll {
        $script:patterns = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\debloat\bloat-patterns.json') -Raw | ConvertFrom-Json
        # The statements of the script BODY that build $OemProductHints are not in a function; cut them out by position instead.
        $tokens = $null
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($deployScript, [ref]$tokens, [ref]$errs)
        $first = $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -like '$OemBloatAppxPatterns = @($bloatPatterns.generic.appxPatterns)*' } | Select-Object -First 1
        $last = $ast.EndBlock.Statements | Where-Object { $_ -is [System.Management.Automation.Language.ForEachStatementAst] -and $_.Extent.Text -like 'foreach ($oemName in $script:selectedOems)*' } | Select-Object -First 1
        if (-not $first -or -not $last) { throw 'the script body that builds $OemProductHints was not found' }
        $script:wiringText = $ast.Extent.Text.Substring($first.Extent.StartOffset, $last.Extent.EndOffset - $first.Extent.StartOffset)
    }

    It 'the script body adds the Dell hints from bloat-patterns.json to $OemProductHints' {
        $bloatPatterns = $script:patterns
        $script:selectedOems = @('dell')
        . ([scriptblock]::Create($script:wiringText))
        @($OemProductHints).Count | Should -Be @($script:patterns.dell.productHints).Count
        @($OemProductHints).Count | Should -BeGreaterThan 0
    }

    It 'with the shipped hints, <Name> gets the services, processes and switches the removal relies on' -ForEach @(
        @{ Name = 'Dell SupportAssist'; Services = '*SupportAssist*'; Processes = 'SupportAssist*'; Switches = '' }
        @{ Name = 'Dell SupportAssist Remediation'; Services = '*SupportAssist*'; Processes = 'DellSupportAssistRemedationService'; Switches = '' }
        @{ Name = 'Dell SupportAssist OS Recovery Plugin for Dell Update'; Services = '*SupportAssist*'; Processes = 'SupportAssist*'; Switches = '' }
        @{ Name = 'Dell Optimizer'; Services = 'Dell Optimizer*'; Processes = 'DellOptimizer'; Switches = '-remove -runfromtemp /Silent' }
        @{ Name = 'Dell Digital Delivery Services'; Services = 'Dell Digital Delivery*'; Processes = 'Dell.D3.WinSvc'; Switches = '' }
        @{ Name = 'Dell Pair'; Services = $null; Processes = $null; Switches = '' }
    ) {
        $bloatPatterns = $script:patterns
        $script:selectedOems = @('dell')
        . ([scriptblock]::Create($script:wiringText))
        $h = Get-OemProductHint -ProductName $Name
        if ($Services) { $h.Services | Should -Contain $Services }
        if ($Processes) { $h.Processes | Should -Contain $Processes }
        $h.SilentArgs | Should -BeExactly $Switches
    }
}

# ------------------------------------------------------------------------------------------------------------------------------------
Describe 'Test-WindowsInstallerBusy (same body; only the mutex NAME is injected so that a private mutex can stand in for Global\_MSIExecute)' {
    BeforeAll {
        $src = Get-FunctionSource -ScriptPath $deployScript -FunctionName 'Test-WindowsInstallerBusy'
        $seam = $src.Replace('function Test-WindowsInstallerBusy {', "function Test-BusyUnderTest {`n    param([string]`$MutexName)").Replace("OpenExisting('Global\_MSIExecute',", 'OpenExisting($MutexName,')
        if ($seam -eq $src -or $seam -notlike '*OpenExisting($MutexName,*' -or $seam -notlike '*function Test-BusyUnderTest*') { throw 'the mutex-name seam could not be injected into Test-WindowsInstallerBusy' }
        . ([scriptblock]::Create($seam))
    }

    # Windows PowerShell only: in PowerShell 7 Mutex.OpenExisting(string, MutexRights) does not exist (.NET Core), so the function's catch-all
    # makes it answer "idle" for ever there. The worker runs on Windows PowerShell 5.1, which is what this pins.
    It 'says idle when no such mutex exists, busy while another thread holds it, and idle again once it is released' -Skip:($PSVersionTable.PSEdition -ne 'Desktop') {
        $name = 'Local\OemTestMutex_' + [guid]::NewGuid().ToString('N')
        Test-BusyUnderTest -MutexName $name | Should -BeFalse
        $ready = New-Object System.Threading.ManualResetEvent $false
        $release = New-Object System.Threading.ManualResetEvent $false
        $released = New-Object System.Threading.ManualResetEvent $false
        $done = New-Object System.Threading.ManualResetEvent $false
        $ps = [powershell]::Create()
        $holder = {
            param($n, $ready, $release, $released, $done)
            $m = New-Object System.Threading.Mutex($false, $n)
            [void]$m.WaitOne()
            [void]$ready.Set()
            [void]$release.WaitOne()
            $m.ReleaseMutex()
            [void]$released.Set()
            [void]$done.WaitOne()
            $m.Dispose()
        }
        [void]$ps.AddScript($holder).AddArgument($name).AddArgument($ready).AddArgument($release).AddArgument($released).AddArgument($done)
        $handle = $ps.BeginInvoke()
        try {
            $ready.WaitOne(10000) | Should -BeTrue
            Test-BusyUnderTest -MutexName $name | Should -BeTrue
            [void]$release.Set()
            $released.WaitOne(10000) | Should -BeTrue
            Test-BusyUnderTest -MutexName $name | Should -BeFalse
        } finally {
            # Release the holder thread whatever happened above, or a FAILING assertion would leave EndInvoke waiting for ever.
            [void]$release.Set()
            [void]$done.Set()
            try { $null = $ps.EndInvoke($handle) } catch {}
            $ps.Dispose()
        }
    }
}

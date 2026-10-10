# Pester tests for what Phase 1 of Deploy-DellOfficeSetup.ps1 takes as evidence that a program is STILL INSTALLED before it clears an
# entry from the Apps list: how registry text (quoted, carrying %VARIABLES%, blank, a bare command name, a network path) is turned into
# something worth asking the file system about, and the rule that an installer's "not installed" answer (1605/1614) deletes nothing
# while the program's folder, icon file or service is still there. The real functions are cut out of the script with the PowerShell
# parser; the registry, the processes and the clock are stood in for, so nothing is installed or removed. ASCII only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $deployScript = Join-Path $PSScriptRoot '..\debloat\Deploy-DellOfficeSetup.ps1'
    foreach ($fn in 'Get-UninstallEntries', 'Start-ProcessLowPriority', 'ConvertFrom-UninstallString', 'Test-PathQuiet', 'ConvertTo-OemFolderPath', 'Get-OemUninstallerFolder', 'Resolve-UninstallExecutable', 'Test-OemProgramFolderPresent', 'Get-OemProgramEvidence', 'Stop-ServiceBounded', 'Test-OemProcessMayBeStopped', 'ConvertTo-MsiUninstallArguments', 'Get-PendingRestartReasons', 'Test-OemResultRetryable', 'Remove-OemBloatware', 'Get-OemProductHint', 'Get-UninstallExitClass', 'ConvertTo-BurnUninstallArguments', 'Get-OemUninstallLayer', 'Group-OemProductEntries',
        'Get-OemRemovalSummaryLines', 'Get-OemAttemptLines', 'Format-OemFailureDetail', 'Format-OemLayerCommand', 'Get-RunWarningCount', 'Get-OemHangGuess', 'Get-OemAppxIdentity', 'Test-OemFolderHasContent', 'Get-OemIconFilePath', 'Get-OemProgramFootprints', 'Format-OemNothingToCheck', 'Test-OemProductPresent', 'Wait-OemProductGone', 'Stop-OemProductActivity', 'Invoke-OemUninstallLayer',
        'Remove-StaleUninstallEntry', 'Remove-OemUninstallLogs', 'Remove-OemWin32Product', 'Test-WindowsInstallerBusy', 'Wait-WindowsInstallerIdle',
        'Get-MsiLogFailureSummary', 'Get-OemMsiEventSummary', 'Remove-OemAppxPackages', 'Invoke-ThrottledSteps', 'Test-IsWorkSchoolTeams') {
        . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $deployScript -FunctionName $fn)))
    }

    # The log is captured so that the tests can read what the operator would read; the warning counter is what the run's banner shows.
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
    function New-TestFile {
        param([string]$Rel)
        $p = Join-Path $TestDrive $Rel
        $null = New-Item -ItemType Directory -Path (Split-Path $p -Parent) -Force
        Set-Content -LiteralPath $p -Value 'x'
        $p
    }
}

AfterAll {
    Remove-Variable -Name OemTestLog, OemTestInstalled, OemTestRuns, OemTestCalls, OemTestStaleCalls, OemTestWarnCount -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -Path Env:\OEMEVID_ROOT -ErrorAction SilentlyContinue
}

Describe 'ConvertTo-OemFolderPath: registry text becomes a path worth asking the file system about' {
    It 'keeps a rooted path as it is' {
        ConvertTo-OemFolderPath -Text 'C:\Program Files\Dell\Dell Pair' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        ConvertTo-OemFolderPath -Text '\\fileserver\share\Dell' | Should -BeExactly '\\fileserver\share\Dell'
    }

    It 'takes off quotes and white space, turns "/" into "\" and expands %VARIABLES%' {
        ConvertTo-OemFolderPath -Text '  "C:\Program Files\Dell"  ' | Should -BeExactly 'C:\Program Files\Dell'
        ConvertTo-OemFolderPath -Text 'C:/Program Files/Dell/Dell Pair' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        $env:OEMEVID_ROOT = 'C:\Evidence Root'
        ConvertTo-OemFolderPath -Text '%OEMEVID_ROOT%\Vendor\Prog A' | Should -BeExactly 'C:\Evidence Root\Vendor\Prog A'
    }

    It 'gives nothing for text that is not a rooted path (Test-Path reads "." or "C:" as the current directory)' -ForEach @(
        @{ Text = '' }
        @{ Text = ' ' }
        @{ Text = '.' }
        @{ Text = '\' }
        @{ Text = 'C:' }
        @{ Text = 'Program Files\Dell' }
        @{ Text = 'powershell.exe' }
        @{ Text = '..\x' }
        @{ Text = '"' }
    ) {
        ConvertTo-OemFolderPath -Text $Text | Should -BeExactly ''
    }
}

Describe 'Get-OemUninstallerFolder' {
    It 'cuts the folder off an uninstaller path, however the registry spells it' {
        Get-OemUninstallerFolder -UninstallerPath 'C:\Program Files\Dell\Dell Pair\Uninstall.exe' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        Get-OemUninstallerFolder -UninstallerPath '"C:\Program Files\Dell\Dell Pair\Uninstall.exe"' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        Get-OemUninstallerFolder -UninstallerPath 'C:/Program Files/Dell/Dell Pair/Uninstall.exe' | Should -BeExactly 'C:\Program Files\Dell\Dell Pair'
        $env:OEMEVID_ROOT = 'C:\Evidence Root'
        Get-OemUninstallerFolder -UninstallerPath '%OEMEVID_ROOT%\Vendor\uninst.exe' | Should -BeExactly 'C:\Evidence Root\Vendor'
        Get-OemUninstallerFolder -UninstallerPath '\\fileserver\share\Dell\uninst.exe' | Should -BeExactly '\\fileserver\share\Dell'
    }

    It 'has no folder for a bare program name or a file in a drive root' -ForEach @(
        @{ Text = 'powershell.exe' }
        @{ Text = 'C:\uninst.exe' }
        @{ Text = '' }
        @{ Text = ':\x.exe' }
    ) {
        Get-OemUninstallerFolder -UninstallerPath $Text | Should -BeExactly ''
    }
}

Describe 'Test-PathQuiet and Test-OemProgramFolderPresent never throw and never write an error' {
    It 'answers $false for a folder on a network server that cannot be reached (Test-Path throws for those, even with SilentlyContinue)' {
        # (the error stream is read with 2>&1: an exception that is caught is still listed in $Error, but nothing is shown to the operator)
        { Test-PathQuiet -Path '\\oem-no-such-host-7f3a91\share\folder' -PathType Container } | Should -Not -Throw
        $out = @(Test-PathQuiet -Path '\\oem-no-such-host-7f3a91\share\folder' -PathType Container 2>&1)
        @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        $out[-1] | Should -BeFalse
        { Test-OemProgramFolderPresent -UninstallerPath '\\oem-no-such-host-7f3a91\share\folder\uninst.exe' } | Should -Not -Throw
        $out = @(Test-OemProgramFolderPresent -UninstallerPath '\\oem-no-such-host-7f3a91\share\folder\uninst.exe' 2>&1)
        @($out | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }).Count | Should -Be 0
        $out[-1] | Should -BeFalse
    }

    It 'answers $false, without an error, for text that is not a path at all' -ForEach @(
        @{ Text = ':\x.exe' }
        @{ Text = ':' }
        @{ Text = '"' }
        @{ Text = 'C:\a<b>\x.exe' }
        @{ Text = '|' }
    ) {
        $Error.Clear()
        Test-OemProgramFolderPresent -UninstallerPath $Text | Should -BeFalse -Because $Text
        Test-PathQuiet -Path $Text -PathType Container | Should -BeFalse -Because $Text
        $Error.Count | Should -Be 0 -Because $Text
    }

    It 'sees the folder of an uninstaller that is written with quotes, forward slashes or a %VARIABLE%' {
        $exe = New-TestFile 'Program Files\Vendor\Prog A\uninst.exe'
        $folder = Split-Path $exe -Parent
        Test-OemProgramFolderPresent -UninstallerPath ('"' + $exe + '"') | Should -BeTrue
        Test-OemProgramFolderPresent -UninstallerPath ($exe -replace '\\', '/') | Should -BeTrue
        $env:OEMEVID_ROOT = $TestDrive
        Test-OemProgramFolderPresent -UninstallerPath '%OEMEVID_ROOT%\Program Files\Vendor\Prog A\uninst.exe' | Should -BeTrue
        $folder | Should -Not -BeNullOrEmpty
    }
}

Describe 'Test-OemFolderHasContent: an empty folder is what an uninstaller leaves behind, not a program' {
    It 'is true for a folder that holds something and for a file' {
        $file = New-TestFile 'Program Files\Vendor\Full\a.dll'
        Test-OemFolderHasContent -Path (Split-Path $file -Parent) | Should -BeTrue
        Test-OemFolderHasContent -Path $file | Should -BeTrue
    }

    It 'is false for an empty folder, a missing path and text that is not a path' {
        $empty = Join-Path $TestDrive 'Program Files\Vendor\Empty'
        $null = New-Item -ItemType Directory -Path $empty -Force
        Test-OemFolderHasContent -Path $empty | Should -BeFalse
        Test-OemFolderHasContent -Path (Join-Path $TestDrive 'no\such\folder') | Should -BeFalse
        Test-OemFolderHasContent -Path '' | Should -BeFalse
        Test-OemFolderHasContent -Path 'C:\a<b>' | Should -BeFalse
    }

    It 'counts a folder that holds only an empty sub-folder as holding something (that is not proof that the program is gone)' {
        $dir = Join-Path $TestDrive 'Program Files\Vendor\Sub'
        $null = New-Item -ItemType Directory -Path (Join-Path $dir 'inner') -Force
        Test-OemFolderHasContent -Path $dir | Should -BeTrue
    }
}

Describe 'Get-OemProgramEvidence reads registry text before it asks the file system' {
    AfterEach { if ($script:savedRoot) { $env:SystemRoot = $script:savedRoot; $script:savedRoot = $null } }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $hint = [PSCustomObject]@{ Services = @() }
        Mock Get-Service {}
    }

    It 'finds the install folder when the registry value is quoted' {
        $folder = Split-Path (New-TestFile 'Program Files\Vendor\Prog A\a.dll') -Parent
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = ''; InstallLocation = ('"' + $folder + '"'); DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $hint) | Should -Contain "the program's folder still exists ($folder)"
    }

    It 'finds the install folder when the registry value still carries a %VARIABLE%' {
        $null = New-TestFile 'Program Files\Vendor\Prog B\b.dll'
        $env:OEMEVID_ROOT = $TestDrive
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = ''; InstallLocation = '%OEMEVID_ROOT%\Program Files\Vendor\Prog B'; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $hint) | Should -Not -BeNullOrEmpty
    }

    It 'takes <Text> for no folder at all (Test-Path answers $true for the current directory)' -ForEach @(
        @{ Text = ' ' }
        @{ Text = '.' }
        @{ Text = '\' }
        @{ Text = 'C:' }
    ) {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = ''; InstallLocation = $Text; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $hint) | Should -BeNullOrEmpty
    }

    It 'does not take a system file for the program''s icon (a bare name is judged against the working directory; C:\Windows\Installer is only an icon cache)' -ForEach @(
        @{ Icon = 'shell32.dll,-5' }
        @{ Icon = 'cmd.exe' }
        @{ Icon = '"%SystemRoot%\Installer\{65043213-393F-49BF-B658-5B06C5F713FF}\app.ico",0' }
        @{ Icon = '%SystemRoot%\System32\shell32.dll,-5' }
    ) {
        $layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = $Icon }
        @(Get-OemProgramEvidence -Layer $layer -Hint $hint) | Should -BeNullOrEmpty -Because $Icon
    }

    It 'still takes the icon file of a program outside the Windows folder, with or without an icon index, quotes or variables' {
        # (the icon file lies in $TestDrive, which is under the Windows folder when Pester runs as SYSTEM; icons in the Windows folder do not count)
        $script:savedRoot = $env:SystemRoot
        $env:SystemRoot = 'Z:\OemNoSuchWindowsFolder'
        $icon = New-TestFile 'Program Files\Vendor\IconProg\app.ico'
        $env:OEMEVID_ROOT = $TestDrive
        foreach ($text in ($icon + ',0'), ('"' + $icon + '",-3'), '%OEMEVID_ROOT%\Program Files\Vendor\IconProg\app.ico') {
            $layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = $text }
            (@(Get-OemProgramEvidence -Layer $layer -Hint $hint) -join ' | ') | Should -BeLike '*the file its Apps icon points at still exists*' -Because $text
        }
    }

    It 'never takes a location on a network share for proof that the program is gone' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = '\\oem-no-such-host-7f3a91\share\Dell\uninst.exe'; InstallLocation = ''; DisplayIcon = '' }
        (@(Get-OemProgramEvidence -Layer $layer -Hint $hint) -join ' | ') | Should -BeLike '*network share*cannot be checked*'
    }

    It 'cannot judge a command that starts with a bare program name, and says so' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = 'powershell.exe'; InstallLocation = ''; DisplayIcon = '' }
        (@(Get-OemProgramEvidence -Layer $layer -Hint $hint) -join ' | ') | Should -BeLike '*bare program name (powershell.exe)*'
    }

    It 'does not call msiexec a bare program name' {
        $layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = '' }
        @(Get-OemProgramEvidence -Layer $layer -Hint $hint) | Should -BeNullOrEmpty
    }
}

Describe 'Get-OemIconFilePath: the icon file of an Apps entry, when it says something about the program' {
    It 'reads quotes, an icon index and %VARIABLES%' {
        $env:OEMEVID_ROOT = 'C:\Evidence Root'
        Get-OemIconFilePath -DisplayIcon '"C:\Program Files\Dell\Prog\prog.exe",0' | Should -BeExactly 'C:\Program Files\Dell\Prog\prog.exe'
        Get-OemIconFilePath -DisplayIcon 'C:\Program Files\Dell\Prog\prog.ico' | Should -BeExactly 'C:\Program Files\Dell\Prog\prog.ico'
        Get-OemIconFilePath -DisplayIcon 'C:\Program Files\Dell\Prog\prog.exe, -12' | Should -BeExactly 'C:\Program Files\Dell\Prog\prog.exe'
        Get-OemIconFilePath -DisplayIcon '%OEMEVID_ROOT%\Vendor\prog.ico,2' | Should -BeExactly 'C:\Evidence Root\Vendor\prog.ico'
        Get-OemIconFilePath -DisplayIcon '\\fileserver\share\Dell\prog.ico' | Should -BeExactly '\\fileserver\share\Dell\prog.ico'
    }

    It 'gives nothing for a Windows file, a bare name or no icon at all' -ForEach @(
        @{ Icon = '' }
        @{ Icon = 'shell32.dll,-5' }
        @{ Icon = 'cmd.exe' }
        @{ Icon = '%SystemRoot%\System32\shell32.dll,-5' }
        @{ Icon = '"%SystemRoot%\Installer\{65043213-393F-49BF-B658-5B06C5F713FF}\app.ico",0' }
    ) {
        Get-OemIconFilePath -DisplayIcon $Icon | Should -BeExactly '' -Because $Icon
    }

    It 'recognises the Windows folder whatever the case, and does not take a neighbour whose name only starts the same for it' {
        Get-OemIconFilePath -DisplayIcon ($env:SystemRoot.ToUpperInvariant() + '\Installer\x\icon.ico') | Should -BeExactly ''
        $neighbour = $env:SystemRoot + 'Tools\prog.ico'
        Get-OemIconFilePath -DisplayIcon $neighbour | Should -BeExactly $neighbour
    }
}

Describe 'Get-OemProgramFootprints: what an Apps entry registers that can be looked at' {
    BeforeEach {
        $none = [PSCustomObject]@{ Services = @() }
    }

    It 'finds nothing to look at in a Windows Installer entry that registers no folder, icon file or service' {
        $layer = [PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = '' }
        @(Get-OemProgramFootprints -Layer $layer -Hint $none).Count | Should -Be 0
    }

    It 'counts the install folder, the folder of the uninstaller, the icon file and a service named in the hint, each in its own right' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = 'C:\Program Files\Dell\Prog\uninst.exe'; InstallLocation = 'C:\Program Files\Dell\Prog'; DisplayIcon = 'C:\Program Files\Dell\Prog\prog.exe,0' }
        (@(Get-OemProgramFootprints -Layer $layer -Hint ([PSCustomObject]@{ Services = @('Dell Prog Service') })) -join ',') | Should -BeExactly 'install folder,uninstaller folder,icon file,service'
        (@(Get-OemProgramFootprints -Layer ([PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = '"C:\Program Files\Dell\Prog"'; DisplayIcon = '' }) -Hint $none) -join ',') | Should -BeExactly 'install folder'
        (@(Get-OemProgramFootprints -Layer ([PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = '"C:\Program Files\Dell\Prog\prog.exe",0' }) -Hint $none) -join ',') | Should -BeExactly 'icon file'
        (@(Get-OemProgramFootprints -Layer ([PSCustomObject]@{ Kind = 'Msi'; FilePath = 'msiexec.exe'; InstallLocation = ''; DisplayIcon = '' }) -Hint ([PSCustomObject]@{ Services = @('Dell Prog Service') })) -join ',') | Should -BeExactly 'service'
    }

    It 'does not count an installer cache as a place where the program lives' -ForEach @(
        @{ Path = 'C:\ProgramData\Package Cache\{11111111-1111-1111-1111-111111111111}\setup.exe' }
        @{ Path = 'C:\Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe' }
    ) {
        $layer = [PSCustomObject]@{ Kind = 'Bundle'; FilePath = $Path; InstallLocation = ''; DisplayIcon = '' }
        @(Get-OemProgramFootprints -Layer $layer -Hint $none).Count | Should -Be 0 -Because $Path
    }

    It 'does not count a bare uninstaller name, a Windows-folder icon, or a hint that names no service' {
        $layer = [PSCustomObject]@{ Kind = 'Exe'; FilePath = 'rundll32.exe'; InstallLocation = '.'; DisplayIcon = ($env:SystemRoot + '\Installer\x\icon.ico') }
        @(Get-OemProgramFootprints -Layer $layer -Hint ([PSCustomObject]@{ Services = @('', $null) })).Count | Should -Be 0
    }
}

Describe 'Format-OemNothingToCheck: the sentence for an Apps entry that registers nothing to look at' {
    It 'names the registry key (without the PowerShell provider prefix) so that it can be exported and deleted by hand' {
        $text = Format-OemNothingToCheck -PsPaths @('Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{AAAA}')
        $text | Should -BeLike '*it probably is a dead leftover - if so, delete the key by hand (export it first) (registry key: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{AAAA}), and it is left alone'
        $text | Should -Not -BeLike '*Registry::*'
    }

    It 'names every key of a program with several entries, and skips blank ones' {
        $text = Format-OemNothingToCheck -PsPaths @('HKEY_LOCAL_MACHINE\A\{1}', '', $null, 'HKEY_LOCAL_MACHINE\A\{2}')
        $text | Should -BeLike '*(registry key: HKEY_LOCAL_MACHINE\A\{1}; HKEY_LOCAL_MACHINE\A\{2}), and it is left alone'
    }

    It 'still reads as a sentence when no key is known' {
        $text = Format-OemNothingToCheck
        $text | Should -BeLike 'its Apps entry registers nothing that could show whether the program is still installed*(export it first), and it is left alone'
        $text | Should -Not -BeLike '*registry key:*'
    }
}

Describe 'Get-OemUninstallLayer: a command that starts with a bare program name' {
    AfterEach { if ($script:savedRoot) { $env:SystemRoot = $script:savedRoot; $script:savedRoot = $null } }
    It 'resolves it to the real file (found through PATH), so that it is neither judged against the current directory nor taken for a missing uninstaller' {
        $entry = New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'cmd.exe /c exit 0'
        $layer = Get-OemUninstallLayer -Entry $entry -LogPath (Join-Path $TestDrive 'x.log')
        $layer.Kind | Should -Be 'Exe'
        $layer.FilePath | Should -Be ((Get-Command -Name cmd.exe -CommandType Application | Select-Object -First 1).Source)
        $layer.ArgumentList | Should -Be '/c exit 0'
        Test-Path -LiteralPath $layer.FilePath | Should -BeTrue
    }

    It 'leaves a name that is not on PATH as it is' {
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'oem-no-such-uninstaller-7f3a91.exe /S') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be 'oem-no-such-uninstaller-7f3a91.exe'
    }

    It 'does not take a program from a PATH folder outside the Windows folder (a user may be able to write there)' {
        $planted = New-TestFile 'Tools\oem-planted-uninstaller.exe'
        # (the planted file must not count as being in the Windows folder, which it would if Pester ran as SYSTEM and TEMP lay under C:\WINDOWS)
        $script:savedRoot = $env:SystemRoot
        $env:SystemRoot = 'Z:\OemNoSuchWindowsFolder'
        Mock Get-Command { [PSCustomObject]@{ Name = 'oem-planted-uninstaller.exe'; Source = $planted } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'oem-planted-uninstaller.exe /S') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be 'oem-planted-uninstaller.exe'
        # ... and what is left unresolved is then "cannot be checked from here", never a missing uninstaller to clear
        (@(Get-OemProgramEvidence -Layer $layer -Hint ([PSCustomObject]@{ Services = @() })) -join ' | ') | Should -BeLike '*bare program name (oem-planted-uninstaller.exe)*'
    }

    It 'takes a program from the Windows folder' {
        Mock Get-Command { [PSCustomObject]@{ Name = 'rundll32.exe'; Source = (Join-Path $env:SystemRoot 'System32\rundll32.exe') } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'rundll32.exe some.dll,Uninstall') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\rundll32.exe')
    }

    It 'judges the folder of a PATH program as a canonical path: ".." leads out of the Windows folder, "/" does not' {
        # (a PATH entry written "<Windows>\..\Tools" starts with the Windows folder as a string but is not in it)
        $outside = $env:SystemRoot + '\..\OemEvidTools\oem-planted-uninstaller.exe'
        Mock Get-Command { [PSCustomObject]@{ Name = 'oem-planted-uninstaller.exe'; Source = $outside } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'oem-planted-uninstaller.exe /S') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be 'oem-planted-uninstaller.exe'
        # ... and the Windows folder written with "/" is the Windows folder: the program is taken, in its canonical spelling
        $slashed = ($env:SystemRoot -replace '\\', '/') + '/System32/rundll32.exe'
        Mock Get-Command { [PSCustomObject]@{ Name = 'rundll32.exe'; Source = $slashed } }
        $layer = Get-OemUninstallLayer -Entry (New-TestEntry -Name 'Some Dell Tool' -Key 'K1' -Uninstall 'rundll32.exe some.dll,Uninstall') -LogPath (Join-Path $TestDrive 'x.log')
        $layer.FilePath | Should -Be (Join-Path $env:SystemRoot 'System32\rundll32.exe')
    }
}

Describe 'Remove-OemWin32Product: "not installed" (1605/1614) is proof only when nothing shows the program is still there' {
    AfterEach { if ($script:savedRoot) { $env:SystemRoot = $script:savedRoot; $script:savedRoot = $null } }
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestStaleCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestRuns = New-Object System.Collections.Generic.Queue[object]
        $global:OemTestInstalled = @()
        $global:OemTestWarnCount = 0
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
            $global:OemTestStaleCalls.Add("$PsPath|$Reason")
            $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $_.PSPath -ne $PsPath })
            $true
        }
        # The next queued run is what the "uninstaller" returns; a run marked Removes also takes the product it was started for out of the registry.
        Mock Start-ProcessLowPriority {
            $global:OemTestCalls.Add("$FilePath $ArgumentList")
            $next = $global:OemTestRuns.Dequeue()
            if ($next.Removes) { $global:OemTestInstalled = @($global:OemTestInstalled | Where-Object { $ArgumentList -notlike "*$($_.PSChildName)*" }) }
            $next.Run
        }
    }

    It 'keeps the Apps entry, and says why, when an MSI says "not installed" but the program folder is still there' {
        $folder = Split-Path (New-TestFile 'Program Files\Dell\SupportAssistAgent\agent.dll') -Parent
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location $folder
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'Failed'
        $global:OemTestStaleCalls.Count | Should -Be 0
        @($global:OemTestInstalled).Count | Should -Be 1
        $r.Detail | Should -BeLike '*Msi: exit 1605*'
        $r.Detail | Should -BeLike '*the Msi uninstaller says the product is not installed, yet the program still seems to be installed: the program''s folder still exists*Apps entry is left alone*'
    }

    It 'keeps the Apps entry when an InstallShield wrapper says "not installed" but the product''s service is still there' {
        $wrapper = New-TestFile 'Program Files (x86)\InstallShield Installation Information\{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}\setup.exe'
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell Optimizer*'; services = @('Dell Optimizer Service') })
        Mock Get-Service { [PSCustomObject]@{ Name = 'DellOptimizerSvc'; DisplayName = 'Dell Optimizer Service'; Status = 'Stopped'; StartType = 'Disabled' } }
        $e = New-TestEntry -Name 'Dell Optimizer' -Key '{286A9ADE-A581-43E8-AA85-6F5D58C7DC88}' -Uninstall ('"' + $wrapper + '" -remove')
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'Failed'
        $global:OemTestStaleCalls.Count | Should -Be 0
        $r.Detail | Should -BeLike '*yet the program still seems to be installed: its service ''DellOptimizerSvc'' still exists*'
    }

    It 'clears the dead registration when the only thing left is an EMPTY install folder' {
        $folder = Join-Path $TestDrive 'Program Files\Dell\EmptyLeftover'
        $null = New-Item -ItemType Directory -Path $folder -Force
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location $folder
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'StaleEntryCleared'
        $global:OemTestStaleCalls.Count | Should -Be 1
    }

    It 'clears the dead registration, naming the reason, when nothing shows the program is still there' {
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}' -Location (Join-Path $TestDrive 'gone\Dell\SupportAssistAgent')
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'StaleEntryCleared'
        $global:OemTestStaleCalls.Count | Should -Be 1
        $global:OemTestStaleCalls[0] | Should -BeLike '*|the installer says the product is not installed and nothing it registers (install folder, icon file, service) shows it is still there'
    }

    It 'keeps and reports an entry that registers nothing that could be looked at - "nothing found" would mean nothing - and names its registry key' {
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'Failed'
        $global:OemTestStaleCalls.Count | Should -Be 0
        @($global:OemTestInstalled).Count | Should -Be 1
        $r.Detail | Should -BeLike '*Msi: exit 1605*'
        $r.Detail | Should -BeLike '*the Msi uninstaller says the product is not installed, but its Apps entry registers nothing that could show whether the program is still installed*(registry key: HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{65043213-393F-49BF-B658-5B06C5F713FF}), and it is left alone*'
    }

    It 'treats an icon in the Windows folder (the installer cache) as nothing to look at' {
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $e | Add-Member -NotePropertyName DisplayIcon -NotePropertyValue ($env:SystemRoot + '\Installer\{65043213-393F-49BF-B658-5B06C5F713FF}\app.ico,0') -Force
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'Failed'
        $global:OemTestStaleCalls.Count | Should -Be 0
    }

    It 'clears it when the one place the entry registers is an icon file in a program folder, and that file is gone' {
        # (the icon file lies in $TestDrive, which is under the Windows folder when Pester runs as SYSTEM; icons in the Windows folder do not count)
        $script:savedRoot = $env:SystemRoot
        $env:SystemRoot = 'Z:\OemNoSuchWindowsFolder'
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $e | Add-Member -NotePropertyName DisplayIcon -NotePropertyValue ('"' + (Join-Path $TestDrive 'gone\Dell\SupportAssist\app.exe') + '",0') -Force
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'StaleEntryCleared'
        $global:OemTestStaleCalls.Count | Should -Be 1
    }

    It 'clears it when the one place the entry registers is a service named in the product hint, and that service is not there' {
        $OemProductHints = @([PSCustomObject]@{ match = 'Dell SupportAssist*'; services = @('SupportAssistAgent') })
        $e = New-TestEntry -Name 'Dell SupportAssist' -Key '{65043213-393F-49BF-B658-5B06C5F713FF}' -Uninstall 'MsiExec.exe /X{65043213-393F-49BF-B658-5B06C5F713FF}'
        $global:OemTestInstalled = @($e)
        Add-TestRun (New-TestRun -ExitCode 1605)
        $r = Remove-OemWin32Product -Product (New-TestProduct @($e))
        $r.Status | Should -Be 'StaleEntryCleared'
        $global:OemTestStaleCalls.Count | Should -Be 1
    }

    It 'does not delete the Apps entry of a layer that was not listed for a moment and is listed again by the time the entries are judged' {
        # (B is not in the registry at first, so it has nothing to run; it is registered again before the judgement. "Not listed" is not
        # "its uninstaller file is gone": B is a live entry again and must not be taken for a leftover.)
        $place = Join-Path $TestDrive 'gone\Dell Foo'
        $a = New-TestEntry -Name 'Dell Foo' -Key '{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA}' -Location $place
        $b = New-TestEntry -Name 'Dell Foo' -Key '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}' -Location $place
        $global:OemTestBack = $b
        $global:OemTestInstalled = @($a)
        Mock Wait-OemProductGone { $global:OemTestInstalled = @($global:OemTestInstalled) + @($global:OemTestBack); $false }
        Add-TestRun (New-TestRun -ExitCode 1603)       # A fails
        Add-TestRun (New-TestRun -ExitCode 0)          # A says "success" in the second pass (its entry stays); B is registered again meanwhile
        $r = Remove-OemWin32Product -Product (New-TestProduct @($b, $a))
        $r.Status | Should -Be 'Failed'
        $global:OemTestRuns.Count | Should -Be 0
        $global:OemTestStaleCalls.Count | Should -Be 0
        @($global:OemTestInstalled | Where-Object { $_.PSChildName -eq '{BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB}' }).Count | Should -Be 1
        Remove-Variable -Name OemTestBack -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'Remove-OemBloatware: a note about a layer survives the second look at the program' {
    BeforeEach {
        $global:OemTestLog = New-Object System.Collections.Generic.List[string]
        $global:OemTestCalls = New-Object System.Collections.Generic.List[string]
        $global:OemTestStaleCalls = New-Object System.Collections.Generic.List[string]
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

    It 'keeps what the first look said about a layer that answered "not installed", and counts every try of the other layer in both looks' {
        $folder = Split-Path (New-TestFile 'Program Files\Dell\Dell A One\a.dll') -Parent
        $exe = New-TestFile 'Program Files\Dell\Dell A One\uninstall.exe'
        $a1 = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}' -Location $folder
        $a2 = New-TestEntry -Name 'Dell A One' -Key 'DellAOne' -Uninstall ('"' + $exe + '" /S')
        $b = New-TestEntry -Name 'Dell B Two' -Key '{BBBBBBBB-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{BBBBBBBB-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a1, $a2, $b)
        Add-TestRun (New-TestRun -ExitCode 1605)                        # A, MSI: not installed (yet its folder is there)
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, EXE: fails
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, EXE: fails again in the second pass
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true            # B: removed, which gives A its second look
        Add-TestRun (New-TestRun -ExitCode 1603)                        # A, EXE: fails a third time in the second look
        Remove-OemBloatware
        $global:OemTestRuns.Count | Should -Be 0
        $line = @($global:OemTestLog | Where-Object { $_ -like '*NOT REMOVED: ''Dell A One''*' })
        $line.Count | Should -Be 1
        $line[0] | Should -BeLike '*Msi: exit 1605*'
        $line[0] | Should -BeLike '*Exe: exit 1603 (fatal error during the uninstall) (tried 3 times)*'
        $line[0] | Should -BeLike '*the Msi uninstaller says the product is not installed, yet the program still seems to be installed*'
        $global:OemTestLog -join "`n" | Should -BeLike '*programs: 1 removed, 1 NOT removed*'
    }

    It 'says that nothing is left, and what the warning count means, when a first attempt failed and a later one worked' {
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a)
        Add-TestRun (New-TestRun -ExitCode 1603)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        Remove-OemBloatware
        $text = $global:OemTestLog -join "`n"
        $text | Should -BeLike '*programs: 1 removed, 0 NOT removed*'
        $text | Should -BeLike '*Nothing that was targeted is left. The 1 warning line(s) above are failed first attempts, refusals and notices; the finish banner counts warning lines, not programs.*'
    }

    It 'does not say it when the run raised no warning at all' {
        $a = New-TestEntry -Name 'Dell A One' -Key '{AAAAAAAA-1111-2222-3333-444444444444}' -Uninstall 'MsiExec.exe /X{AAAAAAAA-1111-2222-3333-444444444444}'
        $global:OemTestInstalled = @($a)
        Add-TestRun (New-TestRun -ExitCode 0) -Removes $true
        Remove-OemBloatware
        $global:OemTestLog -join "`n" | Should -Not -BeLike '*Nothing that was targeted is left*'
    }
}

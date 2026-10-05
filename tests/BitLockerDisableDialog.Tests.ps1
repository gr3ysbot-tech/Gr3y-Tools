# Pester tests that run the REAL "Disable BitLocker" window (Show-BitLockerDisableDialog from Gr3ysUtilities.ps1)
# with stand-in BitLocker commands and a stand-in message box, and press its buttons. They check what the dialog
# really does: nothing is decrypted without a checked backup and a Yes, only ticked drives are touched, the backup
# is re-checked right before each drive, no key reaches a status line, message box or log. The window is never
# shown on screen. Needs an STA session (Windows PowerShell 5.1, which CI uses); skipped elsewhere. ASCII only.
# BitLocker, disk and registry commands are ALL stood in for here - nothing real is read or changed.

BeforeDiscovery {
    # needs an STA thread and a session in which a WPF window can be created (it is never shown)
    $script:canRunWindow = $false
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA') {
        try {
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml -ErrorAction Stop
            $null = New-Object System.Windows.Window
            $script:canRunWindow = $true
        } catch { $script:canRunWindow = $false }
    }
    # CI must really run these tests: a runner that cannot (no STA thread, no WPF) fails here instead of skipping them silently
    if (-not $script:canRunWindow -and $env:CI) { throw 'The Disable BitLocker dialog tests need an STA session with WPF (Windows PowerShell 5.1) and CI must not skip them.' }
}

Describe 'Disable BitLocker dialog (real window, stand-in BitLocker)' -Skip:(-not $script:canRunWindow) {
    BeforeAll {
        # every function that exists before this file defines its own: the cleanup test at the end of the file checks that nothing else is left
        $global:BlFnSnapshot = @(Get-ChildItem -Path function: | ForEach-Object { $_.Name })
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
        $repo = Split-Path -Parent $PSScriptRoot
        $gui = Join-Path $repo 'debloat/Gr3ysUtilities.ps1'
        . (Join-Path $repo 'tests/TestHelpers.ps1')

        if (-not ('BlTestMsgBox' -as [type])) {
            Add-Type -TypeDefinition @'
public static class BlTestMsgBox {
    public static System.Func<string, string, string, string, string> Handler;
    public static System.Collections.Generic.List<string> Log = new System.Collections.Generic.List<string>();
    public static string Show(object owner, string text, string caption, string button, string icon, string defaultResult) {
        Log.Add(caption + " | buttons=" + button + " | icon=" + icon + " | default=" + defaultResult + " | " + text.Replace("\r\n", " // "));
        if (Handler == null) throw new System.InvalidOperationException("BlTestMsgBox: no handler set");
        return Handler(text, caption, button, defaultResult);
    }
}
'@
        }

        # the real code under test (nothing else in the script is run)
        # Closures made by the window (GetNewClosure) look functions up in the GLOBAL scope only, so the real code and the
        # stand-ins are defined there for the duration of this file and removed again in AfterAll.
        # Get-BitLockerBackupPlaceNote is loaded under another name: the dialog calls a stand-in (no note by default, because
        # TestDrive sits on the system drive, which the stand-in volumes say is encrypted) that hands over to the real one when
        # a test sets BlFake.RealPlaceNote.
        $script:globalFns = New-Object System.Collections.Generic.List[string]
        foreach ($fn in 'Get-BitLockerPropertyText', 'ConvertTo-BitLockerVolumeDetail', 'Get-BitLockerVolumeDetail', 'Get-BitLockerStateText', 'Get-BitLockerDisableState',
            'Get-BitLockerProtectorSummary', 'Get-BitLockerKeyIds', 'Test-BitLockerKeysCovered', 'Get-BitLockerMountsWithoutRecoveryPassword', 'New-BitLockerBackupText',
            'Test-BitLockerRecoveryPasswordFormat', 'Test-BitLockerBackupText', 'Get-BitLockerBackupPlaceNote', 'Get-BitLockerDefaultBackupFolder', 'Test-BitLockerBackupPath',
            'Test-BitLockerBackupStillGood', 'Get-BitLockerVolumeIdMap', 'Get-BitLockerDriveIdentity', 'Test-BitLockerSameDrive', 'Get-RunningToolJobs', 'Get-BitLockerPathFileSystem', 'Save-BitLockerBackupFile', 'Get-BitLockerRawOutput', 'Get-BitLockerAuditFolder',
            'Write-BitLockerActionLog', 'Get-BitLockerFriendlyError', 'Clear-BitLockerStoredAutoUnlock', 'Start-BitLockerDecrypt', 'Add-BitLockerRecoveryProtector',
            'Get-BitLockerDecryptOrder', 'Get-BitLockerAutoUnlockAffected', 'Get-BitLockerElapsedText', 'Get-BitLockerProgressText', 'Get-BitLockerTypeText', 'Get-SafeFileNamePart') {
            $src = Get-FunctionSource -ScriptPath $gui -FunctionName $fn
            if ($fn -eq 'Get-RunningToolJobs') { $src = $src.Replace('$script:', '$global:') }    # the job variables live in the global scope in this test
            if (-not $src.StartsWith("function $fn ")) { throw "unexpected source start for $fn" }
            $loadAs = $(if ($fn -eq 'Get-BitLockerBackupPlaceNote') { 'Get-RealBitLockerBackupPlaceNote' } else { $fn })
            . ([scriptblock]::Create($src.Replace("function $fn ", "function global:$loadAs ")))
            $script:globalFns.Add($loadAs)
        }
        $dlgSrc = Get-FunctionSource -ScriptPath $gui -FunctionName 'Show-BitLockerDisableDialog'
        foreach ($anchor in '[System.Windows.MessageBox]::Show(', '$dialog.ShowDialog() | Out-Null') { if (-not $dlgSrc.Contains($anchor)) { throw "anchor not found: $anchor" } }
        $dlgSrc = $dlgSrc.Replace('[System.Windows.MessageBox]::Show(', '[BlTestMsgBox]::Show(')
        $dlgSrc = $dlgSrc.Replace('$dialog.ShowDialog() | Out-Null', @'
$global:BlT = @{ Dialog = $dialog; State = $state; PathBox = $pathBox; Status = $statusText; ChkAdd = $chkAddRecovery; ChkPrev = $chkPrevent; Backup = $btnBackup; Disable = $btnDisable; Refresh = $btnRefresh; Timer = $timer; RowsPanel = $rowsPanel }
& $global:BlDriver
'@)
        . ([scriptblock]::Create($dlgSrc.Replace('function Show-BitLockerDisableDialog ', 'function global:Show-BitLockerDisableDialog ')))
        $script:globalFns.Add('Show-BitLockerDisableDialog')
        $global:window = $null

        # --- stand-ins: BitLocker, the registry setting, the machine facts and the drive lookups ---
        $global:BlFake = $null
        function global:Get-BitLockerVolume {
            [CmdletBinding()] param([string]$MountPoint)
            $global:BlFake.GetCalls++
            if ($global:BlFake.GetThrows) { throw $global:BlFake.GetThrows }
            if ($global:BlFake.WriteError) { Write-Error $global:BlFake.WriteError }
            # something happens at the instant ONE drive is read (the read Start-BitLockerDecrypt makes right before it asks Windows)
            if ($MountPoint -and $global:BlFake.OnSingleRead) { & $global:BlFake.OnSingleRead }
            $all = @($global:BlFake.Volumes)
            # a read plan answers the next reads one by one: 'err' = a read error and the drive named in PlanDrop missing from that read
            if ($global:BlFake.Plan -and $global:BlFake.Plan.Count -gt 0 -and -not $MountPoint) {
                $step = $global:BlFake.Plan.Dequeue()
                if ($step -eq 'err') { Write-Error 'stand-in: BitLocker could not read a volume just now'; $all = @($all | Where-Object { $_.MountPoint -ne $global:BlFake.PlanDrop }) }
            }
            if ($MountPoint) { return @($all | Where-Object { $_.MountPoint -eq $MountPoint }) }
            return $all
        }
        # the Storage module's Get-Volume: only what a test puts in BlFake.VolumeIds (letter -> volume ID), never this PC's volumes
        function global:Get-Volume {
            [CmdletBinding()] param()
            if ($global:BlFake.VolumeThrows) { throw $global:BlFake.VolumeThrows }
            foreach ($k in @($global:BlFake.VolumeIds.Keys)) { [pscustomobject]@{ DriveLetter = [char]([string]$k)[0]; UniqueId = [string]$global:BlFake.VolumeIds[$k] } }
        }
        function global:Disable-BitLocker {
            [CmdletBinding()] param([string]$MountPoint)
            $global:BlFake.DisableCalls.Add($MountPoint)
            if ($global:BlFake.DisableThrows -and (-not $global:BlFake.DisableThrowsFor -or $global:BlFake.DisableThrowsFor -eq $MountPoint)) { throw $global:BlFake.DisableThrows }
            $v = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq $MountPoint })[0]
            if ($v) { $v.VolumeStatus = 'DecryptionInProgress'; $v.ProtectionStatus = 'Off'; $v.EncryptionPercentage = 99 }
        }
        function global:Add-BitLockerKeyProtector {
            [CmdletBinding()] param([string]$MountPoint, [switch]$RecoveryPasswordProtector)
            $global:BlFake.AddCalls.Add($MountPoint)
            if ($global:BlFake.AddThrowsFor -and $global:BlFake.AddThrowsFor -eq $MountPoint) { throw 'stand-in: BitLocker refused to add the protector' }
            Write-Warning "A new recovery password was created: $($script:addedPw)"
            $v = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq $MountPoint })[0]
            if ($v) { $v.KeyProtector = @($v.KeyProtector) + @(New-Prot 'RecoveryPassword' '{ADDED000-0000-0000-0000-000000000001}' $script:addedPw) }
            if ($global:BlFake.AfterAdd) { & $global:BlFake.AfterAdd }      # something else happens right after a protector was added (a test's hook)
        }
        function global:Clear-BitLockerAutoUnlock {
            [CmdletBinding()] param()
            $global:BlFake.ClearCalls++
            $global:BlFake.CallLog.Add('clear-auto-unlock')
            foreach ($v in @($global:BlFake.Volumes)) { $v.AutoUnlockKeyStored = $false }
        }
        function global:manage-bde { if ($args -contains '-status') { return 'FAKE STATUS' }; return "FAKE PROTECTORS FOR $($args[-1])" }
        function global:Get-Tpm { [pscustomobject]@{ TpmPresent = $true; TpmReady = $true; TpmEnabled = $true } }
        function global:Get-PreventDeviceEncryptionValue { param([string]$Path) return $global:BlFake.PreventValue }
        function global:Set-PreventDeviceEncryption { param([string]$Path) $global:BlFake.PreventCalls++; $global:BlFake.CallLog.Add('prevent'); return [pscustomobject]@{ Ok = $global:BlFake.PreventOk; Error = $(if ($global:BlFake.PreventOk) { $null } else { 'stand-in: registry write refused' }); AlreadySet = $false } }
        function global:Get-BitLockerDecryptWarnings { return @($global:BlFake.Warnings) }
        function global:Get-BitLockerBackupSystemInfo { [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'TESTPC\tester'; Date = '2026-10-04 12:00:00'; Os = 'Windows 11 Pro'; Machine = 'Acme Box, serial SER123'; Tpm = 'present=True' } }
        function global:Get-MachineTag { return 'TESTPC_Acme' }
        function global:Get-BitLockerDriveDescription { param([string]$MountPoint) return [pscustomobject]@{ Kind = 'Fixed'; Label = $(if ($global:BlFake.Labels -and $global:BlFake.Labels[$MountPoint]) { [string]$global:BlFake.Labels[$MountPoint] } else { '' }) } }
        function global:Get-BitLockerBackupPlaceNote {
            param([string]$Path, $Volumes, [string[]]$Mounts, [string[]]$CloudRoots)
            if ($global:BlFake.RealPlaceNote) { return (Get-RealBitLockerBackupPlaceNote -Path $Path -Volumes $Volumes -Mounts $Mounts -CloudRoots $CloudRoots) }
            return [string]$global:BlFake.PlaceNote
        }

        function global:New-Prot([string]$Type, [string]$Id, [string]$Password) {
            $o = [pscustomobject]@{ KeyProtectorType = $Type; KeyProtectorId = $Id; AutoUnlockProtector = $false }
            if ($Password) { $o | Add-Member -NotePropertyName RecoveryPassword -NotePropertyValue $Password }
            return $o
        }
        function global:New-Vol([string]$Mount, [string]$Type, [string]$Status, [string]$Prot, [string]$Lock, [int]$Pct, $Protectors, [bool]$AutoStored = $false, $AutoOn = $false) {
            return [pscustomobject]@{ MountPoint = $Mount; VolumeType = $Type; ProtectionStatus = $Prot; VolumeStatus = $Status; LockStatus = $Lock; EncryptionMethod = 'XtsAes256'; EncryptionPercentage = $Pct; CapacityGB = 931.5; AutoUnlockEnabled = $AutoOn; AutoUnlockKeyStored = $AutoStored; KeyProtector = $Protectors }
        }
        $script:pwC = '000011-000022-000033-000044-000055-000066-000077-000088'     # clearly synthetic (each group is a multiple of 11, so it passes the format check)
        $script:pwD = '111111-222222-333333-444444-555555-666666-707707-000011'
        $script:pwNew = '011000-022000-033000-044000-055000-066000-077000-088000'
        $script:addedPw = '123420-234520-345620-456720-567820-678920-691020-703120'
        $script:idTpm = '{AAAAAAAA-0000-0000-0000-000000000001}'
        $script:idRecC = '{D8542C81-40F6-45DC-9E68-8594BB27FC34}'
        $script:idRecD = '{DDDD0000-40F6-45DC-9E68-8594BB27FC35}'
        function global:Get-StdVolumes { return @(
            (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null), (New-Prot 'RecoveryPassword' $script:idRecC $script:pwC))),
            (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD))),
            (New-Vol 'E:' 'Data' 'FullyEncrypted' 'On' 'Locked' 100 @((New-Prot 'Password' '{EEEEEEEE-0000-0000-0000-000000000005}' $null))),
            (New-Vol 'F:' 'Data' 'FullyDecrypted' 'Off' 'Unlocked' 0 @())
        ) }

        # --- helpers that drive the window ---
        function global:Reset-Fake {
            $global:BlFake = @{ Volumes = @(); GetThrows = $null; WriteError = $null; GetCalls = 0; DisableCalls = (New-Object System.Collections.Generic.List[string]); DisableThrows = $null
                AddCalls = (New-Object System.Collections.Generic.List[string]); ClearCalls = 0; CallLog = (New-Object System.Collections.Generic.List[string])
                PreventCalls = 0; PreventValue = $null; PreventOk = $true; Warnings = @(); PlaceNote = ''; RealPlaceNote = $false; Labels = @{}
                Plan = $null; PlanDrop = ''; DisableThrowsFor = ''; AddThrowsFor = ''; AfterAdd = $null; OnSingleRead = $null; VolumeIds = @{}; VolumeThrows = $null }
            [BlTestMsgBox]::Log.Clear(); [BlTestMsgBox]::Handler = $null
            $global:deployProc = $null; $global:fixProc = $null; $global:installProc = $null; $global:provisionProc = $null; $global:wingetInstallProc = $null
            $global:BlOut = $null
            # every test starts with an empty action log (it is one shared file; a line an earlier test wrote must not decide a later test)
            $logPath = Get-ActionLogPath
            if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }
            $Error.Clear()
        }
        function Set-Answer([string]$Answer, [scriptblock]$Before = $null) {
            # globals, because the delegate below is called from C# and must not depend on scope lookups
            $global:BlAnswer = $Answer; $global:BlBeforeAnswer = $Before
            [BlTestMsgBox]::Handler = [System.Func[string, string, string, string, string]]{ param($t, $c, $b, $d) if ($global:BlBeforeAnswer) { & $global:BlBeforeAnswer }; return $global:BlAnswer }
        }
        # the window's 5 s timer is stopped when the driver is done: a dialog that is never shown is never closed, and a timer left
        # running would tick during later tests, against THEIR stand-in volumes and into the shared action log
        function global:Invoke-Dialog { param([scriptblock]$Driver) $global:BlDriver = $Driver; try { Show-BitLockerDisableDialog } finally { if ($global:BlT -and $global:BlT.Timer) { $global:BlT.Timer.Stop() } } }
        function Raise-Click($Button, [switch]$Force) {
            if (-not $Button.IsEnabled -and -not $Force) { throw "the button '$($Button.Content)' is disabled - a person could not press it" }
            $Button.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Primitives.ButtonBase]::ClickEvent, $Button)))
        }
        function Raise-Loaded($Dialog) { $Dialog.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.FrameworkElement]::LoadedEvent, $Dialog))) }
        function Set-Tick($T, [string]$Mount, [bool]$On = $true) { ($T.State.Rows | Where-Object { $_.Mount -eq $Mount }).CheckBox.IsChecked = $On }
        function Get-Rows($T) { return @($T.State.Rows | ForEach-Object { '{0}(can={1},tick={2})' -f $_.Mount, $_.CanDisable, $_.CheckBox.IsChecked }) -join ' ' }
        function Pump([int]$Ms = 120) {
            $frame = New-Object System.Windows.Threading.DispatcherFrame
            $t = New-Object System.Windows.Threading.DispatcherTimer
            $t.Interval = [TimeSpan]::FromMilliseconds($Ms)
            $t.Add_Tick({ $t.Stop(); $frame.Continue = $false }.GetNewClosure())
            $t.Start()
            [System.Windows.Threading.Dispatcher]::PushFrame($frame)
        }
        # runs the window's message loop until the condition holds (a timer tick, a handler) - never a fixed wait, which a loaded CI machine can miss.
        # A condition that never comes true is a failure of its own, not a silent pass: the assertions after a wait would often be true anyway.
        function Wait-Until([scriptblock]$Condition, [int]$TimeoutMs = 10000) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
            while ([DateTime]::UtcNow -lt $deadline) {
                if (& $Condition) { return $true }
                Pump 40
            }
            if (& $Condition) { return $true }
            throw "Wait-Until: gave up after $TimeoutMs ms waiting for { $($Condition.ToString().Trim()) }"
        }
        # every piece of text a window shows (text blocks and check box labels), to pin wording that has no name of its own
        function Get-WindowText($Element) {
            $texts = New-Object System.Collections.Generic.List[string]
            $walk = $null
            $walk = {
                param($e)
                if ($e -is [System.Windows.Controls.TextBlock]) { $texts.Add([string]$e.Text) }
                if ($e -is [System.Windows.DependencyObject]) { foreach ($c in [System.Windows.LogicalTreeHelper]::GetChildren($e)) { if ($c -is [System.Windows.DependencyObject]) { & $walk $c } } }
            }
            & $walk $Element
            return ($texts -join "`n")
        }
        function global:Get-ActionLogPath {
            $dir = Get-BitLockerAuditFolder
            if (-not $dir) { $dir = $global:workDir }
            return (Join-Path $dir 'bitlocker-actions.log')
        }
        function global:Get-ActionLogText {
            $p = Get-ActionLogPath
            if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) }
            return ''
        }
        function Get-BackupPath([string]$Name) { return (Join-Path $TestDrive $Name) }

        # the action log goes to a throw-away place, never to this PC's real audit folder
        $script:oldProgramData = $env:ProgramData
        $env:ProgramData = Join-Path $TestDrive 'ProgramData'
        New-Item -ItemType Directory -Path $env:ProgramData -Force | Out-Null
        $global:workDir = Join-Path $TestDrive 'work'
        New-Item -ItemType Directory -Path $global:workDir -Force | Out-Null
    }

    AfterAll {
        $env:ProgramData = $script:oldProgramData
        # Remove-Item 'function:global:Name' reports success and removes NOTHING; 'function:Name' does remove it (checked below)
        $names = @($script:globalFns) + @('Get-BitLockerVolume', 'Get-Volume', 'Disable-BitLocker', 'Add-BitLockerKeyProtector', 'Clear-BitLockerAutoUnlock', 'manage-bde', 'Get-Tpm', 'Get-PreventDeviceEncryptionValue', 'Set-PreventDeviceEncryption', 'Get-BitLockerDecryptWarnings', 'Get-BitLockerBackupSystemInfo', 'Get-MachineTag', 'Get-BitLockerDriveDescription', 'Get-BitLockerBackupPlaceNote', 'New-Prot', 'New-Vol', 'Get-StdVolumes', 'Reset-Fake', 'Invoke-Dialog', 'Get-ActionLogText', 'Get-ActionLogPath')
        foreach ($n in $names) {
            if (Test-Path -LiteralPath ('function:' + $n)) { Remove-Item -LiteralPath ('function:' + $n) -Force }
        }
        Remove-Variable -Name BlT, BlDriver, BlOut, BlFake, BlAnswer, BlBeforeAnswer, workDir, window, deployProc, fixProc, installProc, provisionProc, wingetInstallProc -Scope Global -ErrorAction SilentlyContinue
    }

    BeforeEach { Reset-Fake }

    Context 'what the window shows and what it lets you press' {
        It 'lists every drive, ticks nothing for you and keeps button 2 off until a backup exists' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $global:BlOut = @{ Rows = (Get-Rows $T); Backup = $T.Backup.IsEnabled; Disable = $T.Disable.IsEnabled; Prevent = $T.ChkPrev.IsEnabled }
            }
            $global:BlOut.Rows | Should -Be 'C:(can=True,tick=False) D:(can=True,tick=False) E:(can=False,tick=False) F:(can=False,tick=False)'
            $global:BlOut.Disable | Should -BeFalse
            $global:BlOut.Backup | Should -BeTrue
        }

        It 'does not tick a lone eligible drive either (the person chooses)' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC))))
            Invoke-Dialog { $T = $global:BlT; Raise-Loaded $T.Dialog; $global:BlOut = @{ Rows = (Get-Rows $T) } }
            $global:BlOut.Rows | Should -Be 'C:(can=True,tick=False)'
        }

        It 'keeps the person''s ticks when the list is refreshed' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'
                Raise-Click $T.Refresh
                $global:BlOut = @{ Rows = (Get-Rows $T) }
            }
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=True\)'
            $global:BlOut.Rows | Should -Match 'C:\(can=True,tick=False\)'
        }

        It 'lists what it can read and says that some volumes could not be read' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.WriteError = 'Volume G: could not be read (stand-in)'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $global:BlOut = @{ Rows = (Get-Rows $T); Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.Rows | Should -Match 'C:\(can=True'
            $global:BlOut.Status | Should -Match 'could not read some volumes, so they are not listed: Volume G: could not be read'
            $global:BlOut.Color | Should -Be '#FFD29922'
        }

        It 'says why BitLocker cannot be read, and offers nothing' {
            $global:BlFake.GetThrows = 'The term Get-BitLockerVolume is not recognized'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $global:BlOut = @{ Status = $T.Status.Text; Backup = $T.Backup.IsEnabled; Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.Status | Should -Match 'Could not read BitLocker status'
            $global:BlOut.Backup | Should -BeFalse
            $global:BlOut.Disable | Should -BeFalse
        }
    }

    Context 'the happy path' {
        It 'backs up, asks (default No), decrypts only the ticked drive, and leaks no key anywhere' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'happy.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'
                $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $afterBackup = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text; Disable = $T.Disable.IsEnabled }
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterBackup = $afterBackup; Status = $T.Status.Text; Rows = (Get-Rows $T); TimerOn = $T.Timer.IsEnabled }
            }
            $global:BlOut.AfterBackup.Ok | Should -BeTrue
            $global:BlOut.AfterBackup.Disable | Should -BeTrue
            Test-Path -LiteralPath $path | Should -BeTrue
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Status | Should -Match 'Decryption started for C:'
            $global:BlOut.Status | Should -Match 'Do not delete the backup file yet, and do not unplug a removable drive'
            $global:BlOut.Status | Should -Match 'It continues in the background even if you close this window'
            $global:BlOut.TimerOn | Should -BeTrue
            # the confirmation: owned warning, defaults to No, names the drive and the backup
            $box = @([BlTestMsgBox]::Log)[-1]
            $box | Should -Match 'icon=Warning \| default=No'
            $box | Should -Match 'Decrypt these drives now'
            $box | Should -Match 'C: '
            # no key in any status line, message box, log or error record; only the backup file holds them
            $hay = (@($global:BlOut.AfterBackup.Status, $global:BlOut.Status) + @([BlTestMsgBox]::Log) + @(Get-ActionLogText) + @($Error | ForEach-Object { $_ | Out-String })) -join "`n"
            $hay.Contains($script:pwC) | Should -BeFalse
            $hay.Contains($script:pwD) | Should -BeFalse
            $hay | Should -Not -Match '\d{6}-\d{6}-\d{6}-\d{6}'
            $file = Get-Content -LiteralPath $path -Raw
            $file.Contains($script:pwC) | Should -BeTrue
            $file.Contains($script:pwD) | Should -BeTrue
            (Get-ActionLogText) | Should -Match 'Decryption started: C:'
        }

        It 'does nothing at all when the person answers No' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'No'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'no.txt')
                Raise-Click $T.Backup
                Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlFake.PreventCalls | Should -Be 0
            $global:BlFake.ClearCalls | Should -Be 0
            $global:BlOut.Status | Should -Match 'Cancelled'
        }

        It 'decrypts data drives first and the Windows drive last' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'order.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:,C:'
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'data drives first'
        }

        It 'only ever touches a drive that is ticked AND eligible (a ticked locked or decrypted drive is ignored)' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                foreach ($r in $T.State.Rows) { $r.CheckBox.IsChecked = $true }     # even the disabled boxes, programmatically
                $T.PathBox.Text = (Get-BackupPath 'ticked.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            (@($global:BlFake.DisableCalls) | Sort-Object) -join ',' | Should -Be 'C:,D:'
            # the locked and the decrypted drive are not even offered in the confirmation or reported as 'not started'
            @([BlTestMsgBox]::Log)[-1] | Should -Not -Match '  [EF]: '
            $global:BlOut.Status | Should -Not -Match 'Not started'
        }

        It 'does not pre-tick another drive after the first decrypt starts, and keeps button 2 off' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'after.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Rows = (Get-Rows $T); Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Disable | Should -BeFalse
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
        }

        It 'tells Windows not to re-encrypt only after the Windows drive really started, and only when it was ticked' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'prevent-data.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $global:BlFake.PreventCalls | Should -Be 0
            Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes; Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'prevent-os.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $global:BlFake.PreventCalls | Should -Be 1
            @($global:BlFake.CallLog) -join ',' | Should -Be 'prevent'
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
        }

        It 'does not touch the setting when decrypting the Windows drive failed, and says so' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.DisableThrows = 'This drive is locked by BitLocker Drive Encryption. You must unlock this drive from Control Panel. (Exception from HRESULT: 0x80310000)'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'fail.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.PreventCalls | Should -Be 0
            $global:BlOut.Status | Should -Match 'Nothing was started'
            $global:BlOut.Status | Should -Match 'Unlock it first'
        }

        It 'leaves the registry setting alone (and the box greyed) when this PC already has it' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.PreventValue = 1
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $global:BlOut = @{ Enabled = $T.ChkPrev.IsEnabled; Checked = $T.ChkPrev.IsChecked }
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'prevent-set.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $global:BlOut.Enabled | Should -BeFalse
            $global:BlOut.Checked | Should -BeFalse
            $global:BlFake.PreventCalls | Should -Be 0
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
        }
    }

    Context 'the gates before anything is decrypted' {
        It 'refuses a forced press of button 2 when there is no backup' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'
                $global:BlOut = @{ Enabled = $T.Disable.IsEnabled }
                Raise-Click $T.Disable -Force
                $global:BlOut.Status = $T.Status.Text
            }
            $global:BlOut.Enabled | Should -BeFalse
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'Press button 1 first'
            @([BlTestMsgBox]::Log).Count | Should -Be 0
        }

        It 'refuses when the backup file is edited, or deleted, before button 2 is pressed' {
            foreach ($mutation in 'edit', 'delete') {
                Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes; Set-Answer 'Yes'
                $path = Get-BackupPath "gate-$mutation.txt"
                $script:gatePath = $path; $script:gateMutation = $mutation
                Invoke-Dialog {
                    $T = $global:BlT; Raise-Loaded $T.Dialog
                    Set-Tick $T 'C:'; $T.PathBox.Text = $script:gatePath
                    Raise-Click $T.Backup
                    if ($script:gateMutation -eq 'edit') { Add-Content -LiteralPath $script:gatePath -Value 'tampered' -Encoding ASCII } else { Remove-Item -LiteralPath $script:gatePath -Force }
                    Raise-Click $T.Disable
                    $global:BlOut = @{ Status = $T.Status.Text; BackupOk = $T.State.BackupOk }
                }
                $global:BlFake.DisableCalls.Count | Should -Be 0 -Because $mutation
                $global:BlOut.BackupOk | Should -BeFalse -Because $mutation
                @([BlTestMsgBox]::Log).Count | Should -Be 0 -Because "no confirmation should be asked for a backup that is already stale ($mutation)"
            }
        }

        It 'refuses when a new key protector appears before button 2 is pressed' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'newkey-before.txt')
                Raise-Click $T.Backup
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.KeyProtector = @($c.KeyProtector) + @(New-Prot 'RecoveryPassword' '{NEWKEY00-0000-0000-0000-000000000009}' $script:pwNew)
                Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'keys on this PC have changed'
            @([BlTestMsgBox]::Log).Count | Should -Be 0
        }

        It 'catches a change made WHILE the confirmation box is open: backup deleted, key added, drive swapped' {
            $cases = @(
                @{ Name = 'backup deleted'; Do = { Remove-Item -LiteralPath $script:gatePath -Force } },
                @{ Name = 'key added'; Do = { $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]; $c.KeyProtector = @($c.KeyProtector) + @(New-Prot 'RecoveryPassword' '{NEWKEY00-0000-0000-0000-000000000009}' $script:pwNew) } },
                @{ Name = 'drive swapped'; Do = { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{SWAPPED0-0000-0000-0000-00000000000D}' $script:pwNew) } }
            )
            foreach ($case in $cases) {
                Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes
                $script:gatePath = Get-BackupPath ("while-open-" + ($case.Name -replace ' ', '-') + '.txt')
                Set-Answer 'Yes' $case.Do
                Invoke-Dialog {
                    $T = $global:BlT; Raise-Loaded $T.Dialog
                    Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = $script:gatePath
                    Raise-Click $T.Backup; Raise-Click $T.Disable
                    $global:BlOut = @{ Status = $T.Status.Text }
                }
                $global:BlFake.DisableCalls.Count | Should -Be 0 -Because $case.Name
                $global:BlFake.PreventCalls | Should -Be 0 -Because $case.Name
                $global:BlOut.Status | Should -Match 'Not started' -Because $case.Name
            }
        }

        It 'refuses a drive whose keys changed after the confirmation even when the backup still covers them, and goes on with the others' {
            $global:BlFake.Volumes = Get-StdVolumes
            $script:gatePath = Get-BackupPath 'reduced-keys.txt'
            # C: loses a protector while the box is open: the backup still covers every key, but it is no longer the drive that was confirmed
            Set-Answer 'Yes' { $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]; $c.KeyProtector = @($c.KeyProtector | Where-Object { $_.KeyProtectorType -ne 'Tpm' }) }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = $script:gatePath
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:'
            $global:BlOut.Status | Should -Match 'C: - it changed after you confirmed'
            $global:BlOut.Status | Should -Match 'nothing was decrypted' -Because 'the person must be told that this drive was left alone'
            $global:BlOut.Status | Should -Match 'Started: D:'
        }

        It 'will not decrypt while one of this app''s own jobs (debloat, installs, provisioning) is running' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            $global:deployProc = [pscustomobject]@{ HasExited = $false }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'job.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'job is still running \(Debloat / Office\)'
            @([BlTestMsgBox]::Log).Count | Should -Be 0
        }
    }

    Context 'the backup step' {
        It 'checks the file place BEFORE it adds a recovery password to a drive' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = 'relative-name.txt'
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk }
            }
            $global:BlFake.AddCalls.Count | Should -Be 0
            @([BlTestMsgBox]::Log).Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'nothing was changed'
            $global:BlOut.Ok | Should -BeFalse
        }

        It 'adds a recovery password on request, backs it up, and never lets it reach a status line or the warning stream' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Set-Answer 'Yes'
            $path = Get-BackupPath 'add-recovery.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Status | Should -Match 'A recovery password was added to C:'
            $global:BlOut.Status.Contains($script:addedPw) | Should -BeFalse
            (Get-Content -LiteralPath $path -Raw).Contains($script:addedPw) | Should -BeTrue
            (Get-ActionLogText).Contains($script:addedPw) | Should -BeFalse
        }

        It 'warns, in amber, that a drive with no recovery password cannot be unlocked with the file' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $T.ChkAdd.IsChecked = $false
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'hollow.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlFake.AddCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'no recovery password exists for C:'
            $global:BlOut.Color | Should -Be '#FFD29922'
        }

        It 'is not an error to press button 1 again for a backup that is still good' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'twice.txt')
                Raise-Click $T.Backup
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Disable | Should -BeTrue
            $global:BlOut.Status | Should -Match 'still good'
        }

        It 'offers a new file name when a refresh that cannot read BitLocker makes the earlier backup stop counting' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'refresh-error.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlFake.GetThrows = 'WMI hiccup (stand-in)'
                Raise-Click $T.Refresh
                $global:BlOut = @{ Ok = $T.State.BackupOk; Box = $T.PathBox.Text; Status = $T.Status.Text; Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Box | Should -Not -Be $path
            $global:BlOut.Box | Should -Match 'BitLocker-Backup_TESTPC_Acme_\d{8}_\d{6}\.txt$'
            $global:BlOut.Status | Should -Match 'Could not read BitLocker status'
            $global:BlOut.Status | Should -Match 'earlier no longer counts'
            $global:BlOut.Disable | Should -BeFalse
        }

        It 'never overwrites an earlier file, and says so' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'earlier.txt'
            Set-Content -LiteralPath $path -Value 'EARLIER BACKUP' -Encoding ASCII
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk }
            }
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Status | Should -Match 'already exists'
            (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'EARLIER BACKUP'
        }

        It 'says where the file is when it is on a drive about to be decrypted, or on an encrypted one that stays - and asks BEFORE the keys are written there' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'F:' })
            $global:BlFake.RealPlaceNote = $true
            $script:placePath = Get-BackupPath 'place-ticked.txt'
            $script:fileWhenAsked = $null
            Set-Answer 'Yes' { if ($null -eq $script:fileWhenAsked) { $script:fileWhenAsked = (Test-Path -LiteralPath $script:placePath) } }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                # TestDrive is on the system drive, so C: is the drive the file sits on
                Set-Tick $T 'C:'; $T.PathBox.Text = $script:placePath
                Raise-Click $T.Backup
                $global:BlOut = @{ Ticked = $T.Status.Text }
                $global:BlOut.TickedColor = $T.Status.Foreground.Color.ToString()
            }
            $script:fileWhenAsked | Should -BeFalse -Because 'the question comes before the file is written'
            @([BlTestMsgBox]::Log)[0] | Should -Match 'default=No'
            @([BlTestMsgBox]::Log)[0] | Should -Match 'Save it there anyway'
            @([BlTestMsgBox]::Log)[0] | Should -Match 'about to be decrypted'
            $global:BlOut.Ticked | Should -Match 'about to be decrypted'
            $global:BlOut.TickedColor | Should -Be '#FFD29922'
            Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes; $global:BlFake.RealPlaceNote = $true
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'place-encrypted.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            @([BlTestMsgBox]::Log)[0] | Should -Match 'which is encrypted'
            $global:BlOut.Status | Should -Match 'which is encrypted'
        }

        It 'writes and changes nothing when the person says No to a place that deserves a second thought' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.PlaceNote = 'The file is inside OneDrive, so a copy of these keys also goes to your cloud storage (stand-in note).'
            $path = Get-BackupPath 'place-no.txt'
            Set-Answer 'No'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Disable = $T.Disable.IsEnabled }
            }
            Test-Path -LiteralPath $path | Should -BeFalse
            $global:BlFake.AddCalls.Count | Should -Be 0
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Disable | Should -BeFalse
            $global:BlOut.Status | Should -Match 'Nothing was changed - choose another place'
            @([BlTestMsgBox]::Log).Count | Should -Be 1
        }
    }

    Context 'the Windows drive and auto-unlock keys' {
        It 'names the drives that will ask for a password, clears the stored keys first, then decrypts the Windows drive' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $global:BlOut = @{ Note = ($T.State.Rows | Where-Object { $_.Mount -eq 'C:' }).NoteBlock.Text }
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'auto.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut.Status = $T.Status.Text
            }
            $global:BlOut.Note | Should -Match 'auto-unlock keys'
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'Drives that stay encrypted \(D:\) will ask for their password or recovery key from then on\.'
            $global:BlFake.ClearCalls | Should -Be 1
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
            @($global:BlFake.CallLog)[0] | Should -Be 'clear-auto-unlock'
            $global:BlOut.Status | Should -Match 'auto-unlock keys stored on the Windows drive were cleared'
        }

        It 'does not clear anything when only a data drive is decrypted' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'auto-data.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $global:BlFake.ClearCalls | Should -Be 0
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:'
        }
    }

    Context 'progress after a decrypt starts' {
        It 'keeps following a drive started earlier when another one is started later' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'track.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                Set-Tick $T 'C:'
                Raise-Click $T.Disable
                $global:BlOut = @{ Started = (@($T.State.Started | ForEach-Object { $_.Mount }) -join ',') }
            }
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:,C:'
            $global:BlOut.Started | Should -Be 'D:,C:'
        }

        It 'reports a drive that disappears as missing, not as finished' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'vanish.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                # the stick is pulled: the drive is gone from the list
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.Status | Should -Match 'no longer listed'
            $global:BlOut.Status | Should -Match 'Plug it back in and press Refresh status to see where it got to'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
            (Get-ActionLogText) | Should -Match 'Decryption: no longer listed: D:'
        }

        It 'reports finished, with how long it took and how to turn BitLocker on again, when the drive is fully decrypted' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finish.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Rows = $T.State.Rows | Where-Object { $_.Mount -eq 'D:' } | ForEach-Object { $_.StateBlock.Text }; Followed = @($T.State.Started).Count }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'turn BitLocker on from Windows'
            $global:BlOut.Status | Should -Not -Match 'Provisioning tab' -Because 'that button only handles the Windows drive'
            $global:BlOut.Rows | Should -Match 'Decrypted - took'
            $global:BlOut.Followed | Should -Be 0 -Because 'a drive that has been reported is not followed (or reported) any more'
            (Get-ActionLogText) | Should -Match 'Decryption finished: D:'
        }

        It 'points to the Provisioning tab only when the Windows drive is among the finished drives' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'finish-os.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:'
            $global:BlOut.Status | Should -Match 'Provisioning tab, Enable BitLocker'
            $global:BlOut.Status | Should -Not -Match 'encrypt a data drive again' -Because 'that hint is for data drives only'
        }

        It 'keeps following a drive BitLocker cannot read for a moment (it is not "unplugged" after one bad read)' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'blip.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                # the next two reads fail for D: (a read error, D: missing from the list), then it is readable again
                $global:BlFake.Plan = New-Object 'System.Collections.Generic.Queue[string]'
                $global:BlFake.Plan.Enqueue('err'); $global:BlFake.Plan.Enqueue('err')
                $global:BlFake.PlanDrop = 'D:'
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # both bad reads are used up, and a good read after them has put the drive's progress back on its row
                $null = Wait-Until { $global:BlFake.Plan.Count -eq 0 -and (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text -match 'Decrypting') }
                $T.Timer.Stop()
                $row = $T.State.Rows | Where-Object { $_.Mount -eq 'D:' }
                $global:BlOut = @{ Row = $row.StateBlock.Text; Misses = $T.State.Started[0].Misses; Status = $T.Status.Text }
            }
            $global:BlOut.Row | Should -Match 'Decrypting'
            $global:BlOut.Row | Should -Not -Match 'No longer listed'
            $global:BlOut.Misses | Should -Be 0
            $global:BlOut.Status | Should -Not -Match 'no longer listed'
        }

        It 'does call a drive gone when BitLocker keeps failing to read it' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'blip-long.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlFake.Plan = New-Object 'System.Collections.Generic.Queue[string]'
                1..30 | ForEach-Object { $global:BlFake.Plan.Enqueue('err') }
                $global:BlFake.PlanDrop = 'D:'
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $row = $T.State.Rows | Where-Object { $_.Mount -eq 'D:' }
                $global:BlOut = @{ Row = $row.StateBlock.Text; Status = $T.Status.Text }
            }
            $global:BlOut.Row | Should -Match 'No longer listed'
            $global:BlOut.Status | Should -Match 'no longer listed'
        }

        It 'keeps the "Not started" text on screen when the drives that did start finish' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.DisableThrows = 'This drive is locked by BitLocker Drive Encryption. (Exception from HRESULT: 0x80310000)'
            $global:BlFake.DisableThrowsFor = 'C:'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'partial.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'Not started: C:'
            $global:BlOut.Color | Should -Be '#FFD29922'
        }
    }

    Context 'what the final review found' {
        It 'does not let a tick follow a drive letter to another drive: a swapped stick is refused before anything changes' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'swap-tick.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                # another encrypted stick takes the letter D: after the tick
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{0THER000-0000-0000-0000-00000000000B}' $script:pwNew)
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Rows = (Get-Rows $T); Ok = $T.State.BackupOk }
            }
            Test-Path -LiteralPath $path | Should -BeFalse
            $global:BlFake.AddCalls.Count | Should -Be 0
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'D: is no longer the drive that was listed'
            @([BlTestMsgBox]::Log).Count | Should -Be 0
        }

        It 'names each drive in the confirmation by label and size, so two sticks can be told apart' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.Labels = @{ 'D:' = 'WORK-STICK-A' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'label.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'D:   Data drive, fixed \(WORK-STICK-A\), 931[.,]5 GB, Encrypted'
        }

        It 'asks about adding a recovery password with No as the default, and No adds nothing' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Set-Answer 'No'
            $path = Get-BackupPath 'add-no.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk }
            }
            @([BlTestMsgBox]::Log)[0] | Should -Match 'no recovery password'
            @([BlTestMsgBox]::Log)[0] | Should -Match 'default=No'
            $global:BlFake.AddCalls.Count | Should -Be 0
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Status | Should -Match 'no recovery password exists for C:'
        }

        It 'says in the failure that a recovery password WAS added when the save fails after the add, and shows it on the row' {
            $script:vanishDir = Join-Path $TestDrive 'vanishing'
            New-Item -ItemType Directory -Path $script:vanishDir -Force | Out-Null
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            # the folder disappears while the question is open (a stick pulled)
            Set-Answer 'Yes' { if (Test-Path -LiteralPath $script:vanishDir) { Remove-Item -LiteralPath $script:vanishDir -Recurse -Force } }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Join-Path $script:vanishDir 'gone.txt')
                Raise-Click $T.Backup
                $cells = @(@($T.RowsPanel.Children) | ForEach-Object { @($_.Child.Children) | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | ForEach-Object { $_.Text } })
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Cells = ($cells -join '|') }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Status | Should -Match 'A recovery password WAS added to C:'
            $global:BlOut.Status | Should -Match 'press button 1 again'
            $global:BlOut.Cells | Should -Match 'Recovery password'
        }

        It 'names the recovery password that WAS added when adding one to a second drive fails' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Password' '{DDDDDDDD-0000-0000-0000-00000000000D}' $null)))
            )
            $global:BlFake.AddThrowsFor = 'D:'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'second-add-fails.txt')
                Raise-Click $T.Backup
                $afterFail = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Rows = (Get-Rows $T) }
                # the cause goes away; button 1 again (C: has its recovery password now, D: gets one), then button 2
                $global:BlFake.AddThrowsFor = ''
                Raise-Click $T.Backup
                $afterRetry = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text }
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterFail = $afterFail; AfterRetry = $afterRetry }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:,D:,D:'
            $global:BlOut.AfterFail.Status | Should -Match 'A recovery password was added to C: first - it is in no backup yet'
            $global:BlOut.AfterFail.Status | Should -Match 'Could not add a recovery password to D:'
            $global:BlOut.AfterFail.Ok | Should -BeFalse
            # C: got its password on purpose and is still the same drive, so its tick survives the refresh; D: was not touched
            $global:BlOut.AfterFail.Rows | Should -Match 'C:\(can=True,tick=True\)'
            $global:BlOut.AfterFail.Rows | Should -Match 'D:\(can=True,tick=True\)'
            $global:BlOut.AfterRetry.Ok | Should -BeTrue
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:,C:'
        }

        It 'keeps the drive that got a recovery password as the same drive when another drive is swapped before the backup is read' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)))
            )
            # right after the recovery password was added to C:, another stick takes the letter D:
            $global:BlFake.AfterAdd = { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.CapacityGB = 14.5 }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'added-then-swapped-1.txt')
                Raise-Click $T.Backup
                $afterFirst = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text; Rows = (Get-Rows $T) }
                # the other stick is gone again and the person's own D: is back; button 1 once more
                $global:BlFake.AfterAdd = $null
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.CapacityGB = 931.5
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'added-then-swapped-2.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ AfterFirst = $afterFirst; Ok = $T.State.BackupOk; Status = $T.Status.Text }
            }
            $global:BlOut.AfterFirst.Ok | Should -BeFalse
            $global:BlOut.AfterFirst.Status | Should -Match 'A recovery password WAS added to C: before this failed'
            $global:BlOut.AfterFirst.Status | Should -Match 'The backup was NOT made: D: is no longer the drive that was listed'
            $global:BlOut.AfterFirst.Rows | Should -Match 'C:\(can=True,tick=True\)'
            $global:BlOut.AfterFirst.Rows | Should -Match 'D:\(can=True,tick=False\)'
            # C: is the same drive with one more key, so the second press is not refused for it - and adds nothing again
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Status | Should -Not -Match 'no longer the drive that was listed'
        }

        It 'does not forget a drive''s volume ID when the read after adding a recovery password cannot get it' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\' }
            # right after the recovery password is added, Windows cannot give volume IDs for a moment
            $global:BlFake.AfterAdd = { $global:BlFake.VolumeThrows = 'the Storage module is busy (stand-in)' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'keeps-volume-id.txt')
                Raise-Click $T.Backup
                $afterBackup = @{ Ok = $T.State.BackupOk }
                # it works again - and shows that another volume now has the letter C:
                $global:BlFake.VolumeThrows = $null
                $global:BlFake.VolumeIds['C'] = '\\?\Volume{C-2}\'
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterBackup = $afterBackup; Status = $T.Status.Text }
            }
            $global:BlOut.AfterBackup.Ok | Should -BeTrue
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'C: is no longer the drive that was listed'
        }

        It 'lets the drive that just got a recovery password be decrypted straight afterwards (the same drive, with one more key)' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'add-then-decrypt.txt')
                Raise-Click $T.Backup
                $afterBackup = @{ Ok = $T.State.BackupOk; Rows = (Get-Rows $T); Prot = (($T.State.Rows | Where-Object { $_.Mount -eq 'C:' }).ProtBlock.Text) }
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterBackup = $afterBackup; Status = $T.Status.Text }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.AfterBackup.Ok | Should -BeTrue
            $global:BlOut.AfterBackup.Rows | Should -Match 'C:\(can=True,tick=True\)'
            $global:BlOut.AfterBackup.Prot | Should -Match 'Recovery password'
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Status | Should -Match 'Decryption started for C:'
        }

        It 'refuses bad file names (* ? : trailing dot, device names) before anything is changed' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            Set-Answer 'Yes'
            $script:badNames = @('a*b.txt', 'a?b.txt', 'NUL.txt', 'aux', 'x:y.txt', 'trailing.')
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'
                $statuses = @()
                foreach ($n in $script:badNames) {
                    $T.PathBox.Text = "$TestDrive\$n"
                    Raise-Click $T.Backup
                    $statuses += $T.Status.Text
                }
                $global:BlOut = @{ Statuses = $statuses }
            }
            $global:BlFake.AddCalls.Count | Should -Be 0
            @([BlTestMsgBox]::Log).Count | Should -Be 0
            @($global:BlOut.Statuses | Where-Object { $_ -match 'not a usable file name' -and $_ -match 'nothing was changed' }).Count | Should -Be 6
        }

        It 'cleans the quotes Explorer puts round a copied path' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'quoted.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = '"' + $path + '"'
                Raise-Click $T.Backup
                $global:BlOut = @{ Ok = $T.State.BackupOk; Box = $T.PathBox.Text }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Box | Should -BeExactly $path
            Test-Path -LiteralPath $path | Should -BeTrue
        }

        It 'fills in a new file name when the backup stops counting, and leaves a name the person typed alone' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'stale-name.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $okBefore = $T.State.BackupOk
                # a new key appears on D:, then the list is refreshed: the backup no longer counts
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'RecoveryPassword' '{NEWKEY00-0000-0000-0000-000000000009}' $script:pwNew)
                Raise-Click $T.Refresh
                $global:BlOut = @{ OkBefore = $okBefore; Ok = $T.State.BackupOk; Box = $T.PathBox.Text; Status = $T.Status.Text; Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.OkBefore | Should -BeTrue
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Disable | Should -BeFalse
            $global:BlOut.Box | Should -Not -Be $path
            [System.IO.Path]::GetDirectoryName($global:BlOut.Box) | Should -Be ([System.IO.Path]::GetDirectoryName($path))
            [System.IO.Path]::GetFileName($global:BlOut.Box) | Should -Match '^BitLocker-Backup_TESTPC_Acme_\d{8}_\d{6}\.txt$'
            $global:BlOut.Status | Should -Match 'no longer counts'
            # a name the person typed is left alone
            Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes
            $script:ownName = Get-BackupPath 'my-own-name.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'stale-typed.txt')
                Raise-Click $T.Backup
                $T.PathBox.Text = $script:ownName
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'RecoveryPassword' '{NEWKEY00-0000-0000-0000-000000000009}' $script:pwNew)
                Raise-Click $T.Refresh
                $global:BlOut = @{ Box = $T.PathBox.Text }
            }
            $global:BlOut.Box | Should -Be $script:ownName
        }

        It 'uses a new file name by itself when button 1 is pressed again for a backup file that was changed' {
            $global:BlFake.Volumes = Get-StdVolumes
            $script:firstPath = Get-BackupPath 'again-stale.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $script:firstPath
                Raise-Click $T.Backup
                Add-Content -LiteralPath $script:firstPath -Value 'tampered' -Encoding ASCII
                Raise-Click $T.Backup
                $global:BlOut = @{ Ok = $T.State.BackupOk; Path = $T.State.BackupPath; Status = $T.Status.Text; Disable = $T.Disable.IsEnabled }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Path | Should -Not -Be $script:firstPath
            Test-Path -LiteralPath $global:BlOut.Path | Should -BeTrue
            $global:BlOut.Status | Should -Match 'a new file name was used'
            (Get-Content -LiteralPath $script:firstPath -Raw) | Should -Match 'tampered'
        }

        It 'does not treat an unreadable BitLocker as a stale backup: the earlier backup stays and no new file name is made up' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'unreadable-recheck.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlFake.GetThrows = 'WMI hiccup (stand-in)'
                Raise-Click $T.Backup
                $global:BlOut = @{ Ok = $T.State.BackupOk; Box = $T.PathBox.Text; Path = $T.State.BackupPath; Status = $T.Status.Text }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Box | Should -Be $path
            $global:BlOut.Path | Should -Be $path
            $global:BlOut.Status | Should -Match 'Could not read BitLocker status'
        }

        It 'refuses a ticked drive that gained a key after it was listed (nothing is saved), and works again after a refresh and a new tick' {
            $global:BlFake.Volumes = Get-StdVolumes
            $first = Get-BackupPath 'baseline-1.txt'
            $second = Get-BackupPath 'baseline-2.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                # D: is ticked, then another key appears on it: it is not the drive the person looked at any more
                Set-Tick $T 'D:'; $T.PathBox.Text = $first
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'RecoveryPassword' '{NEWKEY00-0000-0000-0000-00000000000A}' $script:pwNew)
                Raise-Click $T.Backup
                $afterFirst = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text; Rows = (Get-Rows $T); FileThere = (Test-Path -LiteralPath $first) }
                # a refresh lists the drive as it is now; ticked again and backed up under another name, it is accepted and can be decrypted
                Raise-Click $T.Refresh
                Set-Tick $T 'D:'; $T.PathBox.Text = $second
                Raise-Click $T.Backup
                $afterSecond = @{ Ok = $T.State.BackupOk; Path = $T.State.BackupPath; Status = $T.Status.Text }
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterFirst = $afterFirst; AfterSecond = $afterSecond }
            }
            $global:BlOut.AfterFirst.Ok | Should -BeFalse
            $global:BlOut.AfterFirst.FileThere | Should -BeFalse
            $global:BlOut.AfterFirst.Status | Should -Match '^D: is no longer the drive that was listed .* It was unticked and nothing was changed\. Press Refresh status'
            $global:BlOut.AfterFirst.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.AfterSecond.Ok | Should -BeTrue
            $global:BlOut.AfterSecond.Path | Should -Be $second
            $global:BlOut.AfterSecond.Status | Should -Not -Match 'no longer the drive that was listed'
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:'
        }

        It 'keeps an earlier good backup when only a new file name is bad' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'good-first.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $T.PathBox.Text = (Join-Path $TestDrive 'no-such-folder\typo.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Ok = $T.State.BackupOk; Disable = $T.Disable.IsEnabled; Status = $T.Status.Text; Path = $T.State.BackupPath }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Disable | Should -BeTrue
            $global:BlOut.Path | Should -Be $path
            $global:BlOut.Status | Should -Match 'Your earlier backup .* still counts'
        }

        It 'says, on screen and in the file, that a volume BitLocker could not read is NOT in the backup' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'unreadable.txt'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                $global:BlFake.WriteError = 'Volume G: could not be read (stand-in)'
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString(); Ok = $T.State.BackupOk }
            }
            $global:BlOut.Ok | Should -BeTrue
            $global:BlOut.Status | Should -Match 'could not read some volumes just now, so their keys are NOT in this backup: Volume G:'
            $global:BlOut.Color | Should -Be '#FFD29922'
            (Get-Content -LiteralPath $path -Raw) | Should -Match 'NOT IN THIS BACKUP: BitLocker could not read some volumes'
        }

        It 'stops, naming the drive, when a ticked drive cannot be read at the moment of the backup' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            $path = Get-BackupPath 'vanished-during.txt'
            # the drive drops out between the first read and the backup read (while the add question is open)
            Set-Answer 'No' { $global:BlFake.Volumes = @() }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk }
            }
            Test-Path -LiteralPath $path | Should -BeFalse
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Status | Should -Match 'The backup was NOT made: C: is no longer the drive that was listed \(its keys or size are different, or BitLocker cannot read it now'
        }

        It 'reports the auto-unlock keys as cleared, and logs it, even when the decrypt then fails' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            $global:BlFake.DisableThrows = 'Decryption is refused by policy (stand-in). (Exception from HRESULT: 0x80070005)'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'cleared-then-failed.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.ClearCalls | Should -Be 1
            $global:BlOut.Status | Should -Match 'Nothing was started'
            $global:BlOut.Status | Should -Match 'auto-unlock keys stored on the Windows drive WERE cleared'
            (Get-ActionLogText) | Should -Match 'Cleared the auto-unlock keys stored on C:'
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'including the keys of drives that are not plugged in now'
        }

        It 'records the confirmation in the action log, and says before the Yes when no log can be written anywhere' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'No'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'logged.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            (Get-ActionLogText) | Should -Match 'Decrypt confirmation shown for: C:'
            @([BlTestMsgBox]::Log)[-1] | Should -Not -Match 'action log cannot be written'
            # now the log cannot be written at all (a stand-in that fails), and the real function is put back afterwards
            $realSource = Get-FunctionSource -ScriptPath $gui -FunctionName 'Write-BitLockerActionLog'
            try {
                function global:Write-BitLockerActionLog { param([string]$Message, [switch]$PassThru) if ($PassThru) { return $false } }
                Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes; Set-Answer 'No'
                Invoke-Dialog {
                    $T = $global:BlT; Raise-Loaded $T.Dialog
                    Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'logged-2.txt')
                    Raise-Click $T.Backup; Raise-Click $T.Disable
                }
            } finally {
                . ([scriptblock]::Create($realSource.Replace('function Write-BitLockerActionLog ', 'function global:Write-BitLockerActionLog ')))
            }
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'The action log cannot be written on this PC'
        }

        It 'has a Close button that answers Esc, fits the screen, and gives each tick box a screen-reader hint' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $cb = ($T.State.Rows | Where-Object { $_.Mount -eq 'E:' }).CheckBox
                $work = [System.Windows.SystemParameters]::WorkArea
                $global:BlOut = @{ IsCancel = $T.Dialog.FindName('BtnBlClose').IsCancel; Height = $T.Dialog.Height; Work = $work.Height; MinH = $T.Dialog.MinHeight
                    Help = [System.Windows.Automation.AutomationProperties]::GetHelpText($cb); Name = [System.Windows.Automation.AutomationProperties]::GetName($cb) }
            }
            $global:BlOut.IsCancel | Should -BeTrue
            $global:BlOut.Height | Should -BeLessOrEqual $global:BlOut.Work
            $global:BlOut.MinH | Should -BeLessOrEqual $global:BlOut.Work
            # the longest status needs 600 at the window's minimum size (rendered and checked); on a screen with a smaller work area the window lowers it to fit
            $global:BlOut.MinH | Should -BeGreaterOrEqual ([math]::Min(600, $global:BlOut.Work - 20)) -Because 'the minimum height must not be lowered below what the content needs'
            $global:BlOut.Name | Should -Be 'Decrypt E:'
            $global:BlOut.Help | Should -Match 'Cannot be selected: Locked'
        }
    }

    Context 'a tick stays with the drive that was ticked (a letter can be given to another drive at any moment)' {
        It 'does not carry a tick over to a different drive that has taken the letter, and says so' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'
                # another stick, with other keys and another size, now has the letter D:
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{SWAPPED0-0000-0000-0000-00000000000D}' $script:pwNew)
                $d.CapacityGB = 14.5
                Raise-Click $T.Refresh
                $global:BlOut = @{ Rows = (Get-Rows $T); Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.Rows | Should -Match 'C:\(can=True,tick=True\)'
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'D: was unticked: it is not the drive that was ticked'
            $global:BlOut.Color | Should -Be '#FFD29922'
        }

        It 'keeps the tick of a drive whose size and keys are unchanged, even though its state changed' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.EncryptionPercentage = 87      # a progress number is not part of what a drive is
                Raise-Click $T.Refresh
                $global:BlOut = @{ Rows = (Get-Rows $T); Status = $T.Status.Text }
            }
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=True\)'
            $global:BlOut.Status | Should -Not -Match 'unticked'
        }

        It 'adds no recovery password to a drive that was swapped while the add question was open' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            $script:gatePath = Get-BackupPath 'swap-during-add.txt'
            # while the question is open another drive takes the letter: its TPM protector has another ID
            Set-Answer 'Yes' { $c = @($global:BlFake.Volumes)[0]; $c.KeyProtector = @(New-Prot 'Tpm' '{BBBBBBBB-0000-0000-0000-000000000002}' $null) }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = $script:gatePath
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Rows = (Get-Rows $T) }
            }
            $global:BlFake.AddCalls.Count | Should -Be 0
            Test-Path -LiteralPath $script:gatePath | Should -BeFalse
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Rows | Should -Match 'C:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'no recovery password was added'
        }

        It 'makes no backup of a drive that was swapped while the place question was open' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.PlaceNote = 'The file is inside OneDrive (stand-in note).'
            $script:gatePath = Get-BackupPath 'swap-during-place.txt'
            Set-Answer 'Yes' { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.CapacityGB = 14.5 }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $script:gatePath
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text; Ok = $T.State.BackupOk; Rows = (Get-Rows $T) }
            }
            Test-Path -LiteralPath $script:gatePath | Should -BeFalse
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'The backup was NOT made: D: is no longer the drive that was listed'
        }

        It 'refuses at button 2 a drive that changed after the backup even though the backup still covers every key' {
            $global:BlFake.Volumes = Get-StdVolumes
            $script:gatePath = Get-BackupPath 'changed-after-backup.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = $script:gatePath
                Raise-Click $T.Backup
                # D: is replaced by a stick of another size that has the same keys: nothing the backup could notice
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.CapacityGB = 14.5
                Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text; Rows = (Get-Rows $T); BackupOk = $T.State.BackupOk }
            }
            $global:BlFake.DisableCalls.Count | Should -Be 0
            @([BlTestMsgBox]::Log).Count | Should -Be 0 -Because 'nothing is asked when a drive is already known not to be the one that was listed'
            $global:BlOut.Rows | Should -Match 'C:\(can=True,tick=True\)'
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'D: is no longer the drive that was listed'
            $global:BlOut.Status | Should -Match 'nothing was decrypted'
        }

        It 'ignores both buttons while one of the window''s own jobs is running' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'busy.txt')
                Raise-Click $T.Backup
                $reads = $global:BlFake.GetCalls
                $T.State.Busy = $true
                Raise-Click $T.Backup -Force; Raise-Click $T.Disable -Force
                $global:BlOut = @{ Reads = ($global:BlFake.GetCalls - $reads); Boxes = @([BlTestMsgBox]::Log).Count }
            }
            $global:BlOut.Reads | Should -Be 0
            $global:BlOut.Boxes | Should -Be 0
            $global:BlFake.DisableCalls.Count | Should -Be 0
        }

        It 'stops following the drives when the window is closed' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'closing.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $before = $T.Timer.IsEnabled
                try { $T.Dialog.Close() } catch { $global:BlCloseError = $_.Exception.Message }
                $global:BlOut = @{ Before = $before; After = $T.Timer.IsEnabled }
            }
            $global:BlOut.Before | Should -BeTrue
            $global:BlCloseError | Should -BeNullOrEmpty
            $global:BlOut.After | Should -BeFalse
            Remove-Variable -Name BlCloseError -Scope Global -ErrorAction SilentlyContinue
        }

        It 'does not keep the tick of a drive that gained a key outside this app' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'
                # somebody adds a key to D: with another tool; only the app's own "add a recovery password" step may do that to a ticked drive
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'Password' '{EXTRA000-0000-0000-0000-0000000000D1}' $null)
                Raise-Click $T.Refresh
                $global:BlOut = @{ Rows = (Get-Rows $T); Status = $T.Status.Text }
            }
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
            $global:BlOut.Status | Should -Match 'D: was unticked'
        }

        It 'does not take a drive that was swapped right after it got a recovery password for the drive that was listed' {
            $global:BlFake.Volumes = @(
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Password' '{DDDDDDDD-0000-0000-0000-00000000000D}' $null)))
            )
            # right after the recovery password is added to D:, another (smaller) stick takes the letter
            $global:BlFake.AfterAdd = { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.CapacityGB = 14.5 }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'added-and-swapped-1.txt')
                Raise-Click $T.Backup
                $afterFirst = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text }
                # the person does not notice, ticks D: again and presses button 1 once more: it is still not the drive that was listed
                $global:BlFake.AfterAdd = $null
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'added-and-swapped-2.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ AfterFirst = $afterFirst; Ok = $T.State.BackupOk; Status = $T.Status.Text }
            }
            $global:BlOut.AfterFirst.Ok | Should -BeFalse
            $global:BlOut.AfterFirst.Status | Should -Match 'A recovery password WAS added to D: before this failed'
            $global:BlOut.AfterFirst.Status | Should -Match 'The backup was NOT made: D: is no longer the drive that was listed'
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Status | Should -Match 'D: is no longer the drive that was listed'
        }

        It 'refuses a ticked drive that gained a key outside the app while the add question was being answered, even when another drive just got its key from the app' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)))
            )
            # right after the recovery password is added to C:, somebody adds a key to D: with another tool
            $global:BlFake.AfterAdd = { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'Password' '{EXTRA000-0000-0000-0000-0000000000D2}' $null) }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'key-outside.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Ok = $T.State.BackupOk; Status = $T.Status.Text; Rows = (Get-Rows $T) }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Ok | Should -BeFalse
            $global:BlOut.Status | Should -Match 'The backup was NOT made: D: is no longer the drive that was listed'
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)'
        }

        It 'unticks a drive that gained a key outside the app even when ANOTHER drive got a recovery password from the app and a later add failed' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD))),
                (New-Vol 'E:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Password' '{EEEEEEEE-0000-0000-0000-00000000000E}' $null)))
            )
            $global:BlFake.AddThrowsFor = 'E:'
            # right after the recovery password is added to C:, somebody adds a key to D: with another tool; then adding one to E: fails,
            # and the window refreshes with C: marked as "got its recovery password on purpose"
            $global:BlFake.AfterAdd = { $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]; $d.KeyProtector = @($d.KeyProtector) + @(New-Prot 'Password' '{EXTRA000-0000-0000-0000-0000000000D3}' $null) }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; Set-Tick $T 'E:'; $T.PathBox.Text = (Get-BackupPath 'key-outside-and-failed-add.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Rows = (Get-Rows $T); Status = $T.Status.Text }
            }
            @($global:BlFake.AddCalls) -join ',' | Should -Be 'C:,E:'
            $global:BlOut.Rows | Should -Match 'C:\(can=True,tick=True\)' -Because 'C: got its password on purpose and is still the same drive'
            $global:BlOut.Rows | Should -Match 'D:\(can=True,tick=False\)' -Because 'D: gained a key that the app did not add'
            $global:BlOut.Status | Should -Match 'Could not add a recovery password to E:'
        }

        It 'takes a volume ID that became readable when the recovery password was added as part of what the drive is' {
            $global:BlFake.Volumes = @((New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))))
            # no volume ID can be read at first; right after the recovery password is added Windows gives one
            $global:BlFake.VolumeThrows = 'the Storage module is busy (stand-in)'
            $global:BlFake.AfterAdd = { $global:BlFake.VolumeThrows = $null; $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\' } }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'late-volume-id.txt')
                Raise-Click $T.Backup
                $afterBackup = @{ Ok = $T.State.BackupOk }
                # another volume now has the letter C:
                $global:BlFake.VolumeIds['C'] = '\\?\Volume{C-2}\'
                Raise-Click $T.Disable
                $global:BlOut = @{ AfterBackup = $afterBackup; Status = $T.Status.Text }
            }
            $global:BlOut.AfterBackup.Ok | Should -BeTrue
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'C: is no longer the drive that was listed'
        }
    }

    Context 'following a decrypt: a different drive is reported as gone, not as finished' {
        It 'calls a drive gone when another drive (another size) has taken its letter, instead of calling it finished' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'replaced.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                # the stick is pulled and a smaller one, with nothing encrypted on it, gets the letter D:
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @(); $d.CapacityGB = 14.5
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Row = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Status | Should -Match 'another drive has taken its letter'
            $global:BlOut.Status | Should -Match '(?m)^D: is no longer listed' -Because 'a drive is named once, not once for every way it was found to be gone'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
            $global:BlOut.Row | Should -Match 'A different drive now has this letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
            (Get-ActionLogText) | Should -Match 'Decryption: no longer listed: D:\s*$'
        }

        It 'keeps a drive that finished as finished when it is unplugged while another one is still working' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-then-gone.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # D: finishes first (C: is still decrypting) ...
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                $finishedAt = @($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0].Finished
                # ... then the stick is pulled; a few more reads go by, and C: finishes too
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                Pump 250
                $finishedKept = (@($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0].Finished -eq $finishedAt)
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString(); FinishedKept = $finishedKept }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for D:, C:'
            $global:BlOut.Status | Should -Not -Match 'no longer listed'
            $global:BlOut.Color | Should -Be '#FF3FB950'
            $global:BlOut.FinishedKept | Should -BeTrue -Because 'the time a drive took stops running when it finishes, and later reads do not start it again'
            (Get-ActionLogText) | Should -Match 'Decryption finished: D:'
            (Get-ActionLogText) | Should -Match 'Decryption finished: C:'
        }

        It 'does not call an identical-looking drive "finished" either: another volume ID on the letter means another drive' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'lookalike-timer.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                # the stick is replaced by one of the same size and type that is not encrypted at all (another volume)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Row = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Status | Should -Match 'another drive has taken its letter'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
            $global:BlOut.Row | Should -Match 'A different drive now has this letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
        }

        It 'does not take up a drive that was missing for a while again, unless its volume ID proves it is the same drive' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'missing-unproven.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # D: is pulled ...
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # ... and a drive that looks the same (size, type, nothing encrypted) takes the letter, with no volume ID Windows could read
                $global:BlFake.VolumeIds.Remove('D')
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @((New-Vol 'D:' 'Data' 'FullyDecrypted' 'Off' 'Unlocked' 0 @()))
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'A different drive now has this letter' }
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
        }

        It 'keeps a drive it judged to be another one judged so, even when a drive that looks like the original takes the letter later' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'stays-gone.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # a smaller stick takes D: (judged to be another drive) ...
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @(); $d.CapacityGB = 14.5
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'A different drive now has this letter' }
                # ... and then a drive with the original's size and type, whose volume ID Windows cannot give, takes it
                $global:BlFake.VolumeIds.Remove('D')
                $d.CapacityGB = 931.5
                Pump 300
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
        }

        It 'does not call a drive of another type "finished" either (same size)' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'other-type.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @(); $d.VolumeType = 'OperatingSystem'
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'another drive has taken its letter'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
        }

        It 'takes a drive that was unplugged and plugged in again up again when its volume ID proves it is the same one' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'missing-proven.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $dOriginal = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # the same stick again (same volume ID), still decrypting: it is followed again
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @($dOriginal)
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypting' }
                foreach ($m in 'C:', 'D:') { $x = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq $m })[0]; $x.VolumeStatus = 'FullyDecrypted'; $x.EncryptionPercentage = 0; $x.KeyProtector = @() }
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for D:, C:'
            $global:BlOut.Status | Should -Not -Match 'no longer listed'
        }

        It 'forgets a drive it judged gone, so that letter does not flag the next drive that is decrypted there' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'forgets-gone.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                # the stick is replaced by a smaller one: judged gone, and the timer stops
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @(); $d.CapacityGB = 14.5
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $afterFirst = @{ Started = (@($T.State.Started | ForEach-Object { $_.Mount }) -join ','); Status = $T.Status.Text }
                # a different drive is decrypted afterwards: the old letter must not be reported again
                Raise-Click $T.Refresh
                Set-Tick $T 'C:'
                Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ AfterFirst = $afterFirst; Started = (@($T.State.Started | ForEach-Object { $_.Mount }) -join ','); Status = $T.Status.Text; RowD = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.AfterFirst.Started | Should -Be ''
            $global:BlOut.AfterFirst.Status | Should -Match 'another drive has taken its letter'
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:,C:'
            $global:BlOut.Started | Should -Be '' -Because 'what was followed has been reported, and nothing of it is kept'
            $global:BlOut.Status | Should -Match 'Decryption finished for C:'
            $global:BlOut.Status | Should -Not -Match 'D:'
            $global:BlOut.RowD | Should -Not -Match 'A different drive now has this letter'
        }

        It 'puts the "Decrypted - took" text back on a finished drive''s row after a refresh, for as long as it is the same drive' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-text.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypted - took' }
                # a refresh rebuilds the rows: D: now reads "Not encrypted" until the next tick puts its own text back
                Raise-Click $T.Refresh
                $afterRefresh = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypted - took' }
                $restored = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                # another drive takes the letter D: (not the same volume): its row must be left alone
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                Raise-Click $T.Refresh
                $callsBefore = $global:BlFake.GetCalls
                $null = Wait-Until { $global:BlFake.GetCalls -ge ($callsBefore + 2) }      # two ticks have looked at the new D:
                $other = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                $T.Timer.Stop()
                $global:BlOut = @{ AfterRefresh = $afterRefresh; Restored = $restored; Other = $other }
            }
            $global:BlOut.AfterRefresh | Should -Be 'Not encrypted'
            $global:BlOut.Restored | Should -Match 'Decrypted - took'
            $global:BlOut.Other | Should -Be 'Not encrypted'
        }

        It 'checks the drive once more in the very read right before it asks Windows, and refuses a drive swapped at that instant' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'last-instant.txt')
                Raise-Click $T.Backup
                # everything before the call has passed; at the instant the one drive is read for the call, another volume has the letter
                $global:BlFake.OnSingleRead = { $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\' }
                Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlFake.DisableCalls.Count | Should -Be 0
            $global:BlOut.Status | Should -Match 'Nothing was started'
            $global:BlOut.Status | Should -Match 'D: - it is not the drive that was confirmed'
            $global:BlOut.Status | Should -Match 'nothing was decrypted' -Because 'the person must be told that this drive was left alone'
        }

        It 'still lists, backs up and decrypts when Windows cannot give volume IDs at all' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeThrows = 'the Storage module is not available (stand-in)'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'no-volume-ids.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text; Rows = (Get-Rows $T) }
            }
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'D:'
            $global:BlOut.Status | Should -Match 'Decryption started for D:'
        }

        It 'refuses a look-alike (same keys, size and type, another volume) that takes the letter while the confirmation box is open' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes' { $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\' }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'lookalike-box.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            # D: is refused; C: (the same drive as when it was ticked) goes ahead
            @($global:BlFake.DisableCalls) -join ',' | Should -Be 'C:'
            $global:BlOut.Status | Should -Match 'Started: C:'
            $global:BlOut.Status | Should -Match 'Not started: D: - it changed after you confirmed'
        }

        It 'does not report a drive that finished in an earlier run again, even when another drive has taken its letter since' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'earlier-run-1.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $first = $T.Status.Text
                # another stick, still encrypted, takes the letter D:; the list is refreshed and C: is decrypted next
                $global:BlFake.Volumes = @(@($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' }) + @((New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' '{DDDD0002-0000-0000-0000-000000000002}' $script:pwNew)))))
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                Raise-Click $T.Refresh
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'earlier-run-2.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ First = $first; Status = $T.Status.Text; RowD = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text); Disabled = (@($global:BlFake.DisableCalls) -join ',') }
            }
            $global:BlOut.First | Should -Match 'Decryption finished for D:'
            $global:BlOut.Disabled | Should -Be 'D:,C:'
            $global:BlOut.Status | Should -Match 'Decryption finished for C:'
            $global:BlOut.Status | Should -Not -Match 'D:' -Because 'D: finished in the earlier run and another drive has the letter now: this run never followed that one'
            $global:BlOut.RowD | Should -BeLike 'Encrypted*' -Because 'the row of the other stick is left alone'
        }

        It 'starts no follow-up, and keeps "Nothing was started" on screen, when button 2 starts nothing - even though a drive finished earlier' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'nothing-started-1.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                # another stick takes the letter D:; Windows refuses to decrypt it
                $global:BlFake.Volumes = @(@($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' }) + @((New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' '{DDDD0002-0000-0000-0000-000000000002}' $script:pwNew)))))
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                $global:BlFake.DisableThrows = 'This drive is locked by BitLocker Drive Encryption. (Exception from HRESULT: 0x80310000)'
                $global:BlFake.DisableThrowsFor = 'D:'
                Raise-Click $T.Refresh
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'nothing-started-2.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $timerRunning = $T.Timer.IsEnabled
                Pump 400           # a timer that was started would have ticked ten times
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Running = $timerRunning; Followed = @($T.State.Started).Count }
            }
            $global:BlOut.Status | Should -Match 'Nothing was started'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
            $global:BlOut.Running | Should -BeFalse -Because 'there is nothing to follow'
            $global:BlOut.Followed | Should -Be 0
        }

        It 'does not call a drive finished when an encrypted drive is on its letter now (another drive, or this one encrypted again), and shows the real state on its row' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-then-swapped.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                # a stick of the same size and type, still encrypted, takes the letter D: (Windows gives no volume IDs here, so it cannot be told from the same stick)
                $d.VolumeStatus = 'FullyEncrypted'; $d.ProtectionStatus = 'On'; $d.EncryptionPercentage = 100; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{DDDD0004-0000-0000-0000-000000000004}' $script:pwNew)
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString(); RowD = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'D: finished decrypting, but the drive on D: is not fully decrypted now - it may be another drive, or this one encrypted again'
            $global:BlOut.Status | Should -Not -Match 'no longer listed' -Because 'the drive is listed and nobody can say another drive took its letter'
            $global:BlOut.Color | Should -Be '#FFD29922'
            $global:BlOut.RowD | Should -Be 'Encrypted' -Because 'the row shows what is on the letter now, not the text of the finished drive'
            (Get-ActionLogText) | Should -Match 'Decryption: finished, but the drive on the letter is not fully decrypted now: D:'
        }

        It 'does not call a drive finished when a smaller drive has taken its letter since it finished' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-then-smaller.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                # a smaller stick with nothing encrypted on it takes the letter D:
                $d.CapacityGB = 14.5
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
        }

        It 'follows a drive by the volume ID it was confirmed with, even when the reads right after the confirmation could not get one' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            # Windows' volume lookup fails during the reads that follow the Yes (the guard reads, and the one inside Start-BitLockerDecrypt)
            Set-Answer 'Yes' { $global:BlFake.VolumeThrows = 'the Storage module hiccuped (stand-in)' }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'confirmed-id.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $global:BlFake.VolumeThrows = $null
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $followed = (@($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0]).VolumeId
                # D: is missing for a moment and comes back: only its volume ID can prove it is the same stick
                $dOriginal = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @($dOriginal)
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypting|A different drive' }
                $T.Timer.Stop()
                $global:BlOut = @{ Followed = $followed; Row = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Followed | Should -Be '\\?\Volume{D-1}\' -Because 'the volume ID the drive was confirmed with, not the (empty) one of the read that failed'
            $global:BlOut.Row | Should -Match 'Decrypting'
            $global:BlOut.Row | Should -Not -Match 'A different drive'
        }

        It 'does not take up a drive that was missing when Windows gives no volume IDs at all (nothing can prove it is the same one)' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeThrows = 'the Storage module is not available (stand-in)'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'missing-no-ids.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # a look-alike (same size and type, nothing encrypted) takes the letter; there is no ID to compare on either side
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @((New-Vol 'D:' 'Data' 'FullyDecrypted' 'Off' 'Unlocked' 0 @()))
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'A different drive now has this letter' } 3000
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
        }

        It 'does not take up a drive that was missing when the original had no volume ID, even though the drive that takes the letter has one' {
            $global:BlFake.Volumes = Get-StdVolumes
            # Windows cannot give volume IDs when the decrypt starts, so the followed drive has none ...
            $global:BlFake.VolumeThrows = 'the Storage module is not available (stand-in)'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'missing-id-never-known.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # ... and can again when a look-alike takes the letter: an ID proves nothing when none was known for the first drive
                $global:BlFake.VolumeThrows = $null
                $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-9}\' }
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @((New-Vol 'D:' 'Data' 'FullyDecrypted' 'Off' 'Unlocked' 0 @()))
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'A different drive now has this letter' } 3000
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
        }

        It 'forgets that a drive was missing once its volume ID has proved it is the same one, so a later read without an ID does not make it "another drive"' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'missing-then-blind.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $dOriginal = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # the same stick again: its volume ID proves it
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @($dOriginal)
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypting' }
                # from now on Windows cannot give any volume ID: that proves nothing against the drive
                $global:BlFake.VolumeThrows = 'the Storage module is busy (stand-in)'
                $callsBefore = $global:BlFake.GetCalls
                $null = Wait-Until { $global:BlFake.GetCalls -ge ($callsBefore + 4) }
                $T.Timer.Stop()
                $global:BlOut = @{ Row = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Row | Should -Match 'Decrypting'
            $global:BlOut.Row | Should -Not -Match 'A different drive'
        }

        It 'keeps following when BitLocker cannot be read AT ALL for a few ticks (the whole read fails), and finishes normally afterwards' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'whole-read-fails.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # BitLocker cannot be read at all (the module is busy, a WMI hiccup): a few ticks go by
                $global:BlFake.GetThrows = 'WMI hiccup (stand-in)'
                $callsBefore = $global:BlFake.GetCalls
                $null = Wait-Until { $global:BlFake.GetCalls -ge ($callsBefore + 3) }
                $stillRunning = $T.Timer.IsEnabled
                $rowDuring = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                # BitLocker answers again, and the drive finishes
                $global:BlFake.GetThrows = $null
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; StillRunning = $stillRunning; RowDuring = $rowDuring }
            }
            $global:BlOut.StillRunning | Should -BeTrue -Because 'one failed read of the whole list must not end the follow-up'
            $global:BlOut.RowDuring | Should -Not -Match 'No longer listed'
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Not -Match 'no longer listed'
        }

        It 'does not put the "Decrypted - took" text back on a drive that is encrypting again' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'encrypting-again.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'Decrypted - took' }
                # BitLocker is turned on again for that very stick (same volume), and the list is refreshed
                $d.VolumeStatus = 'EncryptionInProgress'; $d.EncryptionPercentage = 5; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{DDDD0005-0000-0000-0000-000000000005}' $script:pwNew)
                Raise-Click $T.Refresh
                $callsBefore = $global:BlFake.GetCalls
                $null = Wait-Until { $global:BlFake.GetCalls -ge ($callsBefore + 4) }
                $T.Timer.Stop()
                $global:BlOut = @{ Row = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Row | Should -Be 'Encrypting (5% done)'
        }

        It 'does not call a drive finished when a decrypted look-alike with ANOTHER volume ID has taken its letter since it finished, and says so in amber and in the log' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-then-lookalike.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                # a stick of the same size and type, nothing encrypted on it, but ANOTHER volume, takes the letter D:
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString(); RowD = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match '(?m)^D: is no longer listed, or another drive has taken its letter'
            $global:BlOut.Color | Should -Be '#FFD29922' -Because 'a drive reported as gone is a warning, not a success'
            $global:BlOut.RowD | Should -Match 'A different drive now has this letter' -Because 'the row still shows the drive that finished, which is not there any more'
            (Get-ActionLogText) | Should -Match 'Decryption: no longer listed: D:'
        }

        It 'does not call a drive finished when a drive of another type (same size) has taken its letter since it finished' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-then-other-type.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                $d.VolumeType = 'OperatingSystem'
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
        }

        It 'judges a drive that finished while its row was not on screen (no "Decrypted - took" text was ever kept for it)' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'finished-without-row.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $dOriginal = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'D:' })
                $null = Wait-Until { (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) -match 'No longer listed' }
                # the person refreshes while the stick is out: its row is gone
                Raise-Click $T.Refresh
                $rowCount = @($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).Count
                # the same stick comes back, already decrypted (its volume ID proves it): it finishes, and there is no row to keep a text on
                $dOriginal.VolumeStatus = 'FullyDecrypted'; $dOriginal.EncryptionPercentage = 0; $dOriginal.KeyProtector = @()
                $global:BlFake.Volumes = @($global:BlFake.Volumes) + @($dOriginal)
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                $doneText = [string](@($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0]).DoneText
                # another volume of the same size and type takes the letter
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-2}\'
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; RowCount = $rowCount; DoneText = $doneText }
            }
            $global:BlOut.RowCount | Should -Be 0 -Because 'the test needs the row to be missing when the drive finishes'
            $global:BlOut.DoneText | Should -Be '' -Because 'the test needs a finished drive without a kept text'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
        }

        It 'names a finished-then-replaced drive AND a drive that was found replaced while it was working, each once' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null), (New-Prot 'RecoveryPassword' $script:idRecC $script:pwC))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD))),
                (New-Vol 'E:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' '{EEEE0000-40F6-45DC-9E68-8594BB27FC36}' '222222-333333-444444-555555-666666-707707-000011-111111')))
            )
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\'; 'E' = '\\?\Volume{E-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; Set-Tick $T 'E:'; $T.PathBox.Text = (Get-BackupPath 'two-kinds-of-gone.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                # D: (finished) gets another stick, still encrypted; E: (still working) gets a smaller stick
                $d.VolumeStatus = 'FullyEncrypted'; $d.EncryptionPercentage = 100; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{DDDD0008-0000-0000-0000-000000000008}' $script:pwNew)
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-8}\'
                $e = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'E:' })[0]
                $e.VolumeStatus = 'FullyDecrypted'; $e.EncryptionPercentage = 0; $e.KeyProtector = @(); $e.CapacityGB = 14.5
                Pump 250
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for C:\.'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished for [^.]*[DE]:'
            $global:BlOut.Status | Should -Match '(D:, E:|E:, D:) is no longer listed, or another drive has taken its letter'
            ([regex]::Matches($global:BlOut.Status, 'D:')).Count | Should -Be 1 -Because 'a drive is named once'
        }

        It 'leaves the row of the drive that is there now alone when a refresh was made after another drive took the letter (while the followed drive was still working)' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'row-of-other-drive-1.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                # another stick, encrypted, takes the letter D: and the person refreshes: the row of D: shows THAT stick
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyEncrypted'; $d.ProtectionStatus = 'On'; $d.EncryptionPercentage = 100; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{DDDD0009-0000-0000-0000-000000000009}' $script:pwNew)
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-9}\'
                Raise-Click $T.Refresh
                $rowAfterRefresh = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                $callsBefore = $global:BlFake.GetCalls
                $null = Wait-Until { $global:BlFake.GetCalls -ge ($callsBefore + 3) }      # three ticks have judged the followed drive gone
                $goneLatched = [bool](@($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0]).Gone
                $rowAfterTicks = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text)
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ RowAfterRefresh = $rowAfterRefresh; RowAfterTicks = $rowAfterTicks; GoneLatched = $goneLatched; Status = $T.Status.Text; RowAtEnd = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.RowAfterRefresh | Should -Be 'Encrypted'
            $global:BlOut.GoneLatched | Should -BeTrue -Because 'the test needs the followed drive to have been judged gone'
            $global:BlOut.RowAfterTicks | Should -Be 'Encrypted' -Because 'a sentence about the drive that was being decrypted must not replace the real state of the stick that is there now'
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            $global:BlOut.RowAtEnd | Should -Be 'Encrypted'
        }

        It 'leaves the row of the drive that is there now alone when a refresh was made after another drive took the letter of a drive that had already finished' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' }
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'row-of-other-drive-2.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { @($T.State.Started | Where-Object { $_.Mount -eq 'D:' -and $_.Finished }).Count -gt 0 }
                # another stick, encrypted, takes the letter D: and the person refreshes
                $d.VolumeStatus = 'FullyEncrypted'; $d.ProtectionStatus = 'On'; $d.EncryptionPercentage = 100; $d.KeyProtector = @(New-Prot 'RecoveryPassword' '{DDDD0010-0000-0000-0000-000000000010}' $script:pwNew)
                $global:BlFake.VolumeIds['D'] = '\\?\Volume{D-10}\'
                Raise-Click $T.Refresh
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; RowD = (($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).StateBlock.Text) }
            }
            $global:BlOut.Status | Should -Match 'D: is no longer listed, or another drive has taken its letter'
            $global:BlOut.RowD | Should -Be 'Encrypted'
        }

        It 'reports a finish that happened while a message box was open only after the box is closed, so the report is not overwritten behind it' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'box-open.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                # the person starts another decrypt; while its confirmation box is open the timer ticks (as a real one does) and D: finishes
                Set-Tick $T 'C:'
                Set-Answer 'No' { Pump 400 }
                Raise-Click $T.Disable
                $afterBox = @{ Status = $T.Status.Text; Running = $T.Timer.IsEnabled; Followed = @($T.State.Started).Count }
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ AfterBox = $afterBox; Status = $T.Status.Text }
            }
            $global:BlOut.AfterBox.Status | Should -Match 'Cancelled - nothing was changed'
            $global:BlOut.AfterBox.Running | Should -BeTrue -Because 'the finish is reported by the first tick after the box, not behind it'
            $global:BlOut.AfterBox.Followed | Should -Be 1
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
        }

        It 'keeps what it said when the decrypt started (keys cleared, a setting that could not be written) in the status that is shown when the drives finish' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            $global:BlFake.PreventOk = $false
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'run-notes.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $afterStart = @{ Status = $T.Status.Text }
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ AfterStart = $afterStart; Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString(); Notes = @($T.State.RunNotes).Count }
            }
            $global:BlOut.AfterStart.Status | Should -Match 'auto-unlock keys stored on the Windows drive WERE cleared'
            $global:BlOut.AfterStart.Status | Should -Match 'Could not set PreventDeviceEncryption'
            $global:BlOut.Status | Should -Match 'Decryption finished for C:'
            $global:BlOut.Status | Should -Match 'auto-unlock keys stored on the Windows drive WERE cleared'
            $global:BlOut.Status | Should -Match 'Could not set PreventDeviceEncryption'
            $global:BlOut.Color | Should -Be '#FFD29922' -Because 'something the person must not overlook happened during this run'
            $global:BlOut.Notes | Should -Be 0 -Because 'the notes belong to one run and are shown once'
        }

        It 'does not carry the notes of one run into the status of the next' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'run-notes-1.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $c = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'C:' })[0]
                $c.VolumeStatus = 'FullyDecrypted'; $c.EncryptionPercentage = 0; $c.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $first = $T.Status.Text
                # a second run: only D:, nothing to clear any more
                Raise-Click $T.Refresh
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'run-notes-2.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ First = $first; Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.First | Should -Match 'WERE cleared'
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Not -Match 'WERE cleared'
            $global:BlOut.Color | Should -Be '#FF3FB950'
        }

        It 'does not keep the notes of a press that started nothing (keys cleared, decrypt refused) for the status of a later run' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecC $script:pwC)) $true $null),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)) $false $true)
            )
            $global:BlFake.DisableThrows = 'This drive is locked by BitLocker Drive Encryption. (Exception from HRESULT: 0x80310000)'
            $global:BlFake.DisableThrowsFor = 'C:'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'notes-nothing-started-1.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $first = @{ Status = $T.Status.Text; Running = $T.Timer.IsEnabled; Notes = @($T.State.RunNotes).Count }
                # the cause goes away; the next run is D: only
                $global:BlFake.DisableThrows = $null
                Raise-Click $T.Refresh
                Set-Tick $T 'C:' $false; Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'notes-nothing-started-2.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Interval = [TimeSpan]::FromMilliseconds(40)
                $d = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq 'D:' })[0]
                $d.VolumeStatus = 'FullyDecrypted'; $d.EncryptionPercentage = 0; $d.KeyProtector = @()
                $null = Wait-Until { -not $T.Timer.IsEnabled }
                $T.Timer.Stop()
                $global:BlOut = @{ First = $first; Status = $T.Status.Text }
            }
            $global:BlOut.First.Status | Should -Match 'Nothing was started'
            $global:BlOut.First.Status | Should -Match 'WERE cleared' -Because 'the keys were cleared even though the decrypt was then refused'
            $global:BlOut.First.Running | Should -BeFalse
            $global:BlOut.First.Notes | Should -Be 0 -Because 'nothing is followed, so nothing will report them later'
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Not -Match 'WERE cleared'
        }

        It 'follows a drive by the volume ID of the guard read when the confirmed identity had none' {
            $global:BlFake.Volumes = Get-StdVolumes
            # Windows gives no volume IDs while the window lists the drives; they are available again by the time of the Yes
            $global:BlFake.VolumeThrows = 'the Storage module is busy (stand-in)'
            Set-Answer 'Yes' { $global:BlFake.VolumeThrows = $null; $global:BlFake.VolumeIds = @{ 'C' = '\\?\Volume{C-1}\'; 'D' = '\\?\Volume{D-1}\' } }
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $idAtListing = [string]($T.State.Rows | Where-Object { $_.Mount -eq 'D:' }).Identity.VolumeId
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'guard-read-id.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
                $T.Timer.Stop()
                $global:BlOut = @{ IdAtListing = $idAtListing; Followed = [string](@($T.State.Started | Where-Object { $_.Mount -eq 'D:' })[0]).VolumeId }
            }
            $global:BlOut.IdAtListing | Should -Be '' -Because 'the test needs a drive that was listed without an ID'
            $global:BlOut.Followed | Should -Be '\\?\Volume{D-1}\'
        }
    }

    Context 'what the window says, and what the confirmation tells the person before the Yes' {
        It 'puts the file, what happens, the no-recovery-password caution, the place note and every warning in the confirmation' {
            $global:BlFake.Volumes = @(
                (New-Vol 'C:' 'OperatingSystem' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'Tpm' $script:idTpm $null))),
                (New-Vol 'D:' 'Data' 'FullyEncrypted' 'On' 'Unlocked' 100 @((New-Prot 'RecoveryPassword' $script:idRecD $script:pwD)))
            )
            $global:BlFake.PlaceNote = 'STAND-IN PLACE NOTE.'
            $global:BlFake.Warnings = @('STAND-IN WARNING ONE.', 'STAND-IN WARNING TWO.')
            $path = Get-BackupPath 'pins.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $T.ChkAdd.IsChecked = $false         # no recovery password is added to C:, so the caution about it must appear
                Set-Tick $T 'C:'; Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $boxes = @([BlTestMsgBox]::Log)
            $boxes.Count | Should -Be 2 -Because 'one question about the place of the file, then the confirmation'
            $boxes[0] | Should -Match 'STAND-IN PLACE NOTE'
            $final = $boxes[-1]
            $final | Should -Match 'icon=Warning \| default=No'
            $final | Should -Match 'Decrypt these drives now'
            $final | Should -Match 'Your key backup was saved and checked: // [^|]*pins\.txt'
            $final | Should -Match 'Decryption runs in the background and can take from minutes to hours'
            $final | Should -Match 'keep it on and plugged in'
            $final | Should -Match 'You can close this window'
            $final | Should -Match 'BitLocker protection is already off while a drive decrypts, and when it finishes anyone with physical access to the PC can read the drive without a key'
            $final | Should -Match 'Windows removes the drive''s key protectors at the end, so the backup becomes your only record of them'
            $final | Should -Match 'PreventDeviceEncryption = 1'
            $final | Should -Match 'Before you go on:'
            $final | Should -Match 'No recovery password exists for C:, so the backup has none for it'
            $final | Should -Not -Match 'No recovery password exists for D:'
            $final | Should -Match 'STAND-IN PLACE NOTE'
            $final | Should -Match 'STAND-IN WARNING ONE'
            $final | Should -Match 'STAND-IN WARNING TWO'
        }

        It 'says nothing about PreventDeviceEncryption when only a data drive is decrypted' {
            $global:BlFake.Volumes = Get-StdVolumes
            Set-Answer 'No'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'no-prevent-text.txt')
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'Decrypt these drives now'
            @([BlTestMsgBox]::Log)[-1] | Should -Not -Match 'PreventDeviceEncryption'
            @([BlTestMsgBox]::Log)[-1] | Should -Not -Match 'Before you go on'
        }

        It 'tells the truth about who can read the backup file (NTFS only), and that the question defaults to No' {
            $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                $scroll = $T.Dialog.FindName('BlStatusScroll')
                $global:BlOut = @{ Text = (Get-WindowText $T.Dialog); ScrollName = [System.Windows.Automation.AutomationProperties]::GetName($scroll); ScrollMax = $scroll.MaxHeight; Tab = $scroll.IsTabStop }
            }
            $global:BlOut.Text | Should -Match 'On an NTFS drive only you, administrators and SYSTEM can read it'
            $global:BlOut.Text | Should -Match 'a stick formatted FAT32 or exFAT cannot restrict that, so keep the stick safe'
            $global:BlOut.Text | Should -Not -Match 'only administrators can read'
            $global:BlOut.Text | Should -Match 'the question defaults to No'
            $global:BlOut.Text | Should -Match 'delete that value to undo'
            $global:BlOut.ScrollName | Should -Be 'Status'
            $global:BlOut.ScrollMax | Should -Be 90
            $global:BlOut.Tab | Should -BeTrue
        }

        It 'writes each step to the action log, and never a key' {
            $global:BlFake.Volumes = Get-StdVolumes
            $path = Get-BackupPath 'log-lines.txt'
            Set-Answer 'Yes'
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = $path
                Raise-Click $T.Backup; Raise-Click $T.Disable
            }
            $log = Get-ActionLogText
            $log | Should -Match 'Key backup saved and verified: .*log-lines\.txt \(4 volume\(s\), 2 recovery password\(s\), \d+ key protector\(s\)\)'
            $log | Should -Match 'Decrypt confirmation shown for: D:'
            $log | Should -Match 'Decryption started: D:'
            $log | Should -Not -Match '\d{6}-\d{6}-\d{6}'
        }
    }
}

Describe 'the Disable BitLocker dialog tests clean up after themselves' -Skip:(-not $script:canRunWindow) {
    It 'leaves no stand-in with the name of a real command behind' {
        # runs after the first Describe's AfterAll: a stand-in left in the global scope would shadow the real command for every later test file
        (Get-Command manage-bde -ErrorAction SilentlyContinue).CommandType | Should -Not -Be 'Function'
        # the BitLocker and TPM commands may exist for real (as module functions); what must not exist is a stand-in, which has no module
        foreach ($n in 'Get-BitLockerVolume', 'Get-Volume', 'Disable-BitLocker', 'Add-BitLockerKeyProtector', 'Clear-BitLockerAutoUnlock', 'Get-Tpm') {
            $cmd = Get-Command $n -ErrorAction SilentlyContinue
            if ($cmd) { $cmd.ModuleName | Should -Not -BeNullOrEmpty -Because "$n must be the real command of its module, not a stand-in" }
        }
        foreach ($n in 'Get-BitLockerBackupPlaceNote', 'Get-RealBitLockerBackupPlaceNote', 'Show-BitLockerDisableDialog', 'Save-BitLockerBackupFile', 'Start-BitLockerDecrypt', 'Invoke-Dialog', 'New-Vol') {
            Get-Command $n -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "$n is a helper of the dialog tests and must be removed again"
        }
        Get-Variable -Name BlFake, BlT, BlAnswer -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }

    It 'leaves no helper or stand-in function and no global variable behind, whatever it is called' {
        if (-not (Get-Variable -Name BlFnSnapshot -Scope Global -ErrorAction SilentlyContinue)) { Set-ItResult -Skipped -Because 'the dialog tests before this one did not run'; return }
        # a function without a module that did not exist before the dialog tests is one of theirs (the real commands of the BitLocker, Storage and TPM modules have a module)
        $left = @(Get-ChildItem -Path function: | Where-Object { -not $_.ModuleName -and ($global:BlFnSnapshot -notcontains $_.Name) } | ForEach-Object { $_.Name })
        $left | Should -BeNullOrEmpty -Because "the dialog tests defined these functions and did not remove them: $($left -join ', ')"
        foreach ($v in 'BlT', 'BlDriver', 'BlOut', 'BlFake', 'BlAnswer', 'BlBeforeAnswer', 'BlCloseError', 'workDir', 'window', 'deployProc', 'fixProc', 'installProc', 'provisionProc', 'wingetInstallProc') {
            Get-Variable -Name $v -Scope Global -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because "`$global:$v belongs to the dialog tests and must be removed again"
        }
        Remove-Variable -Name BlFnSnapshot -Scope Global -ErrorAction SilentlyContinue
    }
}

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
}

Describe 'Disable BitLocker dialog (real window, stand-in BitLocker)' -Skip:(-not $script:canRunWindow) {
    BeforeAll {
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
        $script:globalFns = New-Object System.Collections.Generic.List[string]
        foreach ($fn in 'Get-BitLockerPropertyText', 'ConvertTo-BitLockerVolumeDetail', 'Get-BitLockerVolumeDetail', 'Get-BitLockerStateText', 'Get-BitLockerDisableState',
            'Get-BitLockerProtectorSummary', 'Get-BitLockerKeyIds', 'Test-BitLockerKeysCovered', 'Get-BitLockerMountsWithoutRecoveryPassword', 'New-BitLockerBackupText',
            'Test-BitLockerRecoveryPasswordFormat', 'Test-BitLockerBackupText', 'Get-BitLockerBackupPlaceNote', 'Get-BitLockerDefaultBackupFolder', 'Test-BitLockerBackupPath',
            'Test-BitLockerBackupStillGood', 'Get-BitLockerKeyIdSet', 'Get-RunningToolJobs', 'Save-BitLockerBackupFile', 'Get-BitLockerRawOutput', 'Get-BitLockerAuditFolder',
            'Write-BitLockerActionLog', 'Get-BitLockerFriendlyError', 'Clear-BitLockerStoredAutoUnlock', 'Start-BitLockerDecrypt', 'Add-BitLockerRecoveryProtector',
            'Get-BitLockerDecryptOrder', 'Get-BitLockerAutoUnlockAffected', 'Get-BitLockerElapsedText', 'Get-BitLockerProgressText', 'Get-BitLockerTypeText', 'Get-SafeFileNamePart') {
            $src = Get-FunctionSource -ScriptPath $gui -FunctionName $fn
            if ($fn -eq 'Get-RunningToolJobs') { $src = $src.Replace('$script:', '$global:') }    # the job variables live in the global scope in this test
            if (-not $src.StartsWith("function $fn ")) { throw "unexpected source start for $fn" }
            . ([scriptblock]::Create($src.Replace("function $fn ", "function global:$fn ")))
            $script:globalFns.Add($fn)
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
            $all = @($global:BlFake.Volumes)
            if ($MountPoint) { return @($all | Where-Object { $_.MountPoint -eq $MountPoint }) }
            return $all
        }
        function global:Disable-BitLocker {
            [CmdletBinding()] param([string]$MountPoint)
            $global:BlFake.DisableCalls.Add($MountPoint)
            if ($global:BlFake.DisableThrows) { throw $global:BlFake.DisableThrows }
            $v = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq $MountPoint })[0]
            if ($v) { $v.VolumeStatus = 'DecryptionInProgress'; $v.ProtectionStatus = 'Off'; $v.EncryptionPercentage = 99 }
        }
        function global:Add-BitLockerKeyProtector {
            [CmdletBinding()] param([string]$MountPoint, [switch]$RecoveryPasswordProtector)
            $global:BlFake.AddCalls.Add($MountPoint)
            Write-Warning "A new recovery password was created: $($script:addedPw)"
            $v = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -eq $MountPoint })[0]
            if ($v) { $v.KeyProtector = @($v.KeyProtector) + @(New-Prot 'RecoveryPassword' '{ADDED000-0000-0000-0000-000000000001}' $script:addedPw) }
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
        function global:Get-BitLockerDriveDescription { param([string]$MountPoint) return [pscustomobject]@{ Kind = 'Fixed'; Label = '' } }

        function global:New-Prot([string]$Type, [string]$Id, [string]$Password) {
            $o = [pscustomobject]@{ KeyProtectorType = $Type; KeyProtectorId = $Id; AutoUnlockProtector = $false }
            if ($Password) { $o | Add-Member -NotePropertyName RecoveryPassword -NotePropertyValue $Password }
            return $o
        }
        function global:New-Vol([string]$Mount, [string]$Type, [string]$Status, [string]$Prot, [string]$Lock, [int]$Pct, $Protectors, [bool]$AutoStored = $false, $AutoOn = $false) {
            return [pscustomobject]@{ MountPoint = $Mount; VolumeType = $Type; ProtectionStatus = $Prot; VolumeStatus = $Status; LockStatus = $Lock; EncryptionMethod = 'XtsAes256'; EncryptionPercentage = $Pct; CapacityGB = 931.5; AutoUnlockEnabled = $AutoOn; AutoUnlockKeyStored = $AutoStored; KeyProtector = $Protectors }
        }
        $script:pwC = '303853-558635-091828-709577-000891-120549-364804-297176'
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
                PreventCalls = 0; PreventValue = $null; PreventOk = $true; Warnings = @() }
            [BlTestMsgBox]::Log.Clear(); [BlTestMsgBox]::Handler = $null
            $global:deployProc = $null; $global:fixProc = $null; $global:installProc = $null; $global:provisionProc = $null; $global:wingetInstallProc = $null
            $global:BlOut = $null
            $Error.Clear()
        }
        function Set-Answer([string]$Answer, [scriptblock]$Before = $null) {
            # globals, because the delegate below is called from C# and must not depend on scope lookups
            $global:BlAnswer = $Answer; $global:BlBeforeAnswer = $Before
            [BlTestMsgBox]::Handler = [System.Func[string, string, string, string, string]]{ param($t, $c, $b, $d) if ($global:BlBeforeAnswer) { & $global:BlBeforeAnswer }; return $global:BlAnswer }
        }
        function global:Invoke-Dialog { param([scriptblock]$Driver) $global:BlDriver = $Driver; Show-BitLockerDisableDialog }
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
        function global:Get-ActionLogText {
            $dir = Get-BitLockerAuditFolder
            if (-not $dir) { $dir = $global:workDir }
            $p = Join-Path $dir 'bitlocker-actions.log'
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
        $global:BlT = $null; $global:BlDriver = $null; $global:BlOut = $null; $global:BlFake = $null; $global:workDir = $null; $global:window = $null
        foreach ($n in @($script:globalFns) + @('Get-BitLockerVolume', 'Disable-BitLocker', 'Add-BitLockerKeyProtector', 'Clear-BitLockerAutoUnlock', 'manage-bde', 'Get-Tpm', 'Get-PreventDeviceEncryptionValue', 'Set-PreventDeviceEncryption', 'Get-BitLockerDecryptWarnings', 'Get-BitLockerBackupSystemInfo', 'Get-MachineTag', 'Get-BitLockerDriveDescription', 'New-Prot', 'New-Vol', 'Get-StdVolumes', 'Reset-Fake', 'Invoke-Dialog', 'Get-ActionLogText')) {
            if (Test-Path -LiteralPath ('function:global:' + $n)) { Remove-Item -LiteralPath ('function:global:' + $n) -Force }
        }
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

        It 'says where the file is when it is on a drive about to be decrypted, or on an encrypted one that stays' {
            $global:BlFake.Volumes = Get-StdVolumes
            $global:BlFake.Volumes = @($global:BlFake.Volumes | Where-Object { $_.MountPoint -ne 'F:' })
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                # TestDrive is on the system drive, so C: is the drive the file sits on
                Set-Tick $T 'C:'; $T.PathBox.Text = (Get-BackupPath 'place-ticked.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Ticked = $T.Status.Text }
                $global:BlOut.TickedColor = $T.Status.Foreground.Color.ToString()
            }
            $global:BlOut.Ticked | Should -Match 'about to be decrypted'
            $global:BlOut.TickedColor | Should -Be '#FFD29922'
            Reset-Fake; $global:BlFake.Volumes = Get-StdVolumes
            Invoke-Dialog {
                $T = $global:BlT; Raise-Loaded $T.Dialog
                Set-Tick $T 'D:'; $T.PathBox.Text = (Get-BackupPath 'place-encrypted.txt')
                Raise-Click $T.Backup
                $global:BlOut = @{ Status = $T.Status.Text }
            }
            $global:BlOut.Status | Should -Match 'which is encrypted'
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
            @([BlTestMsgBox]::Log)[-1] | Should -Match 'Drives that stay encrypted \(D:\)'
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
                Pump 400
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Color = $T.Status.Foreground.Color.ToString() }
            }
            $global:BlOut.Status | Should -Match 'no longer listed'
            $global:BlOut.Status | Should -Not -Match 'Decryption finished'
            (Get-ActionLogText) | Should -Not -Match 'Decryption finished: D:'
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
                Pump 400
                $T.Timer.Stop()
                $global:BlOut = @{ Status = $T.Status.Text; Rows = $T.State.Rows | Where-Object { $_.Mount -eq 'D:' } | ForEach-Object { $_.StateBlock.Text } }
            }
            $global:BlOut.Status | Should -Match 'Decryption finished for D:'
            $global:BlOut.Status | Should -Match 'Provisioning tab, Enable BitLocker'
            $global:BlOut.Rows | Should -Match 'Decrypted - took'
        }
    }
}

# Pester tests for the helpers behind the guarded "Disable BitLocker" dialog in Gr3ysUtilities.ps1:
# reading volumes, deciding what can be decrypted, writing and CHECKING the key backup, and the
# decrypt guard. The BitLocker cmdlets are stood in for by functions of the same name defined below,
# so nothing here ever touches a real drive; the registry tests use Pester's TestRegistry:. Extracted
# with the repo's Get-FunctionSource helper (CI runs this under Windows PowerShell 5.1). ASCII only.

Describe 'Disable BitLocker helpers' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $gui = Join-Path $repo 'debloat/Gr3ysUtilities.ps1'
        $script:guiPath = $gui
        . (Join-Path $repo 'tests/TestHelpers.ps1')
        foreach ($fn in 'Get-BitLockerPropertyText', 'ConvertTo-BitLockerVolumeDetail', 'Get-BitLockerVolumeDetail', 'Get-BitLockerStateText',
            'Get-BitLockerDisableState', 'Get-BitLockerProtectorSummary', 'Get-BitLockerKeyIds', 'Test-BitLockerKeysCovered',
            'Get-BitLockerMountsWithoutRecoveryPassword', 'New-BitLockerBackupText', 'Test-BitLockerRecoveryPasswordFormat',
            'Test-BitLockerBackupText', 'Get-BitLockerBackupPlaceNote', 'Get-BitLockerDefaultBackupFolder', 'Test-BitLockerBackupPath', 'Test-BitLockerBackupStillGood',
            'Get-BitLockerKeyIdSet', 'Get-RunningToolJobs', 'Save-BitLockerBackupFile', 'Get-BitLockerRawOutput', 'Get-BitLockerAuditFolder', 'Write-BitLockerActionLog',
            'Get-BitLockerFriendlyError', 'Clear-BitLockerStoredAutoUnlock', 'Start-BitLockerDecrypt', 'Add-BitLockerRecoveryProtector',
            'Get-PreventDeviceEncryptionValue', 'Set-PreventDeviceEncryption', 'Test-BitLockerPolicyPresent', 'Get-BitLockerDecryptWarnings',
            'Get-BitLockerDecryptOrder', 'Get-BitLockerAutoUnlockAffected', 'Get-BitLockerElapsedText', 'Get-BitLockerProgressText',
            'Get-BitLockerDriveDescription', 'Get-BitLockerTypeText') {
            . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $gui -FunctionName $fn)))
        }

        # a well-formed fake recovery password: 8 groups of 6 digits, each a multiple of 11 and at most 720885
        $script:pwdC = '111111-222222-333333-444444-555555-666666-707707-000011'
        $script:idTpm = '{AAAAAAAA-0000-0000-0000-000000000001}'
        $script:idRec = '{D8542C81-40F6-45DC-9E68-8594BB27FC34}'

        # --- stand-ins for the BitLocker module (same names, so the real code calls them) ---
        $script:fake = $null
        function Get-BitLockerVolume {
            [CmdletBinding()]
            param([string]$MountPoint)
            if ($script:fake.GetThrows) { throw $script:fake.GetThrows }
            $all = @($script:fake.Volumes)
            if ($MountPoint) { return @($all | Where-Object { $_.MountPoint -eq $MountPoint }) }
            return $all
        }
        function Disable-BitLocker {
            [CmdletBinding()]
            param([string]$MountPoint)
            $script:fake.DisableCalls += , $MountPoint
            if ($script:fake.DisableThrows) { throw $script:fake.DisableThrows }
        }
        function Add-BitLockerKeyProtector {
            [CmdletBinding()]
            param([string]$MountPoint, [switch]$RecoveryPasswordProtector)
            $script:fake.AddCalls += , $MountPoint
            # the real cmdlet writes the new password into the WARNING stream
            Write-Warning "A new recovery password was created: $($script:pwdC)"
            if ($script:fake.AddThrows) { throw $script:fake.AddThrows }
        }
        function Clear-BitLockerAutoUnlock {
            [CmdletBinding()]
            param()
            $script:fake.ClearCalls++
            if ($script:fake.ClearThrows) { throw $script:fake.ClearThrows }
            if (-not $script:fake.ClearIsNoOp) { foreach ($v in @($script:fake.Volumes)) { $v.AutoUnlockKeyStored = $false } }
        }
        function manage-bde {
            if ($args -contains '-status') { return 'FAKE STATUS OUTPUT' }
            return "FAKE PROTECTORS FOR $($args[-1])"
        }

        function New-FakeProtector([string]$Type, [string]$Id, [string]$Password, [string]$KeyFile, [bool]$AutoUnlock = $false) {
            $o = [pscustomobject]@{ KeyProtectorType = $Type; KeyProtectorId = $Id; AutoUnlockProtector = $AutoUnlock }
            if ($Password) { $o | Add-Member -NotePropertyName RecoveryPassword -NotePropertyValue $Password }
            if ($KeyFile) { $o | Add-Member -NotePropertyName KeyFileName -NotePropertyValue $KeyFile }
            return $o
        }
        function New-FakeVolume([string]$Mount, [string]$Status = 'FullyEncrypted', [string]$Protection = 'On', [string]$Lock = 'Unlocked', [int]$Percent = 100, [string]$Type = 'OperatingSystem', $Protectors = @(), [string]$Method = 'XtsAes256', [bool]$AutoUnlockKeyStored = $false, $AutoUnlockEnabled = $false) {
            return [pscustomobject]@{
                MountPoint = $Mount; VolumeType = $Type; ProtectionStatus = $Protection; VolumeStatus = $Status; LockStatus = $Lock
                EncryptionMethod = $Method; EncryptionPercentage = $Percent; CapacityGB = 931.5
                AutoUnlockEnabled = $AutoUnlockEnabled; AutoUnlockKeyStored = $AutoUnlockKeyStored
                KeyProtector = $Protectors
            }
        }
        function ConvertTo-Detail($Volume) { return (ConvertTo-BitLockerVolumeDetail -Volume $Volume) }
    }

    BeforeEach {
        $script:fake = @{ Volumes = @(); GetThrows = $null; DisableCalls = @(); DisableThrows = $null; AddCalls = @(); AddThrows = $null; ClearCalls = 0; ClearThrows = $null; ClearIsNoOp = $false }
    }

    Context 'ConvertTo-BitLockerVolumeDetail' {
        It 'maps a volume and keeps the recovery password only on the recovery protector' {
            $v = New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC))
            $d = ConvertTo-BitLockerVolumeDetail -Volume $v
            $d.MountPoint | Should -Be 'C:'
            $d.VolumeStatus | Should -Be 'FullyEncrypted'
            $d.EncryptionPercentage | Should -Be 100
            $d.Protectors.Count | Should -Be 2
            ($d.Protectors | Where-Object { $_.Type -eq 'Tpm' }).RecoveryPassword | Should -Be ''
            ($d.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' }).RecoveryPassword | Should -Be $script:pwdC
        }

        It 'gives an empty ARRAY (not $null) for a volume with no key protectors' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Status 'FullyDecrypted' -Protection 'Off' -Percent 0 -Type 'Data' -Protectors $null)
            $null -eq $d.Protectors | Should -BeFalse
            @($d.Protectors).Count | Should -Be 0
        }

        It 'survives missing properties and null entries' {
            $odd = [pscustomobject]@{ MountPoint = 'E:'; KeyProtector = @($null, [pscustomobject]@{ KeyProtectorType = 'Password' }) }
            $d = ConvertTo-BitLockerVolumeDetail -Volume $odd
            $d.LockStatus | Should -Be ''
            $d.EncryptionPercentage | Should -Be 0
            $d.AutoUnlockKeyStored | Should -BeFalse
            @($d.Protectors).Count | Should -Be 1
            $d.Protectors[0].Id | Should -Be ''
            $d.Protectors[0].AutoUnlock | Should -BeFalse
        }

        It 'keeps the auto-unlock facts: keys stored on the Windows drive, and an auto-unlock protector on a data drive' {
            $c = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)
            $c.AutoUnlockKeyStored | Should -BeTrue
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -AutoUnlockEnabled $true -Protectors @((New-FakeProtector 'ExternalKey' '{X}' '' '' $true), (New-FakeProtector 'ExternalKey' '{Y}' '' 'K.BEK' $false)))
            $d.AutoUnlockEnabled | Should -Be 'True'
            $d.AutoUnlockKeyStored | Should -BeFalse
            $d.Protectors[0].AutoUnlock | Should -BeTrue
            $d.Protectors[1].AutoUnlock | Should -BeFalse
        }
    }

    Context 'Get-BitLockerVolumeDetail' {
        It 'reports an error instead of throwing' {
            $script:fake.GetThrows = 'The term Get-BitLockerVolume is not recognized'
            $r = Get-BitLockerVolumeDetail
            $r.Error | Should -Match 'not recognized'
            @($r.Volumes).Count | Should -Be 0
        }

        It 'returns one volume as a one-element array (the 5.1 single-object trap)' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:')
            $r = Get-BitLockerVolumeDetail
            $r.Error | Should -BeNullOrEmpty
            @($r.Volumes).Count | Should -Be 1
            $r.Volumes[0].MountPoint | Should -Be 'C:'
        }

        It 'returns an empty array when there are no volumes' {
            $r = Get-BitLockerVolumeDetail
            $null -eq $r.Volumes | Should -BeFalse
            @($r.Volumes).Count | Should -Be 0
        }
    }

    Context 'what can be decrypted' {
        It 'allows encrypted and still-encrypting drives, refuses the rest and says why (the real VolumeStatus values)' {
            $cases = @(
                @{ S = 'FullyEncrypted'; L = 'Unlocked'; Can = $true }
                @{ S = 'EncryptionInProgress'; L = 'Unlocked'; Can = $true }
                @{ S = 'EncryptionSuspended'; L = 'Unlocked'; Can = $true }
                @{ S = 'FullyDecrypted'; L = 'Unlocked'; Can = $false }
                @{ S = 'DecryptionInProgress'; L = 'Unlocked'; Can = $false }
                @{ S = 'DecryptionSuspended'; L = 'Unlocked'; Can = $false }
                @{ S = 'FullyEncryptedWipeInProgress'; L = 'Unlocked'; Can = $false }
                @{ S = 'FullyEncryptedWipeSuspended'; L = 'Unlocked'; Can = $false }
                @{ S = 'FullyEncrypted'; L = 'Locked'; Can = $false }
                @{ S = 'Unknown'; L = 'Unlocked'; Can = $false }
                @{ S = ''; L = ''; Can = $false }
                @{ S = 'SomeStatusAddedByANewWindows'; L = 'Unlocked'; Can = $false }
                @{ S = 'EncryptionPaused'; L = 'Unlocked'; Can = $false }
            )
            foreach ($c in $cases) {
                $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'X:' -Status $c.S -Lock $c.L)
                $r = Get-BitLockerDisableState -Volume $d
                $r.CanDisable | Should -Be $c.Can -Because "status '$($c.S)' lock '$($c.L)'"
                if (-not $c.Can) { $r.Reason | Should -Not -BeNullOrEmpty }
            }
        }

        It 'never offers a volume that has no drive letter' {
            foreach ($m in @('', '\\?\Volume{11111111-2222-3333-4444-555555555555}\', 'C:\Mount\Data', 'CC:', 'C:\')) {
                $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount $m)
                (Get-BitLockerDisableState -Volume $d).CanDisable | Should -BeFalse -Because "mount point '$m'"
            }
        }

        It 'does not offer a drive that encrypts itself in hardware' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Type 'Data' -Method 'Hardware')
            $r = Get-BitLockerDisableState -Volume $d
            $r.CanDisable | Should -BeFalse
            $r.Reason | Should -Match 'hardware'
        }

        It 'tells you how to resume a decryption that was paused, naming the drive' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -Status 'DecryptionSuspended' -Percent 40)
            (Get-BitLockerDisableState -Volume $d).Reason | Should -Match 'manage-bde -resume D:'
        }

        It 'still offers a Windows drive that holds auto-unlock keys, with a note that they are cleared first' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)
            $r = Get-BitLockerDisableState -Volume $d
            $r.CanDisable | Should -BeTrue
            $r.Note | Should -Match 'auto-unlock keys'
            (Get-BitLockerDisableState -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:'))).Note | Should -BeNullOrEmpty
            (Get-BitLockerDisableState -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -AutoUnlockKeyStored $true))).Note | Should -BeNullOrEmpty
        }

        It 'notes a drive that is not fully encrypted yet' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -Status 'EncryptionInProgress' -Percent 30)
            (Get-BitLockerDisableState -Volume $d).Note | Should -Match 'Not fully encrypted'
        }

        It 'describes every state in plain words' {
            $text = { param($Status, $Protection = 'On', $Percent = 100, $Lock = 'Unlocked') Get-BitLockerStateText -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Status $Status -Protection $Protection -Percent $Percent -Lock $Lock)) }
            (& $text 'FullyEncrypted') | Should -Be 'Encrypted'
            (& $text 'FullyEncrypted' 'Off') | Should -Be 'Encrypted, protection suspended'
            (& $text 'FullyDecrypted' 'Off' 0) | Should -Be 'Not encrypted'
            (& $text 'DecryptionInProgress' 'Off' 63) | Should -Be 'Decrypting (63% still encrypted)'
            (& $text 'EncryptionInProgress' 'Off' 40) | Should -Be 'Encrypting (40% done)'
            (& $text 'EncryptionSuspended' 'Off' 40) | Should -Be 'Encryption paused at 40%'
            (& $text 'DecryptionSuspended' 'Off' 63) | Should -Be 'Decryption paused (63% still encrypted)'
            (& $text 'FullyEncryptedWipeInProgress') | Should -Be 'Encrypted, wiping free space'
            (& $text 'FullyEncryptedWipeSuspended') | Should -Be 'Encrypted, free-space wipe paused'
            (& $text 'SomethingNew') | Should -Be 'SomethingNew'
            (& $text '') | Should -Be 'Unknown'
        }

        It 'says Locked for a locked drive, which reports no status at all' {
            (Get-BitLockerStateText -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Lock 'Locked' -Type 'Data'))) | Should -Match '^Locked'
            $noStatus = [pscustomobject]@{ MountPoint = 'E:'; LockStatus = 'Locked'; KeyProtector = @() }
            (Get-BitLockerStateText -Volume (ConvertTo-BitLockerVolumeDetail -Volume $noStatus)) | Should -Match '^Locked'
        }

        It 'summarises the key protectors, telling an auto-unlock key from a startup key file' {
            $d = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC), (New-FakeProtector 'RecoveryPassword' '{X}' '1')))
            Get-BitLockerProtectorSummary -Volume $d | Should -Be 'TPM, Recovery password'
            Get-BitLockerProtectorSummary -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors $null)) | Should -Be 'none'
            Get-BitLockerProtectorSummary -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors @(New-FakeProtector 'SomethingNew' '{Y}'))) | Should -Be 'SomethingNew'
            Get-BitLockerProtectorSummary -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors @((New-FakeProtector 'Password' '{P}'), (New-FakeProtector 'ExternalKey' '{A}' '' '' $true)))) | Should -Be 'Password, Auto-unlock key'
            Get-BitLockerProtectorSummary -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors @(New-FakeProtector 'ExternalKey' '{B}' '' 'K.BEK'))) | Should -Be 'Startup key file (.BEK)'
        }
    }

    Context 'which drives, in what order, and who is affected' {
        BeforeAll {
            $script:mixed = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -AutoUnlockEnabled $true)),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Type 'Data' -Status 'FullyDecrypted' -Protection 'Off' -Percent 0 -AutoUnlockEnabled $true)),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'F:' -Type 'Data'))
            )
        }

        It 'starts data drives first and the Windows drive last, keeping the order of the rest' {
            @(Get-BitLockerDecryptOrder -Volumes $script:mixed -Mounts @('C:', 'F:', 'D:')) -join ',' | Should -Be 'F:,D:,C:'
            @(Get-BitLockerDecryptOrder -Volumes $script:mixed -Mounts @('C:')) -join ',' | Should -Be 'C:'
            @(Get-BitLockerDecryptOrder -Volumes $script:mixed -Mounts @('D:')) -join ',' | Should -Be 'D:'
            @(Get-BitLockerDecryptOrder -Volumes $script:mixed -Mounts @()).Count | Should -Be 0
            # a drive that is not in the list is treated as a data drive
            @(Get-BitLockerDecryptOrder -Volumes $script:mixed -Mounts @('C:', 'Q:')) -join ',' | Should -Be 'Q:,C:'
        }

        It 'names the encrypted drives that will lose auto-unlock and are not being decrypted' {
            @(Get-BitLockerAutoUnlockAffected -Volumes $script:mixed -Mounts @('C:')) -join ',' | Should -Be 'D:'
            @(Get-BitLockerAutoUnlockAffected -Volumes $script:mixed -Mounts @('C:', 'D:')).Count | Should -Be 0
            @(Get-BitLockerAutoUnlockAffected -Volumes $script:mixed -Mounts $null) -join ',' | Should -Be 'D:'
            @(Get-BitLockerAutoUnlockAffected -Volumes @() -Mounts @('C:')).Count | Should -Be 0
        }
    }

    Context 'which keys a backup covers' {
        It 'lists every key protector ID' {
            $vols = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC)))),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors $null))
            )
            @(Get-BitLockerKeyIds -Volumes $vols).Count | Should -Be 2
            @(Get-BitLockerKeyIds -Volumes @()).Count | Should -Be 0
        }

        It 'stays covered while no new key appears, and stops being covered when one does' {
            $vols = @(ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC))))
            $ids = @($script:idTpm, $script:idRec)
            Test-BitLockerKeysCovered -Volumes $vols -BackedUpIds $ids | Should -BeTrue
            Test-BitLockerKeysCovered -Volumes $vols -BackedUpIds @($script:idTpm) | Should -BeFalse
            # a protector that has gone away is harmless
            Test-BitLockerKeysCovered -Volumes @() -BackedUpIds $ids | Should -BeTrue
            Test-BitLockerKeysCovered -Volumes $vols -BackedUpIds @() | Should -BeFalse
        }

        It 'finds the ticked drives that have no recovery password' {
            $vols = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @(New-FakeProtector 'Tpm' $script:idTpm))),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Type 'Data' -Protectors @(New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC))),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'F:' -Type 'Data' -Protectors @(New-FakeProtector 'Password' '{P}')))
            )
            $lacking = @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $vols -Mounts @('C:', 'E:'))
            $lacking.Count | Should -Be 1
            $lacking[0] | Should -Be 'C:'
            @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes $vols -Mounts @()).Count | Should -Be 0
        }
    }

    Context 'the recovery password format' {
        It 'accepts well-formed passwords, including the edges of the allowed range' {
            Test-BitLockerRecoveryPasswordFormat -Candidate $script:pwdC | Should -BeTrue
            Test-BitLockerRecoveryPasswordFormat -Candidate '303853-558635-091828-709577-000891-120549-364804-297176' | Should -BeTrue
            Test-BitLockerRecoveryPasswordFormat -Candidate '000000-000000-000000-000000-000000-000000-000000-000000' | Should -BeTrue
            Test-BitLockerRecoveryPasswordFormat -Candidate '720885-720885-720885-720885-720885-720885-720885-720885' | Should -BeTrue
        }

        It 'rejects anything else' {
            $bad = @(
                '', ' ', '111111-222222-333333-444444-555555-666666-707707',
                '111111-222222-333333-444444-555555-666666-707707-000011-000011',
                '111111-222222-333333-444444-555555-666666-707707-00001',
                '111111-222222-333333-444444-555555-666666-707707-00001A',
                '111111-222222-333333-444444-555555-666666-707707-000012',
                '111111-222222-333333-444444-555555-666666-707707-720896',
                '111111 222222 333333 444444 555555 666666 707707 000011',
                '111111-222222-333333-444444-555555-666666-707707-000011 ',
                ('111111-222222-333333-444444-555555-666666-707707-000011' + "`n"),
                ($script:pwdC.Replace('1', [string][char]0x0661)),
                '(this protector exists but Windows did not return its password)'
            )
            foreach ($b in $bad) { Test-BitLockerRecoveryPasswordFormat -Candidate $b | Should -BeFalse -Because "'$b'" }
            Test-BitLockerRecoveryPasswordFormat -Candidate $null | Should -BeFalse
        }
    }

    Context 'the key backup text' {
        BeforeAll {
            $script:vols = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true -Protectors @(
                    (New-FakeProtector 'Tpm' $script:idTpm),
                    (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC),
                    (New-FakeProtector 'Password' '{PPPPPPPP-0000-0000-0000-000000000003}'),
                    (New-FakeProtector 'TpmPin' '{PPPPPPPP-0000-0000-0000-000000000004}'),
                    (New-FakeProtector 'ExternalKey' '{EEEEEEEE-0000-0000-0000-000000000005}' '' 'ABC123.BEK')))),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -AutoUnlockEnabled $true -Protectors @(
                    (New-FakeProtector 'ExternalKey' '{AAAAAAAA-0000-0000-0000-000000000006}' '' '' $true)))),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Status 'FullyDecrypted' -Protection 'Off' -Percent 0 -Type 'Data' -Protectors $null))
            )
            $script:info = [pscustomobject]@{ ComputerName = 'TESTPC'; UserName = 'TESTPC\tester'; Date = '2026-10-04 17:45:12'; Os = 'Windows 11 Pro (version 10.0.26200)'; Machine = 'Acme Box 1, serial XYZ, BIOS 1.0'; Tpm = 'present=True ready=True enabled=True' }
            $script:text = New-BitLockerBackupText -Volumes $script:vols -Info $script:info -RawStatus 'RAW STATUS' -RawProtectors @{ 'C:' = 'RAW PROTECTORS C' }
        }

        It 'holds every drive, key ID and recovery password, and explains each kind of protector' {
            $script:text | Should -Match 'BITLOCKER KEY BACKUP'
            $script:text | Should -Match 'TESTPC'
            $script:text | Should -Match 'Drive C:'
            $script:text | Should -Match 'Drive D:'
            $script:text | Should -Match 'Drive E:'
            $script:text.Contains($script:pwdC) | Should -BeTrue
            $script:text.Contains($script:idRec) | Should -BeTrue
            $script:text.Contains($script:idTpm) | Should -BeTrue
            $script:text | Should -Match 'password itself cannot be read back'
            $script:text | Should -Match 'PIN cannot be read back'
            $script:text | Should -Match 'ABC123\.BEK'
            $script:text | Should -Match 'RAW PROTECTORS C'
            $script:text | Should -Match 'RAW STATUS'
        }

        It 'does not overpromise about the Key ID shown on the recovery screen' {
            $script:text | Should -Match 'it should match the start of the ID above \(D8542C81\)'
            $script:text | Should -Not -Match 'must start with'
        }

        It 'scopes the recovery instructions to the kind of drive, and says what it cannot hold' {
            $script:text | Should -Match 'blue recovery screen when the PC starts'
            $dataVols = @(ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -Protectors @(New-FakeProtector 'RecoveryPassword' '{D1D1D1D1-0000-0000-0000-000000000001}' $script:pwdC)))
            $dataText = New-BitLockerBackupText -Volumes $dataVols -Info $script:info -RawStatus '' -RawProtectors @{}
            $dataText | Should -Match 'More options, then Enter recovery key'
            $dataText | Should -Not -Match 'blue recovery screen when the PC starts'
            $script:text | Should -Match 'cannot be read back from Windows, so they are not in it'
        }

        It 'records the auto-unlock facts' {
            $script:text | Should -Match 'Holds auto-unlock keys for other drives: True'
            $script:text | Should -Match 'Auto-unlock: True'
            $script:text | Should -Match 'Auto-unlock key: lets Windows unlock this drive by itself'
        }

        It 'uses CRLF lines, ends with its marker, and is plain ASCII' {
            $script:text.Contains("`r`n") | Should -BeTrue
            ($script:text -replace "`r`n", '').Contains("`n") | Should -BeFalse
            $script:text.TrimEnd() | Should -Match 'END OF BACKUP$'
            ($script:text.ToCharArray() | Where-Object { [int]$_ -gt 127 }).Count | Should -Be 0
        }

        It 'copes with no volumes at all' {
            $t = New-BitLockerBackupText -Volumes @() -Info $script:info -RawStatus '' -RawProtectors @{}
            $t | Should -Match 'SUMMARY \(0 volume'
            $t.TrimEnd() | Should -Match 'END OF BACKUP$'
        }

        It 'passes its own check, and fails it when anything is missing or damaged' {
            (Test-BitLockerBackupText -Text $script:text -Volumes $script:vols).Ok | Should -BeTrue
            $badPassword = $script:text.Replace($script:pwdC, $script:pwdC.Replace('1', '2'))
            $r = Test-BitLockerBackupText -Text $badPassword -Volumes $script:vols
            $r.Ok | Should -BeFalse
            ($r.Missing -join ' ') | Should -Match 'recovery password'
            $cut = $script:text.Substring(0, [int]($script:text.Length / 2))
            (Test-BitLockerBackupText -Text $cut -Volumes $script:vols).Ok | Should -BeFalse
            (Test-BitLockerBackupText -Text '' -Volumes $script:vols).Ok | Should -BeFalse
            $noId = $script:text.Replace($script:idTpm, 'REDACTED')
            ((Test-BitLockerBackupText -Text $noId -Volumes $script:vols).Missing -join ' ') | Should -Match 'key ID'
        }

        It 'fails the check for a recovery password that is not a well-formed 48-digit one, even when the file holds it' {
            $odd = @(ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @(New-FakeProtector 'RecoveryPassword' $script:idRec '123456-123456')))
            $t = New-BitLockerBackupText -Volumes $odd -Info $script:info -RawStatus '' -RawProtectors @{}
            $r = Test-BitLockerBackupText -Text $t -Volumes $odd
            $r.Ok | Should -BeFalse
            ($r.Missing -join ' ') | Should -Match 'well-formed'
        }
    }

    Context 'where the backup file is saved' {
        BeforeAll {
            $script:placeVols = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:')),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data')),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Type 'Data' -Status 'FullyDecrypted' -Protection 'Off' -Percent 0))
            )
        }

        It 'says nothing when the file is on a drive that is not encrypted' {
            Get-BitLockerBackupPlaceNote -Path 'E:\Backups\k.txt' -Volumes $script:placeVols -Mounts @('C:', 'D:') -CloudRoots @() | Should -BeNullOrEmpty
            Get-BitLockerBackupPlaceNote -Path 'Q:\k.txt' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @() | Should -BeNullOrEmpty
            Get-BitLockerBackupPlaceNote -Path '' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @() | Should -BeNullOrEmpty
            Get-BitLockerBackupPlaceNote -Path 'E:' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @() | Should -BeNullOrEmpty
        }

        It 'warns when the file is on a drive that is about to be decrypted (any letter case)' {
            Get-BitLockerBackupPlaceNote -Path 'C:\Users\x\k.txt' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @() | Should -Match 'about to be decrypted'
            Get-BitLockerBackupPlaceNote -Path 'c:\users\x\k.txt' -Volumes $script:placeVols -Mounts @('E:', 'C:') -CloudRoots $null | Should -Match 'on C:'
        }

        It 'warns when the file is on an encrypted drive that is NOT being decrypted: its key would be locked inside it' {
            $n = Get-BitLockerBackupPlaceNote -Path 'C:\Users\x\k.txt' -Volumes $script:placeVols -Mounts @('D:') -CloudRoots @()
            $n | Should -Match 'on C:, which is encrypted'
            $n | Should -Match 'locked inside it'
        }

        It 'says a file inside OneDrive also goes to the cloud, whatever drive it is on' {
            $n = Get-BitLockerBackupPlaceNote -Path 'C:\Users\x\OneDrive - Acme\Desktop\k.txt' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @('', 'C:\Users\x\OneDrive - Acme')
            $n | Should -Match 'inside OneDrive'
            $n | Should -Match 'on C:'
            (Get-BitLockerBackupPlaceNote -Path 'E:\OneDrive\k.txt' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @('E:\OneDrive')) | Should -Match '^The file is inside OneDrive'
            # a folder that merely starts with the same letters is not inside OneDrive
            Get-BitLockerBackupPlaceNote -Path 'E:\OneDrive - Acme2\k.txt' -Volumes $script:placeVols -Mounts @('C:') -CloudRoots @('E:\OneDrive - Acme') | Should -BeNullOrEmpty
        }
    }

    Context 'which folder is offered for the backup' {
        BeforeAll {
            function New-FakeDrive([string]$Name, [string]$Kind, [bool]$Ready = $true) { [pscustomobject]@{ Name = $Name; DriveType = $Kind; IsReady = $Ready } }
            $script:driveVols = @(
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:')),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data')),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'F:' -Type 'Data' -Status 'FullyDecrypted' -Protection 'Off' -Percent 0)),
                (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'G:' -Type 'Data' -Lock 'Locked'))
            )
        }

        It 'prefers a ready, unencrypted removable drive, then another unencrypted fixed drive, never the Windows drive' {
            $drives = @((New-FakeDrive 'C:\' 'Fixed'), (New-FakeDrive 'D:\' 'Fixed'), (New-FakeDrive 'E:\' 'Removable'), (New-FakeDrive 'F:\' 'Fixed'))
            Get-BitLockerDefaultBackupFolder -Drives $drives -Volumes $script:driveVols -WindowsDrive 'C:' -Fallback 'FALLBACK' | Should -Be 'E:\'
            # E: not ready -> the fixed drive that is not encrypted (D: is encrypted)
            $drives2 = @((New-FakeDrive 'C:\' 'Fixed'), (New-FakeDrive 'D:\' 'Fixed'), (New-FakeDrive 'E:\' 'Removable' $false), (New-FakeDrive 'F:\' 'Fixed'))
            Get-BitLockerDefaultBackupFolder -Drives $drives2 -Volumes $script:driveVols -WindowsDrive 'C:' -Fallback 'FALLBACK' | Should -Be 'F:\'
        }

        It 'skips encrypted and locked drives and falls back when nothing suits' {
            $drives = @((New-FakeDrive 'C:\' 'Fixed'), (New-FakeDrive 'D:\' 'Fixed'), (New-FakeDrive 'G:\' 'Removable'), (New-FakeDrive 'Z:\' 'Network'), (New-FakeDrive 'H:\' 'CDRom'))
            Get-BitLockerDefaultBackupFolder -Drives $drives -Volumes $script:driveVols -WindowsDrive 'C:' -Fallback 'FALLBACK' | Should -Be 'FALLBACK'
            Get-BitLockerDefaultBackupFolder -Drives @() -Volumes @() -WindowsDrive 'C:' -Fallback 'FALLBACK' | Should -Be 'FALLBACK'
            Get-BitLockerDefaultBackupFolder -Drives $null -Volumes $null -WindowsDrive 'C:' -Fallback '' | Should -Be ''
        }

        It 'treats a drive BitLocker does not list as unencrypted, and ignores odd names' {
            $drives = @((New-FakeDrive '\\server\share\' 'Removable'), (New-FakeDrive 'EE:\' 'Removable'), (New-FakeDrive 'K:\' 'Removable'))
            Get-BitLockerDefaultBackupFolder -Drives $drives -Volumes $script:driveVols -WindowsDrive 'C:' -Fallback 'FALLBACK' | Should -Be 'K:\'
        }
    }

    Context 'checking a backup place and a backup that was made' {
        It 'accepts only a full path in an existing, writable folder where nothing has that name yet' {
            (Test-BitLockerBackupPath -Path (Join-Path $TestDrive 'ok.txt')).Ok | Should -BeTrue
            (Test-BitLockerBackupPath -Path 'ok.txt').Ok | Should -BeFalse
            (Test-BitLockerBackupPath -Path 'C:ok.txt').Ok | Should -BeFalse      # drive-relative: rooted, but not a full path
            (Test-BitLockerBackupPath -Path '\ok.txt').Ok | Should -BeFalse
            (Test-BitLockerBackupPath -Path '').Ok | Should -BeFalse
            (Test-BitLockerBackupPath -Path (Join-Path $TestDrive 'no-such-dir\ok.txt')).Error | Should -Match 'does not exist'
            Set-Content -LiteralPath (Join-Path $TestDrive 'taken.txt') -Value 'x' -Encoding ASCII
            (Test-BitLockerBackupPath -Path (Join-Path $TestDrive 'taken.txt')).Error | Should -Match 'already exists'
        }

        It 'leaves nothing behind when it checks the folder' {
            $dir = Join-Path $TestDrive 'probe-dir'
            New-Item -ItemType Directory -Path $dir | Out-Null
            (Test-BitLockerBackupPath -Path (Join-Path $dir 'ok.txt')).Ok | Should -BeTrue
            @(Get-ChildItem -LiteralPath $dir -Force).Count | Should -Be 0
        }

        It 'sorts a drive''s key IDs into one comparable text' {
            $v = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' '{B}'), (New-FakeProtector 'RecoveryPassword' '{A}' $script:pwdC)))
            Get-BitLockerKeyIdSet -Volume $v | Should -BeExactly '{A},{B}'
            Get-BitLockerKeyIdSet -Volume (ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Protectors $null)) | Should -BeExactly ''
        }

        It 'says the backup is still good only while the file, its hash and the keys all match' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC)))
            $vols = @((Get-BitLockerVolumeDetail).Volumes)
            $text = New-BitLockerBackupText -Volumes $vols -Info ([pscustomobject]@{ ComputerName = 'T'; UserName = 'T\t'; Date = 'now'; Os = ''; Machine = ''; Tpm = '' }) -RawStatus '' -RawProtectors @{}
            $path = Join-Path $TestDrive 'still-good.txt'
            $save = Save-BitLockerBackupFile -Path $path -Text $text
            $ids = @(Get-BitLockerKeyIds -Volumes $vols)
            $ok = Test-BitLockerBackupStillGood -Path $path -Hash $save.Hash -BackedUpIds $ids
            $ok.Ok | Should -BeTrue
            @($ok.Volumes).Count | Should -Be 1
            # the file was edited
            $bad = Test-BitLockerBackupStillGood -Path $path -Hash 'DIFFERENT' -BackedUpIds $ids
            $bad.Ok | Should -BeFalse; $bad.Stale | Should -BeTrue; $bad.Reason | Should -Match 'changed'
            # the file is gone
            $gone = Test-BitLockerBackupStillGood -Path (Join-Path $TestDrive 'missing.txt') -Hash $save.Hash -BackedUpIds $ids
            $gone.Ok | Should -BeFalse; $gone.Stale | Should -BeTrue; $gone.Reason | Should -Match 'gone'
            # a new key appeared
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'Tpm' $script:idTpm), (New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC), (New-FakeProtector 'RecoveryPassword' '{NEW}' $script:pwdC)))
            $newKey = Test-BitLockerBackupStillGood -Path $path -Hash $save.Hash -BackedUpIds $ids
            $newKey.Ok | Should -BeFalse; $newKey.Stale | Should -BeTrue; $newKey.Reason | Should -Match 'keys on this PC have changed'
            # BitLocker cannot be read this time: not good, but the backup itself is not stale
            $script:fake.GetThrows = 'WMI hiccup'
            $hiccup = Test-BitLockerBackupStillGood -Path $path -Hash $save.Hash -BackedUpIds $ids
            $hiccup.Ok | Should -BeFalse; $hiccup.Stale | Should -BeFalse; $hiccup.Reason | Should -Match 'Could not read BitLocker status'
        }
    }

    Context 'long jobs that should finish before a decrypt' {
        It 'names the jobs of this app that are still running' {
            $script:deployProc = [pscustomobject]@{ HasExited = $false }
            $script:fixProc = [pscustomobject]@{ HasExited = $true }
            $script:installProc = $null
            $script:provisionProc = [pscustomobject]@{ HasExited = $false }
            $script:wingetInstallProc = [pscustomobject]@{ HasExited = $true }
            (@(Get-RunningToolJobs) -join ',') | Should -Be 'Debloat / Office,Provisioning'
            $script:deployProc = $null; $script:provisionProc = $null
            @(Get-RunningToolJobs).Count | Should -Be 0
        }
    }

    Context 'saving the backup file' {
        BeforeAll {
            $script:vols2 = @(ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:' -Protectors @((New-FakeProtector 'RecoveryPassword' $script:idRec $script:pwdC))))
            $script:text2 = New-BitLockerBackupText -Volumes $script:vols2 -Info ([pscustomobject]@{ ComputerName = 'T'; UserName = 'T\t'; Date = 'now'; Os = ''; Machine = ''; Tpm = '' }) -RawStatus '' -RawProtectors @{}
        }

        It 'writes UTF-8 without a BOM, reads it back, and returns its hash' {
            $path = Join-Path $TestDrive 'backup1.txt'
            $r = Save-BitLockerBackupFile -Path $path -Text $script:text2
            $r.Ok | Should -BeTrue
            $r.Error | Should -BeNullOrEmpty
            $r.Text | Should -BeExactly $script:text2
            $r.Hash | Should -Be (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
            $bytes = [System.IO.File]::ReadAllBytes($path)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeFalse
            (Test-BitLockerBackupText -Text $r.Text -Volumes $script:vols2).Ok | Should -BeTrue
        }

        It 'stops the file being inherited from the folder (only the owner, administrators and SYSTEM)' {
            $path = Join-Path $TestDrive 'backup-acl.txt'
            $r = Save-BitLockerBackupFile -Path $path -Text $script:text2
            $r.Ok | Should -BeTrue
            (Get-Acl -LiteralPath $path).AreAccessRulesProtected | Should -BeTrue
            $names = @((Get-Acl -LiteralPath $path).Access | ForEach-Object { $_.IdentityReference.Value })
            ($names | Where-Object { $_ -match 'SYSTEM' }).Count | Should -BeGreaterThan 0
            ($names | Where-Object { $_ -match 'Administrators' }).Count | Should -BeGreaterThan 0
            ($names | Where-Object { $_ -match 'Everyone|Users$|Authenticated' }).Count | Should -Be 0
        }

        It 'never overwrites an existing file' {
            $path = Join-Path $TestDrive 'backup-existing.txt'
            Set-Content -LiteralPath $path -Value 'EARLIER BACKUP' -Encoding ASCII
            $r = Save-BitLockerBackupFile -Path $path -Text $script:text2
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'already exists'
            (Get-Content -LiteralPath $path -Raw).Trim() | Should -Be 'EARLIER BACKUP'
        }

        It 'refuses a relative path, a missing folder and an empty path without writing anything' {
            (Save-BitLockerBackupFile -Path 'backup.txt' -Text $script:text2).Ok | Should -BeFalse
            (Save-BitLockerBackupFile -Path '' -Text $script:text2).Ok | Should -BeFalse
            $missing = Join-Path $TestDrive 'no-such-folder\backup.txt'
            $r = Save-BitLockerBackupFile -Path $missing -Text $script:text2
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'does not exist'
            Test-Path -LiteralPath $missing | Should -BeFalse
        }
    }

    Context 'Windows error text' {
        It 'adds what to do about the codes it knows, keeping Windows own wording' {
            $locked = Get-BitLockerFriendlyError -Message 'This drive is locked by BitLocker Drive Encryption. You must unlock this drive from Control Panel. (0x80310000)'
            $locked | Should -Match '^This drive is locked by BitLocker'
            $locked | Should -Match 'Unlock it first'
            Get-BitLockerFriendlyError -Message 'BitLocker Drive Encryption cannot be turned off on the operating system drive until the auto unlock feature has been disabled for the fixed data drives and removable data drives associated with this computer. (0x80310029)' | Should -Match 'Clear them'
            Get-BitLockerFriendlyError -Message 'BitLocker Drive Encryption is not enabled on this drive. Turn on BitLocker. (0x80310008)' | Should -Match 'nothing to turn off'
        }

        It 'finds the code in the wording Windows PowerShell 5.1 gives it ("Exception from HRESULT: 0x...")' {
            Get-BitLockerFriendlyError -Message 'This drive is locked by BitLocker Drive Encryption. You must unlock this drive from Control Panel. (Exception from HRESULT: 0x80310000)' | Should -Match 'Unlock it first'
            Get-BitLockerFriendlyError -Message 'BitLocker Drive Encryption is not enabled on this drive. Turn on BitLocker. (Exception from HRESULT: 0x80310008)' | Should -Match 'nothing to turn off'
            Get-BitLockerFriendlyError -Message 'x (Exception from HRESULT: 0x80310029)' | Should -Match 'Clear them'
        }

        It 'explains a bare access-denied code, from the text or from the HRESULT' {
            Get-BitLockerFriendlyError -Message '0x80041003' | Should -Match 'administrator'
            Get-BitLockerFriendlyError -Message 'Access is denied. (0x80070005 (E_ACCESSDENIED))' | Should -Match 'administrator'
            Get-BitLockerFriendlyError -Message '' -HResult ([int]0x80041003) | Should -Match 'administrator'
            Get-BitLockerFriendlyError -Message 'Something else' -HResult ([int]0x80041003) | Should -Match 'administrator'
        }

        It 'leaves an unknown error as it is' {
            Get-BitLockerFriendlyError -Message 'The drive is too small to be protected. (0x8031006F)' | Should -Be 'The drive is too small to be protected. (0x8031006F)'
            Get-BitLockerFriendlyError -Message 'boom' | Should -Be 'boom'
            Get-BitLockerFriendlyError -Message '' | Should -Be 'Unknown error'
        }
    }

    Context 'the decrypt guard' {
        It 'only ever acts on exactly one drive letter' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:')
            $bad = @('C', 'C:\', '*', 'C: D:', 'CD:', '', ' C:', 'C:*', ('c' + [char]0x212A + ':'), ([string][char]0x212A + ':'))
            foreach ($b in $bad) {
                (Start-BitLockerDecrypt -MountPoint $b).Ok | Should -BeFalse -Because "'$b' is not a drive letter"
            }
            $script:fake.DisableCalls.Count | Should -Be 0
        }

        It 'decrypts an encrypted, unlocked drive by calling Disable-BitLocker once with that drive' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:'; New-FakeVolume -Mount 'D:')
            $r = Start-BitLockerDecrypt -MountPoint 'C:'
            $r.Ok | Should -BeTrue
            $r.ClearedAutoUnlock | Should -BeFalse
            $script:fake.DisableCalls.Count | Should -Be 1
            $script:fake.DisableCalls[0] | Should -Be 'C:'
            $script:fake.ClearCalls | Should -Be 0
        }

        It 'refuses a drive that has changed since the dialog looked (locked, decrypted, already decrypting, paused, hardware)' {
            foreach ($case in @(@('FullyEncrypted', 'Locked', 'XtsAes256'), @('FullyDecrypted', 'Unlocked', 'None'), @('DecryptionInProgress', 'Unlocked', 'XtsAes256'), @('DecryptionSuspended', 'Unlocked', 'XtsAes256'), @('FullyEncrypted', 'Unlocked', 'Hardware'))) {
                $script:fake.Volumes = @(New-FakeVolume -Mount 'E:' -Status $case[0] -Lock $case[1] -Method $case[2])
                $r = Start-BitLockerDecrypt -MountPoint 'E:'
                $r.Ok | Should -BeFalse
                $r.Error | Should -Match 'cannot be decrypted now'
            }
            $script:fake.DisableCalls.Count | Should -Be 0
        }

        It 'reports a failure from BitLocker or from reading the drive, without throwing' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:')
            $script:fake.DisableThrows = 'Access is denied'
            $r = Start-BitLockerDecrypt -MountPoint 'C:'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'Access is denied'
            $script:fake.GetThrows = 'no module'
            (Start-BitLockerDecrypt -MountPoint 'C:').Error | Should -Match 'Could not read C:'
        }

        It 'says what to do when Windows refuses with one of its own codes' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'D:' -Type 'Data')
            $script:fake.DisableThrows = 'This drive is locked by BitLocker Drive Encryption. You must unlock this drive from Control Panel. (0x80310000)'
            (Start-BitLockerDecrypt -MountPoint 'D:').Error | Should -Match 'Unlock it first'
        }

        It 'refuses a Windows drive that holds auto-unlock keys unless it is told to clear them' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)
            $r = Start-BitLockerDecrypt -MountPoint 'C:'
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'auto-unlock keys'
            $script:fake.ClearCalls | Should -Be 0
            $script:fake.DisableCalls.Count | Should -Be 0
            @($script:fake.Volumes)[0].AutoUnlockKeyStored | Should -BeTrue
        }

        It 'clears the stored auto-unlock keys first when told to, then decrypts' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)
            $r = Start-BitLockerDecrypt -MountPoint 'C:' -ClearAutoUnlock
            $r.Ok | Should -BeTrue
            $r.ClearedAutoUnlock | Should -BeTrue
            $script:fake.ClearCalls | Should -Be 1
            $script:fake.DisableCalls.Count | Should -Be 1
            @($script:fake.Volumes)[0].AutoUnlockKeyStored | Should -BeFalse
        }

        It 'does not decrypt when the keys cannot be cleared, or Windows still reports them afterwards' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true)
            $script:fake.ClearThrows = 'Access is denied'
            $r = Start-BitLockerDecrypt -MountPoint 'C:' -ClearAutoUnlock
            $r.Ok | Should -BeFalse
            $r.Error | Should -Match 'Could not clear the auto-unlock keys'
            $script:fake.DisableCalls.Count | Should -Be 0
            $script:fake.ClearThrows = $null
            $script:fake.ClearIsNoOp = $true
            $r2 = Start-BitLockerDecrypt -MountPoint 'C:' -ClearAutoUnlock
            $r2.Ok | Should -BeFalse
            $r2.Error | Should -Match 'still reports'
            $script:fake.DisableCalls.Count | Should -Be 0
        }

        It 'never clears auto-unlock keys when the drive being decrypted is a data drive' {
            $script:fake.Volumes = @(New-FakeVolume -Mount 'C:' -AutoUnlockKeyStored $true; New-FakeVolume -Mount 'D:' -Type 'Data')
            $r = Start-BitLockerDecrypt -MountPoint 'D:' -ClearAutoUnlock
            $r.Ok | Should -BeTrue
            $r.ClearedAutoUnlock | Should -BeFalse
            $script:fake.ClearCalls | Should -Be 0
            @($script:fake.Volumes)[0].AutoUnlockKeyStored | Should -BeTrue
        }

        It 'adds a recovery password only to a named drive letter and reports failures' {
            (Add-BitLockerRecoveryProtector -MountPoint 'C:' 3>$null).Ok | Should -BeTrue
            $script:fake.AddCalls.Count | Should -Be 1
            (Add-BitLockerRecoveryProtector -MountPoint 'C:\').Ok | Should -BeFalse
            $script:fake.AddCalls.Count | Should -Be 1
            $script:fake.AddThrows = 'denied'
            (Add-BitLockerRecoveryProtector -MountPoint 'D:' 3>$null).Error | Should -Be 'denied'
        }

        It 'never lets the new recovery password reach the warning stream' {
            $out = @(Add-BitLockerRecoveryProtector -MountPoint 'C:' 3>&1)
            @($out | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }).Count | Should -Be 0
            ($out | Out-String) | Should -Not -Match '111111'
        }
    }

    Context 'the PreventDeviceEncryption setting' {
        It 'reads $null when the key or the value is missing, and the number when it is there' {
            Get-PreventDeviceEncryptionValue -Path 'TestRegistry:\NoSuchKey' | Should -BeNullOrEmpty
            New-Item -Path 'TestRegistry:\EmptyKey' -Force | Out-Null
            Get-PreventDeviceEncryptionValue -Path 'TestRegistry:\EmptyKey' | Should -BeNullOrEmpty
            New-Item -Path 'TestRegistry:\HasValue' -Force | Out-Null
            New-ItemProperty -LiteralPath 'TestRegistry:\HasValue' -Name 'PreventDeviceEncryption' -Value 1 -PropertyType DWord | Out-Null
            Get-PreventDeviceEncryptionValue -Path 'TestRegistry:\HasValue' | Should -Be 1
        }

        It 'creates the key and the value when they are missing' {
            $r = Set-PreventDeviceEncryption -Path 'TestRegistry:\Fresh\Control\BitLocker'
            $r.Ok | Should -BeTrue
            $r.AlreadySet | Should -BeFalse
            Get-PreventDeviceEncryptionValue -Path 'TestRegistry:\Fresh\Control\BitLocker' | Should -Be 1
        }

        It 'changes a 0 to 1 and keeps the key''s other values' {
            New-Item -Path 'TestRegistry:\Zero' -Force | Out-Null
            New-ItemProperty -LiteralPath 'TestRegistry:\Zero' -Name 'PreventDeviceEncryption' -Value 0 -PropertyType DWord | Out-Null
            New-ItemProperty -LiteralPath 'TestRegistry:\Zero' -Name 'SomethingElse' -Value 'keep me' -PropertyType String | Out-Null
            $r = Set-PreventDeviceEncryption -Path 'TestRegistry:\Zero'
            $r.Ok | Should -BeTrue
            $r.AlreadySet | Should -BeFalse
            Get-PreventDeviceEncryptionValue -Path 'TestRegistry:\Zero' | Should -Be 1
            (Get-ItemProperty -LiteralPath 'TestRegistry:\Zero').SomethingElse | Should -Be 'keep me'
        }

        It 'writes nothing when it is already 1' {
            New-Item -Path 'TestRegistry:\One' -Force | Out-Null
            New-ItemProperty -LiteralPath 'TestRegistry:\One' -Name 'PreventDeviceEncryption' -Value 1 -PropertyType DWord | Out-Null
            $r = Set-PreventDeviceEncryption -Path 'TestRegistry:\One'
            $r.Ok | Should -BeTrue
            $r.AlreadySet | Should -BeTrue
        }
    }

    Context 'warnings before decrypting' {
        It 'sees a BitLocker policy only when a policy key actually holds a value' {
            Test-BitLockerPolicyPresent -Path @('TestRegistry:\NoPolicyHere') | Should -BeFalse
            New-Item -Path 'TestRegistry:\Pol\Empty' -Force | Out-Null
            Test-BitLockerPolicyPresent -Path @('TestRegistry:\Pol\Empty') | Should -BeFalse
            New-Item -Path 'TestRegistry:\Pol\Set' -Force | Out-Null
            New-ItemProperty -LiteralPath 'TestRegistry:\Pol\Set' -Name 'EncryptionMethodWithXtsOs' -Value 7 -PropertyType DWord | Out-Null
            Test-BitLockerPolicyPresent -Path @('TestRegistry:\Pol\Set') | Should -BeTrue
            Test-BitLockerPolicyPresent -Path @('TestRegistry:\NoPolicyHere', 'TestRegistry:\Pol\Empty', 'TestRegistry:\Pol\Set') | Should -BeTrue
        }

        It 'never throws, and always gives back plain text lines' {
            { Get-BitLockerDecryptWarnings } | Should -Not -Throw
            foreach ($w in @(Get-BitLockerDecryptWarnings)) { $w | Should -BeOfType [string] }
        }
    }

    Context 'progress while decrypting' {
        It 'writes elapsed times the way a person would' {
            Get-BitLockerElapsedText -Span ([timespan]::FromSeconds(0)) | Should -Be 'under a minute'
            Get-BitLockerElapsedText -Span ([timespan]::FromSeconds(59)) | Should -Be 'under a minute'
            Get-BitLockerElapsedText -Span ([timespan]::FromSeconds(60)) | Should -Be '1 min'
            Get-BitLockerElapsedText -Span ([timespan]::FromMinutes(12.9)) | Should -Be '12 min'
            Get-BitLockerElapsedText -Span ([timespan]::FromMinutes(59)) | Should -Be '59 min'
            Get-BitLockerElapsedText -Span ([timespan]::FromMinutes(60)) | Should -Be '1 h 00 min'
            Get-BitLockerElapsedText -Span ([timespan]::FromMinutes(125)) | Should -Be '2 h 05 min'
        }

        It 'shows the state, the time so far and - once it has moved - a rough time left' {
            $t0 = Get-Date '2026-10-04 12:00:00'
            $started = [pscustomobject]@{ At = $t0; StartPercent = 100 }
            $vol = { param($Status, $Percent) ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'D:' -Type 'Data' -Status $Status -Protection 'Off' -Percent $Percent) }
            # 20 points in 10 minutes -> 80 points to go -> about 40 minutes
            Get-BitLockerProgressText -Volume (& $vol 'DecryptionInProgress' 80) -Started $started -Now $t0.AddMinutes(10) | Should -Be 'Decrypting (80% still encrypted) - running 10 min, about 40 min left'
            # too little progress, or too little time, for an estimate
            Get-BitLockerProgressText -Volume (& $vol 'DecryptionInProgress' 98) -Started $started -Now $t0.AddMinutes(10) | Should -Be 'Decrypting (98% still encrypted) - running 10 min'
            Get-BitLockerProgressText -Volume (& $vol 'DecryptionInProgress' 90) -Started $started -Now $t0.AddSeconds(30) | Should -Be 'Decrypting (90% still encrypted) - running under a minute'
            Get-BitLockerProgressText -Volume (& $vol 'FullyDecrypted' 0) -Started $started -Now $t0.AddMinutes(41) | Should -Be 'Decrypted - took 41 min'
            Get-BitLockerProgressText -Volume (& $vol 'DecryptionSuspended' 55) -Started $started -Now $t0.AddMinutes(7) | Should -Be 'Decryption paused (55% still encrypted) - running 7 min'
            Get-BitLockerProgressText -Volume (& $vol 'DecryptionInProgress' 80) -Started $null -Now $t0 | Should -Be 'Decrypting (80% still encrypted)'
        }
    }

    Context 'what kind of drive it is' {
        It 'names a Windows drive, and a data drive with its kind and label' {
            $os = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:')
            $data = ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'E:' -Type 'Data')
            Get-BitLockerTypeText -Volume $os -Drive ([pscustomobject]@{ Kind = 'Fixed'; Label = '' }) | Should -Be 'Windows drive'
            Get-BitLockerTypeText -Volume $os -Drive ([pscustomobject]@{ Kind = 'Fixed'; Label = 'OS' }) | Should -Be 'Windows drive (OS)'
            Get-BitLockerTypeText -Volume $data -Drive ([pscustomobject]@{ Kind = 'Removable'; Label = 'BACKUPS' }) | Should -Be 'Data drive, removable (BACKUPS)'
            Get-BitLockerTypeText -Volume $data -Drive ([pscustomobject]@{ Kind = 'Fixed'; Label = '' }) | Should -Be 'Data drive, fixed'
            Get-BitLockerTypeText -Volume $data -Drive ([pscustomobject]@{ Kind = 'Unknown'; Label = '' }) | Should -Be 'Data drive'
            Get-BitLockerTypeText -Volume $data -Drive $null | Should -Be 'Data drive'
        }

        It 'asks .NET about a real drive letter only, and never throws' {
            (Get-BitLockerDriveDescription -MountPoint 'not a drive').Kind | Should -Be ''
            (Get-BitLockerDriveDescription -MountPoint '').Kind | Should -Be ''
            (Get-BitLockerDriveDescription -MountPoint 'C:\').Kind | Should -Be ''
            (Get-BitLockerDriveDescription -MountPoint $env:SystemDrive).Kind | Should -Be 'Fixed'
        }
    }

    Context 'the raw manage-bde text and the action log' {
        It 'collects manage-bde output per valid drive letter only' {
            $vols = @(ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'C:'); ConvertTo-BitLockerVolumeDetail -Volume (New-FakeVolume -Mount 'bad'))
            $raw = Get-BitLockerRawOutput -Volumes $vols
            $raw.Status | Should -Be 'FAKE STATUS OUTPUT'
            $raw.Protectors.ContainsKey('C:') | Should -BeTrue
            $raw.Protectors['C:'] | Should -Match 'FAKE PROTECTORS FOR C:'
            $raw.Protectors.ContainsKey('bad') | Should -BeFalse
        }

        It 'does not create the audit folder in a session that is not elevated (it would lock that session out of it)' {
            $isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            if ($isAdmin) { Set-ItResult -Skipped -Because 'this session is elevated'; return }
            $oldPd = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive 'ProgramDataNoAdmin'
            try {
                New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
                Get-BitLockerAuditFolder | Should -BeNullOrEmpty
                Test-Path -LiteralPath (Join-Path $env:ProgramData 'Gr3yTools') | Should -BeFalse
            } finally { $env:ProgramData = $oldPd }
        }

        It 'writes the action log to a protected audit folder (UTF-8), restricted to administrators and SYSTEM' {
            $isAdmin = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            if (-not $isAdmin) { Set-ItResult -Skipped -Because 'needs an elevated session: the folder is restricted to elevated administrators'; return }
            $oldPd = $env:ProgramData
            $env:ProgramData = Join-Path $TestDrive 'ProgramData'
            try {
                New-Item -ItemType Directory -Path $env:ProgramData | Out-Null
                Write-BitLockerActionLog "Key backup saved: $TestDrive\Sicherung-$([char]0xE4).txt"
                Write-BitLockerActionLog 'Decryption started: C:'
                $audit = Join-Path $env:ProgramData 'Gr3yTools\audit'
                $logFile = Join-Path $audit 'bitlocker-actions.log'
                Test-Path -LiteralPath $logFile | Should -BeTrue
                $log = [System.IO.File]::ReadAllText($logFile, (New-Object System.Text.UTF8Encoding($false)))
                $log | Should -Match 'Decryption started: C:'
                $log.Contains([string][char]0xE4) | Should -BeTrue
                (Get-Acl -LiteralPath $audit).AreAccessRulesProtected | Should -BeTrue
                $who = @((Get-Acl -LiteralPath $audit).Access | ForEach-Object { $_.IdentityReference.Value })
                @($who | Where-Object { $_ -match 'Everyone|Users$|Authenticated' }).Count | Should -Be 0
                @($who | Where-Object { $_ -match 'Administrators' }).Count | Should -BeGreaterThan 0
            } finally { $env:ProgramData = $oldPd }
        }

        It 'falls back to the work folder when the audit folder cannot be used, and never throws' {
            $oldPd = $env:ProgramData
            $script:workDirBackup = $workDir
            try {
                $env:ProgramData = 'Z:\no-such-drive-for-sure'
                $workDir = Join-Path $TestDrive 'logs'
                Write-BitLockerActionLog 'Decryption started: C:'
                (Get-Content -LiteralPath (Join-Path $workDir 'bitlocker-actions.log') -Raw) | Should -Match 'Decryption started: C:'
                $workDir = 'Z:\no-such-drive-for-sure\logs'
                { Write-BitLockerActionLog 'ignored' } | Should -Not -Throw
            } finally { $env:ProgramData = $oldPd; $workDir = $script:workDirBackup }
        }
    }

    Context 'structural guards on the real script' {
        BeforeAll {
            $tokens = $null; $errs = $null
            $script:ast = [System.Management.Automation.Language.Parser]::ParseFile($script:guiPath, [ref]$tokens, [ref]$errs)
            function Get-CallSites([string]$CommandName) {
                $calls = $script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq $CommandName }, $true)
                return @($calls | ForEach-Object {
                    $p = $_.Parent
                    while ($p -and $p -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $p = $p.Parent }
                    $(if ($p) { $p.Name } else { '(script level)' })
                })
            }
        }

        It 'decrypts a drive from exactly one place, Start-BitLockerDecrypt' {
            $sites = @(Get-CallSites 'Disable-BitLocker')
            $sites.Count | Should -Be 1
            $sites[0] | Should -Be 'Start-BitLockerDecrypt'
        }

        It 'clears auto-unlock keys, adds key protectors and runs manage-bde from one place each' {
            @(Get-CallSites 'Clear-BitLockerAutoUnlock') -join ',' | Should -Be 'Clear-BitLockerStoredAutoUnlock'
            @(Get-CallSites 'Add-BitLockerKeyProtector') -join ',' | Should -Be 'Add-BitLockerRecoveryProtector'
            (@(Get-CallSites 'manage-bde') | Select-Object -Unique) -join ',' | Should -Be 'Get-BitLockerRawOutput'
        }

        It 'never removes or changes a key protector, suspends protection or turns BitLocker on from the Disable dialog code' {
            foreach ($cmd in 'Remove-BitLockerKeyProtector', 'Suspend-BitLocker', 'Resume-BitLocker', 'Enable-BitLocker', 'Enable-BitLockerAutoUnlock', 'Disable-BitLockerAutoUnlock', 'Lock-BitLocker', 'Unlock-BitLocker') {
                @(Get-CallSites $cmd).Count | Should -Be 0 -Because $cmd
            }
        }

        It 'never hands a recovery password or the backup text to the action log' {
            $logCalls = @($script:ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-BitLockerActionLog' }, $true))
            $logCalls.Count | Should -BeGreaterThan 5
            foreach ($c in $logCalls) { $c.Extent.Text | Should -Not -Match 'RecoveryPassword|\$text\b|\.Text\b|\$save\b' -Because $c.Extent.Text }
        }
    }
}

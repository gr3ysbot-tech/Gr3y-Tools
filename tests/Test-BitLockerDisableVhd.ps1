#Requires -Version 5.1
#Requires -PSEdition Desktop
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    End-to-end test of the "Disable BitLocker" code against REAL BitLocker, on a THROWAWAY virtual disk only.

.DESCRIPTION
    Run it once, from an elevated Windows PowerShell 5.1, before relying on Panels -> "Disable BitLocker..."
    on a real drive:

        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-BitLockerDisableVhd.ps1

    It creates a small VHDX (BLTEST-xxxxxxxx.vhdx under %LOCALAPPDATA%\Gr3yLabs\BitLockerTest), formats it,
    turns BitLocker on for that volume only, then runs the app's own functions from debloat\Gr3ysUtilities.ps1
    (the same ones the dialog uses) against it: read the volume, check the recovery password format, write and
    verify a key backup, add a recovery password, lock it, refuse to decrypt it while locked, unlock it, decrypt
    it (Start-BitLockerDecrypt) and confirm Windows removed the protectors. Then it deletes the VHDX.

    WHAT IT CANNOT TOUCH
      * Every state-changing call goes through Assert-Target, which refuses anything but the throwaway drive and
        re-runs the helper's identity guard (the volume must belong to the BLTEST VHDX, a file-backed virtual disk
        that is not the system disk). See BitLockerTestVolume.ps1 for the guard.
      * The app functions that change settings on the real machine (Set-PreventDeviceEncryption,
        Clear-BitLockerStoredAutoUnlock) are deliberately NOT loaded here, so they cannot run.
      * Real drives are only READ, and only for a before/after comparison of their non-secret status
        (the test fails if any real drive changed). Recovery passwords are never written to the log or console.

    Output goes to the console and to -LogPath. -CleanupOnly detaches and deletes any BLTEST VHDX left behind
    by an interrupted run.
#>
[CmdletBinding()]
param(
    [string]$GuiScript,
    [string]$LogPath = (Join-Path $env:TEMP ('bitlocker-e2e-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [ValidateRange(256, 2048)][int]$SizeMB = 1024,
    [switch]$CleanupOnly,
    [switch]$Pause
)
# 'Continue' is what Gr3ysUtilities.ps1 itself runs with, so the app functions behave here as they do in the
# app; every call that must not fail silently carries its own -ErrorAction Stop or sits inside a Check.
$ErrorActionPreference = 'Continue'
# $PSScriptRoot is EMPTY inside a parameter default in Windows PowerShell 5.1 when a script is started with -File (as the launcher does it),
# which ended the first real run before it wrote a single line: the default of -GuiScript is worked out here, in the body, where it is set.
if (-not $GuiScript) { $GuiScript = Join-Path (Split-Path -Parent $PSScriptRoot) 'debloat\Gr3ysUtilities.ps1' }

. (Join-Path $PSScriptRoot 'TestHelpers.ps1')            # Get-FunctionSource
. (Join-Path $PSScriptRoot 'BitLockerTestVolume.ps1')    # the guarded throwaway-VHD helpers

function Write-Log {
    param([string]$Message)
    $line = '{0}  {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    Write-Host $line
    try { [System.IO.File]::AppendAllText($LogPath, $line + "`r`n") } catch { }
}

if ($CleanupOnly) {
    $folder = Get-BlTestFolder
    # only files that pass the helper's own name guard (BLTEST-<8 hex>.vhdx); one that cannot be removed does not stop the others
    $left = @(Get-ChildItem -LiteralPath $folder -Filter 'BLTEST-*.vhdx' -File -ErrorAction SilentlyContinue | Where-Object { Test-BlTestVhdPath -Path $_.FullName })
    Write-Log "Cleanup only: $($left.Count) test VHDX file(s) in $folder"
    foreach ($f in $left) {
        try { Remove-TestVolume -VhdPath $f.FullName -Confirm:$false -ErrorAction Stop; Write-Log "Removed $($f.Name)" }
        catch {
            Write-Log "COULD NOT remove $($f.Name): $($_.Exception.Message)"
            Write-Log "  By hand: Disk Management > right-click the 1 GB 'Virtual' disk (label BLTEST) > Detach VHD, then delete $($f.FullName)"
        }
    }
    # what an interrupted run leaves in %TEMP% (only these names, which only this script makes)
    foreach ($leftover in @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'bl-e2e-backup-*.txt' -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'bl-e2e-programdata-*' -Directory -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $leftover.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $leftover.FullName) { Write-Log "COULD NOT remove $($leftover.Name) (in use?) - delete it by hand" } else { Write-Log "Removed $($leftover.Name)" }
    }
    return
}

# ---- the app's own functions, taken from the real GUI script (nothing in that script is run) ----
$appFunctions = @(
    'Get-BitLockerPropertyText', 'ConvertTo-BitLockerVolumeDetail', 'Get-BitLockerVolumeDetail', 'Get-BitLockerStateText', 'Get-BitLockerDisableState',
    'Get-BitLockerProtectorSummary', 'Get-BitLockerKeyIds', 'Test-BitLockerKeysCovered', 'Get-BitLockerMountsWithoutRecoveryPassword',
    'New-BitLockerBackupText', 'Test-BitLockerRecoveryPasswordFormat', 'Test-BitLockerBackupText', 'Save-BitLockerBackupFile',
    'Get-BitLockerRawOutput', 'Get-BitLockerBackupSystemInfo', 'Get-BitLockerFriendlyError', 'Start-BitLockerDecrypt',
    'Add-BitLockerRecoveryProtector', 'Get-PreventDeviceEncryptionValue', 'Test-BitLockerPolicyPresent', 'Get-BitLockerDecryptWarnings',
    'Get-BitLockerDecryptOrder', 'Get-BitLockerAutoUnlockAffected', 'Get-BitLockerElapsedText', 'Get-BitLockerProgressText',
    'Get-BitLockerDriveDescription', 'Get-BitLockerTypeText', 'Test-BitLockerBackupPath', 'Test-BitLockerBackupStillGood', 'Get-BitLockerVolumeIdMap', 'Get-BitLockerDriveIdentity', 'Test-BitLockerSameDrive',
    'Get-BitLockerBackupPlaceNote', 'Get-BitLockerDefaultBackupFolder', 'Get-BitLockerAuditFolder', 'Write-BitLockerActionLog',
    'Test-BitLockerManagedText', 'Get-BitLockerPathFileSystem'     # called by Get-BitLockerDecryptWarnings and Save-BitLockerBackupFile
)
foreach ($fn in $appFunctions) { . ([scriptblock]::Create((Get-FunctionSource -ScriptPath $GuiScript -FunctionName $fn))) }

# ---- a tiny test harness ----
$script:Passed = 0
$script:Failed = 0
$script:FailedNames = New-Object System.Collections.Generic.List[string]
function Check {
    # $Test must return exactly one $true / $false (or throw, which fails the check).
    param([string]$Name, [scriptblock]$Test)
    $ok = $false
    $detail = ''
    try {
        $r = @(& $Test)
        if ($r.Count -eq 1 -and $r[0] -is [bool]) { $ok = $r[0]; if (-not $ok) { $detail = 'the condition was false' } }
        else { $detail = "the check did not return a single true/false (got $($r.Count) value(s))" }
    } catch { $detail = $_.Exception.Message }
    if ($ok) { $script:Passed++; Write-Log "PASS  $Name" }
    else { $script:Failed++; $script:FailedNames.Add($Name); Write-Log "FAIL  $Name  -- $detail" }
}

function Get-RealVolumeSnapshot {
    # Non-secret facts about every volume; each KeyProtector is reduced to its ID. Read-only. A volume BitLocker cannot
    # read is a NON-terminating error in the module (it carries on with the others): it is recorded as text, so it is
    # compared before and after like everything else, instead of aborting the run (-ErrorAction Stop would).
    $snap = @{}
    $readProblems = @()
    foreach ($v in @(Get-BitLockerVolume -ErrorAction SilentlyContinue -ErrorVariable readProblems)) {
        if ([string]$v.MountPoint -cnotmatch '^[A-Za-z]:\z') { continue }     # only drive letters (a stray volume path is not a "drive")
        if ($null -ne $t -and [string]$v.MountPoint -ceq $t.MountPoint) { continue }   # the throwaway drive is not a real one
        $ids = @(@($v.KeyProtector) | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_.KeyProtectorId } | Sort-Object)
        $snap[[string]$v.MountPoint] = ('{0}|{1}|{2}|{3}|{4}|auto={5}|stored={6}|{7}' -f $v.VolumeType, $v.VolumeStatus, $v.ProtectionStatus, $v.LockStatus, $v.EncryptionMethod, $v.AutoUnlockEnabled, $v.AutoUnlockKeyStored, ($ids -join ','))
    }
    $unreadable = @(@($readProblems) | ForEach-Object { [string]$_.Exception.Message } | Where-Object { $_ } | Sort-Object -Unique)
    if ($unreadable.Count -gt 0) { $snap['(unreadable volumes)'] = ($unreadable -join ' | ') }
    return $snap
}

function Wait-Until {
    param([scriptblock]$Condition, [int]$TimeoutSeconds = 60, [string]$What = 'the condition')
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSeconds s waiting for $What" }
        Start-Sleep -Milliseconds 500
    }
}

function Get-TestDetail {
    # The throwaway volume as the dialog's own read gives it: the BitLocker facts plus the volume's own ID. Read-only.
    # A read that fails for a moment (BitLocker's WMI provider can be busy while a drive encrypts or decrypts) is tried again.
    $lastError = $null
    foreach ($attempt in 1..4) {
        try {
            $x = ConvertTo-BitLockerVolumeDetail -Volume (Get-BitLockerVolume -MountPoint $target -ErrorAction Stop)
            $ids = Get-BitLockerVolumeIdMap
            if ($ids.ContainsKey($target)) { $x.VolumeId = [string]$ids[$target] }
            return $x
        } catch { $lastError = $_; Start-Sleep -Milliseconds 400 }
    }
    throw $lastError
}

$t = $null            # the throwaway volume (set below); Assert-Target reads it
$backupFiles = New-Object System.Collections.Generic.List[string]

function Assert-Target {
    # Every call that CHANGES a drive goes through here first. Only the throwaway drive passes.
    param([string]$Mount, [switch]$Locked)
    if ($null -eq $t) { throw 'SAFETY: there is no throwaway volume.' }
    # the letter must be the throwaway's by BOTH names the helper hands out (MountPoint and DriveLetter): if they ever disagree, nothing is touched
    if ($Mount -cne $t.MountPoint -or $Mount -cne ($t.DriveLetter + ':')) { throw "SAFETY: refusing to touch '$Mount' - only $($t.MountPoint), the throwaway drive, may be changed." }
    if ($Locked) {
        # the full letter check reads the volume, which may not work while it is locked - but the letter must still be the
        # throwaway's: exactly one partition of the test VHDX's disk holds it (a different drive that took the letter has none)
        $id = Assert-BlTestIdentity -VhdPath $t.VhdPath
        $own = @(Get-Partition -DiskNumber $id.DiskNumber -ErrorAction Stop | Where-Object { ([string]$_.DriveLetter).ToUpperInvariant() -ceq $t.DriveLetter })
        if ($own.Count -ne 1) { throw "SAFETY: $Mount is not a partition of the throwaway VHDX any more." }
    }
    else { $null = Assert-BlTestIdentity -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter }
}

Write-Log 'Disable BitLocker - end-to-end test on a throwaway virtual disk'
Write-Log "App script : $GuiScript (SHA256 $((Get-FileHash -LiteralPath $GuiScript -Algorithm SHA256).Hash.Substring(0, 16)))"
Write-Log "Log file   : $LogPath"
Write-Log ("PowerShell : {0} {1}; Windows {2}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion, [System.Environment]::OSVersion.Version)
Write-Log 'NOTE: while the throwaway disk is being prepared Windows may pop up "You need to format the disk in drive X: before you can use it" - click CANCEL (never Format), and do not open the new drive in Explorer or Disk Management until the run has finished.'

try {
    # ================= 1. what is on this PC now (read-only) =================
    $before = Get-RealVolumeSnapshot
    $preventBefore = Get-PreventDeviceEncryptionValue
    Write-Log ('Real volumes: ' + ((@($before.Keys) | Sort-Object) -join ' '))

    $readTime = Measure-Command { $script:all = Get-BitLockerVolumeDetail }
    $all = $script:all
    Write-Log ("  INFO reading every volume (what the dialog does on open, refresh and every 5 s while decrypting) took {0:N0} ms" -f $readTime.TotalMilliseconds)
    Check 'Get-BitLockerVolumeDetail reads every volume without an error' { ($null -eq $all.Error) -and (@($all.Volumes).Count -ge 1) }
    foreach ($v in @($all.Volumes)) {
        $dis = Get-BitLockerDisableState -Volume $v
        $verdict = $(if ($dis.CanDisable) { 'would be offered' } else { "not offered: $($dis.Reason)" })
        Write-Log ("  INFO {0,-3} {1} | {2} | protectors: {3} | auto-unlock on={4} keys-stored={5} | {6} {7}" -f $v.MountPoint, (Get-BitLockerTypeText -Volume $v -Drive (Get-BitLockerDriveDescription -MountPoint $v.MountPoint)), (Get-BitLockerStateText -Volume $v), (Get-BitLockerProtectorSummary -Volume $v), $v.AutoUnlockEnabled, $v.AutoUnlockKeyStored, $verdict, $dis.Note)
    }
    foreach ($w in @(Get-BitLockerDecryptWarnings)) { Write-Log "  INFO the confirmation would also warn: $w" }
    $folderOffer = Get-BitLockerDefaultBackupFolder -Drives @([System.IO.DriveInfo]::GetDrives()) -Volumes @($all.Volumes) -WindowsDrive ([string]$env:SystemDrive) -Fallback '(the Desktop)'
    Write-Log "  INFO the dialog would offer this place for the backup: $folderOffer"
    $tempNote = Get-BitLockerBackupPlaceNote -Path (Join-Path $env:TEMP 'x.txt') -Volumes @($all.Volumes) -Mounts @($env:SystemDrive) -CloudRoots @($env:OneDrive, $env:OneDriveCommercial, $env:OneDriveConsumer)
    Write-Log ('  INFO a backup saved in the temp folder would be described as: ' + $(if ($tempNote) { $tempNote } else { '(nothing to warn about)' }))
    Write-Log ("  INFO PreventDeviceEncryption on this PC: {0}" -f $(if ($null -eq $preventBefore) { '(not set)' } else { $preventBefore }))

    # ================= 1b. the protected audit log, with ProgramData pointed at a temp folder (the real one is not touched) =================
    $isElevated = ([System.Security.Principal.WindowsPrincipal][System.Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isElevated) {
        $realProgramData = $env:ProgramData
        $fakeProgramData = Join-Path $env:TEMP ('bl-e2e-programdata-' + [guid]::NewGuid().ToString('N'))
        try {
            New-Item -ItemType Directory -Path $fakeProgramData -Force | Out-Null
            $env:ProgramData = $fakeProgramData
            $auditDir = Get-BitLockerAuditFolder
            Check 'the audit folder is created, and only administrators and SYSTEM can write or read it' {
                if (-not $auditDir) { throw 'Get-BitLockerAuditFolder returned nothing in an elevated session' }
                $acl = Get-Acl -LiteralPath $auditDir
                $names = @($acl.Access | ForEach-Object { $_.IdentityReference.Value })
                $acl.AreAccessRulesProtected -and (@($names | Where-Object { $_ -match 'Everyone|Users$|Authenticated' }).Count -eq 0) -and (@($names | Where-Object { $_ -match 'Administrators' }).Count -gt 0) -and (@($names | Where-Object { $_ -match 'SYSTEM' }).Count -gt 0)
            }
            Write-BitLockerActionLog 'e2e test line - no key here'
            Check 'a log line is written to it (UTF-8)' { (Get-Content -LiteralPath (Join-Path $auditDir 'bitlocker-actions.log') -Raw) -match 'e2e test line' }
        } finally {
            $env:ProgramData = $realProgramData
            if (Test-Path -LiteralPath $fakeProgramData) { Remove-Item -LiteralPath $fakeProgramData -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Log '  INFO this session is not elevated, so the audit-folder check is skipped'
    }

    # ================= 2. the throwaway volume =================
    $t = New-TestVhdVolume -SizeMB $SizeMB
    Write-Log "Throwaway drive: $($t.MountPoint)  ($($t.VhdPath), disk $($t.DiskNumber), $($t.SizeMB) MB)"
    $target = $t.MountPoint
    Check 'the throwaway drive letter is not any real volume, and not the system drive' { (@($before.Keys) -notcontains $target) -and ($target -cne $env:SystemDrive) -and ($target -cne 'C:') }
    # a detector is not a stop: a wrong target ends the run here, before any BitLocker call
    if (($before.Keys -contains $target) -or ($target -ceq $env:SystemDrive) -or ($target -ceq 'C:')) { throw "SAFETY: the throwaway drive letter $target is a real drive." }

    $en = Enable-TestVolumeBitLocker -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter -FullEncryption
    $pw = $en.TestPassword
    Write-Log "BitLocker is on for $target (password + recovery password, full encryption)."

    # ================= 3. reading it the way the dialog does =================
    $raw = Get-BitLockerVolume -MountPoint $target
    Check 'the real BitLockerVolume object has every property the dialog reads' {
        $names = @($raw.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($n in 'MountPoint', 'VolumeType', 'VolumeStatus', 'ProtectionStatus', 'LockStatus', 'EncryptionMethod', 'EncryptionPercentage', 'CapacityGB', 'AutoUnlockEnabled', 'AutoUnlockKeyStored', 'KeyProtector') {
            if ($names -notcontains $n) { throw "missing property $n" }
        }
        return $true
    }
    $d = ConvertTo-BitLockerVolumeDetail -Volume $raw
    Check 'detail: an encrypted, unlocked data drive with a password and one recovery password' {
        ($d.MountPoint -ceq $target) -and ($d.VolumeType -eq 'Data') -and ($d.VolumeStatus -eq 'FullyEncrypted') -and ($d.LockStatus -eq 'Unlocked') -and
        ($d.ProtectionStatus -eq 'On') -and ($d.EncryptionMethod -eq 'XtsAes256') -and ($d.AutoUnlockKeyStored -eq $false) -and (@($d.Protectors).Count -eq 2) -and
        (@($d.Protectors | Where-Object { $_.Type -eq 'Password' }).Count -eq 1) -and (@($d.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' -and $_.RecoveryPassword }).Count -eq 1)
    }
    $recPw = [string](@($d.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' })[0]).RecoveryPassword
    Check 'a real Windows recovery password passes the 48-digit format check' { Test-BitLockerRecoveryPasswordFormat -Candidate $recPw }
    Check 'the same password with its first digit changed fails the check (checksum)' {
        $chars = $recPw.ToCharArray()
        $chars[0] = $(if ($chars[0] -eq [char]'9') { [char]'8' } else { [char]([int]$chars[0] + 1) })
        -not (Test-BitLockerRecoveryPasswordFormat -Candidate (-join $chars))
    }
    Check 'the dialog would offer this drive, with no warning note' { $s = Get-BitLockerDisableState -Volume $d; ($s.CanDisable -eq $true) -and ([string]$s.Note -eq '') }
    Check 'state text, protector summary and type text read correctly' {
        $drive = Get-BitLockerDriveDescription -MountPoint $target
        ((Get-BitLockerStateText -Volume $d) -eq 'Encrypted') -and
        ((((Get-BitLockerProtectorSummary -Volume $d) -split ', ') | Sort-Object) -join ',') -eq 'Password,Recovery password' -and
        ((Get-BitLockerTypeText -Volume $d -Drive $drive) -eq 'Data drive, fixed (BLTEST)')
    }

    # ================= 4. step 1 of the dialog: the key backup =================
    $vols = @($d)
    # (timed on the throwaway drive only: a real drive's protectors, recovery password included, are not read through manage-bde here)
    $mbdeTime = Measure-Command { $script:rawOutTmp = Get-BitLockerRawOutput -Volumes $vols }
    $rawOut = $script:rawOutTmp
    Write-Log ("  INFO manage-bde -status plus -protectors for the throwaway drive (part of button 1; the window waits) took {0:N0} ms" -f $mbdeTime.TotalMilliseconds)
    Check 'manage-bde output is captured for the drive' { ($rawOut.Status.Length -gt 20) -and $rawOut.Protectors.ContainsKey($target) -and ($rawOut.Protectors[$target].Length -gt 20) }
    $info = Get-BitLockerBackupSystemInfo
    Check 'the system details for the backup header are filled in' { [bool]$info.ComputerName -and [bool]$info.Os -and [bool]$info.Machine }
    $text = New-BitLockerBackupText -Volumes $vols -Info $info -RawStatus $rawOut.Status -RawProtectors $rawOut.Protectors
    $backup1 = Join-Path $env:TEMP ('bl-e2e-backup-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $backupFiles.Add($backup1)
    $save = Save-BitLockerBackupFile -Path $backup1 -Text $text
    Check 'the backup file is written, reads back identical, and only the owner, Administrators and SYSTEM can read it' {
        if (-not $save.Ok) { throw $save.Error }
        if ($save.AclWarning) { throw $save.AclWarning }
        $acl = Get-Acl -LiteralPath $backup1
        # exactly the three the app grants (the user, Administrators, SYSTEM), compared as SIDs, and nobody else
        $sids = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
        $allowedSids = @([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-32-544', 'S-1-5-18')
        ($save.Text -ceq $text) -and $acl.AreAccessRulesProtected -and (@($sids | Where-Object { $allowedSids -notcontains $_ }).Count -eq 0) -and ($sids.Count -ge 1)
    }
    Check 'the file system of the backup place is read as NTFS (what decides whether an unrestrictable key file is deleted)' { (Get-BitLockerPathFileSystem -Path $backup1) -ceq 'NTFS' }
    $verify = Test-BitLockerBackupText -Text $save.Text -Volumes $vols
    Check 'the backup check passes on the real file' { if (-not $verify.Ok) { throw ($verify.Missing -join '; ') }; return $true }
    Check 'the file holds the recovery password, every key ID and the raw manage-bde text' {
        $has = $save.Text.Contains($recPw) -and $save.Text.Contains('manage-bde -protectors -get ' + $target) -and $save.Text.Contains('END OF BACKUP')
        foreach ($p in @($d.Protectors)) { if (-not $save.Text.Contains([string]$p.Id)) { $has = $false } }
        $has
    }
    Check 'the backup covers every key that exists' { Test-BitLockerKeysCovered -Volumes $vols -BackedUpIds @(Get-BitLockerKeyIds -Volumes $vols) }
    # The real dialog's backup covers every volume; this test's file holds only the throwaway drive (the real drives' keys
    # are never copied anywhere), so the IDs of the real drives' keys - not secrets - are added to what "was backed up".
    $coveredIds = @(Get-BitLockerKeyIds -Volumes $all.Volumes) + @(Get-BitLockerKeyIds -Volumes $vols)
    $stillGood = Test-BitLockerBackupStillGood -Path $backup1 -Hash $save.Hash -BackedUpIds $coveredIds
    Check 'the re-check that runs right before each decrypt passes on the real file and the real keys' { if (-not $stillGood.Ok) { throw $stillGood.Reason }; return $true }
    Check 'the same re-check fails when the file is not the one that was checked' { $x = Test-BitLockerBackupStillGood -Path $backup1 -Hash 'NOT-THE-HASH' -BackedUpIds $coveredIds; (-not $x.Ok) -and $x.Stale }
    Check 'the same re-check fails when a key exists that the backup does not cover' { $x = Test-BitLockerBackupStillGood -Path $backup1 -Hash $save.Hash -BackedUpIds @($coveredIds | Select-Object -First ([math]::Max(0, $coveredIds.Count - 1))); (-not $x.Ok) -and $x.Stale }
    Check 'a backup saved on the drive being decrypted is flagged' { (Get-BitLockerBackupPlaceNote -Path ($target + '\x.txt') -Volumes $vols -Mounts @($target) -CloudRoots @()) -match 'about to be decrypted' }
    # what the dialog uses to know a drive is still THE drive (key IDs, size, type, volume ID): it must hold between two reads of a real volume
    $d = Get-TestDetail      # as the dialog's own read gives it: with the volume's own ID
    # Storage can lag behind BitLocker for a moment: a missing ID is read again for a few seconds before it counts as "Windows gives none"
    foreach ($attempt in 1..8) { if ($d.VolumeId) { break }; Start-Sleep -Milliseconds 800; $d = Get-TestDetail }
    $identity = Get-BitLockerDriveIdentity -Volume $d
    Write-Log ("  INFO a drive's identity as Windows reports it: {0} key ID(s), size '{1}', type '{2}', volume ID {3}" -f @($identity.KeyIds).Count, $identity.Capacity, $identity.VolumeType, $(if ($identity.VolumeId) { "'" + $identity.VolumeId + "'" } else { '(none)' }))
    Check 'Windows gives the throwaway drive a volume ID (the window uses it to tell look-alike drives apart)' { [bool]$identity.VolumeId -and ($identity.VolumeId -match '^\\\\\?\\Volume\{[0-9a-fA-F-]+\}\\$') }
    Check 'a drive is recognised as the same drive between two reads (key IDs, size, type, volume ID)' { Test-BitLockerSameDrive -Identity $identity -Volume (Get-TestDetail) }
    Check 'a drive of another size, another type or another volume is not recognised' {
        $fake = Get-TestDetail
        $fake.CapacityGB = 14.5
        $other = Get-TestDetail
        $other.VolumeType = 'OperatingSystem'
        $clone = Get-TestDetail
        $clone.VolumeId = '\\?\Volume{00000000-0000-0000-0000-00000000dead}\'
        (-not (Test-BitLockerSameDrive -Identity $identity -Volume $fake)) -and (-not (Test-BitLockerSameDrive -Identity $identity -Volume $other)) -and (-not (Test-BitLockerSameDrive -Identity $identity -Volume $clone))
    }

    # ================= 5. a drive with no recovery password: add one =================
    $recProtector = @($raw.KeyProtector | Where-Object { [string]$_.KeyProtectorType -eq 'RecoveryPassword' })[0]
    Assert-Target $target
    Remove-BitLockerKeyProtector -MountPoint $target -KeyProtectorId $recProtector.KeyProtectorId -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    $d2 = Get-TestDetail
    Check 'a drive left with only a password is reported as having no recovery password' { @(Get-BitLockerMountsWithoutRecoveryPassword -Volumes @($d2) -Mounts @($target)) -contains $target }
    $identityBeforeAdd = Get-BitLockerDriveIdentity -Volume $d2
    Assert-Target $target
    $addOut = @(Add-BitLockerRecoveryProtector -MountPoint $target 3>&1)
    $addRes = @($addOut | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] -and $null -ne $_.PSObject.Properties['Ok'] })
    $addWarn = @($addOut | Where-Object { $_ -is [System.Management.Automation.WarningRecord] })
    Check 'adding a recovery password works, and Windows'' warning (which carries the new password) is not passed on' { ($addRes.Count -eq 1) -and ($addRes[0].Ok -eq $true) -and ($addWarn.Count -eq 0) }
    $d3 = Get-TestDetail
    $newRec = @($d3.Protectors | Where-Object { $_.Type -eq 'RecoveryPassword' })
    Check 'the new recovery password exists, is well-formed and is a different one' { ($newRec.Count -eq 1) -and (Test-BitLockerRecoveryPasswordFormat -Candidate $newRec[0].RecoveryPassword) -and ($newRec[0].RecoveryPassword -cne $recPw) }
    Check 'a new key makes the earlier backup stale (the dialog would ask for a new one)' { -not (Test-BitLockerKeysCovered -Volumes @($d3) -BackedUpIds @(Get-BitLockerKeyIds -Volumes $vols)) }
    Check 'the drive that got the recovery password is the same drive only when the added key is allowed for (the dialog allows it for that one step)' {
        (Test-BitLockerSameDrive -Identity $identityBeforeAdd -Volume $d3 -AllowAddedKeys) -and (-not (Test-BitLockerSameDrive -Identity $identityBeforeAdd -Volume $d3))
    }

    # the new backup the dialog would now insist on
    $vols = @($d3)
    $rawOut2 = Get-BitLockerRawOutput -Volumes $vols
    $text2 = New-BitLockerBackupText -Volumes $vols -Info $info -RawStatus $rawOut2.Status -RawProtectors $rawOut2.Protectors
    $backup2 = Join-Path $env:TEMP ('bl-e2e-backup-{0}.txt' -f [guid]::NewGuid().ToString('N'))
    $backupFiles.Add($backup2)
    $save2 = Save-BitLockerBackupFile -Path $backup2 -Text $text2
    Check 'the second backup is written and passes the check, and covers the new key' {
        if (-not $save2.Ok) { throw $save2.Error }
        $v2 = Test-BitLockerBackupText -Text $save2.Text -Volumes $vols
        if (-not $v2.Ok) { throw ($v2.Missing -join '; ') }
        Test-BitLockerKeysCovered -Volumes $vols -BackedUpIds @(Get-BitLockerKeyIds -Volumes $vols)
    }
    $backedUpIds = @(Get-BitLockerKeyIds -Volumes $vols)

    # ================= 6. a locked drive =================
    Assert-Target $target
    Lock-BitLocker -MountPoint $target -ForceDismount -ErrorAction Stop | Out-Null
    Wait-Until -What "$target to report Locked" -Condition { [string](Get-BitLockerVolume -MountPoint $target).LockStatus -eq 'Locked' }
    $rawL = Get-BitLockerVolume -MountPoint $target
    $dL = ConvertTo-BitLockerVolumeDetail -Volume $rawL
    Write-Log ("  INFO a locked drive as Windows reports it: VolumeStatus='{0}' ProtectionStatus='{1}' EncryptionPercentage='{2}' (empty = no value)" -f $rawL.VolumeStatus, $rawL.ProtectionStatus, $rawL.EncryptionPercentage)
    $lockedIds = Get-BitLockerVolumeIdMap
    Write-Log ("  INFO volume ID of the locked drive: {0}" -f $(if ($lockedIds.ContainsKey($target)) { "'" + $lockedIds[$target] + "'" } else { '(none - Get-Volume did not list the locked drive just now; with no ID the window compares size, type and keys only)' }))
    Check 'a locked drive is shown as Locked and is not offered' { ((Get-BitLockerStateText -Volume $dL) -like 'Locked*') -and (-not (Get-BitLockerDisableState -Volume $dL).CanDisable) }
    Assert-Target $target -Locked
    $refusal = Start-BitLockerDecrypt -MountPoint $target
    Check 'Start-BitLockerDecrypt refuses a locked drive before asking Windows to decrypt it' { (-not $refusal.Ok) -and ($refusal.Error -match 'cannot be decrypted now') }
    Assert-Target $target -Locked
    $lockedErr = $null
    try { Disable-BitLocker -MountPoint $target -ErrorAction Stop | Out-Null } catch { $lockedErr = $_ }
    $lockedMsg = $(if ($lockedErr) { [string]$lockedErr.Exception.Message } else { '' })
    $lockedHr = $(if ($lockedErr) { [int]$lockedErr.Exception.HResult } else { 0 })
    Write-Log ("  INFO Windows' own error when asked to decrypt the locked drive: 0x{0:X8} - {1}" -f $lockedHr, $lockedMsg)
    Check 'Windows refuses a locked drive, and the friendly text tells you to unlock it first' { ($null -ne $lockedErr) -and ((Get-BitLockerFriendlyError -Message $lockedMsg -HResult $lockedHr) -match 'Unlock it first') }
    Assert-Target $target -Locked
    Unlock-BitLocker -MountPoint $target -Password $pw -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    Wait-Until -What "$target to report Unlocked" -Condition { [string](Get-BitLockerVolume -MountPoint $target).LockStatus -eq 'Unlocked' }
    Check 'unlocked again: the keys are unchanged, so the backup still covers them' {
        $dU = Get-TestDetail
        ($dU.VolumeStatus -eq 'FullyEncrypted') -and (Test-BitLockerKeysCovered -Volumes @($dU) -BackedUpIds $backedUpIds)
    }
    # Is the volume ID the same after a lock and an unlock? Nothing documents it and the window does not rely on it (a locked drive
    # is never offered, and after an unlock the list is refreshed, which takes the drive's identity anew) - so it is reported, not
    # judged. Storage can take a moment to list the volume again.
    $idAfterUnlock = ''
    foreach ($attempt in 1..30) { $idAfterUnlock = [string](Get-BitLockerVolumeIdMap)[$target]; if ($idAfterUnlock) { break }; Start-Sleep -Seconds 1 }
    Write-Log ("  INFO volume ID after the unlock: {0} ({1})" -f $(if ($idAfterUnlock) { "'" + $idAfterUnlock + "'" } else { '(none)' }), $(if ($idAfterUnlock -and ($idAfterUnlock -ceq [string]$identity.VolumeId)) { 'the same as before the lock' } else { 'NOT the same as before the lock, or not listed' }))

    # ================= 7. step 2 of the dialog: decrypt =================
    Assert-Target $target
    # the window follows a decrypting drive by its size, type and volume ID (its key IDs disappear when it finishes): Windows must keep reporting all three
    $beforeDecrypt = Get-TestDetail
    $startCapacity = [string]$beforeDecrypt.CapacityGB
    $startType = [string]$beforeDecrypt.VolumeType
    $startVolumeId = [string]$beforeDecrypt.VolumeId
    $identityDrift = ''
    $idPolls = 0
    $idSeen = 0
    $rightIdentity = Get-BitLockerDriveIdentity -Volume $beforeDecrypt
    # the last guard in Start-BitLockerDecrypt: an identity that is not this drive's is refused BEFORE Windows is asked to do anything
    $wrongIdentity = Get-BitLockerDriveIdentity -Volume $beforeDecrypt
    $wrongIdentity.KeyIds = @('{00000000-0000-0000-0000-00000000dead}')
    Assert-Target $target
    $wrongTry = Start-BitLockerDecrypt -MountPoint $target -ExpectedIdentity $wrongIdentity
    Check 'Start-BitLockerDecrypt refuses a drive that is not the one that was confirmed, and nothing is decrypted' { (-not $wrongTry.Ok) -and ($wrongTry.Error -match 'not the drive that was confirmed') -and ([string](Get-BitLockerVolume -MountPoint $target).VolumeStatus -eq 'FullyEncrypted') }
    $startedAt = Get-Date
    Assert-Target $target
    $r = Start-BitLockerDecrypt -MountPoint $target -ExpectedIdentity $rightIdentity
    Check 'Start-BitLockerDecrypt starts decrypting the throwaway drive (given the identity of the drive that was confirmed)' { if (-not $r.Ok) { throw $r.Error }; $r.ClearedAutoUnlock -eq $false }
    $seen = New-Object System.Collections.Generic.List[string]
    $pauseTried = $false
    $startState = [pscustomobject]@{ At = $startedAt; StartPercent = 100 }
    $deadline = (Get-Date).AddSeconds(420)
    $final = $null
    while ($r.Ok) {
        try { $cur = Get-TestDetail } catch {
            # a read that keeps failing is not a reason to abandon a decryption that is under way: wait for it, until the deadline
            Write-Log "  INFO could not read the drive just now: $($_.Exception.Message)"
            if ((Get-Date) -gt $deadline) { break }
            continue
        }
        $idPolls++
        if ([string]$cur.VolumeId) { $idSeen++ }
        # an ID that cannot be read in one poll proves nothing (the window treats it the same way); an ID that is read and differs is a change
        if (-not $identityDrift -and ([string]$cur.CapacityGB -cne $startCapacity -or [string]$cur.VolumeType -cne $startType -or ($startVolumeId -and [string]$cur.VolumeId -and [string]$cur.VolumeId -cne $startVolumeId))) {
            $identityDrift = ("size '{0}' (was '{1}'), type '{2}' (was '{3}') and volume ID '{4}' (was '{5}') while the status was {6}" -f $cur.CapacityGB, $startCapacity, $cur.VolumeType, $startType, $cur.VolumeId, $startVolumeId, $cur.VolumeStatus)
        }
        $line = Get-BitLockerProgressText -Volume $cur -Started $startState -Now (Get-Date)
        if (-not $seen.Contains($line)) { $seen.Add($line); Write-Log "  INFO progress text: $line (status $($cur.VolumeStatus), protection $($cur.ProtectionStatus))" }
        if ($cur.VolumeStatus -eq 'DecryptionInProgress' -and $cur.ProtectionStatus -ne 'Off') { Write-Log '  INFO note: protection was not Off while decrypting, so the confirmation text "protection is already off" is wrong' }
        if ($cur.VolumeStatus -eq 'DecryptionInProgress' -and -not $pauseTried) {
            # opportunistic: pause the decryption once to see the paused state and the hint for resuming it
            $pauseTried = $true
            Assert-Target $target
            try { $null = & manage-bde.exe -pause $target 2>&1 } catch { }
            Start-Sleep -Milliseconds 700
            $p = ConvertTo-BitLockerVolumeDetail -Volume (Get-BitLockerVolume -MountPoint $target)
            if ($p.VolumeStatus -eq 'DecryptionSuspended') {
                $ps = Get-BitLockerDisableState -Volume $p
                Write-Log "  INFO paused: $(Get-BitLockerStateText -Volume $p) | $($ps.Reason)"
                Check 'a paused decryption is shown as paused and not offered, with the manage-bde -resume hint' { ((Get-BitLockerStateText -Volume $p) -like 'Decryption paused*') -and (-not $ps.CanDisable) -and ($ps.Reason -match ('manage-bde -resume ' + [regex]::Escape($target))) }
                # a question for the next version of the dialog: what does Windows do if it is simply asked to decrypt a paused drive again?
                Assert-Target $target
                $againErr = $null
                try { Disable-BitLocker -MountPoint $target -ErrorAction Stop | Out-Null } catch { $againErr = $_ }
                Start-Sleep -Milliseconds 700
                $afterAgain = ConvertTo-BitLockerVolumeDetail -Volume (Get-BitLockerVolume -MountPoint $target)
                Write-Log ("  INFO Disable-BitLocker on a PAUSED decryption: threw={0} {1} | status afterwards {2}" -f ($null -ne $againErr), $(if ($againErr) { $againErr.Exception.Message } else { '' }), $afterAgain.VolumeStatus)
            } else {
                Write-Log "  INFO could not catch the decryption while paused (status $($p.VolumeStatus)) - paused-state check skipped"
            }
            # always resume, whatever was seen: harmless when nothing is paused, essential when something is
            Assert-Target $target
            try { $null = & manage-bde.exe -resume $target 2>&1 } catch { }
        }
        if ($cur.VolumeStatus -eq 'FullyDecrypted') { $final = $cur; break }
        if ((Get-Date) -gt $deadline) { break }
        Start-Sleep -Seconds 1
    }
    Check 'the drive reaches FullyDecrypted' { $null -ne $final }
    Write-Log ("  INFO the volume ID could be read in {0} of {1} polls while the drive decrypted" -f $idSeen, $idPolls)
    Check 'the size and type Windows reports do not change while the drive decrypts or when it is done, and a volume ID that is read stays the same (the window relies on that to follow the same drive)' { if ($identityDrift) { throw $identityDrift }; $true }
    if ($final) {
        Write-Log ("  INFO decrypting took {0}" -f (Get-BitLockerElapsedText -Span ((Get-Date) - $startedAt)))
        Check 'when decryption finished Windows had removed every key protector (the dialog says so)' { @($final.Protectors).Count -eq 0 }
        Check 'a decrypted drive reads as Not encrypted, and is no longer offered' { ((Get-BitLockerStateText -Volume $final) -eq 'Not encrypted') -and (-not (Get-BitLockerDisableState -Volume $final).CanDisable) }
        Assert-Target $target
        $again = Start-BitLockerDecrypt -MountPoint $target
        Check 'a second Start-BitLockerDecrypt on the decrypted drive is refused' { (-not $again.Ok) -and ($again.Error -match 'cannot be decrypted now') }
        Assert-Target $target
        $notOnErr = $null
        try { Disable-BitLocker -MountPoint $target -ErrorAction Stop | Out-Null } catch { $notOnErr = $_ }
        $notOnMsg = $(if ($notOnErr) { [string]$notOnErr.Exception.Message } else { '' })
        $notOnHr = $(if ($notOnErr) { [int]$notOnErr.Exception.HResult } else { 0 })
        Write-Log ("  INFO Windows' own error when asked to decrypt a drive that is not encrypted: threw={0} 0x{1:X8} - {2}" -f ($null -ne $notOnErr), $notOnHr, $notOnMsg)
    }

    # ================= 8. a drive letter that does not exist (READ-ONLY: nothing is asked to decrypt anything here) =================
    $free = Get-BlTestFreeDriveLetter
    $null = Assert-BlTestLetterFree -Letter $free      # throws (and so stops the step) when anything uses that letter any more
    $ghostErr = $null
    try { $null = Get-BitLockerVolume -MountPoint ($free + ':') -ErrorAction Stop } catch { $ghostErr = $_ }
    Write-Log ("  INFO Windows' own error for a drive letter that has no volume: {0}" -f $(if ($ghostErr) { [string]$ghostErr.Exception.Message } else { '(no error)' }))
    Check 'Windows reports a drive letter with no volume as an error (read-only probe)' { $null -ne $ghostErr }

} catch {
    $script:Failed++
    $script:FailedNames.Add('the run itself')
    Write-Log "FAIL  the run stopped early: $($_.Exception.Message)"
    Write-Log "      at $($_.InvocationInfo.ScriptName):$($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    # ================= 9. clean up, then prove nothing real changed =================
    foreach ($f in $backupFiles) { if (Test-Path -LiteralPath $f) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue } }
    if ($null -ne $t) {
        try { Remove-TestVolume -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter -Confirm:$false; Write-Log "Removed the throwaway VHDX $($t.VhdPath)" }
        catch {
            try { Remove-TestVolume -VhdPath $t.VhdPath -Confirm:$false; Write-Log "Removed the throwaway VHDX $($t.VhdPath)" }
            catch { Write-Log "WARNING: could not remove the throwaway VHDX ($($_.Exception.Message)). Run this script with -CleanupOnly." }
        }
    }
    try {
        $after = Get-RealVolumeSnapshot
        $preventAfter = Get-PreventDeviceEncryptionValue
        Check 'no real drive changed (status, protection, lock, method, auto-unlock flags and key protector IDs all identical)' {
            $diffs = New-Object System.Collections.Generic.List[string]
            foreach ($k in @($before.Keys)) { if (-not $after.ContainsKey($k)) { $diffs.Add("$k vanished") } elseif ($after[$k] -cne $before[$k]) { $diffs.Add("$k changed") } }
            foreach ($k in @($after.Keys)) { if (-not $before.ContainsKey($k)) { $diffs.Add("$k appeared") } }
            if ($diffs.Count -gt 0) { throw ($diffs -join '; ') }
            return $true
        }
        Check 'the PreventDeviceEncryption setting was not touched' { $preventAfter -eq $preventBefore }
    } catch {
        $script:Failed++
        $script:FailedNames.Add('the final before/after comparison')
        Write-Log "FAIL  the final comparison could not run: $($_.Exception.Message)"
    }
    $leftover = @(Get-ChildItem -LiteralPath (Get-BlTestFolder) -Filter 'BLTEST-*.vhdx' -File -ErrorAction SilentlyContinue)
    Write-Log ('Test VHDX files left behind: {0}' -f $leftover.Count)
    # a throwaway disk that could not be removed is a FAILURE (a green result must not hide an attached disk and a 1 GB file)
    if ($leftover.Count -gt 0) {
        $script:Failed++
        $script:FailedNames.Add('the throwaway VHDX was removed')
        Write-Log "FAIL  $($leftover.Count) throwaway VHDX file(s) are still there. Clean up with:  powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -CleanupOnly   (elevated)"
    }
    Write-Log ('RESULT: {0} passed, {1} failed' -f $script:Passed, $script:Failed)
    if ($script:Failed -gt 0) { Write-Log ('Failed: ' + ($script:FailedNames -join ' | ')) }
    if ($Pause) { Read-Host 'Press Enter to close' | Out-Null }
}
if ($script:Failed -gt 0) { exit 1 }
exit 0

#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Throw-away VHDX data volume for an end-to-end test of "enable BitLocker -> decrypt -> delete"
    WITHOUT touching a real drive (Windows PowerShell 5.1, elevated, no Hyper-V module needed).

.DESCRIPTION
    This file only DEFINES functions. Dot-source it; nothing happens until you call a function.

        . 'C:\path\New-BitLockerTestVolume.ps1'
        $t = New-TestVhdVolume                        # 256 MB expandable VHDX, NTFS label BLTEST, free letter F-Z
        $t | Enable-TestVolumeBitLocker               # password + recovery-password protectors, XtsAes256, used space only
        Get-TestVolumeBitLockerStatus -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter
        #   ... point the dialog / the code under test at $t.MountPoint (and ONLY at that) ...
        Disable-TestVolumeBitLocker -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter -Wait
        Remove-TestVolume -VhdPath $t.VhdPath -DriveLetter $t.DriveLetter -Confirm:$false

    WHY IT CANNOT ACT ON C: OR ANY OTHER REAL DRIVE
      1. The VHDX is a brand-new file named BLTEST-<8 hex>.vhdx directly inside
         %LOCALAPPDATA%\Gr3yLabs\BitLockerTest (diskpart "create vdisk" cannot overwrite an existing file).
      2. diskpart is used ONLY for: create vdisk / select vdisk file=<that file> / attach vdisk.
         Partitioning, formatting and BitLocker use Storage/BitLocker cmdlets with an explicit disk number
         or drive letter, never with a value taken from the caller.
      3. Before EVERY state-changing step, Assert-BlTestIdentity resolves the disk number from
         Get-DiskImage -ImagePath <that file> (Attached, Number) and requires: BusType = File Backed Virtual,
         not IsSystem, not IsBoot, not the disk that holds %SystemDrive%, size <= 3 GB, and (when a letter is
         involved) that the letter is F-Z, is not the system drive, belongs to a partition of THAT disk, and
         maps back to the same VHDX path through Get-Volume / Get-DiskImage -Volume.
      4. No function accepts a free-form mount point, disk number or volume. Every guard is a positive
         assertion, so a null/unknown value fails closed.
      5. Remove-TestVolume only ever runs Dismount-DiskImage -ImagePath <guarded file> and
         Remove-Item -LiteralPath <guarded file> (single file, no -Recurse, no wildcards).
      6. No key material is printed: BitLocker cmdlets are piped to Out-Null with -WarningAction
         SilentlyContinue (the module writes the recovery password into the WARNING stream), and the status
         object never contains the KeyProtector.RecoveryPassword property.

    NOTE: auto-unlock is deliberately NOT enabled. Enable-BitLockerAutoUnlock on a data volume stores a key on
    the OS volume, and on an encrypted C: that would make Disable-BitLocker C: fail with
    FVE_E_AUTOUNLOCK_ENABLED (0x80310029) until Clear-BitLockerAutoUnlock is run.
#>

$script:BlTestFolder       = Join-Path $env:LOCALAPPDATA 'Gr3yLabs\BitLockerTest'
$script:BlTestNameRegex    = '^BLTEST-[0-9a-f]{8}\.vhdx$'
$script:BlTestLabel        = 'BLTEST'
$script:BlTestMaxDiskBytes = [int64]3GB

# ----------------------------------------------------------------------------------------------
# Small pure / read-only helpers
# ----------------------------------------------------------------------------------------------

function Assert-BlTestElevated {
    $identity  = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this from an elevated Windows PowerShell 5.1 session (Run as administrator).'
    }
}

function Get-BlTestFolder {
    [CmdletBinding()]
    param([switch]$Create)

    $folder = [System.IO.Path]::GetFullPath($script:BlTestFolder)
    if ($Create -and -not (Test-Path -LiteralPath $folder -PathType Container)) {
        New-Item -ItemType Directory -Path $folder -Force -ErrorAction Stop | Out-Null
    }
    if (Test-Path -LiteralPath $folder -PathType Container) {
        $item = Get-Item -LiteralPath $folder -Force -ErrorAction Stop
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw ("Refusing: test folder '{0}' is a reparse point (junction/symlink)." -f $folder)
        }
    }
    return $folder
}

function Test-BlTestVhdPath {
    # $true only for  <test folder>\BLTEST-xxxxxxxx.vhdx  (no traversal, no other folder, no other name)
    [CmdletBinding()]
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    if ($Path.IndexOfAny([char[]]@('*', '?', '"', '<', '>', '|')) -ge 0) { return $false }
    try { $full = [System.IO.Path]::GetFullPath($Path) } catch { return $false }
    $folder = [System.IO.Path]::GetFullPath($script:BlTestFolder).TrimEnd('\')
    $parent = [System.IO.Path]::GetDirectoryName($full)
    $leaf   = [System.IO.Path]::GetFileName($full)
    if ([string]::IsNullOrEmpty($parent) -or [string]::IsNullOrEmpty($leaf)) { return $false }
    if (-not [string]::Equals($parent.TrimEnd('\'), $folder, [System.StringComparison]::OrdinalIgnoreCase)) { return $false }
    if ($leaf -notmatch $script:BlTestNameRegex) { return $false }
    return $true
}

function Get-BlTestUsedDriveLetters {
    # Every letter that is, or may be, taken: volumes, partitions, DriveInfo (incl. network/optical),
    # PSDrives (subst, mapped), Win32_LogicalDisk, persistent mappings of this user and letters the
    # mount manager remembers for currently absent volumes. A, B, C and the system drive always count.
    [CmdletBinding()]
    param()

    $raw = New-Object System.Collections.ArrayList
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue)) { [void]$raw.Add([string]$v.DriveLetter) }
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) { [void]$raw.Add([string]$p.DriveLetter) }
    try { foreach ($d in [System.IO.DriveInfo]::GetDrives()) { [void]$raw.Add([string]$d.Name) } } catch { }
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) { [void]$raw.Add([string]$d.Name) }
    foreach ($d in @(Get-CimInstance -ClassName Win32_LogicalDisk -ErrorAction SilentlyContinue)) { [void]$raw.Add([string]$d.DeviceID) }
    try { foreach ($k in @(Get-ChildItem -LiteralPath 'HKCU:\Network' -ErrorAction Stop)) { [void]$raw.Add([string]$k.PSChildName) } } catch { }
    try {
        $md = Get-Item -LiteralPath 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop
        foreach ($n in $md.GetValueNames()) {
            if ($n -match '^\\DosDevices\\([A-Za-z]):$') { [void]$raw.Add($Matches[1]) }
        }
    } catch { }
    foreach ($fixed in @('A', 'B', 'C', [string]$env:SystemDrive)) { [void]$raw.Add($fixed) }

    $used = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($item in $raw) {
        $t = ([string]$item).Trim()
        if ($t -match '^([A-Za-z])(:\\?)?$') { [void]$used.Add($Matches[1].ToUpperInvariant()) }
    }
    return ,$used
}

function Get-BlTestFreeDriveLetter {
    # Highest free letter in F..Z (Z is usually a mapped drive, so we normally land on Y or below).
    [CmdletBinding()]
    param()

    $used = Get-BlTestUsedDriveLetters
    foreach ($c in [char[]]'ZYXWVUTSRQPONMLKJIHGF') {
        $s = [string]$c
        if (-not $used.Contains($s)) { return $s }
    }
    throw 'No free drive letter between F: and Z:.'
}

function Assert-BlTestLetterFree {
    # Refuses (throws) when the letter exists in ANY form; returns the normalised letter when it is free.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Letter)

    $L = $Letter.Trim().TrimEnd(':').ToUpperInvariant()
    if ($L -notmatch '^[F-Z]$') { throw ("Refusing: drive letter must be F-Z, got '{0}'." -f $Letter) }
    $used = Get-BlTestUsedDriveLetters
    if ($used.Contains($L)) {
        throw ("Refusing: drive letter {0}: already exists (volume, partition, mapped drive, subst or reserved mount)." -f $L)
    }
    if ($null -ne (Get-Volume -DriveLetter $L -ErrorAction SilentlyContinue)) {
        throw ("Refusing: a volume already uses {0}:." -f $L)
    }
    if (Test-Path -LiteralPath ($L + ':\')) {
        throw ("Refusing: path {0}:\ already exists." -f $L)
    }
    return $L
}

function Test-BlTestIsFileBackedVirtual {
    [CmdletBinding()]
    param($Disk)

    if ($null -eq $Disk -or $null -eq $Disk.BusType) { return $false }
    $s = [string]$Disk.BusType
    if ($s -match '^\s*15\s*$') { return $true }                 # numeric MSFT_Disk.BusType 15
    if ($s -match 'File\s*Backed\s*Virtual') { return $true }    # enum / display name
    return $false
}

function Wait-BlTestUntil {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$Condition,
        [int]$TimeoutSeconds = 30,
        [int]$IntervalMilliseconds = 500,
        [string]$What = 'condition'
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($true) {
        $ok = $false
        try { $ok = [bool](& $Condition) } catch { $ok = $false }
        if ($ok) { return }
        if ((Get-Date) -gt $deadline) {
            throw ('Timed out after {0} s waiting for: {1}' -f $TimeoutSeconds, $What)
        }
        Start-Sleep -Milliseconds $IntervalMilliseconds
    }
}

function ConvertTo-BlTestSafeSummary {
    # Never copies KeyProtector.RecoveryPassword (or any other secret) into the output.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Volume)

    $protectors = @()
    foreach ($kp in @($Volume.KeyProtector)) {
        if ($null -ne $kp) { $protectors += ('{0} {1}' -f $kp.KeyProtectorType, $kp.KeyProtectorId) }
    }
    return [pscustomobject]@{
        MountPoint           = [string]$Volume.MountPoint
        VolumeType           = [string]$Volume.VolumeType
        VolumeStatus         = [string]$Volume.VolumeStatus
        ProtectionStatus     = [string]$Volume.ProtectionStatus
        LockStatus           = [string]$Volume.LockStatus
        EncryptionMethod     = [string]$Volume.EncryptionMethod
        EncryptionPercentage = $Volume.EncryptionPercentage
        KeyProtectors        = $protectors
    }
}

function New-BlTestPassword {
    # 24 random characters from an unambiguous alphabet, returned as a read-only SecureString.
    [CmdletBinding()]
    param()

    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $rng   = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 24
    $rng.GetBytes($bytes)
    $secure = New-Object System.Security.SecureString
    foreach ($b in $bytes) { $secure.AppendChar($alphabet[$b % $alphabet.Length]) }
    $secure.MakeReadOnly()
    $rng.Dispose()
    return $secure
}

# ----------------------------------------------------------------------------------------------
# The identity guard. Every state-changing function calls this first.
# ----------------------------------------------------------------------------------------------

function Assert-BlTestIdentity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$VhdPath,
        [string]$DriveLetter,
        [switch]$RequireFormatted
    )

    # 1. file name and folder
    if (-not (Test-BlTestVhdPath -Path $VhdPath)) {
        throw ("Refusing: '{0}' is not a BLTEST-xxxxxxxx.vhdx file directly inside '{1}'." -f $VhdPath, $script:BlTestFolder)
    }
    $full = [System.IO.Path]::GetFullPath($VhdPath)
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw ("Refusing: VHDX file '{0}' does not exist." -f $full)
    }

    # 2. the image must be attached and Windows must report the same path back
    $img = Get-DiskImage -ImagePath $full -ErrorAction Stop
    if (-not ($null -ne $img -and $img.Attached -eq $true)) {
        throw ("Refusing: '{0}' is not attached." -f $full)
    }
    if ($null -eq $img.Number) { throw 'Refusing: Get-DiskImage returned no disk number.' }
    $reported = [string]$img.ImagePath
    if ($reported.StartsWith('\\?\')) { $reported = $reported.Substring(4) }
    if (-not (Test-BlTestVhdPath -Path $reported)) {
        throw ("Refusing: Windows reports the image path as '{0}', which is not a guarded test VHDX." -f $reported)
    }
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($reported), $full, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw ("Refusing: image path mismatch ('{0}' vs '{1}')." -f $reported, $full)
    }

    # 3. the disk behind it (NOTE: [int]$null would be 0 = the OS disk, hence the explicit null check above)
    $num  = [int]$img.Number
    $disk = Get-Disk -Number $num -ErrorAction Stop
    if (-not (Test-BlTestIsFileBackedVirtual -Disk $disk)) {
        throw ("Refusing: disk {0} is not a file-backed virtual disk (BusType {1})." -f $num, $disk.BusType)
    }
    if (-not ($disk.IsSystem -eq $false -and $disk.IsBoot -eq $false)) {
        throw ("Refusing: disk {0} is a system/boot disk." -f $num)
    }
    if (-not ($disk.Size -gt 0 -and $disk.Size -le $script:BlTestMaxDiskBytes)) {
        throw ("Refusing: disk {0} has size {1} bytes, expected a small test disk." -f $num, $disk.Size)
    }
    $sysLetter = ([string]$env:SystemDrive).Substring(0, 1).ToUpperInvariant()
    $osPart = Get-Partition -DriveLetter $sysLetter -ErrorAction Stop
    if (@($osPart | Where-Object { $_.DiskNumber -eq $num }).Count -gt 0) {
        throw ("Refusing: disk {0} holds the system drive {1}:." -f $num, $sysLetter)
    }

    # 4. the drive letter, when one is involved
    $L = $null
    if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) {
        $L = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant()
        if ($L -notmatch '^[F-Z]$') { throw ("Refusing: drive letter must be F-Z, got '{0}'." -f $DriveLetter) }
        if ($L -eq $sysLetter) { throw 'Refusing: that is the system drive.' }
        $parts = @(Get-Partition -DiskNumber $num -ErrorAction Stop | Where-Object { ([string]$_.DriveLetter).ToUpperInvariant() -eq $L })
        if ($parts.Count -ne 1) {
            throw ("Refusing: {0}: is not a partition of the test VHDX (disk {1})." -f $L, $num)
        }
        $vol = Get-Volume -DriveLetter $L -ErrorAction Stop
        $imgByVolume = $null
        try { $imgByVolume = @(Get-DiskImage -Volume $vol -ErrorAction Stop) } catch { $imgByVolume = $null }
        if ($null -ne $imgByVolume -and $imgByVolume.Count -gt 0) {
            foreach ($candidate in $imgByVolume) {
                $p = [string]$candidate.ImagePath
                if ($p.StartsWith('\\?\')) { $p = $p.Substring(4) }
                if (-not [string]::Equals($p, $full, [System.StringComparison]::OrdinalIgnoreCase)) {
                    throw ("Refusing: volume {0}: belongs to image '{1}', not to '{2}'." -f $L, $p, $full)
                }
            }
        }
        if ($RequireFormatted -and ([string]$vol.FileSystemLabel -ne $script:BlTestLabel)) {
            throw ("Refusing: volume {0}: has label '{1}', expected '{2}'." -f $L, $vol.FileSystemLabel, $script:BlTestLabel)
        }
    }

    return [pscustomobject]@{ VhdPath = $full; DiskNumber = $num; DriveLetter = $L }
}

function Invoke-BlTestDiskpart {
    # diskpart is only used to create + attach the VHDX (the Storage module cannot create one without Hyper-V).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Lines)

    $dp = Join-Path $env:windir 'System32\diskpart.exe'
    if (-not (Test-Path -LiteralPath $dp)) { throw 'diskpart.exe not found.' }
    $folder = Get-BlTestFolder -Create
    $scriptFile = Join-Path $folder ('diskpart-' + [guid]::NewGuid().ToString('N') + '.txt')
    $out = $null
    $code = -1
    try {
        Set-Content -LiteralPath $scriptFile -Value $Lines -Encoding ASCII -ErrorAction Stop
        $out = & $dp /s $scriptFile 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        if ([string]::Equals([System.IO.Path]::GetDirectoryName($scriptFile), $folder.TrimEnd('\'), [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $scriptFile -Force -ErrorAction SilentlyContinue
        }
    }
    if ($code -ne 0) {
        throw ('diskpart failed with exit code {0}: {1}' -f $code, (($out | Out-String).Trim()))
    }
    return $out
}

# ----------------------------------------------------------------------------------------------
# Public functions
# ----------------------------------------------------------------------------------------------

function New-TestVhdVolume {
    <#
    .SYNOPSIS
        Creates a small expandable VHDX, attaches it, formats it NTFS (label BLTEST) and gives it a FREE drive letter.
    .OUTPUTS
        PSCustomObject with DriveLetter, MountPoint, VhdPath, DiskNumber, SizeMB, Label.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        # BitLocker refuses volumes that are "too small" (0x8031006F); the exact minimum is undocumented, so 256 is the default.
        [ValidateRange(128, 2048)][int]$SizeMB = 256,
        # Optional preference; it must still pass the same "free" checks. Default: highest free letter F-Z.
        [ValidatePattern('^[F-Zf-z]:?$')][string]$DriveLetter
    )

    Assert-BlTestElevated
    foreach ($cmd in 'Get-DiskImage', 'Dismount-DiskImage', 'Get-Disk', 'Set-Disk', 'Initialize-Disk', 'New-Partition', 'Format-Volume', 'Get-Volume', 'Get-Partition') {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw ("Required cmdlet '{0}' (Storage module) is missing." -f $cmd) }
    }

    $folder = Get-BlTestFolder -Create
    $id  = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $vhd = Join-Path $folder ('BLTEST-' + $id + '.vhdx')
    if (-not (Test-BlTestVhdPath -Path $vhd)) { throw 'Internal error: generated path failed the name guard.' }
    if (Test-Path -LiteralPath $vhd) { throw ("Refusing: '{0}' already exists." -f $vhd) }

    if ($DriveLetter) { $letter = $DriveLetter.Trim().TrimEnd(':').ToUpperInvariant() } else { $letter = Get-BlTestFreeDriveLetter }
    $letter = Assert-BlTestLetterFree -Letter $letter

    if (-not $PSCmdlet.ShouldProcess($vhd, ('create {0} MB VHDX, attach, format NTFS, assign {1}:' -f $SizeMB, $letter))) { return }

    try {
        Invoke-BlTestDiskpart -Lines @(
            ('create vdisk file="{0}" maximum={1} type=expandable' -f $vhd, $SizeMB),
            ('select vdisk file="{0}"' -f $vhd),
            'attach vdisk'
        ) | Out-Null

        $attachedCheck = {
            $i = Get-DiskImage -ImagePath $vhd -ErrorAction Stop
            ($i.Attached -eq $true) -and ($null -ne $i.Number)
        }.GetNewClosure()
        Wait-BlTestUntil -What 'the VHDX to report Attached with a disk number' -TimeoutSeconds 30 -Condition $attachedCheck

        $img = Get-DiskImage -ImagePath $vhd -ErrorAction Stop
        if ($null -eq $img.Number) { throw 'Refusing: the attached VHDX has no disk number.' }
        $n = [int]$img.Number

        $diskCheck = {
            $null -ne (Get-Disk -Number $n -ErrorAction Stop)
        }.GetNewClosure()
        Wait-BlTestUntil -What ('disk ' + $n + ' to be visible') -TimeoutSeconds 30 -Condition $diskCheck
        $disk = Get-Disk -Number $n -ErrorAction Stop

        # only a brand-new, empty, virtual, small disk may be partitioned
        if (-not (Test-BlTestIsFileBackedVirtual -Disk $disk)) { throw ("Refusing: disk {0} is not file-backed virtual." -f $n) }
        if (-not ($disk.IsSystem -eq $false -and $disk.IsBoot -eq $false)) { throw ("Refusing: disk {0} is a system/boot disk." -f $n) }
        $style = [string]$disk.PartitionStyle
        if (-not (($style -eq 'RAW' -or $style -eq 'Unknown' -or $style -eq '0') -and $disk.NumberOfPartitions -eq 0)) {
            throw ("Refusing: disk {0} is not a blank RAW disk (style {1}, partitions {2})." -f $n, $style, $disk.NumberOfPartitions)
        }
        $expected = [int64]$SizeMB * 1MB
        if (-not ($disk.Size -ge ($expected - 2MB) -and $disk.Size -le ($expected + 2MB))) {
            throw ("Refusing: disk {0} has {1} bytes, expected about {2}." -f $n, $disk.Size, $expected)
        }
        # cross-check through the image path before the first write
        $null = Assert-BlTestIdentity -VhdPath $vhd

        if ($disk.IsReadOnly) { Set-Disk -Number $n -IsReadOnly $false -ErrorAction Stop }
        if ($disk.IsOffline)  { Set-Disk -Number $n -IsOffline $false -ErrorAction Stop }
        Initialize-Disk -Number $n -PartitionStyle GPT -ErrorAction Stop

        $letter = Assert-BlTestLetterFree -Letter $letter      # re-check right before it is used
        $part = New-Partition -DiskNumber $n -UseMaximumSize -DriveLetter $letter -ErrorAction Stop
        if (-not ($part.DiskNumber -eq $n)) { throw 'Refusing: the new partition is not on the test disk.' }
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel $script:BlTestLabel -Confirm:$false -Force -ErrorAction Stop | Out-Null

        $volumeCheck = {
            Test-Path -LiteralPath ($letter + ':\')
        }.GetNewClosure()
        Wait-BlTestUntil -What ('volume ' + $letter + ': to appear') -TimeoutSeconds 30 -Condition $volumeCheck
        $null = Assert-BlTestIdentity -VhdPath $vhd -DriveLetter $letter -RequireFormatted
    }
    catch {
        $failure = $_
        Write-Warning ('New-TestVhdVolume failed: {0}. Cleaning up the test VHDX (guarded).' -f $failure.Exception.Message)
        try {
            if (Test-Path -LiteralPath $vhd) { Remove-TestVolume -VhdPath $vhd -Confirm:$false }
        }
        catch { Write-Warning ('Cleanup also failed: {0}' -f $_.Exception.Message) }
        throw $failure
    }

    return [pscustomobject]@{
        DriveLetter = $letter
        MountPoint  = ($letter + ':')
        VhdPath     = $vhd
        DiskNumber  = $n
        SizeMB      = $SizeMB
        Label       = $script:BlTestLabel
    }
}

function Enable-TestVolumeBitLocker {
    <#
    .SYNOPSIS
        Enables BitLocker on the guarded test volume: password protector + recovery-password protector.
    .DESCRIPTION
        Defaults: XtsAes256, used space only. Without -Password a random 24-character password is generated and
        returned as a SecureString in the TestPassword property of the result (never printed).
        The recovery password is NOT printed; read it the same way the dialog will: (Get-BitLockerVolume X:).KeyProtector.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$VhdPath,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$DriveLetter,
        [System.Security.SecureString]$Password,
        [ValidateSet('XtsAes256', 'XtsAes128', 'Aes256', 'Aes128')][string]$EncryptionMethod = 'XtsAes256',
        [switch]$FullEncryption,
        [int]$TimeoutSeconds = 180
    )
    process {
        Assert-BlTestElevated
        $id = Assert-BlTestIdentity -VhdPath $VhdPath -DriveLetter $DriveLetter -RequireFormatted
        $mp = $id.DriveLetter + ':'
        Import-Module BitLocker -ErrorAction Stop -WarningAction SilentlyContinue

        $before = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
        # KeyProtector can be $null or empty on a fresh volume; @($null).Count would be 1, so drop null elements first
        $existingProtectors = @(@($before.KeyProtector) | Where-Object { $null -ne $_ })
        if (-not ([string]$before.VolumeStatus -eq 'FullyDecrypted' -and $existingProtectors.Count -eq 0)) {
            throw ("Refusing: {0} is not a fresh, fully decrypted volume (status '{1}')." -f $mp, $before.VolumeStatus)
        }
        if (-not $PSCmdlet.ShouldProcess($mp, ('Enable-BitLocker {0} + password and recovery-password protectors' -f $EncryptionMethod))) { return }

        $generated = $false
        if ($null -eq $Password) { $Password = New-BlTestPassword; $generated = $true }

        $enableArgs = @{
            MountPoint        = $mp
            EncryptionMethod  = $EncryptionMethod
            PasswordProtector = $true
            Password          = $Password
            ErrorAction       = 'Stop'
            WarningAction     = 'SilentlyContinue'
        }
        if (-not $FullEncryption) { $enableArgs['UsedSpaceOnly'] = $true }
        Enable-BitLocker @enableArgs | Out-Null
        Add-BitLockerKeyProtector -MountPoint $mp -RecoveryPasswordProtector -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null

        $encryptedCheck = {
            ([string](Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop).VolumeStatus) -eq 'FullyEncrypted'
        }.GetNewClosure()
        Wait-BlTestUntil -What ('BitLocker on ' + $mp + ' to reach FullyEncrypted') -TimeoutSeconds $TimeoutSeconds -IntervalMilliseconds 1000 -Condition $encryptedCheck

        $summary = Get-TestVolumeBitLockerStatus -VhdPath $id.VhdPath -DriveLetter $id.DriveLetter
        $result = [pscustomobject]@{
            DriveLetter          = $id.DriveLetter
            MountPoint           = $mp
            VhdPath              = $id.VhdPath
            VolumeStatus         = $summary.VolumeStatus
            ProtectionStatus     = $summary.ProtectionStatus
            EncryptionMethod     = $summary.EncryptionMethod
            EncryptionPercentage = $summary.EncryptionPercentage
            KeyProtectors        = $summary.KeyProtectors
            TestPassword         = $null
        }
        if ($generated) { $result.TestPassword = $Password }
        return $result
    }
}

function Get-TestVolumeBitLockerStatus {
    <#
    .SYNOPSIS
        Read-only status of the guarded test volume. Contains protector TYPES and IDs only, never secrets.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$VhdPath,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$DriveLetter
    )
    process {
        $id = Assert-BlTestIdentity -VhdPath $VhdPath -DriveLetter $DriveLetter
        Import-Module BitLocker -ErrorAction Stop -WarningAction SilentlyContinue
        $v = Get-BitLockerVolume -MountPoint ($id.DriveLetter + ':') -ErrorAction Stop
        return (ConvertTo-BlTestSafeSummary -Volume $v)
    }
}

function Disable-TestVolumeBitLocker {
    <#
    .SYNOPSIS
        Runs Disable-BitLocker on the guarded test volume only; with -Wait shows progress until FullyDecrypted.
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$VhdPath,
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$DriveLetter,
        [switch]$Wait,
        [int]$TimeoutSeconds = 300
    )
    process {
        Assert-BlTestElevated
        $id = Assert-BlTestIdentity -VhdPath $VhdPath -DriveLetter $DriveLetter
        $mp = $id.DriveLetter + ':'
        Import-Module BitLocker -ErrorAction Stop -WarningAction SilentlyContinue
        if (-not $PSCmdlet.ShouldProcess($mp, 'Disable-BitLocker (decrypt) the TEST volume')) { return }

        Disable-BitLocker -MountPoint $mp -ErrorAction Stop | Out-Null

        if ($Wait) {
            $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
            while ($true) {
                $v = Get-BitLockerVolume -MountPoint $mp -ErrorAction Stop
                $status = [string]$v.VolumeStatus
                if ($status -eq 'FullyDecrypted') { break }
                if ((Get-Date) -gt $deadline) { throw ('Timed out after {0} s; last status {1}.' -f $TimeoutSeconds, $status) }
                $pct = 0
                if ($null -ne $v.EncryptionPercentage) { $pct = [int](100 - [double]$v.EncryptionPercentage) }
                $pct = [Math]::Max(0, [Math]::Min(100, $pct))
                Write-Progress -Activity ('Decrypting ' + $mp) -Status ('{0} ({1}% still encrypted)' -f $status, $v.EncryptionPercentage) -PercentComplete $pct
                Start-Sleep -Seconds 1
            }
            Write-Progress -Activity ('Decrypting ' + $mp) -Completed
        }
        return (Get-TestVolumeBitLockerStatus -VhdPath $id.VhdPath -DriveLetter $id.DriveLetter)
    }
}

function Remove-TestVolume {
    <#
    .SYNOPSIS
        Dismounts (detaches) and deletes the test VHDX. It can only act on a guarded BLTEST-xxxxxxxx.vhdx file.
    .DESCRIPTION
        The only two destructive calls are  Dismount-DiskImage -ImagePath <guarded file>  and
        Remove-Item -LiteralPath <guarded file>. If the image is attached, its disk is re-verified first
        (file-backed virtual, not system/boot, not the OS disk, small) and, when -DriveLetter is given, that
        letter must belong to it. A stale mount-manager entry for the letter may remain; that is harmless.
    #>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true)][string]$VhdPath,
        [Parameter(ValueFromPipelineByPropertyName = $true)][string]$DriveLetter
    )
    process {
        Assert-BlTestElevated
        if (-not (Test-BlTestVhdPath -Path $VhdPath)) {
            throw ("Refusing: '{0}' is not a BLTEST-xxxxxxxx.vhdx file directly inside '{1}'." -f $VhdPath, $script:BlTestFolder)
        }
        $null = Get-BlTestFolder
        $full = [System.IO.Path]::GetFullPath($VhdPath)

        $img = $null
        try { $img = Get-DiskImage -ImagePath $full -ErrorAction Stop } catch { $img = $null }
        $attached = ($null -ne $img -and $img.Attached -eq $true)

        if ($attached) {
            $null = Assert-BlTestIdentity -VhdPath $full
            if (-not [string]::IsNullOrWhiteSpace($DriveLetter)) { $null = Assert-BlTestIdentity -VhdPath $full -DriveLetter $DriveLetter }
        }

        if (-not $PSCmdlet.ShouldProcess($full, 'Dismount the VHDX and delete the file')) { return }

        if ($attached) {
            $detached = $false
            $detachedCheck = {
                (Get-DiskImage -ImagePath $full -ErrorAction Stop).Attached -eq $false
            }.GetNewClosure()
            for ($attempt = 1; $attempt -le 5 -and -not $detached; $attempt++) {
                try { Dismount-DiskImage -ImagePath $full -ErrorAction Stop | Out-Null } catch { Start-Sleep -Seconds 2 }
                try {
                    Wait-BlTestUntil -What 'the VHDX to detach' -TimeoutSeconds 10 -Condition $detachedCheck
                    $detached = $true
                }
                catch { Start-Sleep -Seconds 1 }
            }
            if (-not $detached) {
                throw ("Could not detach '{0}'. Close Explorer windows / programs that use the test drive and run Remove-TestVolume again. The file was NOT deleted." -f $full)
            }
        }

        if (Test-Path -LiteralPath $full -PathType Leaf) {
            Remove-Item -LiteralPath $full -Force -ErrorAction Stop
        }
        if (Test-Path -LiteralPath $full) { throw ("The file '{0}' still exists." -f $full) }
    }
}

Write-Host 'Loaded BitLocker test-volume helpers: New-TestVhdVolume, Enable-TestVolumeBitLocker, Get-TestVolumeBitLockerStatus, Disable-TestVolumeBitLocker, Remove-TestVolume. Nothing has been created or changed.'

<#
.SYNOPSIS
    Gr3y's Utilities - native Windows GUI for Dell/Lenovo debloat, Microsoft 365 Apps
    for business deploy, and a WinUtil-style app install catalog.

.DESCRIPTION
    Two tabs:
      1. Debloat + Office - same engine as Deploy-DellOfficeSetup.ps1 (must sit next to
         this script), driven through checkboxes instead of a command line, with live
         log streaming and a CPU-activity heartbeat across the whole process tree.
      2. Install Apps - a categorized winget-backed install catalog loaded from
         apps-catalog.json (must also sit next to this script). Edit that JSON file to
         add/remove/rename entries - no code changes needed.

    Launch via the repo's debloat.ps1 bootstrap (self-elevates, downloads all three
    files fresh, then runs this), or directly if already elevated:
        .\Gr3ysUtilities.ps1

.NOTES
    Requires Administrator and an STA PowerShell process (both handled automatically -
    this script re-launches itself if either is missing, so it's safe to double-click
    or run from a non-elevated/non-STA shell).
#>

[CmdletBinding()]
param()

# ============================================================================
# Elevation + STA self-relaunch (WPF requires STA; admin is required by the
# worker script). Safe even when this file is invoked some other way than via
# debloat.ps1, since debloat.ps1 already guarantees both before calling this.
# ============================================================================

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$needsElevation = -not (Test-IsAdmin)
$needsSTA = [System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA'

if ($needsElevation -or $needsSTA) {
    $relaunchArgs = @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($needsElevation) {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs -Verb RunAs
    } else {
        Start-Process -FilePath 'powershell.exe' -ArgumentList $relaunchArgs
    }
    exit
}

$ErrorActionPreference = 'Continue'

# Loaded up front (not just before XamlReader.Load below) since the file-existence
# checks right after this also show a MessageBox on failure, and referencing that
# type before its assembly is loaded would itself throw a confusing error exactly
# when something has already gone wrong.
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$scriptDir = Split-Path -Parent $PSCommandPath
$deployScript = Join-Path $scriptDir 'Deploy-DellOfficeSetup.ps1'
$catalogPath = Join-Path $scriptDir 'apps-catalog.json'
$patternsPath = Join-Path $scriptDir 'bloat-patterns.json'
$workDir = Join-Path $env:ProgramData 'DellOfficeDeploy'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

if (-not (Test-Path $deployScript)) {
    [System.Windows.Forms.MessageBox]::Show("Deploy-DellOfficeSetup.ps1 not found next to this script at:`r`n$deployScript", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
if (-not (Test-Path $patternsPath)) {
    [System.Windows.Forms.MessageBox]::Show("bloat-patterns.json not found next to this script at:`r`n$patternsPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$bloatPatterns = Get-Content -Path $patternsPath -Raw | ConvertFrom-Json

# ============================================================================
# Shared helpers (same logic as WebApp.ps1's browser-panel version, reused here
# since the process-launching / log-tailing / CPU-heartbeat mechanics don't
# depend on how the UI renders them).
# ============================================================================

function Get-SafeFileNamePart {
    param([string]$Value)
    if (-not $Value) { return 'Unknown' }
    $clean = ($Value -replace '[\\/:*?"<>|]', '') -replace '\s+', '-'
    $clean = $clean.Trim('-')
    if (-not $clean) { return 'Unknown' }
    return $clean
}

function Get-MachineTag {
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction SilentlyContinue
    $mfr = if ($cs -and $cs.Manufacturer) { $cs.Manufacturer } else { 'UnknownMfr' }
    $model = if ($cs -and $cs.Model) { $cs.Model } else { 'UnknownModel' }
    $serial = if ($bios -and $bios.SerialNumber) { $bios.SerialNumber } else { 'UnknownSerial' }
    return "{0}_{1}-{2}_{3}" -f `
        (Get-SafeFileNamePart $env:COMPUTERNAME), `
        (Get-SafeFileNamePart $mfr), `
        (Get-SafeFileNamePart $model), `
        (Get-SafeFileNamePart $serial)
}

function Get-DescendantProcessIds {
    param([int]$RootId)
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId
    $result = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Generic.Queue[int]
    $queue.Enqueue($RootId)
    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $result.Add($current)
        foreach ($p in ($all | Where-Object { $_.ParentProcessId -eq $current })) {
            $queue.Enqueue([int]$p.ProcessId)
        }
    }
    return $result
}

function Get-TreeCpuSeconds {
    param([int]$RootId)
    $ids = Get-DescendantProcessIds -RootId $RootId
    $total = 0.0
    foreach ($id in $ids) {
        try {
            $p = Get-Process -Id $id -ErrorAction Stop
            $total += $p.TotalProcessorTime.TotalSeconds
        } catch {}
    }
    return [math]::Round($total, 1)
}

function Get-LogTail {
    param([string]$Path, [long]$Offset)
    if (-not $Path -or -not (Test-Path $Path)) { return @{ offset = 0; text = '' } }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($Offset -ge $len) { return @{ offset = $len; text = '' } }
        if ($Offset -lt 0) { $Offset = 0 }
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $bytesToRead = [int]($len - $Offset)
        $buffer = New-Object byte[] $bytesToRead
        $fs.Read($buffer, 0, $bytesToRead) | Out-Null
        $text = [System.Text.Encoding]::UTF8.GetString($buffer)
        return @{ offset = $len; text = $text }
    } finally {
        $fs.Close()
    }
}

function Get-LogSummary {
    param([string]$LogPath)
    $result = @{ phase = 'Idle'; completed = $false }
    if (-not $LogPath -or -not (Test-Path $LogPath)) { return $result }
    $content = Get-Content -Path $LogPath -Raw -ErrorAction SilentlyContinue
    if (-not $content) { $result.phase = 'Starting...'; return $result }
    $phase = 'Starting...'
    $found = [regex]::Matches($content, '--- (Phase \d[a-z]?: [^-]+) ---')
    if ($found.Count -gt 0) { $phase = $found[$found.Count - 1].Groups[1].Value.Trim() }
    if ($content -match 'Run complete\.') {
        $phase = 'All phases complete'
        $result.completed = $true
    }
    $result.phase = $phase
    return $result
}

function Get-UninstallEntries {
    $paths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    Get-ItemProperty -Path $paths -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName }
}

function Get-BloatScanReport {
    # Read-only inspection using the exact same patterns Deploy-DellOfficeSetup.ps1
    # acts on (both load from bloat-patterns.json) - nothing here changes the system,
    # it only reports what a real run would touch. Respects the Dell/Lenovo toggles
    # the same way the real run does, so the scan matches what Start would actually do.
    $lines = New-Object System.Collections.Generic.List[string]

    $oemsToScan = @()
    if ($optDell.IsChecked) { $oemsToScan += 'dell' }
    if ($optLenovo.IsChecked) { $oemsToScan += 'lenovo' }
    if ($oemsToScan.Count -eq 0) { $oemsToScan = @('dell', 'lenovo') }

    $appxPatternsToScan = New-Object System.Collections.Generic.List[string]
    $win32PatternsToScan = New-Object System.Collections.Generic.List[string]
    $taskFoldersToScan = New-Object System.Collections.Generic.List[string]
    $taskKeepPatternsToScan = New-Object System.Collections.Generic.List[string]
    $servicePatternsToScan = New-Object System.Collections.Generic.List[string]
    foreach ($p in $bloatPatterns.generic.appxPatterns) { $appxPatternsToScan.Add($p) }
    foreach ($p in $bloatPatterns.generic.win32Patterns) { $win32PatternsToScan.Add($p) }
    foreach ($oemName in $oemsToScan) {
        $section = $bloatPatterns.$oemName
        if (-not $section) { continue }
        foreach ($p in $section.appxPatterns) { $appxPatternsToScan.Add($p) }
        foreach ($p in $section.win32Patterns) { $win32PatternsToScan.Add($p) }
        foreach ($p in $section.scheduledTaskFolders) { $taskFoldersToScan.Add($p) }
        foreach ($p in $section.scheduledTaskKeepPatterns) { $taskKeepPatternsToScan.Add($p) }
        foreach ($p in $section.servicePatterns) { $servicePatternsToScan.Add($p) }
    }

    $allInstalledAppx = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    $foundAppx = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $appxPatternsToScan) {
        foreach ($pkg in ($allInstalledAppx | Where-Object { $_.Name -like $pattern })) {
            $foundAppx.Add($pkg.Name)
        }
    }

    $entries = Get-UninstallEntries
    $foundWin32 = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $win32PatternsToScan) {
        foreach ($match in ($entries | Where-Object { $_.DisplayName -like $pattern })) {
            $foundWin32.Add($match.DisplayName)
        }
    }

    $foundTasks = New-Object System.Collections.Generic.List[string]
    foreach ($folder in $taskFoldersToScan) {
        $tasks = Get-ScheduledTask -TaskPath "$folder*" -ErrorAction SilentlyContinue
        foreach ($task in $tasks) {
            $isKept = $false
            foreach ($keep in $taskKeepPatternsToScan) {
                if ($task.TaskName -like $keep) { $isKept = $true; break }
            }
            if (-not $isKept -and $task.State -ne 'Disabled') {
                $foundTasks.Add("$($task.TaskPath)$($task.TaskName)")
            }
        }
    }

    $foundServices = New-Object System.Collections.Generic.List[string]
    foreach ($pattern in $servicePatternsToScan) {
        foreach ($svc in (Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like $pattern -or $_.Name -like $pattern })) {
            $foundServices.Add("$($svc.DisplayName) ($($svc.Name))")
        }
    }

    $hasC2R = Test-Path 'HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration'
    $msiOffice = @($entries | Where-Object { $_.DisplayName -like 'Microsoft Office*' -and $_.UninstallString -match 'msiexec' })

    $lines.Add("Scan results for $env:COMPUTERNAME - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $lines.Add('Nothing below has been changed - this is a read-only inspection.')
    $lines.Add('')

    $lines.Add("OEM bloat apps found ($($foundAppx.Count + $foundWin32.Count)):")
    if ($foundAppx.Count -eq 0 -and $foundWin32.Count -eq 0) {
        $lines.Add('  (none matched)')
    } else {
        foreach ($n in $foundAppx) { $lines.Add("  - $n (AppX)") }
        foreach ($n in $foundWin32) { $lines.Add("  - $n (program)") }
    }
    $lines.Add('')

    $lines.Add("OEM scheduled tasks that would be disabled ($($foundTasks.Count)):")
    if ($foundTasks.Count -eq 0) { $lines.Add('  (none matched)') }
    else { foreach ($n in $foundTasks) { $lines.Add("  - $n") } }
    $lines.Add('')

    $lines.Add("OEM services that would be disabled ($($foundServices.Count)):")
    if ($foundServices.Count -eq 0) { $lines.Add('  (none matched)') }
    else { foreach ($n in $foundServices) { $lines.Add("  - $n") } }
    $lines.Add('')

    $lines.Add('Office:')
    if ($hasC2R) { $lines.Add('  - Click-to-Run Office install detected (would be fully removed, then Microsoft 365 Apps installed fresh)') }
    foreach ($m in $msiOffice) { $lines.Add("  - MSI-based Office product detected: $($m.DisplayName)") }
    if (-not $hasC2R -and $msiOffice.Count -eq 0) { $lines.Add('  - No existing Office installation detected') }

    $totalFound = $foundAppx.Count + $foundWin32.Count + $foundTasks.Count + $foundServices.Count
    $lines.Add('')
    $lines.Add("Total items that would be touched: $totalFound" + $(if ($hasC2R -or $msiOffice.Count -gt 0) { ' (plus the existing Office install)' } else { '' }))

    return ($lines -join "`r`n")
}

# ============================================================================
# WPF setup
# ============================================================================

if (-not (Test-Path $catalogPath)) {
    [System.Windows.Forms.MessageBox]::Show("apps-catalog.json not found next to this script at:`r`n$catalogPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$catalog = Get-Content -Path $catalogPath -Raw | ConvertFrom-Json

[xml]$xamlDoc = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gr3y's Utilities" Height="820" Width="1150" MinHeight="640" MinWidth="980"
        WindowStartupLocation="CenterScreen" WindowStyle="None" ResizeMode="CanResize"
        AllowsTransparency="False" Background="#232629"
        FontFamily="Segoe UI" FontSize="12"
        UseLayoutRounding="True" SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display" TextOptions.TextRenderingMode="ClearType">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="44" ResizeBorderThickness="6" GlassFrameThickness="0"
                  CornerRadius="0" UseAeroCaptionButtons="False"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#232629"/>
    <SolidColorBrush x:Key="PanelBorderBrush" Color="#2F373D"/>
    <SolidColorBrush x:Key="ButtonBrush" Color="#1E3747"/>
    <SolidColorBrush x:Key="ButtonHoverBrush" Color="#2A4C69"/>
    <SolidColorBrush x:Key="ControlBorderBrush" Color="#707070"/>
    <SolidColorBrush x:Key="TextBrush" Color="#F7F7F7"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA3AB"/>
    <SolidColorBrush x:Key="HeaderBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="HintBrush" Color="#4FB5D2"/>
    <SolidColorBrush x:Key="NavSelectedBrush" Color="#5E81AC"/>
    <SolidColorBrush x:Key="ToggleOnBrush" Color="#2E77FF"/>
    <SolidColorBrush x:Key="ToggleOffBrush" Color="#707070"/>
    <SolidColorBrush x:Key="LogBgBrush" Color="#1B1E21"/>
    <SolidColorBrush x:Key="ScrollThumbBrush" Color="#3C4146"/>
    <SolidColorBrush x:Key="CloseHoverBrush" Color="#C42B1C"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#5BDCFF"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3FB950"/>
    <SolidColorBrush x:Key="RedBrush" Color="#F85149"/>
    <SolidColorBrush x:Key="YellowBrush" Color="#D29922"/>
    <SolidColorBrush x:Key="OrangeBrush" Color="#F0883E"/>

    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
    <Style x:Key="Header" TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Foreground" Value="{StaticResource HeaderBrush}"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Text" Value="(?)"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource HintBrush}"/>
      <Setter Property="Margin" Value="6,0,0,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Help"/>
      <Setter Property="ToolTipService.InitialShowDelay" Value="200"/>
    </Style>
    <Style x:Key="StatusLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Foreground" Value="{StaticResource HintBrush}"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
    </Style>
    <Style x:Key="StatusSep" TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="Margin" Value="12,0,12,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="Panel" TargetType="Border">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="0"/>
      <Setter Property="Padding" Value="10,8"/>
    </Style>
    <Style TargetType="ToolTip">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToolTip">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Padding="8,5" MaxWidth="380">
              <TextBlock Text="{TemplateBinding Content}" TextWrapping="Wrap" Foreground="{TemplateBinding Foreground}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource ButtonBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="10,3"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Height" Value="25"/>
      <Setter Property="MinWidth" Value="90"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ButtonHoverBrush}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource NavSelectedBrush}"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="NavButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Width" Value="110"/>
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="Padding" Value="4,2"/>
      <Style.Triggers>
        <Trigger Property="Tag" Value="selected">
          <Setter Property="Background" Value="{StaticResource NavSelectedBrush}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="WindowButton" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="44"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Cursor" Value="Arrow"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ScrollThumbBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="WindowCloseButton" TargetType="Button" BasedOn="{StaticResource WindowButton}">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource CloseHoverBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="2,1"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="14" Height="14" Background="{StaticResource ButtonBrush}"
                      BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1" CornerRadius="0" VerticalAlignment="Center">
                <Path x:Name="CheckMark" Data="M2,7 L5.5,10.5 L12,3.5" Stroke="{StaticResource TextBrush}" StrokeThickness="2"
                      Visibility="Collapsed"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center" RecognizesAccessKey="False"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource HeaderBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="34" Height="17">
              <Border x:Name="Track" CornerRadius="8.5" Background="{StaticResource ToggleOffBrush}"/>
              <Ellipse x:Name="Thumb" Width="13" Height="13" Fill="#FFFFFF" HorizontalAlignment="Left" Margin="2,0,0,0"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Track" Property="Background" Value="{StaticResource ToggleOnBrush}"/>
                <Setter TargetName="Thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="Thumb" Property="Margin" Value="0,0,2,0"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="8,4"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="Transparent" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource NavSelectedBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Height" Value="25"/>
      <Setter Property="Padding" Value="8,2"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{StaticResource ButtonBrush}" BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1" CornerRadius="0">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="22"/>
                        </Grid.ColumnDefinitions>
                        <Path Grid.Column="1" Data="M0,0 L4,4 L8,0" Stroke="{StaticResource TextBrush}" StrokeThickness="1.2"
                              HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" Placement="Bottom" PopupAnimation="None">
                <Border Background="{StaticResource BgBrush}" BorderBrush="{StaticResource ControlBorderBrush}" BorderThickness="1"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ComboBox}}" MaxHeight="220">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource ControlBorderBrush}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,3"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="SelectionBrush" Value="{StaticResource NavSelectedBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="0">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource TextBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="SearchBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="BorderBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="6,0,24,0"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="LogBox" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Background" Value="{StaticResource LogBgBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource PanelBorderBrush}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="8,6"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="Width" Value="10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="{TemplateBinding Background}">
              <Track x:Name="PART_Track" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Opacity="0" Focusable="False"/>
                </Track.DecreaseRepeatButton>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Opacity="0" Focusable="False"/>
                </Track.IncreaseRepeatButton>
                <Track.Thumb>
                  <Thumb>
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="{StaticResource ScrollThumbBrush}" Margin="2"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="Orientation" Value="Horizontal">
          <Setter Property="Width" Value="Auto"/>
          <Setter Property="Height" Value="10"/>
          <Setter Property="Template">
            <Setter.Value>
              <ControlTemplate TargetType="ScrollBar">
                <Grid Background="{TemplateBinding Background}">
                  <Track x:Name="PART_Track" IsDirectionReversed="False">
                    <Track.DecreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageLeftCommand}" Opacity="0" Focusable="False"/>
                    </Track.DecreaseRepeatButton>
                    <Track.IncreaseRepeatButton>
                      <RepeatButton Command="{x:Static ScrollBar.PageRightCommand}" Opacity="0" Focusable="False"/>
                    </Track.IncreaseRepeatButton>
                    <Track.Thumb>
                      <Thumb>
                        <Thumb.Template>
                          <ControlTemplate TargetType="Thumb">
                            <Border Background="{StaticResource ScrollThumbBrush}" Margin="2"/>
                          </ControlTemplate>
                        </Thumb.Template>
                      </Thumb>
                    </Track.Thumb>
                  </Track>
                </Grid>
              </ControlTemplate>
            </Setter.Value>
          </Setter>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="TabItem">
      <Setter Property="Visibility" Value="Collapsed"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
  </Window.Resources>
  <Grid Name="RootGrid" Background="{StaticResource BgBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="44"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Background="{StaticResource BgBrush}">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>

      <TextBlock Grid.Column="0" Text="Gr3y's Utilities" FontFamily="Consolas" FontSize="16" FontWeight="Bold"
                 Foreground="{StaticResource HeaderBrush}" VerticalAlignment="Center" Margin="14,0,16,0"/>

      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <Button Name="NavDebloat" Style="{StaticResource NavButton}" Tag="selected" Content="Debloat + Office" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavInstall" Style="{StaticResource NavButton}" Content="Install Apps" WindowChrome.IsHitTestVisibleInChrome="True"/>
        <Button Name="NavFixes" Style="{StaticResource NavButton}" Content="Fixes" WindowChrome.IsHitTestVisibleInChrome="True"/>
      </StackPanel>

      <Grid Grid.Column="2" Margin="12,0,12,0" VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
        <TextBox Name="SearchBox" Height="25" Style="{StaticResource SearchBox}"/>
        <TextBlock Name="SearchHint" Text="Search apps..." Foreground="{StaticResource MutedBrush}"
                   Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
        <Path Data="M4,4 m-3,0 a3,3 0 1,0 6,0 a3,3 0 1,0 -6,0 M6.2,6.2 L9.5,9.5" Stroke="{StaticResource TextBrush}" StrokeThickness="1.2"
              Width="10" Height="10" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0" IsHitTestVisible="False"/>
      </Grid>

      <Button Grid.Column="3" Name="BtnOpenLogs" Style="{StaticResource WindowButton}" ToolTip="Open the log folder"
              WindowChrome.IsHitTestVisibleInChrome="True">
        <Path Data="M0,2 L4,2 L5,3.5 L12,3.5 L12,11 L0,11 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="12" Height="12"/>
      </Button>

      <StackPanel Grid.Column="4" Orientation="Horizontal">
        <Button Name="BtnWinMin" Style="{StaticResource WindowButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Path Data="M0,5 L10,5" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
        </Button>
        <Button Name="BtnWinMax" Style="{StaticResource WindowButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Grid>
            <Path Name="IconMax" Data="M0.5,0.5 L9.5,0.5 L9.5,9.5 L0.5,9.5 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
            <Path Name="IconRestore" Data="M2.5,0.5 L9.5,0.5 L9.5,7.5 M0.5,2.5 L7.5,2.5 L7.5,9.5 L0.5,9.5 Z" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10" Visibility="Collapsed"/>
          </Grid>
        </Button>
        <Button Name="BtnWinClose" Style="{StaticResource WindowCloseButton}" WindowChrome.IsHitTestVisibleInChrome="True">
          <Path Data="M0,0 L10,10 M10,0 L0,10" Stroke="{StaticResource TextBrush}" StrokeThickness="1" Width="10" Height="10"/>
        </Button>
      </StackPanel>
    </Grid>

    <TabControl Grid.Row="1" Name="MainTabs" Margin="10,8,10,10">
      <TabItem Header="Debloat + Office">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>

          <Grid Grid.Row="0">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="3*"/>
              <ColumnDefinition Width="10"/>
              <ColumnDefinition Width="2*"/>
            </Grid.ColumnDefinitions>

            <Border Grid.Column="0" Style="{StaticResource Panel}">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Debloat"/>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptDryRun" Content="Dry run (preview only)"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Preview only: logs everything a real run would do without changing anything."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptCreateRestorePoint" Content="Create System Restore point"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Creates a System Restore point before any change. Can be blocked by policy; Windows allows one per 24h."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipDebloat" Content="Skip OEM debloat"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Skips Phase 1 entirely: no OEM/McAfee app removal and no scheduled task or service changes."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="22,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptDell" Content="Debloat Dell software" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Checks the Dell bloat patterns (SupportAssist, Optimizer, Digital Delivery, ...). Dell Command Update is kept."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="22,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptLenovo" Content="Debloat Lenovo software" IsChecked="True"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Checks the Lenovo bloat patterns (Lenovo Now, Welcome, Glance, ...). Lenovo Vantage is kept."/>
                </DockPanel>
                <TextBlock Style="{StaticResource Header}" Text="Office" Margin="0,10,0,6"/>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipOfficeRemoval" Content="Skip removing existing Office"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Leaves any existing Office / Microsoft 365 install in place instead of removing it first."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,0,0,1">
                  <CheckBox DockPanel.Dock="Left" Name="OptSkipOfficeInstall" Content="Skip installing Microsoft 365 Apps"/>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
                             ToolTip="Does not install Microsoft 365 Apps for business at the end of the run."/>
                </DockPanel>
                <DockPanel LastChildFill="False" Margin="0,6,0,0">
                  <TextBlock DockPanel.Dock="Left" Text="Office channel:" VerticalAlignment="Center" Margin="2,0,8,0"/>
                  <ComboBox DockPanel.Dock="Left" Name="OptChannel" Width="170" SelectedIndex="0">
                    <ComboBoxItem Content="MonthlyEnterprise"/>
                    <ComboBoxItem Content="Current"/>
                    <ComboBoxItem Content="SemiAnnual"/>
                    <ComboBoxItem Content="SemiAnnualPreview"/>
                  </ComboBox>
                  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}" ToolTip="Update channel for the new install. MonthlyEnterprise is the fleet default."/>
                </DockPanel>
              </StackPanel>
            </Border>

            <Border Grid.Column="2" Style="{StaticResource Panel}">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Tweaks"/>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakTelemetry" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Reduce telemetry &amp; activity tracking" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="AllowTelemetry=0, disables the DiagTrack service and the Activity Feed."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakHibernation" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Disable hibernation (frees disk space)" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Runs powercfg /hibernate off, which removes hiberfil.sys and frees its disk space."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakPreventSleep" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Prevent sleep (keep machine reachable)" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Sets system sleep to Never on AC and battery so the machine stays reachable. Display timeout is untouched, so the screen still locks."/>
                </StackPanel>
                <StackPanel Orientation="Horizontal" Margin="0,3,0,3">
                  <CheckBox Name="OptTweakDisableSAC" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
                  <TextBlock Text="Disable Smart App Control" VerticalAlignment="Center" Margin="8,0,0,0"/>
                  <TextBlock Style="{StaticResource Hint}" ToolTip="Smart App Control hard-blocks unsigned/low-reputation installers on a clean Windows 11 22H2+ machine, with no user override - several Install Apps catalog entries will otherwise fail. WARNING: this is one-way on a real machine - once off, it cannot be turned back on without reinstalling Windows. Off by default."/>
                </StackPanel>
              </StackPanel>
            </Border>
          </Grid>

          <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,0">
            <Button Name="BtnScan" Content="Scan This Machine" MinWidth="140"/>
            <Button Name="BtnStart" Content="Start" MinWidth="110" BorderBrush="{StaticResource GreenBrush}"/>
            <Button Name="BtnStop" Content="Stop" MinWidth="90" BorderBrush="{StaticResource RedBrush}" Visibility="Collapsed"/>
            <Button Name="BtnDownloadLog" Content="Download Log" MinWidth="120" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Now" MinWidth="110" BorderBrush="{StaticResource YellowBrush}" Visibility="Collapsed"/>
          </StackPanel>

          <Border Grid.Row="2" Style="{StaticResource Panel}" Padding="10,5" Margin="0,10,0,0">
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="STATE" Style="{StaticResource StatusLabel}"/>
              <Ellipse Name="StatusDot" Width="8" Height="8" Fill="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="0,0,5,0"/>
              <TextBlock Name="StateText" Text="Idle" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="PHASE" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="PhaseText" Text="-" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="ELAPSED" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="ElapsedText" Text="0:00" VerticalAlignment="Center"/>
              <TextBlock Text="|" Style="{StaticResource StatusSep}"/>
              <TextBlock Text="CPU (JOB TREE)" Style="{StaticResource StatusLabel}"/>
              <TextBlock Name="CpuText" Text="0.0s" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>

          <Border Grid.Row="3" Name="BannerBorder" Margin="0,8,0,0" Padding="10,6" BorderThickness="1" Visibility="Collapsed">
            <TextBlock Name="BannerText" TextWrapping="Wrap"/>
          </Border>

          <TextBlock Grid.Row="4" Style="{StaticResource Header}" Text="Live Log" Margin="0,10,0,4"/>
          <TextBox Grid.Row="5" Name="LogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
        </Grid>
      </TabItem>

      <TabItem Header="Install Apps">
        <DockPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
            <Button Name="CatAll" Content="All"/>
            <Button Name="CatBrowsers" Content="Browsers"/>
            <Button Name="CatMsTools" Content="Microsoft Tools"/>
            <Button Name="CatUtilities" Content="Utilities"/>
            <Border Width="12"/>
            <Button Name="BtnSelectAll" Content="Select All"/>
            <Button Name="BtnClearSelection" Content="Clear Selection"/>
            <TextBlock Name="SelectedCountText" Text="Selected: 0" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="{StaticResource MutedBrush}"/>
            <Ellipse Name="WinGetStatusDot" Width="8" Height="8" Fill="{StaticResource MutedBrush}" VerticalAlignment="Center" Margin="16,0,5,0"/>
            <TextBlock Name="WinGetStatusText" Text="Checking winget..." VerticalAlignment="Center" Foreground="{StaticResource MutedBrush}"/>
            <Button Name="BtnInstallWinGet" Content="Install winget" Margin="10,0,0,0"
                    Background="{StaticResource AccentBrush}" Foreground="{StaticResource BgBrush}"
                    Visibility="Collapsed"
                    ToolTip="Runs Install-Module Microsoft.WinGet.Client -Force; Repair-WinGetPackageManager - needs internet access."/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
            <Button Name="BtnCheckInstalled" Content="Scan" BorderBrush="{StaticResource OrangeBrush}" ToolTip="Scan the catalog against what's actually installed on this machine and check the boxes for anything found - ready to hand off to Uninstall Selected."/>
            <Button Name="BtnInstallSelected" Content="Install Selected" BorderBrush="{StaticResource GreenBrush}"/>
            <Button Name="BtnUninstallSelected" Content="Uninstall Selected" BorderBrush="{StaticResource RedBrush}"/>
            <Button Name="BtnUpgradeAll" Content="Upgrade All Installed"/>
            <Button Name="BtnStopInstall" Content="Stop" Visibility="Collapsed"/>
            <TextBlock Name="InstallStatusText" Text="Idle" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="300"/>
            </Grid.ColumnDefinitions>
            <Border Grid.Column="0" Style="{StaticResource Panel}">
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel Name="InstallAppsPanel"/>
              </ScrollViewer>
            </Border>
            <Border Grid.Column="1" Margin="10,0,0,0" Style="{StaticResource Panel}" Padding="0">
              <TextBox Name="InstallLogBox" Style="{StaticResource LogBox}" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>

      <TabItem Header="Fixes">
        <Grid>
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="400"/>
            <ColumnDefinition Width="10"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Style="{StaticResource Panel}">
            <ScrollViewer VerticalScrollBarVisibility="Auto">
              <StackPanel>
                <TextBlock Style="{StaticResource Header}" Text="Fixes"/>
                <Button Name="BtnFixSystemRepair" Content="System File Repair - Run" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Runs sfc /scannow then DISM RestoreHealth. Can take 10-20+ minutes."/>
                <Button Name="BtnFixNetworkReset" Content="Network - Reset" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Resets Winsock and TCP/IP, flushes DNS. Requires a reboot after."/>
                <Button Name="BtnFixWindowsUpdate" Content="Windows Update - Reset" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Clears the update cache and restarts related services - standard fix for a stuck Windows Update."/>
                <Button Name="BtnFixWinGet" Content="WinGet - Reinstall" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Re-registers the App Installer package - fixes a missing/broken winget."/>

                <TextBlock Style="{StaticResource Header}" Text="Quick Panels" Margin="0,14,0,0"/>
                <Button Name="BtnPanelCompMgmt" Content="Computer Management" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelControlPanel" Content="Control Panel" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelMouse" Content="Mouse Properties" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelNetwork" Content="Network Connections" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelPower" Content="Power Panel" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelPrinters" Content="Printer Panel" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelProgramsFeatures" Content="Programs and Features" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelRegion" Content="Region" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelSecurityMaintenance" Content="Security and Maintenance" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelSound" Content="Sound Settings" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelSystemProps" Content="System Properties" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelTimeDate" Content="Time and Date" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelFirewall" Content="Windows Defender Firewall" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>
                <Button Name="BtnPanelSystemRestore" Content="Windows Restore" HorizontalAlignment="Stretch" Margin="0,0,0,4"/>

                <TextBlock Style="{StaticResource Header}" Text="Customize Preferences" Margin="0,14,0,0"/>
                <TextBlock Style="{StaticResource Hint}" Text="One-way: applies the &quot;on&quot; value only, no undo. Explorer restarts once at the end if needed."
                           TextWrapping="Wrap" Margin="0,0,0,6" Opacity="0.7"/>
                <StackPanel Name="TweaksPanel"/>
                <Button Name="BtnApplyTweaks" Content="Apply Selected Tweaks" HorizontalAlignment="Stretch" Margin="0,6,0,4"
                        BorderBrush="{StaticResource GreenBrush}"/>

                <TextBlock Style="{StaticResource Header}" Text="DNS" Margin="0,14,0,4"/>
                <DockPanel Margin="0,0,0,6">
                  <TextBlock Text="Set DNS to:" VerticalAlignment="Center" Margin="0,0,8,0"/>
                  <ComboBox Name="DnsPresetCombo" Width="240" SelectedIndex="0">
                    <ComboBoxItem Content="Default"/>
                    <ComboBoxItem Content="DHCP"/>
                    <ComboBoxItem Content="Google"/>
                    <ComboBoxItem Content="Cloudflare"/>
                    <ComboBoxItem Content="Cloudflare_Malware"/>
                    <ComboBoxItem Content="Cloudflare_Malware_Adult"/>
                    <ComboBoxItem Content="Open_DNS"/>
                    <ComboBoxItem Content="Quad9"/>
                    <ComboBoxItem Content="AdGuard_Ads_Trackers"/>
                    <ComboBoxItem Content="AdGuard_Ads_Trackers_Malware_Adult"/>
                  </ComboBox>
                </DockPanel>
                <Button Name="BtnApplyDns" Content="Apply DNS" HorizontalAlignment="Stretch" Margin="0,0,0,4"
                        ToolTip="Applies to all network adapters currently Up. Default makes no change."/>
              </StackPanel>
            </ScrollViewer>
          </Border>
          <Grid Grid.Column="2">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>
            <StackPanel Grid.Row="0" Orientation="Horizontal">
              <TextBlock Style="{StaticResource Header}" Text="Status" Margin="0,0,10,0"/>
              <TextBlock Name="FixesStatusText" Text="Idle" VerticalAlignment="Bottom"/>
              <Button Name="BtnStopFixes" Content="Stop" Margin="12,0,0,0" BorderBrush="{StaticResource RedBrush}" Visibility="Collapsed"/>
            </StackPanel>
            <TextBlock Grid.Row="1" Style="{StaticResource Header}" Text="Log" Margin="0,10,0,4"/>
            <TextBox Grid.Row="2" Name="FixesLogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap"
                     VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
          </Grid>
        </Grid>
      </TabItem>
    </TabControl>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xamlDoc
try {
    $window = [Windows.Markup.XamlReader]::Load($reader)
} catch {
    [System.Windows.Forms.MessageBox]::Show("Failed to load the GUI layout:`r`n$($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}

# --- Tab 1 controls ---
$optDryRun = $window.FindName('OptDryRun')
$optCreateRestorePoint = $window.FindName('OptCreateRestorePoint')
$optSkipDebloat = $window.FindName('OptSkipDebloat')
$optDell = $window.FindName('OptDell')
$optLenovo = $window.FindName('OptLenovo')
$optSkipOfficeRemoval = $window.FindName('OptSkipOfficeRemoval')
$optSkipOfficeInstall = $window.FindName('OptSkipOfficeInstall')
$optTweakTelemetry = $window.FindName('OptTweakTelemetry')
$optTweakHibernation = $window.FindName('OptTweakHibernation')
$optTweakPreventSleep = $window.FindName('OptTweakPreventSleep')
$optTweakDisableSAC = $window.FindName('OptTweakDisableSAC')
$optTweakDisableSAC.Add_Checked({
    $result = [System.Windows.MessageBox]::Show(
        "Smart App Control blocks unsigned/low-reputation installers with no user override, so this lets more of the Install Apps catalog install cleanly.`r`n`r`nWARNING: this is one-way on a real machine - once turned off, Smart App Control cannot be turned back on without reinstalling Windows.`r`n`r`nEnable this tweak?",
        'Confirm: Disable Smart App Control', 'YesNo', 'Warning')
    if ($result -eq 'No') { $optTweakDisableSAC.IsChecked = $false }
})
$optChannel = $window.FindName('OptChannel')
$btnScan = $window.FindName('BtnScan')
$btnStart = $window.FindName('BtnStart')
$btnStop = $window.FindName('BtnStop')
$btnDownloadLog = $window.FindName('BtnDownloadLog')
$btnReboot = $window.FindName('BtnReboot')
$statusDot = $window.FindName('StatusDot')
$stateText = $window.FindName('StateText')
$phaseText = $window.FindName('PhaseText')
$elapsedText = $window.FindName('ElapsedText')
$cpuText = $window.FindName('CpuText')
$bannerBorder = $window.FindName('BannerBorder')
$bannerText = $window.FindName('BannerText')
$logBox = $window.FindName('LogBox')
$mainTabs = $window.FindName('MainTabs')
$rootGrid = $window.FindName('RootGrid')
$navDebloat = $window.FindName('NavDebloat')
$navInstall = $window.FindName('NavInstall')
$navFixes = $window.FindName('NavFixes')
$searchHint = $window.FindName('SearchHint')
$btnOpenLogs = $window.FindName('BtnOpenLogs')
$btnWinMin = $window.FindName('BtnWinMin')
$btnWinMax = $window.FindName('BtnWinMax')
$btnWinClose = $window.FindName('BtnWinClose')
$iconMax = $window.FindName('IconMax')
$iconRestore = $window.FindName('IconRestore')

# --- Tab 2 controls ---
$searchBox = $window.FindName('SearchBox')
$catAllBtn = $window.FindName('CatAll')
$catBrowsersBtn = $window.FindName('CatBrowsers')
$catMsToolsBtn = $window.FindName('CatMsTools')
$catUtilitiesBtn = $window.FindName('CatUtilities')
$btnSelectAll = $window.FindName('BtnSelectAll')
$btnClearSelection = $window.FindName('BtnClearSelection')
$btnCheckInstalled = $window.FindName('BtnCheckInstalled')
$selectedCountText = $window.FindName('SelectedCountText')
$btnInstallSelected = $window.FindName('BtnInstallSelected')
$btnUninstallSelected = $window.FindName('BtnUninstallSelected')
$btnUpgradeAll = $window.FindName('BtnUpgradeAll')
$btnStopInstall = $window.FindName('BtnStopInstall')
$installStatusText = $window.FindName('InstallStatusText')
$installAppsPanel = $window.FindName('InstallAppsPanel')
$installLogBox = $window.FindName('InstallLogBox')
$wingetStatusDot = $window.FindName('WinGetStatusDot')
$wingetStatusText = $window.FindName('WinGetStatusText')
$btnInstallWinGet = $window.FindName('BtnInstallWinGet')

# --- Tab 3 controls ---
$btnFixSystemRepair = $window.FindName('BtnFixSystemRepair')
$btnFixNetworkReset = $window.FindName('BtnFixNetworkReset')
$btnFixWindowsUpdate = $window.FindName('BtnFixWindowsUpdate')
$btnFixWinGet = $window.FindName('BtnFixWinGet')
$fixesStatusText = $window.FindName('FixesStatusText')
$fixesLogBox = $window.FindName('FixesLogBox')
$btnStopFixes = $window.FindName('BtnStopFixes')

# Quick Panels - direct shortcuts to built-in Windows applets, no job/log involved.
$quickPanels = @(
    @{ Btn = $window.FindName('BtnPanelCompMgmt');           File = 'compmgmt.msc'; Args = $null }
    @{ Btn = $window.FindName('BtnPanelControlPanel');       File = 'control.exe';  Args = $null }
    @{ Btn = $window.FindName('BtnPanelMouse');              File = 'control.exe';  Args = 'main.cpl' }
    @{ Btn = $window.FindName('BtnPanelNetwork');            File = 'control.exe';  Args = 'ncpa.cpl' }
    @{ Btn = $window.FindName('BtnPanelPower');              File = 'control.exe';  Args = 'powercfg.cpl' }
    @{ Btn = $window.FindName('BtnPanelPrinters');           File = 'control.exe';  Args = 'printers' }
    @{ Btn = $window.FindName('BtnPanelProgramsFeatures');   File = 'control.exe';  Args = 'appwiz.cpl' }
    @{ Btn = $window.FindName('BtnPanelRegion');             File = 'control.exe';  Args = 'intl.cpl' }
    @{ Btn = $window.FindName('BtnPanelSecurityMaintenance');File = 'control.exe';  Args = '/name Microsoft.ActionCenter' }
    @{ Btn = $window.FindName('BtnPanelSound');              File = 'control.exe';  Args = 'mmsys.cpl' }
    @{ Btn = $window.FindName('BtnPanelSystemProps');        File = 'control.exe';  Args = 'sysdm.cpl' }
    @{ Btn = $window.FindName('BtnPanelTimeDate');           File = 'control.exe';  Args = 'timedate.cpl' }
    @{ Btn = $window.FindName('BtnPanelFirewall');           File = 'control.exe';  Args = 'firewall.cpl' }
    @{ Btn = $window.FindName('BtnPanelSystemRestore');      File = 'rstrui.exe';   Args = $null }
)
foreach ($p in $quickPanels) {
    $panelFile = $p.File
    $panelArgs = $p.Args
    $p.Btn.Add_Click({
        try {
            if ($panelArgs) { Start-Process -FilePath $panelFile -ArgumentList $panelArgs }
            else { Start-Process -FilePath $panelFile }
        } catch {
            [System.Windows.MessageBox]::Show("Could not open this panel: $($_.Exception.Message)", 'Gr3y Tools', 'OK', 'Error') | Out-Null
        }
    }.GetNewClosure())
}

# Customize Preferences - same Key strings as Deploy-DellOfficeSetup.ps1's $tweakDefs.
$tweaksPanel = $window.FindName('TweaksPanel')
$btnApplyTweaks = $window.FindName('BtnApplyTweaks')
$dnsPresetCombo = $window.FindName('DnsPresetCombo')
$btnApplyDns = $window.FindName('BtnApplyDns')

$tweakList = @(
    @{ Key = 'DarkTheme'; Label = 'Dark Theme for Windows'; Tip = 'Dark Mode for the system and applications.' }
    @{ Key = 'ShowFileExt'; Label = 'File Explorer File Extensions'; Tip = 'Shows file extensions in Explorer (.exe, .png, etc.)' }
    @{ Key = 'ShowHiddenFiles'; Label = 'File Explorer Hidden Files'; Tip = 'Reveals hidden files in Explorer.' }
    @{ Key = 'LongPaths'; Label = 'Enable Long Paths'; Tip = 'Allows file paths longer than 260 characters in Explorer.' }
    @{ Key = 'GameMode'; Label = 'Game Mode'; Tip = 'Prioritizes gaming performance by allocating system resources to games.' }
    @{ Key = 'MouseAcceleration'; Label = 'Mouse Acceleration'; Tip = 'Cursor movement is affected by the speed of physical mouse movements.' }
    @{ Key = 'NumLockOnStartup'; Label = 'Num Lock on Startup'; Tip = 'Turns Num Lock on when the computer starts.' }
    @{ Key = 'WindowSnapping'; Label = 'Window Snapping'; Tip = 'Enables the window snapping feature when dragging windows.' }
    @{ Key = 'ScrollbarsAlwaysVisible'; Label = 'Scrollbars Always Visible'; Tip = 'Scrollbars are always visible instead of auto-hiding.' }
    @{ Key = 'StickyKeys'; Label = 'Sticky Keys'; Tip = 'Enables Sticky Keys (activates by pressing Shift 5 times).' }
    @{ Key = 'TaskbarCenteredIcons'; Label = 'Taskbar Centered Icons'; Tip = 'Centers Taskbar icons instead of left-aligning them.' }
    @{ Key = 'TaskbarSearchIcon'; Label = 'Taskbar Search Icon'; Tip = 'Shows the Search button on the Taskbar.' }
    @{ Key = 'TaskbarTaskViewIcon'; Label = 'Taskbar Task View Icon'; Tip = 'Shows the Task View button on the Taskbar.' }
    @{ Key = 'StartMenuBingSearch'; Label = 'Start Menu Bing Search'; Tip = 'Enables Bing web search results in Windows Search.' }
    @{ Key = 'StartMenuRecommendations'; Label = 'Start Menu Recommendations'; Tip = 'Enables the Recommended section in the Start Menu. WARNING: also affects Windows Spotlight on the Lock Screen.' }
    @{ Key = 'SettingsHomePage'; Label = 'Settings Home Page'; Tip = 'Shows the Home page in the Windows Settings app.' }
    @{ Key = 'BatteryPercentage'; Label = 'System Tray Battery Percentage'; Tip = 'Shows numeric battery percentage next to the battery icon in the system tray.' }
    @{ Key = 'BSoDVerbose'; Label = 'BSoD Verbose Mode'; Tip = 'Gives more information when you blue screen.' }
    @{ Key = 'DisableLockScreen'; Label = 'Lock Screen - Disable'; Tip = 'Skips the lock screen entirely, goes directly to sign-in on boot and wake.' }
    @{ Key = 'LogonAcrylicBlur'; Label = 'Logon Screen Acrylic Blur'; Tip = 'Enables the acrylic blur effect on the login screen background.' }
    @{ Key = 'LogonVerbose'; Label = 'Logon Verbose Mode'; Tip = 'Shows detailed messages during startup/shutdown.' }
    @{ Key = 'NewOutlook'; Label = 'Microsoft Outlook New Version'; Tip = 'Forces the new Outlook application to be used.' }
    @{ Key = 'S0SleepNetwork'; Label = 'S0 Sleep Network Connectivity'; Tip = 'Keeps network connectivity during S0 (modern standby) low-power idle.' }
    @{ Key = 'S3Sleep'; Label = 'S3 Sleep'; Tip = 'Switches from Modern Standby to S3 Sleep (cuts power to the CPU, keeps RAM refreshed).' }
)

$script:tweakCheckBoxes = @{}
foreach ($t in $tweakList) {
    $row = New-Object System.Windows.Controls.StackPanel
    $row.Orientation = 'Horizontal'
    $row.Margin = '0,3,0,3'

    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Style = $window.Resources['ToggleSwitchStyle']
    $cb.VerticalAlignment = 'Center'
    $row.Children.Add($cb) | Out-Null

    $label = New-Object System.Windows.Controls.TextBlock
    $label.Text = $t.Label
    $label.VerticalAlignment = 'Center'
    $label.Margin = '8,0,0,0'
    $row.Children.Add($label) | Out-Null

    $hint = New-Object System.Windows.Controls.TextBlock
    $hint.Style = $window.Resources['Hint']
    $hint.ToolTip = $t.Tip
    $row.Children.Add($hint) | Out-Null

    $tweaksPanel.Children.Add($row) | Out-Null
    $script:tweakCheckBoxes[$t.Key] = $cb
}

$btnApplyTweaks.Add_Click({
    $keys = $script:tweakCheckBoxes.Keys | Where-Object { $script:tweakCheckBoxes[$_].IsChecked }
    if (-not $keys) {
        [System.Windows.MessageBox]::Show('No tweaks selected.', 'Gr3y Tools', 'OK', 'Information') | Out-Null
        return
    }
    Start-FixJob -FixArgs @('-CustomizeTweaks', ($keys -join ',')) -Label 'Apply Tweaks'
})

$btnApplyDns.Add_Click({
    $preset = $dnsPresetCombo.SelectedItem.Content
    if ($preset -eq 'Default') {
        [System.Windows.MessageBox]::Show('DNS preset is Default - nothing to apply.', 'Gr3y Tools', 'OK', 'Information') | Out-Null
        return
    }
    $result = [System.Windows.MessageBox]::Show("Set DNS to '$preset' on every active network adapter? This can disrupt connectivity if the resolver is unreachable.", 'Confirm DNS Change', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-DnsPreset', $preset) -Label "Set DNS to $preset" }
})

$greenBrush = $window.Resources['GreenBrush']
$redBrush = $window.Resources['RedBrush']
$accentBrush = $window.Resources['AccentBrush']
$headerBrush = $window.Resources['HeaderBrush']

# winget presence check - Install Apps is entirely winget-backed, and a machine
# without it (a minimal/no-Store image like Windows Sandbox, or a broken App
# Installer) would otherwise only find out via a raw Start-Process exception the
# moment a button is clicked. Check once at startup and disable the winget-backed
# buttons up front instead, with an explanation instead of a stack trace.
$script:wingetAvailable = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
if ($script:wingetAvailable) {
    $wingetStatusDot.Fill = $greenBrush
    $wingetStatusText.Text = 'winget ready'
    $wingetStatusText.Foreground = $greenBrush
} else {
    $wingetStatusDot.Fill = $redBrush
    $wingetStatusText.Text = 'winget not found'
    $wingetStatusText.Foreground = $redBrush
    $wingetTooltip = "winget (App Installer) was not found on this machine, so Install Apps is disabled. " +
        "Click Install winget, or install it from the Microsoft Store yourself."
    $wingetStatusText.ToolTip = $wingetTooltip
    foreach ($b in @($btnInstallSelected, $btnUninstallSelected, $btnUpgradeAll, $btnCheckInstalled)) {
        $b.IsEnabled = $false
        $b.ToolTip = $wingetTooltip
    }
    $btnInstallWinGet.Visibility = 'Visible'
}

function Set-ActiveTab {
    param([int]$Index)
    $mainTabs.SelectedIndex = $Index
    $navDebloat.Tag = if ($Index -eq 0) { 'selected' } else { '' }
    $navInstall.Tag = if ($Index -eq 1) { 'selected' } else { '' }
    $navFixes.Tag = if ($Index -eq 2) { 'selected' } else { '' }
}
$navDebloat.Add_Click({ Set-ActiveTab -Index 0 })
$navInstall.Add_Click({ Set-ActiveTab -Index 1 })
$navFixes.Add_Click({ Set-ActiveTab -Index 2 })

$btnWinMin.Add_Click({ $window.WindowState = 'Minimized' })
$btnWinMax.Add_Click({
    if ($window.WindowState -eq 'Maximized') { $window.WindowState = 'Normal' } else { $window.WindowState = 'Maximized' }
})
$btnWinClose.Add_Click({ $window.Close() })
$window.Add_StateChanged({
    # WindowChrome lets a maximized window overflow the screen by its resize border.
    $isMax = $window.WindowState -eq 'Maximized'
    $rootGrid.Margin = if ($isMax) { '7' } else { '0' }
    $iconMax.Visibility = if ($isMax) { 'Collapsed' } else { 'Visible' }
    $iconRestore.Visibility = if ($isMax) { 'Visible' } else { 'Collapsed' }
})
$btnOpenLogs.Add_Click({ Invoke-Item -Path $workDir })

# ============================================================================
# Populate Install Apps tab from apps-catalog.json
# ============================================================================

$script:appEntries = New-Object System.Collections.Generic.List[object]
$script:categoryBlocks = New-Object System.Collections.Generic.List[object]

$categories = $catalog.apps | Group-Object category | Sort-Object Name
foreach ($cat in $categories) {
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = $cat.Name
    $header.FontFamily = 'Consolas'
    $header.FontSize = 16
    $header.Foreground = $headerBrush
    $header.Margin = '0,8,0,4'
    $installAppsPanel.Children.Add($header) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($app in ($cat.Group | Sort-Object name)) {
        $row = New-Object System.Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $row.Width = 230
        $row.Margin = '2,1'

        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.name
        $cb.Tag = $app.wingetId
        $cb.MaxWidth = 208
        $row.Children.Add($cb) | Out-Null

        if ($app.url) {
            $help = New-Object System.Windows.Controls.TextBlock
            $help.Text = '(?)'
            $help.Foreground = $headerBrush
            $help.FontSize = 11
            $help.Margin = '3,0,0,0'
            $help.VerticalAlignment = 'Center'
            $help.Cursor = 'Hand'
            $help.TextDecorations = [System.Windows.TextDecorations]::Underline
            $help.ToolTip = "Open $($app.url)"
            $helpUrl = $app.url
            $help.Add_MouseLeftButtonUp({ Start-Process $helpUrl }.GetNewClosure())
            $row.Children.Add($help) | Out-Null
        }

        $wrap.Children.Add($row) | Out-Null
        $entry = [PSCustomObject]@{ CheckBox = $cb; Row = $row; Name = $app.name; Category = $cat.Name; WingetId = $app.wingetId }
        $script:appEntries.Add($entry)
        # Checked/Unchecked (not Click) since they fire off IsChecked itself changing,
        # regardless of interaction method - Click alone was observed to not reliably
        # fire for every path that can toggle a CheckBox.
        $cb.Add_Checked({ Update-SelectedCount })
        $cb.Add_Unchecked({ Update-SelectedCount })
    }
    $installAppsPanel.Children.Add($wrap) | Out-Null
    $script:categoryBlocks.Add([PSCustomObject]@{ Header = $header; Wrap = $wrap; Category = $cat.Name })
}

function Update-SelectedCount {
    $count = ($script:appEntries | Where-Object { $_.CheckBox.IsChecked }).Count
    $selectedCountText.Text = "Selected: $count"
}

$script:activeCategory = 'All'

function Update-AppVisibility {
    $searchText = $searchBox.Text.Trim().ToLower()
    foreach ($block in $script:categoryBlocks) {
        $categoryMatches = ($script:activeCategory -eq 'All') -or ($block.Category -eq $script:activeCategory)
        $anyVisible = $false
        foreach ($entry in ($script:appEntries | Where-Object { $_.Category -eq $block.Category })) {
            $nameMatches = (-not $searchText) -or ($entry.Name.ToLower().Contains($searchText))
            $visible = $categoryMatches -and $nameMatches
            $entry.Row.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
            if ($visible) { $anyVisible = $true }
        }
        $blockVisibility = if ($anyVisible) { 'Visible' } else { 'Collapsed' }
        $block.Header.Visibility = $blockVisibility
        $block.Wrap.Visibility = $blockVisibility
    }
}

$searchBox.Add_TextChanged({
    $searchHint.Visibility = if ($searchBox.Text) { 'Collapsed' } else { 'Visible' }
    if ($searchBox.Text -and $mainTabs.SelectedIndex -ne 1) { Set-ActiveTab -Index 1 }
    Update-AppVisibility
})
$catAllBtn.Add_Click({ $script:activeCategory = 'All'; Update-AppVisibility })
$catBrowsersBtn.Add_Click({ $script:activeCategory = 'Browsers'; Update-AppVisibility })
$catMsToolsBtn.Add_Click({ $script:activeCategory = 'Microsoft Tools'; Update-AppVisibility })
$catUtilitiesBtn.Add_Click({ $script:activeCategory = 'Utilities'; Update-AppVisibility })

$btnSelectAll.Add_Click({
    foreach ($entry in $script:appEntries) {
        if ($entry.Row.Visibility -eq 'Visible') { $entry.CheckBox.IsChecked = $true }
    }
    Update-SelectedCount
})
$btnClearSelection.Add_Click({
    foreach ($entry in $script:appEntries) { $entry.CheckBox.IsChecked = $false }
    Update-SelectedCount
})

# ============================================================================
# Tab 1: Debloat + Office job control
# ============================================================================

$script:deployProc = $null
$script:deployLogFile = $null
$script:deployErrFile = $null
$script:deployLogOffset = 0
$script:deployStartTime = $null
$script:deployIsDryRun = $false
$script:deployHasFinishedBannerShown = $true

$btnScan.Add_Click({
    $btnScan.IsEnabled = $false
    $stateText.Text = 'Scanning...'
    $bannerBorder.Visibility = 'Collapsed'
    $logBox.Text = ''
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)
    try {
        $report = Get-BloatScanReport
        $logBox.Text = $report
    } catch {
        $logBox.Text = "Scan failed: $($_.Exception.Message)"
    } finally {
        $stateText.Text = 'Idle'
        $btnScan.IsEnabled = $true
    }
})

$btnStart.Add_Click({
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deployScript, '-NoReboot')
    if ($optDryRun.IsChecked) { $argList += '-DryRun' }
    if ($optCreateRestorePoint.IsChecked) { $argList += '-CreateRestorePoint' }
    if ($optSkipDebloat.IsChecked) { $argList += '-SkipDebloat' }
    if ($optDell.IsChecked) { $argList += '-Dell' }
    if ($optLenovo.IsChecked) { $argList += '-Lenovo' }
    if ($optSkipOfficeRemoval.IsChecked) { $argList += '-SkipOfficeRemoval' }
    if ($optSkipOfficeInstall.IsChecked) { $argList += '-SkipOfficeInstall' }
    if ($optTweakTelemetry.IsChecked) { $argList += '-TweakReduceTelemetry' }
    if ($optTweakHibernation.IsChecked) { $argList += '-TweakDisableHibernation' }
    if ($optTweakPreventSleep.IsChecked) { $argList += '-TweakPreventSleep' }
    if ($optTweakDisableSAC.IsChecked) { $argList += '-TweakDisableSmartAppControl' }
    $channel = $optChannel.SelectedItem.Content
    $argList += @('-OfficeChannel', $channel)

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:deployLogFile = Join-Path $workDir "gui_run_$stamp.out.log"
    $script:deployErrFile = Join-Path $workDir "gui_run_$stamp.err.log"
    $script:deployLogOffset = 0
    $script:deployIsDryRun = [bool]$optDryRun.IsChecked
    $script:deployHasFinishedBannerShown = $false

    $logBox.Text = ''
    $bannerBorder.Visibility = 'Collapsed'
    $btnReboot.Visibility = 'Collapsed'
    $btnDownloadLog.Visibility = 'Collapsed'

    $script:deployProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:deployLogFile -RedirectStandardError $script:deployErrFile `
        -WindowStyle Hidden -PassThru
    $script:deployStartTime = Get-Date
})

$btnStop.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Stop the running job? Anything mid-uninstall/install may be left partially applied.', 'Confirm Stop', 'YesNo', 'Warning')
    if ($result -eq 'Yes' -and $script:deployProc -and -not $script:deployProc.HasExited) {
        $ids = Get-DescendantProcessIds -RootId $script:deployProc.Id
        foreach ($id in $ids) { try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {} }
    }
})

$btnDownloadLog.Add_Click({
    if (-not $script:deployLogFile -or -not (Test-Path $script:deployLogFile)) { return }
    $dialog = New-Object Microsoft.Win32.SaveFileDialog
    $dialog.FileName = "gr3ytools-debloat_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(Get-MachineTag).log"
    $dialog.InitialDirectory = [Environment]::GetFolderPath('Desktop')
    $dialog.Filter = 'Log files (*.log)|*.log|All files (*.*)|*.*'
    if ($dialog.ShowDialog()) {
        Copy-Item -Path $script:deployLogFile -Destination $dialog.FileName -Force
    }
})

$btnReboot.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Reboot this computer now?', 'Confirm Reboot', 'YesNo', 'Warning')
    if ($result -eq 'Yes') {
        $bannerText.Text = 'Rebooting now - this window will close shortly.'
        Start-Sleep -Milliseconds 500
        Restart-Computer -Force
    }
})

# ============================================================================
# Tab 3: One-click Fixes - each runs Deploy-DellOfficeSetup.ps1 standalone (all
# three main phases skipped) with just its own -Fix... flag, reusing the same
# child-process + redirected-log pattern as the Start button.
# ============================================================================

$script:fixProc = $null
$script:fixLogFile = $null
$script:fixErrFile = $null
$script:fixLogOffset = 0
$script:fixStartTime = $null

$fixButtons = @($btnFixSystemRepair, $btnFixNetworkReset, $btnFixWindowsUpdate, $btnFixWinGet, $btnApplyTweaks, $btnApplyDns)

function Start-FixJob {
    param([string[]]$FixArgs, [string]$Label)
    if ($script:fixProc -and -not $script:fixProc.HasExited) { return }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deployScript,
                 '-NoReboot', '-SkipDebloat', '-SkipOfficeRemoval', '-SkipOfficeInstall') + $FixArgs

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:fixLogFile = Join-Path $workDir "gui_fix_$stamp.out.log"
    $script:fixErrFile = Join-Path $workDir "gui_fix_$stamp.err.log"
    $script:fixLogOffset = 0
    $fixesLogBox.Text = ''
    $fixesStatusText.Text = "Running: $Label..."
    foreach ($b in $fixButtons) { $b.IsEnabled = $false }
    $btnStopFixes.Visibility = 'Visible'

    $script:fixProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:fixLogFile -RedirectStandardError $script:fixErrFile `
        -WindowStyle Hidden -PassThru
    $script:fixStartTime = Get-Date
}

$btnFixSystemRepair.Add_Click({ Start-FixJob -FixArgs @('-FixSystemRepair') -Label 'System File Repair' })

$btnFixNetworkReset.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This resets Winsock and TCP/IP and requires a reboot afterward to fully take effect. Continue?', 'Confirm Network Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-FixNetworkReset') -Label 'Network Reset' }
})

$btnFixWindowsUpdate.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This stops Windows Update-related services and clears their cache. Continue?', 'Confirm Windows Update Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixArgs @('-FixWindowsUpdateReset') -Label 'Windows Update Reset' }
})

$btnFixWinGet.Add_Click({ Start-FixJob -FixArgs @('-FixWinGetReinstall') -Label 'Reinstall winget' })

$btnStopFixes.Add_Click({
    $result = [System.Windows.MessageBox]::Show('Stop the running fix? Interrupting sfc/DISM mid-scan is safe (just leaves the check unverified) - a network/Windows Update reset should finish quickly on its own instead.', 'Confirm Stop', 'YesNo', 'Warning')
    if ($result -eq 'Yes' -and $script:fixProc -and -not $script:fixProc.HasExited) {
        $ids = Get-DescendantProcessIds -RootId $script:fixProc.Id
        foreach ($id in $ids) { try { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } catch {} }
    }
})

# ============================================================================
# Tab 2: Install/Uninstall/Upgrade queue control
# ============================================================================

$script:installQueue = New-Object System.Collections.Generic.Queue[object]
$script:installProc = $null
$script:installLogFile = $null
$script:installMode = $null
$script:installTotal = 0
$script:installDone = 0
$script:installFoundCount = 0
$script:currentQueueEntry = $null

function Start-NextInQueue {
    if ($script:installQueue.Count -eq 0) {
        $installStatusText.Text = "Done ($($script:installDone)/$($script:installTotal))"
        $btnInstallSelected.IsEnabled = $true
        $btnUninstallSelected.IsEnabled = $true
        $btnUpgradeAll.IsEnabled = $true
        $btnCheckInstalled.IsEnabled = $true
        $btnStopInstall.Visibility = 'Collapsed'
        $script:installProc = $null
        $script:currentQueueEntry = $null
        return
    }
    $entry = $script:installQueue.Dequeue()
    $script:currentQueueEntry = $entry
    $actionWord = switch ($script:installMode) {
        'install' { 'Installing' }
        'uninstall' { 'Uninstalling' }
        'check' { 'Checking' }
    }
    $installStatusText.Text = "$actionWord $($entry.Name)... ($($script:installDone + 1)/$($script:installTotal))"
    $installLogBox.AppendText("=== $actionWord`: $($entry.Name) ($($entry.WingetId)) ===`r`n")
    $installLogBox.ScrollToEnd()

    $script:installLogFile = Join-Path $workDir "winget_$($script:installMode)_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').log"
    $wingetArgs = switch ($script:installMode) {
        'install' { @('install', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements') }
        'uninstall' { @('uninstall', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent') }
        'check' { @('list', '--id', $entry.WingetId, '-e', '--source', 'winget', '--accept-source-agreements') }
    }

    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList $wingetArgs `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" `
        -WindowStyle Hidden -PassThru
    $script:installDone++
}

function Start-AppQueue {
    param([string]$Mode)
    # 'check' scans the whole catalog regardless of what's ticked - detecting install
    # status is meant to answer "what's already here", not act on a selection.
    # .ToArray(), not @(...) - wrapping a List[object] directly in @() throws
    # "Argument types do not match" (a real PowerShell quirk, reproduced on both
    # 5.1 and 7); piping through Where-Object below sidesteps it, but the 'check'
    # branch has nothing to pipe through, so it needs the explicit .ToArray().
    $selected = if ($Mode -eq 'check') { $script:appEntries.ToArray() } else { @($script:appEntries | Where-Object { $_.CheckBox.IsChecked }) }
    if ($selected.Count -eq 0) { return }
    $script:installQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($entry in $selected) { $script:installQueue.Enqueue($entry) }
    $script:installMode = $Mode
    $script:installTotal = $selected.Count
    $script:installDone = 0
    $script:installFoundCount = 0
    $installLogBox.Text = ''
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnCheckInstalled.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
    Start-NextInQueue
}

$btnInstallSelected.Add_Click({ Start-AppQueue -Mode 'install' })
$btnUninstallSelected.Add_Click({ Start-AppQueue -Mode 'uninstall' })
$btnCheckInstalled.Add_Click({ Start-AppQueue -Mode 'check' })

$btnUpgradeAll.Add_Click({
    # Distinct mode (not reusing 'install'/'check') so the per-entry completion
    # handling below never mistakes this one-off run for a queued check result.
    $script:installMode = 'upgrade'
    $script:currentQueueEntry = $null
    $script:installLogFile = Join-Path $workDir "winget_upgrade_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $installLogBox.Text = "=== Upgrading all installed apps ===`r`n"
    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements') `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" -WindowStyle Hidden -PassThru
    $installStatusText.Text = 'Upgrading all installed apps...'
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnCheckInstalled.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
})

$btnStopInstall.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) {
        try { Stop-Process -Id $script:installProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:installQueue.Clear()
    $script:currentQueueEntry = $null
    $installStatusText.Text = 'Stopped.'
    $btnInstallSelected.IsEnabled = $true
    $btnUninstallSelected.IsEnabled = $true
    $btnUpgradeAll.IsEnabled = $true
    $btnCheckInstalled.IsEnabled = $true
    $btnStopInstall.Visibility = 'Collapsed'
})

$script:wingetInstallProc = $null
$script:wingetInstallLogFile = $null

$btnInstallWinGet.Add_Click({
    $btnInstallWinGet.IsEnabled = $false
    $btnInstallWinGet.Content = 'Installing winget...'
    $wingetStatusDot.Fill = $accentBrush
    $wingetStatusText.Text = 'Installing winget (needs internet)...'
    $wingetStatusText.Foreground = $accentBrush

    $script:wingetInstallLogFile = Join-Path $workDir "wingetinstall_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $installCmd = 'Install-PackageProvider -Name NuGet -Force | Out-Null; ' +
        'Install-Module -Name Microsoft.WinGet.Client -Force -Repository PSGallery | Out-Null; ' +
        'Repair-WinGetPackageManager'
    $script:wingetInstallProc = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $installCmd) `
        -RedirectStandardOutput $script:wingetInstallLogFile -RedirectStandardError "$($script:wingetInstallLogFile).err" `
        -WindowStyle Hidden -PassThru
})

# ============================================================================
# Poll timer - drives both tabs
# ============================================================================

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(1200)
$timer.Add_Tick({
    # --- Tab 1 ---
    if ($script:deployProc) {
        $logResult = Get-LogTail -Path $script:deployLogFile -Offset $script:deployLogOffset
        if ($logResult.text) {
            $logBox.AppendText($logResult.text)
            $logBox.ScrollToEnd()
        }
        $script:deployLogOffset = $logResult.offset

        $running = $false
        try {
            $script:deployProc.Refresh()
            $running = -not $script:deployProc.HasExited
        } catch {}

        $summary = Get-LogSummary -LogPath $script:deployLogFile
        $phaseText.Text = $summary.phase
        if ($script:deployStartTime) {
            $elapsed = [int]((Get-Date) - $script:deployStartTime).TotalSeconds
            $elapsedText.Text = "{0}:{1:D2}" -f [int]($elapsed / 60), ($elapsed % 60)
        }

        if ($running) {
            $cpu = Get-TreeCpuSeconds -RootId $script:deployProc.Id
            $cpuText.Text = "{0:N1}s" -f $cpu
            $stateText.Text = 'Running'
            $statusDot.Fill = $greenBrush
            $btnStart.IsEnabled = $false
            $btnStop.Visibility = 'Visible'
        } else {
            $btnStart.IsEnabled = $true
            $btnStop.Visibility = 'Collapsed'
            $btnDownloadLog.Visibility = 'Visible'
            if (-not $script:deployHasFinishedBannerShown) {
                $script:deployHasFinishedBannerShown = $true
                if ($summary.completed) {
                    $stateText.Text = 'Done'
                    $statusDot.Fill = $accentBrush
                    $bannerText.Text = 'Run finished successfully. Reboot to finish clearing removed services/drivers.'
                    $bannerBorder.Background = '#0f2a17'
                    $bannerBorder.BorderBrush = $greenBrush
                    $bannerBorder.Visibility = 'Visible'
                    if (-not $script:deployIsDryRun) { $btnReboot.Visibility = 'Visible' }
                } else {
                    $stateText.Text = 'Error'
                    $statusDot.Fill = $redBrush
                    $bannerText.Text = 'The job ended before finishing. Check the log above for where it stopped.'
                    $bannerBorder.Background = '#2a0f0f'
                    $bannerBorder.BorderBrush = $redBrush
                    $bannerBorder.Visibility = 'Visible'
                }
            }
        }
    }

    # --- Tab 2 ---
    if ($script:installProc) {
        $running = $false
        try {
            $script:installProc.Refresh()
            $running = -not $script:installProc.HasExited
        } catch {}
        if (-not $running) {
            $tail = $null
            if ($script:installLogFile -and (Test-Path $script:installLogFile)) {
                $tail = Get-Content -Path $script:installLogFile -Raw -ErrorAction SilentlyContinue
                if ($tail) { $installLogBox.AppendText($tail); $installLogBox.AppendText("`r`n"); $installLogBox.ScrollToEnd() }
            }

            # 'check' mode: mark this entry's checkbox installed/not based on winget's
            # own "No installed package found" text, not the process exit code - exit
            # codes from Start-Process have proven unreliable to read back in testing.
            if ($script:installMode -eq 'check' -and $script:currentQueueEntry -and $tail) {
                $cb = $script:currentQueueEntry.CheckBox
                if ($tail -notmatch 'No installed package found') {
                    $cb.Foreground = $greenBrush
                    $cb.Content = "$($script:currentQueueEntry.Name) (installed)"
                    $cb.IsChecked = $true
                    $script:installFoundCount++
                } else {
                    $cb.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
                    $cb.Content = $script:currentQueueEntry.Name
                    $cb.IsChecked = $false
                }
            }

            $script:installProc = $null
            if ($script:installQueue -and $script:installQueue.Count -gt 0) {
                Start-NextInQueue
            } else {
                $installStatusText.Text = if ($script:installMode -eq 'check') {
                    "Done - $($script:installFoundCount) of $($script:installTotal) already installed (selected below - use Uninstall Selected to remove them)"
                } else {
                    'Idle'
                }
                $btnInstallSelected.IsEnabled = $true
                $btnUninstallSelected.IsEnabled = $true
                $btnUpgradeAll.IsEnabled = $true
                $btnCheckInstalled.IsEnabled = $true
                $btnStopInstall.Visibility = 'Collapsed'
            }
        }
    }

    if ($script:wingetInstallProc) {
        $running = $false
        try {
            $script:wingetInstallProc.Refresh()
            $running = -not $script:wingetInstallProc.HasExited
        } catch {}
        if (-not $running) {
            $script:wingetInstallProc = $null
            $script:wingetAvailable = [bool](Get-Command 'winget.exe' -ErrorAction SilentlyContinue)
            if ($script:wingetAvailable) {
                $wingetStatusDot.Fill = $greenBrush
                $wingetStatusText.Text = 'winget ready'
                $wingetStatusText.Foreground = $greenBrush
                $wingetStatusText.ClearValue([System.Windows.Controls.Control]::ToolTipProperty)
                $btnInstallWinGet.Visibility = 'Collapsed'
                foreach ($b in @($btnInstallSelected, $btnUninstallSelected, $btnUpgradeAll, $btnCheckInstalled)) {
                    $b.IsEnabled = $true
                    $b.ClearValue([System.Windows.Controls.Control]::ToolTipProperty)
                }
            } else {
                $wingetStatusDot.Fill = $redBrush
                $wingetStatusText.Text = 'winget install failed - see Install Apps log'
                $wingetStatusText.Foreground = $redBrush
                $btnInstallWinGet.IsEnabled = $true
                $btnInstallWinGet.Content = 'Retry Install winget'
                if ($script:wingetInstallLogFile -and (Test-Path $script:wingetInstallLogFile)) {
                    $tail = Get-Content -Path $script:wingetInstallLogFile -Raw -ErrorAction SilentlyContinue
                    if ($tail) { $installLogBox.AppendText("=== winget install output ===`r`n$tail`r`n"); $installLogBox.ScrollToEnd() }
                }
                $errFile = "$($script:wingetInstallLogFile).err"
                if (Test-Path $errFile) {
                    $errTail = Get-Content -Path $errFile -Raw -ErrorAction SilentlyContinue
                    if ($errTail) { $installLogBox.AppendText("=== winget install errors ===`r`n$errTail`r`n"); $installLogBox.ScrollToEnd() }
                }
            }
        }
    }

    # --- Tab 3 ---
    if ($script:fixProc) {
        $running = $false
        try {
            $script:fixProc.Refresh()
            $running = -not $script:fixProc.HasExited
        } catch {}

        $logResult = Get-LogTail -Path $script:fixLogFile -Offset $script:fixLogOffset
        if ($logResult.text) {
            $fixesLogBox.AppendText($logResult.text)
            $fixesLogBox.ScrollToEnd()
        }
        $script:fixLogOffset = $logResult.offset

        if ($running) {
            $elapsed = [int]((Get-Date) - $script:fixStartTime).TotalSeconds
            $fixesStatusText.Text = "Running... ({0}:{1:D2} elapsed)" -f [int]($elapsed / 60), ($elapsed % 60)
        } else {
            $summary = Get-LogSummary -LogPath $script:fixLogFile
            $fixesStatusText.Text = if ($summary.completed) { 'Done.' } else { 'Ended before finishing - check the log above.' }
            foreach ($b in $fixButtons) { $b.IsEnabled = $true }
            $btnStopFixes.Visibility = 'Collapsed'
            $script:fixProc = $null
        }
    }
})
$timer.Start()

$window.ShowDialog() | Out-Null

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
        Title="Gr3y's Utilities" Height="820" Width="1150"
        WindowStartupLocation="CenterScreen" Background="#0f1420">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#0f1420"/>
    <SolidColorBrush x:Key="PanelBrush" Color="#1a2030"/>
    <SolidColorBrush x:Key="CardBrush" Color="#171d2b"/>
    <SolidColorBrush x:Key="BorderBrush2" Color="#2a3245"/>
    <SolidColorBrush x:Key="TextBrush" Color="#e4e7ec"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#7d8699"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#4fd1c9"/>
    <SolidColorBrush x:Key="ToggleOnBrush" Color="#3b82f6"/>
    <SolidColorBrush x:Key="ToggleOffBrush" Color="#3a4257"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3fb950"/>
    <SolidColorBrush x:Key="RedBrush" Color="#f85149"/>
    <SolidColorBrush x:Key="YellowBrush" Color="#d29922"/>

    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Default CheckBox = dark square with an accent checkmark (used by the
         Install Apps catalog list, matching WinUtil's tweaks-list checkboxes). -->
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal">
              <Border x:Name="Box" Width="16" Height="16" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1.5"
                      Background="{StaticResource BgBrush}" CornerRadius="3" VerticalAlignment="Center">
                <Path x:Name="CheckMark" Data="M2,7 L6,11 L14,3" Stroke="{StaticResource AccentBrush}" StrokeThickness="2"
                      StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" Visibility="Collapsed" Margin="1"/>
              </Border>
              <ContentPresenter Margin="6,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="CheckMark" Property="Visibility" Value="Visible"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource AccentBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Pill-shaped toggle switch, used explicitly (via StaticResource key) for
         the Debloat + Office tab's preference-style on/off options. -->
    <Style x:Key="ToggleSwitchStyle" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Grid Width="40" Height="20">
              <Border x:Name="Track" CornerRadius="10" Background="{StaticResource ToggleOffBrush}" BorderThickness="0"/>
              <Ellipse x:Name="Thumb" Width="16" Height="16" Fill="#f4f6f9" HorizontalAlignment="Left" Margin="2,0,0,0"/>
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
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ToggleOnBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="4"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Background" Value="{StaticResource CardBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton Focusable="False" ClickMode="Press"
                            IsChecked="{Binding IsDropDownOpen, RelativeSource={RelativeSource TemplatedParent}, Mode=TwoWay}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border Background="{StaticResource CardBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="6">
                      <Grid>
                        <Grid.ColumnDefinitions>
                          <ColumnDefinition Width="*"/>
                          <ColumnDefinition Width="24"/>
                        </Grid.ColumnDefinitions>
                        <Path Grid.Column="1" Data="M0,0 L4,4 L8,0" Stroke="{StaticResource TextBrush}" StrokeThickness="1.5"
                              StrokeStartLineCap="Round" StrokeEndLineCap="Round" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                      </Grid>
                    </Border>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <ContentPresenter IsHitTestVisible="False" Content="{TemplateBinding SelectionBoxItem}"
                                ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                                Margin="{TemplateBinding Padding}" VerticalAlignment="Center" HorizontalAlignment="Left"/>
              <Popup IsOpen="{TemplateBinding IsDropDownOpen}" AllowsTransparency="True" Focusable="False" Placement="Bottom" PopupAnimation="Slide">
                <Border Background="{StaticResource CardBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="6"
                        MinWidth="{Binding ActualWidth, RelativeSource={RelativeSource AncestorType=ComboBox}}" MaxHeight="220" Margin="0,2,0,0">
                  <ScrollViewer><ItemsPresenter/></ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#0a0e17"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="6,4"/>
      <Setter Property="FontFamily" Value="Consolas"/>
      <Setter Property="CaretBrush" Value="{StaticResource TextBrush}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TextBox">
            <Border Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
              <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Segmented nav-button look for the tab strip, matching the reference's
         Install/Tweaks/Config row - active tab highlighted in toggle-blue. -->
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" Background="{StaticResource CardBrush}" BorderBrush="{StaticResource BorderBrush2}"
                    BorderThickness="1" CornerRadius="6" Margin="4,4,4,0" Padding="16,8">
              <ContentPresenter x:Name="Content" ContentSource="Header" HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="{StaticResource ToggleOnBrush}"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource ToggleOnBrush}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
  </Window.Resources>
  <Grid Background="{StaticResource BgBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="#0a0e17" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="0,0,0,1" Padding="16,10">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="Gr3y's Utilities" FontSize="18" FontWeight="Bold" Foreground="{StaticResource AccentBrush}"/>
      </StackPanel>
    </Border>
    <TabControl Grid.Row="1" Name="MainTabs" Background="{StaticResource BgBrush}">
      <TabItem Header="Debloat + Office">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="16">
          <TextBlock Text="PREFERENCES" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,0,0,8"/>
          <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="8" Padding="14,10">
            <StackPanel>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Dry run (preview only)" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptDryRun" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Create System Restore point" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptCreateRestorePoint" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Skip OEM debloat" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptSkipDebloat" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="24,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Debloat Dell software" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptDell" Style="{StaticResource ToggleSwitchStyle}" IsChecked="True" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="24,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Debloat Lenovo software" Foreground="{StaticResource MutedBrush}" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptLenovo" Style="{StaticResource ToggleSwitchStyle}" IsChecked="True" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Skip removing existing Office" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptSkipOfficeRemoval" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Skip installing Microsoft 365 Apps" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptSkipOfficeInstall" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Reduce telemetry &amp; activity tracking" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptTweakTelemetry" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Disable hibernation (frees disk space)" VerticalAlignment="Center"/>
                <CheckBox Grid.Column="1" Name="OptTweakHibernation" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
              </Grid>
            </StackPanel>
          </Border>

          <StackPanel Orientation="Horizontal" Margin="0,14,0,0">
            <TextBlock Text="Office channel:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox Name="OptChannel" Width="180" SelectedIndex="0">
              <ComboBoxItem Content="MonthlyEnterprise"/>
              <ComboBoxItem Content="Current"/>
              <ComboBoxItem Content="SemiAnnual"/>
              <ComboBoxItem Content="SemiAnnualPreview"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
            <Button Name="BtnScan" Content="Scan This Machine" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
            <Button Name="BtnStart" Content="Start" Background="{StaticResource GreenBrush}" Foreground="#04220d"/>
            <Button Name="BtnStop" Content="Stop" Background="{StaticResource RedBrush}" Foreground="#2a0a08" Visibility="Collapsed"/>
            <Button Name="BtnDownloadLog" Content="Download Log" Background="{StaticResource AccentBrush}" Foreground="#04122a" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Now" Background="{StaticResource YellowBrush}" Foreground="#241a00" Visibility="Collapsed"/>
          </StackPanel>

          <TextBlock Text="STATUS" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,20,0,8"/>
          <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="8" Padding="14,10">
            <UniformGrid Columns="4">
              <StackPanel Margin="0,0,8,0">
                <TextBlock Text="STATE" FontSize="10" Foreground="{StaticResource MutedBrush}"/>
                <StackPanel Orientation="Horizontal" Margin="0,2,0,0">
                  <Ellipse Name="StatusDot" Width="10" Height="10" Fill="{StaticResource MutedBrush}" Margin="0,0,6,0"/>
                  <TextBlock Name="StateText" Text="Idle" FontSize="15"/>
                </StackPanel>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="PHASE" FontSize="10" Foreground="{StaticResource MutedBrush}"/>
                <TextBlock Name="PhaseText" Text="-" FontSize="15" Margin="0,2,0,0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="ELAPSED" FontSize="10" Foreground="{StaticResource MutedBrush}"/>
                <TextBlock Name="ElapsedText" Text="0:00" FontSize="15" Margin="0,2,0,0"/>
              </StackPanel>
              <StackPanel>
                <TextBlock Text="CPU TIME (JOB TREE)" FontSize="10" Foreground="{StaticResource MutedBrush}"/>
                <TextBlock Name="CpuText" Text="0.0s" FontSize="15" Margin="0,2,0,0"/>
              </StackPanel>
            </UniformGrid>
          </Border>
          <Border Name="BannerBorder" Margin="0,12,0,0" Padding="10" CornerRadius="6" Visibility="Collapsed">
            <TextBlock Name="BannerText" TextWrapping="Wrap"/>
          </Border>

          <TextBlock Text="LIVE LOG" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,20,0,8"/>
          <TextBox Name="LogBox" Height="300" IsReadOnly="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontSize="12"/>
        </StackPanel>
        </ScrollViewer>
      </TabItem>
      <TabItem Header="Install Apps">
        <DockPanel Margin="16">
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
            <TextBlock Text="Search:" VerticalAlignment="Center" Margin="0,0,6,0"/>
            <TextBox Name="SearchBox" Width="220" Margin="0,0,10,0"/>
            <Button Name="CatAll" Content="All"/>
            <Button Name="CatBrowsers" Content="Browsers"/>
            <Button Name="CatMsTools" Content="Microsoft Tools"/>
            <Button Name="CatUtilities" Content="Utilities"/>
            <Button Name="BtnSelectAll" Content="Select All"/>
            <Button Name="BtnClearSelection" Content="Clear Selection"/>
            <Button Name="BtnCheckInstalled" Content="Check Installed"/>
            <TextBlock Name="SelectedCountText" Text="Selected: 0" VerticalAlignment="Center" Margin="10,0,0,0" Foreground="{StaticResource MutedBrush}"/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,10,0,0">
            <Button Name="BtnInstallSelected" Content="Install Selected" Background="{StaticResource GreenBrush}" Foreground="#04220d"/>
            <Button Name="BtnUninstallSelected" Content="Uninstall Selected" Background="{StaticResource RedBrush}" Foreground="#2a0a08"/>
            <Button Name="BtnUpgradeAll" Content="Upgrade All Installed" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
            <Button Name="BtnStopInstall" Content="Stop" Visibility="Collapsed"/>
            <TextBlock Name="InstallStatusText" Text="Idle" VerticalAlignment="Center" Margin="12,0,0,0"/>
          </StackPanel>
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="300"/>
            </Grid.ColumnDefinitions>
            <ScrollViewer Grid.Column="0" VerticalScrollBarVisibility="Auto">
              <StackPanel Name="InstallAppsPanel"/>
            </ScrollViewer>
            <Border Grid.Column="1" Margin="12,0,0,0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="8">
              <TextBox Name="InstallLogBox" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11" Background="Transparent" BorderThickness="0"/>
            </Border>
          </Grid>
        </DockPanel>
      </TabItem>
      <TabItem Header="Fixes">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="16">
          <TextBlock Text="ONE-CLICK FIXES" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,0,0,8"/>
          <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1" CornerRadius="8" Padding="14,10">
            <StackPanel>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                  <TextBlock Text="System File Repair" FontWeight="SemiBold"/>
                  <TextBlock Text="Runs sfc /scannow then DISM RestoreHealth. Can take 10-20+ minutes." Foreground="{StaticResource MutedBrush}" FontSize="11"/>
                </StackPanel>
                <Button Grid.Column="1" Name="BtnFixSystemRepair" Content="Run" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                  <TextBlock Text="Reset Network" FontWeight="SemiBold"/>
                  <TextBlock Text="Resets Winsock and TCP/IP, flushes DNS. Requires a reboot after." Foreground="{StaticResource MutedBrush}" FontSize="11"/>
                </StackPanel>
                <Button Grid.Column="1" Name="BtnFixNetworkReset" Content="Run" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
              </Grid>
              <Grid Margin="0,6,0,6">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                  <TextBlock Text="Reset Windows Update" FontWeight="SemiBold"/>
                  <TextBlock Text="Clears the update cache and restarts related services - standard fix for a stuck Windows Update." Foreground="{StaticResource MutedBrush}" FontSize="11"/>
                </StackPanel>
                <Button Grid.Column="1" Name="BtnFixWindowsUpdate" Content="Run" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
              </Grid>
              <Grid Margin="0,6,0,0">
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0" VerticalAlignment="Center">
                  <TextBlock Text="Reinstall winget (App Installer)" FontWeight="SemiBold"/>
                  <TextBlock Text="Re-registers the App Installer package - fixes a missing/broken winget." Foreground="{StaticResource MutedBrush}" FontSize="11"/>
                </StackPanel>
                <Button Grid.Column="1" Name="BtnFixWinGet" Content="Run" Background="{StaticResource AccentBrush}" Foreground="#04122a"/>
              </Grid>
            </StackPanel>
          </Border>

          <StackPanel Orientation="Horizontal" Margin="0,20,0,0">
            <TextBlock Text="STATUS" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,0,10,0"/>
            <TextBlock Name="FixesStatusText" Text="Idle" FontSize="13" VerticalAlignment="Center"/>
          </StackPanel>

          <TextBlock Text="LOG" FontWeight="Bold" FontSize="13" Foreground="{StaticResource AccentBrush}" Margin="0,20,0,8"/>
          <TextBox Name="FixesLogBox" Height="320" IsReadOnly="True" TextWrapping="NoWrap"
                   VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" FontSize="12"/>
        </StackPanel>
        </ScrollViewer>
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

# --- Tab 3 controls ---
$btnFixSystemRepair = $window.FindName('BtnFixSystemRepair')
$btnFixNetworkReset = $window.FindName('BtnFixNetworkReset')
$btnFixWindowsUpdate = $window.FindName('BtnFixWindowsUpdate')
$btnFixWinGet = $window.FindName('BtnFixWinGet')
$fixesStatusText = $window.FindName('FixesStatusText')
$fixesLogBox = $window.FindName('FixesLogBox')

$greenBrush = $window.Resources['GreenBrush']
$redBrush = $window.Resources['RedBrush']
$accentBrush = $window.Resources['AccentBrush']

# ============================================================================
# Populate Install Apps tab from apps-catalog.json
# ============================================================================

$script:appEntries = New-Object System.Collections.Generic.List[object]
$script:categoryBlocks = New-Object System.Collections.Generic.List[object]

$categories = $catalog.apps | Group-Object category | Sort-Object Name
foreach ($cat in $categories) {
    $header = New-Object System.Windows.Controls.TextBlock
    $header.Text = "- $($cat.Name)"
    $header.FontWeight = 'Bold'
    $header.FontSize = 14
    $header.Foreground = $accentBrush
    $header.Margin = '0,14,0,6'
    $installAppsPanel.Children.Add($header) | Out-Null

    $wrap = New-Object System.Windows.Controls.WrapPanel
    foreach ($app in ($cat.Group | Sort-Object name)) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $app.name
        $cb.Tag = $app.wingetId
        $cb.Width = 230
        $cb.Margin = '4'
        $wrap.Children.Add($cb) | Out-Null
        $entry = [PSCustomObject]@{ CheckBox = $cb; Name = $app.name; Category = $cat.Name; WingetId = $app.wingetId }
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
            $entry.CheckBox.Visibility = if ($visible) { 'Visible' } else { 'Collapsed' }
            if ($visible) { $anyVisible = $true }
        }
        $blockVisibility = if ($anyVisible) { 'Visible' } else { 'Collapsed' }
        $block.Header.Visibility = $blockVisibility
        $block.Wrap.Visibility = $blockVisibility
    }
}

$searchBox.Add_TextChanged({ Update-AppVisibility })
$catAllBtn.Add_Click({ $script:activeCategory = 'All'; Update-AppVisibility })
$catBrowsersBtn.Add_Click({ $script:activeCategory = 'Browsers'; Update-AppVisibility })
$catMsToolsBtn.Add_Click({ $script:activeCategory = 'Microsoft Tools'; Update-AppVisibility })
$catUtilitiesBtn.Add_Click({ $script:activeCategory = 'Utilities'; Update-AppVisibility })

$btnSelectAll.Add_Click({
    foreach ($entry in $script:appEntries) {
        if ($entry.CheckBox.Visibility -eq 'Visible') { $entry.CheckBox.IsChecked = $true }
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

$fixButtons = @($btnFixSystemRepair, $btnFixNetworkReset, $btnFixWindowsUpdate, $btnFixWinGet)

function Start-FixJob {
    param([string]$FixFlag, [string]$Label)
    if ($script:fixProc -and -not $script:fixProc.HasExited) { return }

    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deployScript,
                 '-NoReboot', '-SkipDebloat', '-SkipOfficeRemoval', '-SkipOfficeInstall', $FixFlag)

    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:fixLogFile = Join-Path $workDir "gui_fix_$stamp.out.log"
    $script:fixErrFile = Join-Path $workDir "gui_fix_$stamp.err.log"
    $script:fixLogOffset = 0
    $fixesLogBox.Text = ''
    $fixesStatusText.Text = "Running: $Label..."
    foreach ($b in $fixButtons) { $b.IsEnabled = $false }

    $script:fixProc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
        -RedirectStandardOutput $script:fixLogFile -RedirectStandardError $script:fixErrFile `
        -WindowStyle Hidden -PassThru
    $script:fixStartTime = Get-Date
}

$btnFixSystemRepair.Add_Click({ Start-FixJob -FixFlag '-FixSystemRepair' -Label 'System File Repair' })

$btnFixNetworkReset.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This resets Winsock and TCP/IP and requires a reboot afterward to fully take effect. Continue?', 'Confirm Network Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixFlag '-FixNetworkReset' -Label 'Network Reset' }
})

$btnFixWindowsUpdate.Add_Click({
    $result = [System.Windows.MessageBox]::Show('This stops Windows Update-related services and clears their cache. Continue?', 'Confirm Windows Update Reset', 'YesNo', 'Warning')
    if ($result -eq 'Yes') { Start-FixJob -FixFlag '-FixWindowsUpdateReset' -Label 'Windows Update Reset' }
})

$btnFixWinGet.Add_Click({ Start-FixJob -FixFlag '-FixWinGetReinstall' -Label 'Reinstall winget' })

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
        'check' { @('list', '--id', $entry.WingetId, '-e', '--accept-source-agreements') }
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
                    $script:installFoundCount++
                } else {
                    $cb.ClearValue([System.Windows.Controls.Control]::ForegroundProperty)
                    $cb.Content = $script:currentQueueEntry.Name
                }
            }

            $script:installProc = $null
            if ($script:installQueue -and $script:installQueue.Count -gt 0) {
                Start-NextInQueue
            } else {
                $installStatusText.Text = if ($script:installMode -eq 'check') {
                    "Done - $($script:installFoundCount) of $($script:installTotal) already installed"
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
            $script:fixProc = $null
        }
    }
})
$timer.Start()

$window.ShowDialog() | Out-Null

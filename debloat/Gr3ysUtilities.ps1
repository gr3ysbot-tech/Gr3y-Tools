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
$scriptDir = Split-Path -Parent $PSCommandPath
$deployScript = Join-Path $scriptDir 'Deploy-DellOfficeSetup.ps1'
$catalogPath = Join-Path $scriptDir 'apps-catalog.json'
$workDir = Join-Path $env:ProgramData 'DellOfficeDeploy'
New-Item -ItemType Directory -Path $workDir -Force | Out-Null

if (-not (Test-Path $deployScript)) {
    [System.Windows.Forms.MessageBox]::Show("Deploy-DellOfficeSetup.ps1 not found next to this script at:`r`n$deployScript", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}

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

# ============================================================================
# WPF setup
# ============================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

if (-not (Test-Path $catalogPath)) {
    [System.Windows.Forms.MessageBox]::Show("apps-catalog.json not found next to this script at:`r`n$catalogPath", 'Gr3y Tools', 'OK', 'Error') | Out-Null
    exit 1
}
$catalog = Get-Content -Path $catalogPath -Raw | ConvertFrom-Json

[xml]$xamlDoc = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Gr3y's Utilities" Height="820" Width="1150"
        WindowStartupLocation="CenterScreen" Background="#0d1117">
  <Window.Resources>
    <SolidColorBrush x:Key="BgBrush" Color="#0d1117"/>
    <SolidColorBrush x:Key="PanelBrush" Color="#161b22"/>
    <SolidColorBrush x:Key="BorderBrush2" Color="#30363d"/>
    <SolidColorBrush x:Key="TextBrush" Color="#c9d1d9"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#8b949e"/>
    <SolidColorBrush x:Key="AccentBrush" Color="#2f81f7"/>
    <SolidColorBrush x:Key="GreenBrush" Color="#3fb950"/>
    <SolidColorBrush x:Key="RedBrush" Color="#f85149"/>
    <SolidColorBrush x:Key="YellowBrush" Color="#d29922"/>
    <Style TargetType="Button">
      <Setter Property="Background" Value="{StaticResource PanelBrush}"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="4"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="Margin" Value="4"/>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Margin" Value="4"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#010409"/>
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
      <Setter Property="BorderBrush" Value="{StaticResource BorderBrush2}"/>
      <Setter Property="FontFamily" Value="Consolas"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="Black"/>
      <Setter Property="Padding" Value="16,8"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="{StaticResource BgBrush}"/>
      <Setter Property="BorderThickness" Value="0"/>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="{StaticResource TextBrush}"/>
    </Style>
  </Window.Resources>
  <Grid>
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <Border Grid.Row="0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="0,0,0,1" Padding="16,10">
      <TextBlock Text="Gr3y's Utilities" FontSize="18" FontWeight="Bold"/>
    </Border>
    <TabControl Grid.Row="1" Name="MainTabs">
      <TabItem Header="Debloat + Office">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
        <StackPanel Margin="16">
          <TextBlock Text="OPTIONS" FontWeight="Bold" FontSize="12" Foreground="{StaticResource MutedBrush}" Margin="0,0,0,8"/>
          <WrapPanel>
            <CheckBox Name="OptDryRun" Content="Dry run (preview only)"/>
            <CheckBox Name="OptCreateRestorePoint" Content="Create System Restore point"/>
            <CheckBox Name="OptSkipDebloat" Content="Skip OEM debloat"/>
            <CheckBox Name="OptSkipOfficeRemoval" Content="Skip removing existing Office"/>
            <CheckBox Name="OptSkipOfficeInstall" Content="Skip installing Microsoft 365 Apps"/>
          </WrapPanel>
          <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
            <TextBlock Text="Office channel:" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <ComboBox Name="OptChannel" Width="180" SelectedIndex="0">
              <ComboBoxItem Content="MonthlyEnterprise"/>
              <ComboBoxItem Content="Current"/>
              <ComboBoxItem Content="SemiAnnual"/>
              <ComboBoxItem Content="SemiAnnualPreview"/>
            </ComboBox>
          </StackPanel>
          <StackPanel Orientation="Horizontal" Margin="0,16,0,0">
            <Button Name="BtnStart" Content="Start" Background="{StaticResource GreenBrush}" Foreground="#04220d"/>
            <Button Name="BtnStop" Content="Stop" Background="{StaticResource RedBrush}" Foreground="#2a0a08" Visibility="Collapsed"/>
            <Button Name="BtnDownloadLog" Content="Download Log" Background="{StaticResource AccentBrush}" Foreground="#04122a" Visibility="Collapsed"/>
            <Button Name="BtnReboot" Content="Reboot Now" Background="{StaticResource YellowBrush}" Foreground="#241a00" Visibility="Collapsed"/>
          </StackPanel>

          <TextBlock Text="STATUS" FontWeight="Bold" FontSize="12" Foreground="{StaticResource MutedBrush}" Margin="0,20,0,8"/>
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
          <Border Name="BannerBorder" Margin="0,12,0,0" Padding="10" CornerRadius="4" Visibility="Collapsed">
            <TextBlock Name="BannerText" TextWrapping="Wrap"/>
          </Border>

          <TextBlock Text="LIVE LOG" FontWeight="Bold" FontSize="12" Foreground="{StaticResource MutedBrush}" Margin="0,20,0,8"/>
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
            <Border Grid.Column="1" Margin="12,0,0,0" BorderBrush="{StaticResource BorderBrush2}" BorderThickness="1">
              <TextBox Name="InstallLogBox" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"/>
            </Border>
          </Grid>
        </DockPanel>
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
$optSkipOfficeRemoval = $window.FindName('OptSkipOfficeRemoval')
$optSkipOfficeInstall = $window.FindName('OptSkipOfficeInstall')
$optChannel = $window.FindName('OptChannel')
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
$selectedCountText = $window.FindName('SelectedCountText')
$btnInstallSelected = $window.FindName('BtnInstallSelected')
$btnUninstallSelected = $window.FindName('BtnUninstallSelected')
$btnUpgradeAll = $window.FindName('BtnUpgradeAll')
$btnStopInstall = $window.FindName('BtnStopInstall')
$installStatusText = $window.FindName('InstallStatusText')
$installAppsPanel = $window.FindName('InstallAppsPanel')
$installLogBox = $window.FindName('InstallLogBox')

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

$btnStart.Add_Click({
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $deployScript, '-NoReboot')
    if ($optDryRun.IsChecked) { $argList += '-DryRun' }
    if ($optCreateRestorePoint.IsChecked) { $argList += '-CreateRestorePoint' }
    if ($optSkipDebloat.IsChecked) { $argList += '-SkipDebloat' }
    if ($optSkipOfficeRemoval.IsChecked) { $argList += '-SkipOfficeRemoval' }
    if ($optSkipOfficeInstall.IsChecked) { $argList += '-SkipOfficeInstall' }
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
# Tab 2: Install/Uninstall/Upgrade queue control
# ============================================================================

$script:installQueue = New-Object System.Collections.Generic.Queue[object]
$script:installProc = $null
$script:installLogFile = $null
$script:installMode = $null
$script:installTotal = 0
$script:installDone = 0

function Start-NextInQueue {
    if ($script:installQueue.Count -eq 0) {
        $installStatusText.Text = "Done ($($script:installDone)/$($script:installTotal))"
        $btnInstallSelected.IsEnabled = $true
        $btnUninstallSelected.IsEnabled = $true
        $btnUpgradeAll.IsEnabled = $true
        $btnStopInstall.Visibility = 'Collapsed'
        $script:installProc = $null
        return
    }
    $entry = $script:installQueue.Dequeue()
    $actionWord = if ($script:installMode -eq 'install') { 'Installing' } else { 'Uninstalling' }
    $installStatusText.Text = "$actionWord $($entry.Name)... ($($script:installDone + 1)/$($script:installTotal))"
    $installLogBox.AppendText("=== $actionWord`: $($entry.Name) ($($entry.WingetId)) ===`r`n")
    $installLogBox.ScrollToEnd()

    $script:installLogFile = Join-Path $workDir "winget_$($script:installMode)_$(Get-Date -Format 'yyyyMMdd_HHmmss_fff').log"
    $wingetArgs = if ($script:installMode -eq 'install') {
        @('install', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements')
    } else {
        @('uninstall', '--id', $entry.WingetId, '-e', '--source', 'winget', '--silent')
    }

    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList $wingetArgs `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" `
        -WindowStyle Hidden -PassThru
    $script:installDone++
}

function Start-AppQueue {
    param([string]$Mode)
    $selected = @($script:appEntries | Where-Object { $_.CheckBox.IsChecked })
    if ($selected.Count -eq 0) { return }
    $script:installQueue = New-Object System.Collections.Generic.Queue[object]
    foreach ($entry in $selected) { $script:installQueue.Enqueue($entry) }
    $script:installMode = $Mode
    $script:installTotal = $selected.Count
    $script:installDone = 0
    $installLogBox.Text = ''
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
    Start-NextInQueue
}

$btnInstallSelected.Add_Click({ Start-AppQueue -Mode 'install' })
$btnUninstallSelected.Add_Click({ Start-AppQueue -Mode 'uninstall' })

$btnUpgradeAll.Add_Click({
    $script:installLogFile = Join-Path $workDir "winget_upgrade_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
    $installLogBox.Text = "=== Upgrading all installed apps ===`r`n"
    $script:installProc = Start-Process -FilePath 'winget.exe' -ArgumentList @('upgrade', '--all', '--silent', '--accept-package-agreements', '--accept-source-agreements') `
        -RedirectStandardOutput $script:installLogFile -RedirectStandardError "$($script:installLogFile).err" -WindowStyle Hidden -PassThru
    $installStatusText.Text = 'Upgrading all installed apps...'
    $btnInstallSelected.IsEnabled = $false
    $btnUninstallSelected.IsEnabled = $false
    $btnUpgradeAll.IsEnabled = $false
    $btnStopInstall.Visibility = 'Visible'
})

$btnStopInstall.Add_Click({
    if ($script:installProc -and -not $script:installProc.HasExited) {
        try { Stop-Process -Id $script:installProc.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
    $script:installQueue.Clear()
    $installStatusText.Text = 'Stopped.'
    $btnInstallSelected.IsEnabled = $true
    $btnUninstallSelected.IsEnabled = $true
    $btnUpgradeAll.IsEnabled = $true
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
            if ($script:installLogFile -and (Test-Path $script:installLogFile)) {
                $tail = Get-Content -Path $script:installLogFile -Raw -ErrorAction SilentlyContinue
                if ($tail) { $installLogBox.AppendText($tail); $installLogBox.AppendText("`r`n"); $installLogBox.ScrollToEnd() }
            }
            $script:installProc = $null
            if ($script:installQueue -and $script:installQueue.Count -gt 0) {
                Start-NextInQueue
            } else {
                $installStatusText.Text = 'Idle'
                $btnInstallSelected.IsEnabled = $true
                $btnUninstallSelected.IsEnabled = $true
                $btnUpgradeAll.IsEnabled = $true
                $btnStopInstall.Visibility = 'Collapsed'
            }
        }
    }
})
$timer.Start()

$window.ShowDialog() | Out-Null

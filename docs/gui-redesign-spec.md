# Gr3y's Utilities - WinUtil-style shell redesign (implementation spec)

Target file: `debloat/Gr3ysUtilities.ps1` (canonical copy also lives in the OneDrive kit at
`C:\Users\gr3y\OneDrive - Gr3y Capital, LLC\USB\debloat\Gr3ysUtilities.ps1`; the two must stay identical).

## 1. Why this exists

The app has been restyled once already (dark navy, cyan headers, pill toggles) and the owner
still says it "looks nowhere like" ChrisTitusTech WinUtil and wants "more of an application feel".
A side-by-side comparison shows the gap is structural, not cosmetic:

| WinUtil (reference)                                             | Current Gr3y's Utilities                              |
|-----------------------------------------------------------------|------------------------------------------------------|
| Draws its own window chrome: dark caption bar holding the tab buttons, a search box and min/max/close | Stock white Windows title bar above a dark body (reads as "a script opened a window") |
| Dense: ~18 DIP rows, 12 px text, 14 px square checkboxes, two columns | ~48 DIP rows, big pill toggles, one column, lots of padding |
| Flat rectangular buttons, dark steel-blue fill, thin grey border | Rounded, saturated green/cyan/red buttons             |
| Monospace cyan section headers, `(?)` hint after each item      | Bold sans-serif uppercase headers, no hints           |
| Log/content areas fill the remaining window height              | Fixed-height 300 px log box inside a scrolling page   |

This spec replaces the shell (chrome, layout, styles) and changes **no behavior**. Every
control `Name`, every event handler and every worker-script argument stays exactly as it is.

## 2. Hard constraints (do not violate)

1. Windows PowerShell 5.1 is the runtime. No PS7-only syntax.
2. The whole file stays **pure ASCII**. No em dashes, no unicode glyphs, no icon fonts. Icons are
   drawn with `Path` geometry. Verify with the command in section 10.
3. No backtick-escaped quotes inside PowerShell strings (`` `" ``). Existing `` `r`n `` sequences
   and line-continuation backticks are fine and already present.
4. The XAML stays a single here-string loaded through `[Windows.Markup.XamlReader]::Load`. That
   means: no `x:Class`, no event attributes in XAML (`Click="..."`), no code-behind. All wiring
   stays in PowerShell via `$window.FindName(...)` + `Add_Click`.
5. In `Window.Resources`, define all brushes **before** any style that references them
   (`StaticResource` resolves at parse time).
6. Every existing `Name` in section 9 must still resolve to a non-null control. Every handler
   block from `# --- Tab 1 controls ---` down to `$window.ShowDialog()` stays byte-identical
   except for the explicit additions listed in section 8.
7. Test on a TEST-ONLY copy with the elevation/STA gate removed (section 10), never on the
   canonical file directly.

## 3. Reference measurements (sampled from the WinUtil screenshots, 150% DPI, converted to DIP)

Palette (exact pixels):

| Token key            | Hex       | Where it was sampled / use                                         |
|----------------------|-----------|--------------------------------------------------------------------|
| `BgBrush`            | `#232629` | Window, caption bar, panels (panels have no fill of their own)     |
| `PanelBorderBrush`   | `#2F373D` | 1 px border around every content panel                             |
| `ButtonBrush`        | `#1E3747` | Button fill, checkbox fill, combobox fill                          |
| `ControlBorderBrush` | `#707070` | Button/checkbox/combobox border, toggle "off" fill                 |
| `TextBrush`          | `#F7F7F7` | Body text, button text, search-box border, nav-button border       |
| `HeaderBrush`        | `#5BDCFF` | Section headers ("Essential Tweaks"), app title                    |
| `HintBrush`          | `#4FB5D2` | `(?)` hints, status labels, note bar text                          |
| `NavSelectedBrush`   | `#5E81AC` | Selected tab button fill                                           |
| `ToggleOnBrush`      | `#2E77FF` | Toggle switch "on" fill (knob is white)                            |
| `ToggleOffBrush`     | `#707070` | Toggle switch "off" fill                                           |

Additional tokens this design adds (not in WinUtil, needed for our status/log UI):

| Token key            | Hex       | Use                                                          |
|----------------------|-----------|--------------------------------------------------------------|
| `MutedBrush`         | `#9AA3AB` | Secondary text, search placeholder                           |
| `ButtonHoverBrush`   | `#2A4C69` | Button hover fill                                            |
| `LogBgBrush`         | `#1B1E21` | Log TextBox fill (slightly darker than the window)           |
| `ScrollThumbBrush`   | `#3C4146` | Scrollbar thumb                                              |
| `CloseHoverBrush`    | `#C42B1C` | Close-button hover fill                                      |
| `AccentBrush`        | `#5BDCFF` | **Keep this key** - code reads `$window.Resources['AccentBrush']` |
| `GreenBrush`         | `#3FB950` | **Keep this key** - status dot / "(installed)" text / banner |
| `RedBrush`           | `#F85149` | **Keep this key** - error dot / banner                       |
| `YellowBrush`        | `#D29922` | Reboot button border                                         |

Sizes (DIP):

| Element                      | Value                                                   |
|------------------------------|---------------------------------------------------------|
| Body font                    | Segoe UI, 12                                            |
| Header font                  | Consolas, 16, `HeaderBrush`, normal weight              |
| Caption bar height           | 44                                                      |
| Nav tab button               | 110 x 25, 1 px `TextBrush` border, 6 gap                |
| Flat button                  | height 25, padding 10,3, min width 90, corner radius 0  |
| Checkbox box                 | 14 x 14, 1 px border, corner radius 0, 6 gap to label   |
| Option row pitch             | 19 (checkbox margin 2,1 gives this with 12 px text)     |
| Toggle switch                | 34 x 17 track, 13 px white knob, 2 px inset             |
| Panel                        | 1 px `PanelBorderBrush`, padding 10,8, no radius, no fill |
| Window control button        | 46 x 44, 10 x 10 icon, 1 px stroke                      |
| Window default / minimum     | 1150 x 820 / 980 x 640                                  |

## 4. Window chrome

Replace the stock title bar with a WPF `WindowChrome`-based caption bar. This keeps native
resizing, Aero snap, double-click-to-maximize and right-click system menu while letting us draw
the whole top of the window.

Window element:

```xml
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
```

`WindowChrome` lives in `System.Windows.Shell` and is part of the default WPF XAML namespace on
.NET Framework 4.5+, so no extra `xmlns` is needed. `TextFormattingMode="Display"` matters: it is
what makes 12 px text look like a native app instead of blurry WPF text.

Root layout:

```xml
  <Grid Name="RootGrid" Background="{StaticResource BgBrush}">
    <Grid.RowDefinitions>
      <RowDefinition Height="44"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>
    <!-- row 0: caption bar (section 5) -->
    <!-- row 1: TabControl (section 6) -->
  </Grid>
</Window>
```

Rules for anything clickable inside the caption bar: set
`WindowChrome.IsHitTestVisibleInChrome="True"` on it, otherwise WindowChrome swallows the click
as a drag.

Known gotchas to verify during testing (fix only if observed):

- Maximized window overflows the screen by the resize border: handled by the `StateChanged`
  handler in section 8 (sets `RootGrid.Margin` to 7 when maximized).
- Maximized window covering the taskbar: if it happens, set
  `$window.MaxHeight = [System.Windows.SystemParameters]::MaximizedPrimaryScreenHeight` once at startup.
- A 1 px white line along the top edge when the window is active: try
  `GlassFrameThickness="0,1,0,0"` on the WindowChrome as the fallback.

## 5. Caption bar (row 0)

Left to right: app title, three nav tab buttons, search box (fills), logs-folder icon button,
minimize / maximize / close. Mirrors WinUtil's `Install | Tweaks | Config | [search] | icons | _ [] X`.

```xml
<Grid Grid.Row="0" Background="{StaticResource BgBrush}">
  <Grid.ColumnDefinitions>
    <ColumnDefinition Width="Auto"/>   <!-- title -->
    <ColumnDefinition Width="Auto"/>   <!-- nav buttons -->
    <ColumnDefinition Width="*"/>      <!-- search -->
    <ColumnDefinition Width="Auto"/>   <!-- logs folder button -->
    <ColumnDefinition Width="Auto"/>   <!-- window controls -->
  </Grid.ColumnDefinitions>

  <TextBlock Grid.Column="0" Text="Gr3y's Utilities" FontFamily="Consolas" FontSize="16" FontWeight="Bold"
             Foreground="{StaticResource HeaderBrush}" VerticalAlignment="Center" Margin="14,0,16,0"/>

  <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
    <Button Name="NavDebloat" Style="{StaticResource NavButton}" Tag="selected" WindowChrome.IsHitTestVisibleInChrome="True">
      <TextBlock><Underline>D</Underline>ebloat + Office</TextBlock>
    </Button>
    <Button Name="NavInstall" Style="{StaticResource NavButton}" WindowChrome.IsHitTestVisibleInChrome="True">
      <TextBlock><Underline>I</Underline>nstall Apps</TextBlock>
    </Button>
    <Button Name="NavFixes" Style="{StaticResource NavButton}" WindowChrome.IsHitTestVisibleInChrome="True">
      <TextBlock><Underline>F</Underline>ixes</TextBlock>
    </Button>
  </StackPanel>

  <Grid Grid.Column="2" Margin="12,0,12,0" VerticalAlignment="Center" WindowChrome.IsHitTestVisibleInChrome="True">
    <TextBox Name="SearchBox" Height="25" Style="{StaticResource SearchBox}"/>
    <TextBlock Name="SearchHint" Text="Search apps..." Foreground="{StaticResource MutedBrush}"
               Margin="8,0,0,0" VerticalAlignment="Center" IsHitTestVisible="False"/>
    <Path Data="M4,4 m-3,0 a3,3 0 1,0 6,0 a3,3 0 1,0 -6,0 M6.2,6.2 L9.5,9.5" Stroke="{StaticResource TextBrush}" StrokeThickness="1.2"
          Width="10" Height="10" HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,8,0" IsHitTestVisible="False"/>
  </Grid>

  <Button Grid.Column="3" Name="BtnOpenLogs" Style="{StaticResource WindowButton}" ToolTip="Open the log folder (C:\ProgramData\DellOfficeDeploy)"
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
```

The search box moves out of the Install Apps tab into the caption bar (WinUtil does the same:
the search only affects the Install tab but is always visible). Keep its `Name="SearchBox"` so
the existing `Update-AppVisibility` wiring works untouched.

## 6. Tab bodies (row 1)

The `TabControl` keeps its three `TabItem`s in the same order (index 0 Debloat + Office,
1 Install Apps, 2 Fixes) but its own header strip is hidden; the caption-bar nav buttons drive
`SelectedIndex`. Give it `Name="MainTabs"` (it already has it) and `Margin="10,8,10,10"`.

### 6.1 Tab 0 - Debloat + Office (modeled on WinUtil's Tweaks tab)

```
+------------------------------------------+----------------------------+
| Debloat                                  | Tweaks                     |
|  [ ] Dry run (preview only)          (?) |  Reduce telemetry &   (o ) |
|  [ ] Create System Restore point     (?) |    activity tracking       |
|  [ ] Skip OEM debloat                (?) |  Disable hibernation  (o ) |
|      [x] Debloat Dell software       (?) |  Prevent sleep        (o ) |
|      [x] Debloat Lenovo software     (?) |                            |
| Office                                   |                            |
|  [ ] Skip removing existing Office   (?) |                            |
|  [ ] Skip installing M365 Apps       (?) |                            |
|  Channel: [MonthlyEnterprise   v]    (?) |                            |
+------------------------------------------+----------------------------+
[Scan This Machine] [Start] [Stop] [Download Log] [Reboot Now]
+----------------------------------------------------------------------+
| STATE  o Idle   |  PHASE  -   |  ELAPSED  0:00   |  CPU (JOB TREE)  0.0s |
+----------------------------------------------------------------------+
(banner, collapsed until a run ends)
Live Log
+----------------------------------------------------------------------+
|                                                                      |
|                (fills all remaining height)                          |
+----------------------------------------------------------------------+
```

Layout: a `Grid` with rows `Auto, Auto, Auto, Auto, Auto, *`. Row 0 is a two-column `Grid`
(`3*` / `2*`, 10 gap) holding two panels. Left panel: header `Debloat`, then option rows, then
header `Office` (Margin 0,10,0,6), then option rows and the channel row. Right panel: header
`Tweaks` and the three toggle rows. Row 1: action buttons. Row 2: status strip. Row 3: banner.
Row 4: header `Live Log`. Row 5: `LogBox` with no fixed `Height` (fills).

Option row (checkbox style) - one full example, repeat for each:

```xml
<DockPanel LastChildFill="False" Margin="0,0,0,1">
  <CheckBox DockPanel.Dock="Left" Name="OptDryRun" Content="Dry run (preview only)"/>
  <TextBlock DockPanel.Dock="Left" Style="{StaticResource Hint}"
             ToolTip="Preview only: logs everything a real run would do without changing anything."/>
</DockPanel>
```

Indented rows (Dell / Lenovo): same but `Margin="22,0,0,1"` and `IsChecked="True"` (keep the
current defaults: Dell and Lenovo on, everything else off).

Channel row:

```xml
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
```

Toggle row (right panel) - WinUtil's Customize Preferences look: toggle first, label after:

```xml
<StackPanel Orientation="Horizontal" Margin="0,3,0,3">
  <CheckBox Name="OptTweakTelemetry" Style="{StaticResource ToggleSwitchStyle}" VerticalAlignment="Center"/>
  <TextBlock Text="Reduce telemetry &amp; activity tracking" VerticalAlignment="Center" Margin="8,0,0,0"/>
  <TextBlock Style="{StaticResource Hint}" ToolTip="AllowTelemetry=0, disables the DiagTrack service and the Activity Feed."/>
</StackPanel>
```

Hint texts to use (`(?)` tooltips):

| Control                | Tooltip                                                                                          |
|------------------------|--------------------------------------------------------------------------------------------------|
| OptDryRun              | Preview only: logs everything a real run would do without changing anything.                     |
| OptCreateRestorePoint  | Creates a System Restore point before any change. Can be blocked by policy; Windows allows one per 24h. |
| OptSkipDebloat         | Skips Phase 1 entirely: no OEM/McAfee app removal and no scheduled task or service changes.        |
| OptDell                | Checks the Dell bloat patterns (SupportAssist, Optimizer, Digital Delivery, ...). Dell Command Update is kept. |
| OptLenovo              | Checks the Lenovo bloat patterns (Lenovo Now, Welcome, Glance, ...). Lenovo Vantage is kept.       |
| OptSkipOfficeRemoval   | Leaves any existing Office / Microsoft 365 install in place instead of removing it first.         |
| OptSkipOfficeInstall   | Does not install Microsoft 365 Apps for business at the end of the run.                           |
| OptTweakTelemetry      | AllowTelemetry=0, disables the DiagTrack service and the Activity Feed.                           |
| OptTweakHibernation    | Runs powercfg /hibernate off, which removes hiberfil.sys and frees its disk space.                |
| OptTweakPreventSleep   | Sets system sleep to Never on AC and battery so the machine stays reachable. Display timeout is untouched, so the screen still locks. |

Action row (all flat `Button`s, `Margin="0,0,6,0"`; keep the same `Visibility="Collapsed"`
defaults on Stop / Download Log / Reboot Now):

```xml
<StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,10,0,0">
  <Button Name="BtnScan" Content="Scan This Machine" MinWidth="140"/>
  <Button Name="BtnStart" Content="Start" MinWidth="110" BorderBrush="{StaticResource GreenBrush}"/>
  <Button Name="BtnStop" Content="Stop" MinWidth="90" BorderBrush="{StaticResource RedBrush}" Visibility="Collapsed"/>
  <Button Name="BtnDownloadLog" Content="Download Log" MinWidth="120" Visibility="Collapsed"/>
  <Button Name="BtnReboot" Content="Reboot Now" MinWidth="110" BorderBrush="{StaticResource YellowBrush}" Visibility="Collapsed"/>
</StackPanel>
```

Status strip (row 2, one bordered strip like WinUtil's bottom "Note:" bar):

```xml
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
```

Banner (row 3) keeps its names; the timer code sets its colors, so only the shape changes:

```xml
<Border Grid.Row="3" Name="BannerBorder" Margin="0,8,0,0" Padding="10,6" BorderThickness="1" Visibility="Collapsed">
  <TextBlock Name="BannerText" TextWrapping="Wrap"/>
</Border>
```

Live Log (rows 4-5): header `TextBlock Style="{StaticResource Header}" Text="Live Log" Margin="0,10,0,4"`,
then `<TextBox Grid.Row="5" Name="LogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>`.
No `ScrollViewer` around the tab any more; the log is what grows.

### 6.2 Tab 1 - Install Apps (modeled on WinUtil's Install tab)

`DockPanel`:

- Top toolbar (`StackPanel Orientation="Horizontal" Margin="0,0,0,8"`): `CatAll` "All",
  `CatBrowsers` "Browsers", `CatMsTools` "Microsoft Tools", `CatUtilities` "Utilities", then a
  12 px spacer, then `BtnSelectAll` "Select All", `BtnClearSelection` "Clear Selection",
  `BtnCheckInstalled` "Check Installed", then `SelectedCountText` (`MutedBrush`, Margin 10,0,0,0).
  No search box here (it moved to the caption bar).
- Bottom action row (`Margin="0,8,0,0"`): `BtnInstallSelected` "Install Selected"
  (`BorderBrush GreenBrush`), `BtnUninstallSelected` "Uninstall Selected" (`BorderBrush RedBrush`),
  `BtnUpgradeAll` "Upgrade All Installed", `BtnStopInstall` "Stop" (`Visibility="Collapsed"`),
  `InstallStatusText` (Margin 12,0,0,0).
- Center: `Grid` with columns `*` / `300`. Column 0: `Border Style="{StaticResource Panel}"`
  containing `ScrollViewer` > `StackPanel Name="InstallAppsPanel"`. Column 1 (`Margin="10,0,0,0"`):
  `Border Style="{StaticResource Panel}" Padding="0"` containing
  `TextBox Name="InstallLogBox" Style="{StaticResource LogBox}" BorderThickness="0" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" FontSize="11"`.

The catalog checkboxes are created in code (see section 8, item 6) and pick up the default
`CheckBox` style automatically. Category headers are also created in code and must use the
header font/colour.

### 6.3 Tab 2 - Fixes (modeled on WinUtil's Config tab)

`Grid` with columns `400` / `*` (10 gap).

Left: `Border Style="{StaticResource Panel}"` > `StackPanel`: header `Fixes`, then four
full-width flat buttons (`HorizontalAlignment="Stretch" Margin="0,0,0,4"`), each keeping its
existing `Name`, with the old description text as its `ToolTip`:

| Name                 | Content                       | ToolTip                                                                                     |
|----------------------|-------------------------------|---------------------------------------------------------------------------------------------|
| BtnFixSystemRepair   | System File Repair - Run      | Runs sfc /scannow then DISM RestoreHealth. Can take 10-20+ minutes.                         |
| BtnFixNetworkReset   | Network - Reset               | Resets Winsock and TCP/IP, flushes DNS. Requires a reboot after.                            |
| BtnFixWindowsUpdate  | Windows Update - Reset        | Clears the update cache and restarts related services - standard fix for a stuck Windows Update. |
| BtnFixWinGet         | WinGet - Reinstall            | Re-registers the App Installer package - fixes a missing/broken winget.                     |

Right: `Grid` rows `Auto, Auto, *`: row 0 a horizontal `StackPanel` with header-styled
`TextBlock Text="Status"` and `TextBlock Name="FixesStatusText" Text="Idle"` (Margin 10,0,0,0,
VerticalAlignment Bottom); row 1 header `Log` (Margin 0,10,0,4); row 2
`TextBox Name="FixesLogBox" Style="{StaticResource LogBox}" IsReadOnly="True" TextWrapping="NoWrap" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"` (fills).

## 7. Styles - paste into `Window.Resources` in this order

```xml
<Window.Resources>
  <!-- 1. Brushes (must come first) -->
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

  <!-- 2. Text -->
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

  <!-- 3. Panels and tooltips -->
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

  <!-- 4. Buttons -->
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

  <!-- 5. CheckBox (WinUtil tweaks-list look) and toggle switch -->
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

  <!-- 6. ComboBox (flat) -->
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

  <!-- 7. TextBoxes -->
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

  <!-- 8. Scrollbars (default WPF scrollbars are light grey and break the look) -->
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

  <!-- 9. TabControl with hidden headers (nav buttons in the caption bar drive it) -->
  <Style TargetType="TabItem">
    <Setter Property="Visibility" Value="Collapsed"/>
  </Style>
  <Style TargetType="TabControl">
    <Setter Property="Background" Value="{StaticResource BgBrush}"/>
    <Setter Property="BorderThickness" Value="0"/>
    <Setter Property="Padding" Value="0"/>
  </Style>
</Window.Resources>
```

Drop the old `PanelBrush`, `CardBrush`, `BorderBrush2` keys - nothing in the code references them
(only `AccentBrush`, `GreenBrush`, `RedBrush` are read from PowerShell).

## 8. PowerShell changes (the only code edits allowed)

1. In `# --- Tab 1 controls ---` add after the existing lines:

```powershell
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
```

2. Directly after the `$greenBrush / $redBrush / $accentBrush` lines add the chrome wiring:

```powershell
$headerBrush = $window.Resources['HeaderBrush']

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
```

3. In the existing `$searchBox.Add_TextChanged({ Update-AppVisibility })` line, extend the block:

```powershell
$searchBox.Add_TextChanged({
    $searchHint.Visibility = if ($searchBox.Text) { 'Collapsed' } else { 'Visible' }
    Update-AppVisibility
})
```

4. Optional but cheap: typing in the search box should show the Install tab, since that is
the only thing it filters. Add inside the same handler, before `Update-AppVisibility`:
`if ($searchBox.Text -and $mainTabs.SelectedIndex -ne 1) { Set-ActiveTab -Index 1 }`.

5. Nothing else in the job-control, queue or timer code changes. `$btnStart`'s `$argList`
block in particular must remain identical.

6. Category headers created in the `foreach ($cat in $categories)` loop: change the four
styling lines to

```powershell
    $header.Text = $cat.Name
    $header.FontFamily = 'Consolas'
    $header.FontSize = 16
    $header.Foreground = $headerBrush
    $header.Margin = '0,8,0,4'
```

and the per-app checkbox margin to `$cb.Margin = '2,1'` (keep `$cb.Width = 230`). Move the
`$headerBrush = ...` line above this loop (it is defined in item 2, which sits above the loop
already if inserted where specified).

7. Remove the three `[System.Windows.Forms.MessageBox]` file-existence checks? **No** - leave
them; they run before the XAML loads and are unaffected.

## 9. Control names that must all resolve (acceptance list)

Tab 0: `OptDryRun OptCreateRestorePoint OptSkipDebloat OptDell OptLenovo OptSkipOfficeRemoval
OptSkipOfficeInstall OptTweakTelemetry OptTweakHibernation OptTweakPreventSleep OptChannel
BtnScan BtnStart BtnStop BtnDownloadLog BtnReboot StatusDot StateText PhaseText ElapsedText
CpuText BannerBorder BannerText LogBox`

Tab 1: `SearchBox CatAll CatBrowsers CatMsTools CatUtilities BtnSelectAll BtnClearSelection
BtnCheckInstalled SelectedCountText BtnInstallSelected BtnUninstallSelected BtnUpgradeAll
BtnStopInstall InstallStatusText InstallAppsPanel InstallLogBox`

Tab 2: `BtnFixSystemRepair BtnFixNetworkReset BtnFixWindowsUpdate BtnFixWinGet FixesStatusText
FixesLogBox`

Shell (new): `MainTabs RootGrid NavDebloat NavInstall NavFixes SearchHint BtnOpenLogs BtnWinMin
BtnWinMax BtnWinClose IconMax IconRestore`

## 10. Testing and definition of done

Work on a TEST-ONLY copy in the session scratchpad: copy `Gr3ysUtilities.ps1`,
`Deploy-DellOfficeSetup.ps1`, `apps-catalog.json`, `bloat-patterns.json` next to each other, and in
the copy replace the whole block from `function Test-IsAdmin {` through the closing `}` of
`if ($needsElevation -or $needsSTA) { ... }` with the single line
`# TEST-ONLY: elevation/STA relaunch gate removed for local smoke testing.`
Launch it with `powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File <copy>`.

Checks, all of which must pass before shipping:

1. Parse: `[System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$t, [ref]$e)` reports 0 errors.
2. ASCII: `[regex]::IsMatch((Get-Content -Raw $f), '[^\x00-\x7F]')` returns `False`.
3. Backtick-quote check: `Select-String -Path $f -Pattern '`"'` returns nothing.
4. Startup: the window opens with no "Failed to load the GUI layout" MessageBox. If it fails,
   the exception text names the XAML line - fix it there, do not simplify the design.
5. All names in section 9 resolve: loop `foreach ($n in $names) { if (-not $window.FindName($n)) { "MISSING $n" } }`
   inside a throwaway copy that exits right after `XamlReader.Load`.
6. UI Automation (System.Windows.Automation, cross-process): clicking each nav button changes the
   visible tab (assert a control unique to that tab, e.g. the "Scan This Machine" / "Install
   Selected" / "System File Repair - Run" button, is now found); each checkbox and toggle in Tab 0
   toggles via TogglePattern; typing in the search box hides the placeholder and filters the
   catalog; minimize/maximize/restore buttons change `WindowState`; close ends the process.
   Note: these checkboxes have no AutomationId, so locate them via the label text of the
   neighbouring TextBlock / the checkbox Content, then the sibling CheckBox.
7. Visual: screenshot the window (System.Drawing `CopyFromScreen` of the window bounds) at the
   default 1150x820 and maximized, and compare against `images/22.png`, `23.png`, `24.png`
   from the reference set. Required to match: no light title bar anywhere; caption bar holds
   tabs + search + window buttons; flat square buttons; 14 px checkboxes at ~19 DIP pitch;
   monospace cyan headers; dark scrollbars; log area reaches the bottom edge of the window.
8. Behavior parity: Start with Dry run on produces the same `-DryRun -Dell -Lenovo -OfficeChannel MonthlyEnterprise`
   argument set as before (visible in the live log's "Starting run." line); Scan This Machine
   still fills the log; Check Installed still marks entries green.
9. Sync: copy the finished file byte-for-byte to both the OneDrive kit and the repo clone
   (`debloat/Gr3ysUtilities.ps1`), verify with `Get-FileHash`, commit, push, then curl the raw
   GitHub URL and confirm it contains `WindowChrome` (proves the push landed).
10. Update `README.md` wording if it describes the old layout, and the memory note about the
    app's visual theme (it currently says "dark navy ... pill toggles ... segmented tab strip").

Out of scope: any change to `Deploy-DellOfficeSetup.ps1`, `debloat.ps1`, the JSON files, or the
worker-script argument list. If something in this spec cannot be made to work in XamlReader on
PS 5.1, keep the intent (chrome, density, flat controls) and note the substitution in the
commit message rather than reverting to the old look.

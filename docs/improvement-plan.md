# Gr3y Support - improvement plan (implementation spec)

Audience: a Claude Code session (Sonnet 5) implementing this in `gr3ysbot-tech/Gr3y-Tools`,
with the repo owner reviewing and pruning. Read the whole document before touching code.
Work in the order given; each numbered item is one commit unless stated otherwise.

Status of this document: DRAFT for owner pruning. Items marked `[OWNER DECISION]` need
an answer before implementation. Items marked `[OPTIONAL]` are backlog - skip unless the
owner asks for them.

---

## 0. Ground rules (do not skip)

### 0.1 Files and the three-copy rule
- Canonical source: `C:\Users\gr3y\OneDrive - Gr3y Capital, LLC\USB\debloat\`
  (`Gr3ysUtilities.ps1`, `Deploy-DellOfficeSetup.ps1`, `apps-catalog.json`, `bloat-patterns.json`, `docs\`).
- Git clone used for commits: the repo `gr3ysbot-tech/Gr3y-Tools`, files under `debloat\`,
  plus `debloat.ps1` and `README.md` at the repo root (those two exist only in the repo).
- Every edit to a `debloat\` file must land in the OneDrive canonical copy AND the repo
  clone, and both must be byte-identical before committing. Verify with
  `Get-FileHash -Algorithm SHA256` on both copies. (The session scratchpad may hold a third
  loose copy; keep it in sync too if it exists, but the two above are what matter.)
- Docs written for the owner live in `docs\` in the repo and are mirrored to the OneDrive
  kit `docs\` folder.
- The file name `Gr3ysUtilities.ps1` stays as-is. The displayed product name is "Gr3yLabs Support"
  (renamed from "Gr3y Support" 2026-09-30, briefly "Gr3yLabs Tools" before settling on this name
  2026-10-01; older references to "Gr3y Support" elsewhere in this document describe the product
  under its previous name).
- The "Gr3y Network Tools" website (`network-toolkit` repo, Synology NAS, Portainer) is a
  separate project. Do not deploy or touch it as part of this plan.

### 0.2 Runtime constraints (hard)
- Target host is Windows PowerShell 5.1. No PS7-only syntax: no ternary `? :`, no `??`,
  no `-not` shortcuts that rely on 7.x, no `ForEach-Object -Parallel`. Every cmdlet used
  must exist in 5.1 or be a built-in Windows module (Appx, BitLocker, NetAdapter,
  PrintManagement, ScheduledTasks, Defender, LAPS on 11 23H2+).
- Source files are pure ASCII, no BOM, LF line endings. Do not introduce smart quotes,
  em dashes or non-ASCII in code, comments or XAML. (`Set-Content` in 5.1 writes CRLF and a
  BOM by default - write files with `[System.IO.File]::WriteAllText($path, $text)` and join
  lines with "`n", or use the Edit tool.)
- No backtick-escaped double quotes inside double-quoted strings (project convention, due
  to remote-clipboard mangling). Use doubled quotes `""` inside `"..."`, or single-quoted
  strings.
- The GUI is a WPF window defined as a XAML here-string inside `Gr3ysUtilities.ps1`.
  Controls are found with `$window.FindName('Name')`. Reuse existing styles:
  `ToggleSwitchStyle` (checkbox switch), `Hint` (the "(?)" tooltip TextBlock), `Header`,
  `Panel`, `LogBox`, `NavButton`, brushes `GreenBrush`/`RedBrush`/`AccentBrush`/`HeaderBrush`.
- All system changes go through `Deploy-DellOfficeSetup.ps1` (the worker), wrapped in
  `Invoke-Step 'description' { ... }` so `-DryRun` is honored automatically, and logged with
  `Write-Log 'text' 'WARN'`. The GUI never modifies the system directly except for
  launching Control Panel applets and opening URLs.
- The GUI launches the worker as a hidden child `powershell.exe` and tails its log with a
  `DispatcherTimer`. Two job systems exist: `$btnStart` (Debloat + Office run, uses
  `$script:deployProc`) and `Start-FixJob -FixArgs @(...) -Label '...'` (Config tab: Fixes,
  Apply Tweaks, Apply DNS, uses `$script:fixProc`). New Config-tab actions must use
  `Start-FixJob`. New buttons that run jobs must be added to `$fixButtons` so they disable
  while a job runs.
- Worker parameters follow the existing pattern: a `[switch]` (or `[string]`) in the
  `param()` block, a `.PARAMETER` doc entry, a function, and one `if ($Flag) { Do-Thing }`
  line in MAIN.

### 0.3 Testing conventions (what has worked, what has not)
- Syntax check both scripts after every edit:
  `[System.Management.Automation.PSParser]::Tokenize((Get-Content $f -Raw), [ref]$errs)`;
  require `$errs.Count -eq 0`. This does NOT validate the XAML - a XAML error only shows at
  runtime as the "Failed to load the GUI layout" MessageBox.
- Logic tests: extract the function text from the worker with `IndexOf` markers, stub
  `Invoke-Step`/`Write-Log`/side-effecting cmdlets, `Invoke-Expression` it, and drive each
  branch. Never let a test perform a real install/uninstall/registry write on the dev box
  unless the write is harmless and reverted.
- The Claude tool shell is NOT elevated. Anything that needs admin (HKLM writes, HKU
  hive access, `reg load`) must be tested by writing a small script, launching it with
  `Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',"""$path""")`
  and having it write results to a file that the tool shell then reads. An earlier
  "elevated admin cannot write HKU:\.Default" conclusion was a false alarm caused by
  forgetting this; from a real elevated process, `HKU:\.Default`, `HKLM:\SOFTWARE\Policies`
  and `reg.exe load/unload` of `C:\Users\Default\NTUSER.DAT` all work.
- GUI smoke test: launch `Gr3ysUtilities.ps1` (it self-elevates), poll with Win32
  `EnumWindows` for a visible window titled exactly `Gr3y Support`, and also check that no
  window titled `Gr3y Tools` (the error MessageBox title) exists. Kill the process after.
  UI Automation cannot read inside the elevated window from the non-elevated tool shell
  (UIPI), so do not attempt click-through automation; do not take screen captures on this
  workstation (multi-monitor layout has produced wrong-window captures).
- Always look for and kill stray `powershell.exe` processes titled `Gr3y Support` after a
  test; check `StartTime` first so you never kill something the owner opened.

### 0.4 Git
- One commit per numbered item. Commit messages explain why. Push to `main` (until
  Phase 4 introduces releases). The one-liner pulls `main` through a ~5-minute
  raw.githubusercontent.com cache, so a pushed change is not live immediately.
- Never rewrite history, never force-push, never touch the `network-toolkit` repo.

---

## 1. What this tool is today (baseline)

Native WPF GUI (`Gr3ysUtilities.ps1`, ~1900 lines) + worker (`Deploy-DellOfficeSetup.ps1`,
~1070 lines) + `apps-catalog.json` (63 apps) + `bloat-patterns.json`. One-liner
`irm get.gr3y.io/debloat | iex` -> `debloat.ps1` self-elevates, downloads the four files
from `main` into `%TEMP%\Gr3yTools_<stamp>\`, launches the GUI.

Tabs: Debloat + Office (OEM debloat, OEM update tool install, Office remove/install via
ODT, Tweaks: telemetry/hibernation/prevent sleep/Smart App Control, Scan, Start/Stop/log),
Install Apps (winget catalog, Scan/Install/Uninstall/Upgrade, winget presence + Install
winget, per-app "(?)" links, direct-download entries), Config (Fixes: sfc+DISM, network
reset, WU reset, winget re-register; 24 Customize Preferences toggles; DNS preset switcher),
Panels (14 Control Panel launchers).

---

## 2. Phase 0 - Correctness and safety fixes to shipped code

These are defects found by a fresh-eyes review on 2026-09-30. Items 0.1-0.3 were
reproduced under real Windows PowerShell 5.1 by the owner's session; treat them as
confirmed. Do all of Phase 0 before any feature work.

### 0.1 Quote `-File` paths in every `Start-Process` launch [CONFIRMED]
Windows PowerShell 5.1 space-joins `-ArgumentList` elements without quoting. An unquoted
path containing a space (`OneDrive - Gr3y Capital, LLC`, or any user profile like
`C:\Users\John Smith\AppData\Local\Temp`) makes `powershell.exe -File` fail with exit
-196608. Pre-quoting the element (`"""$path"""`) works.
- Fix: `Gr3ysUtilities.ps1` self-relaunch (`$relaunchArgs`, ~line 44), `$btnStart`
  (`-File $deployScript`), `Start-FixJob` (`-File $deployScript`), the `Install winget`
  launch, and `debloat.ps1` (the final `Start-Process ... -File (Join-Path $installDir 'Gr3ysUtilities.ps1')`).
  Wrap the path element as a single pre-quoted string; leave flag-only elements alone.
- Also quote any file argument passed to `winget`/`setup.exe` the same way (the ODT call
  already does: `"/configure ""$installXmlPath"""`).
- Test: run the GUI from a copy in a directory with a space; the worker must start.

### 0.2 Fix the Win32 uninstall-string parser and the silent-flag loop [CONFIRMED]
`Deploy-DellOfficeSetup.ps1` ~line 414: `($uninstallString -replace '"','') -split ' ' | Select-Object -First 1`
turns `"C:\Program Files\McAfee\MSC\mcuihost.exe" /body:...` into `C:\Program`, so
`Test-Path` fails and no EXE-based uninstaller under Program Files ever runs. Today only
`msiexec` entries are actually removed. The surrounding loop over `/S`, `/silent`,
`/verysilent /norestart`, `/quiet` also breaks after the first flag whose `Test-Path`
succeeds, which does not depend on the flag - so only `/S` can ever run.
- Fix: prefer `QuietUninstallString` when present. Parse with
  `^"([^"]+)"\s*(.*)$` then `^(\S+?\.exe)\s*(.*)$`, keeping the original arguments.
  Choose the silent flag by uninstaller family: `unins*.exe` (Inno) ->
  `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART`; NSIS -> `/S`; InstallShield -> `/s /x`;
  otherwise try the original args plus `/quiet`. For `msiexec`, take the GUID from the
  string with `\{[0-9A-Fa-f-]{36}\}` (some Dell keys are not named by GUID).
- Use `WaitForExit(600000)` and kill on timeout instead of waiting forever (a wrong flag
  shows a hidden GUI that never closes).
- Keep `Start-ProcessLowPriority` and the pacing sleep between uninstalls.
- Test: unit-test the parser against the three sample strings in
  `docs/improvement-plan.md` section 0.2 plus `RunDll32 ...` and an Inno `unins000.exe` path.

### 0.3 Fix the PHASE indicator regex [CONFIRMED]
`Gr3ysUtilities.ps1` `Get-LogSummary` (~line 161) uses `'--- (Phase \d[a-z]?: [^-]+) ---'`;
the hyphen in `en-us` stops the match so the status bar shows Phase 2 through the whole
Office install. Use `'--- (Phase \d[a-z]?: .+?) ---'`. While there, stop re-reading the whole
`out.log` with `-Raw` every 1.2 s tick: update the phase from the tail text `Get-LogTail`
already returns, and detect `Run complete.` there too.

### 0.4 Customize Preferences: about half the toggles write the Windows default
Only the WinUtil `Value` (ON side) was ported into `$script:tweakDefs`. For every WinUtil
entry whose `DefaultState` is `true` the ON value is the stock Windows state, so the
toggle is a no-op on a fresh image and the value a tech wants is unreachable. Affected keys
(WinUtil id in parentheses): StartMenuBingSearch (WPFToggleBingSearch, want 0),
StartMenuRecommendations (want HideRecommendedSection=1 x2 + IsEducationEnvironment=1),
TaskbarSearchIcon, TaskbarTaskViewIcon (want 0), TaskbarCenteredIcons (0 = left),
MouseAcceleration (want 0/0/0), GameMode (want 0/0), WindowSnapping ('0'),
LogonAcrylicBlur (DisableAcrylicBackgroundOnLogon=1 = blur off), StickyKeys (Flags=58),
SettingsHomePage ('hide:home'), S0SleepNetwork (0), NewOutlook (mixed).
- Fix: move the tweak definitions into `debloat\tweaks.json` (shared by GUI and worker;
  removes the duplicated label table in the GUI). Each entry carries `key`, `label`, `tip`,
  `explorerRestart`, and `entries[]` with `path`, `name`, `type`, `onValue`, `offValue`
  where `offValue` may be the literal `<RemoveEntry>` (delete the value). Values come
  verbatim from `https://raw.githubusercontent.com/ChrisTitusTech/winutil/main/config/tweaks.json`
  (`Value` -> onValue, `OriginalValue` -> offValue).
- GUI: on startup read the live registry for each entry and set the switch to the current
  state (like WinUtil's `DefaultState`). "Apply Selected Tweaks" applies the delta: switches
  that changed since startup get their on/off value written. This gives revert for free
  and makes the switch metaphor honest. Keep the "one-way" hint text only for items that
  truly have no reverse (Smart App Control).
- Worker: `-CustomizeTweaks` stays a comma list but each item becomes `Key=on|off`.
- Test: with stubs, apply `StartMenuBingSearch=off` and assert `BingSearchEnabled=0`;
  apply `BatteryPercentage=off` and assert the value is removed.

### 0.5 Lenovo detection reads the wrong WMI field
On Lenovo, `Win32_ComputerSystem.Model` is the machine-type code (e.g. `21AHCTO1WW`); the
marketing name is `Win32_ComputerSystemProduct.Version` (e.g. `ThinkPad X1 Carbon Gen 10`).
So `Install-OemUpdateTool`'s IdeaPad/Yoga/Legion check never matches on Lenovo, and the
log-file tag reads `LENOVO-21AHCTO1WW`. If switched to the friendly name, `Yoga` must not
exclude `ThinkPad X1 Yoga` / `L13 Yoga` / `X13 Yoga` (commercial).
- Fix: compute `$machineModel` as `Win32_ComputerSystemProduct.Version` when manufacturer
  matches Lenovo (fall back to `.Model`), in both worker and GUI tag logic. Consumer
  filter for Lenovo: match `IdeaPad|Legion` or `Yoga` only when the name does not start
  with `ThinkPad`.
- `[OWNER DECISION]` Dell package: the tool installs `Dell.CommandUpdate` (Classic).
  Research says Dell is moving current Latitude/Precision to the Universal (UWP) build
  and Classic is not offered for some newer models, but Universal needs the Windows App
  SDK/.NET prerequisites. Recommended: try `Dell.CommandUpdate.Universal` first on
  Windows 11, fall back to `Dell.CommandUpdate` if winget fails. Owner may prefer Classic
  only (current behavior). Either way, detect both `Dell Command | Update` and
  `Dell Command | Update for Windows Universal` as "already installed" (already done).

### 0.6 Config tab ignores Dry run; Apply Tweaks has no confirmation
`Start-FixJob` never passes `-DryRun` even though the worker supports it.
- Pass `'-DryRun'` when `$optDryRun.IsChecked`; show a small "Dry run" badge on the Config
  tab status line. Confirm "Apply Selected Tweaks" with the list of labels. After a job
  completes, refresh the switches from the registry (ties into 0.4).

### 0.7 DNS switcher: physical adapters only, domain guard, remember previous servers
`Set-DnsPreset` applies to every adapter with Status Up, including Hyper-V/VMware/WSL
virtual adapters and VPN tunnels (breaks split DNS), and on a domain-joined machine static
public DNS breaks domain sign-in.
- Filter with `Get-NetAdapter -Physical` and exclude `InterfaceDescription -match 'Virtual|Hyper-V|VPN|WAN Miniport|TAP|WireGuard'`.
- If `(Get-CimInstance Win32_ComputerSystem).PartOfDomain` is true, refuse unless the GUI
  passed an explicit second confirmation (add `-DnsForce` switch; GUI shows a second
  "This machine is domain-joined" dialog).
- Log the previous per-adapter server list (and whether it was DHCP) before changing.

### 0.8 bloat-patterns.json: Lenovo Vantage is removed while the UI says it is kept
`E046963F.LenovoCompanion` is the AppX package name of Lenovo Vantage (it kept the old
Companion identity). The tooltip and the worker comment say Vantage is kept.
- Remove that pattern (or gate it behind an explicit opt-in). Reconsider
  `DellInc.DellPeripheralManager` / `Dell Peripheral Manager*` (manages WD19/WD22 dock
  firmware and Dell webcams that SMB clients use) - `[OWNER DECISION]`.
- Scheduled-task keep patterns are matched against `TaskName` only; Dell Command Update
  tasks live under `\Dell\CommandUpdate\` and Lenovo Vantage depends on
  `\Lenovo\ImController\` tasks. Match keep patterns against `"$($task.TaskPath)$($task.TaskName)"`
  in both worker and Scan, and add `*ImController*` to `lenovo.scheduledTaskKeepPatterns`.
- Docs note: the `MicrosoftTeams` AppX pattern only matches the 22H2 consumer Chat
  package. On 23H2/24H2 the inbox client is `MSTeams`, which is also the work/school Teams
  that M365 Apps installs. Do NOT add `MSTeams` to the patterns.

### 0.9 Start button: confirmation and re-entrancy guard
Start removes Office and OEM apps with no confirmation and can be double-clicked (the
button is only disabled on the next timer tick), launching two workers that race.
- Confirm with a summary of the checked phases when Dry run is off. Disable the button and
  set `$script:deployProc` synchronously before `Start-Process`. Add the same guard to
  "Upgrade All Installed" (it overwrites `$script:installProc`).

### 0.10 Install Apps: Scan, Uninstall Selected, exit codes, language
- Scan auto-checks every installed app and the status text tells the tech to click
  Uninstall Selected; on a fresh laptop that set includes Edge, OneDrive, PowerShell,
  Windows Terminal, both VC++ redists and the .NET runtimes. Scan must only colour/relabel
  `(installed)`, not check. Uninstall Selected must confirm with the list of names.
- The installed check uses `$tail -notmatch 'No installed package found'`, which is
  localised. Use the process exit code instead (`0` found, `-1978335212` / `0x8A150014`
  not found) - with `-PassThru`, `$proc.ExitCode` is valid once `HasExited` is true after
  `Refresh()`.
- Replace 63 per-app `winget list` processes (and 126 log files) with one
  `winget list --source winget --disable-interactivity` call parsed by the Id column.
- Tally per-item exit codes and end with "Done: n ok, m failed" instead of "Idle";
  colour failed items red.

### 0.11 Non-interactive children
Add `-NonInteractive` to every hidden child `powershell.exe` launch (Start, Start-FixJob,
Install winget) so a stray prompt errors instead of hanging invisibly. Add
`--disable-interactivity` to every winget call and `--accept-source-agreements` to
`uninstall`.

### 0.12 System Restore point: default on, and make it actually happen
The worker doc says the GUI defaults the checkbox to checked; the XAML does not. Windows
also skips `Checkpoint-Computer` if any restore point was created in the last 24 h.
- `IsChecked="True"` on `OptCreateRestorePoint`. In `New-PreDeploySystemRestorePoint`:
  `Enable-ComputerRestore -Drive "$env:SystemDrive\"`, set
  `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore\SystemRestorePointCreationFrequency = 0`
  (DWord) for the run and restore it after, then verify with `Get-ComputerRestorePoint`
  that a point with the description exists and log its SequenceNumber; WARN loudly if not.

### 0.13 Office phase robustness (this is the most likely real-world incident)
- Neither `Start-Process` for `setup.exe` (`/configure remove-all.xml`, `/configure install.xml`)
  checks an exit code; `Install complete` and `Run complete.` are logged unconditionally,
  so the GUI paints the green success banner with no Office installed. Use
  `-PassThru -Wait`, log WARN/ERROR on non-zero, keep `$script:errorCount`, end MAIN with
  `Run complete with N warnings/errors`, and have `Get-LogSummary` drive a yellow banner
  for that case. Append the run's `.err.log` to the log box when a job finishes.
- Order: today Phase 2 removes the old Office before Phase 3 downloads anything. Pre-flight
  before Phase 2: download `setup.exe`, run `setup.exe /download install.xml` into
  `$workDir\OfficeSource` (add `<Add SourcePath="...">`), check >= 5 GB free; abort the run
  with a clear ERROR before removing anything if that fails.
- `Get-OfficeDeploymentTool` caches `setup.exe` forever in ProgramData; old builds fail
  with "setup.exe is out of date". Always re-download (about 7 MB) or delete it at the end
  of each run.
- `remove-all.xml` removes every C2R product, including a client's licensed Visio/Project.
  Read `HKLM:\SOFTWARE\Microsoft\Office\ClickToRun\Configuration` `ProductReleaseIds` in
  Scan and in Phase 2; list them; refuse (or require explicit confirm) when anything other
  than `O365BusinessRetail`, `O365ProPlusRetail` or consumer SKUs is present. When
  `O365BusinessRetail` is already installed on the requested channel, skip Phase 2 and run
  the ODT config in place.
- Add `<RemoveMSI />` and `<Logging Level="Standard" Path="C:\ProgramData\DellOfficeDeploy" />`
  to `install.xml`; drop the manual `msiexec` loop for old MSI Office. `AUTOACTIVATE=1` is a
  volume-licence property and is ignored for `O365BusinessRetail` - remove it to avoid
  implying something it does not do.
- After Phase 3, verify the ClickToRun Configuration key exists and log the installed
  `ProductReleaseIds` and version.

### 0.14 AppX de-provisioning: run serially and surface errors
`Invoke-ThrottledSteps` runs `Remove-AppxProvisionedPackage -Online` (DISM API, not
thread-safe in-process) three wide, with `-ErrorAction SilentlyContinue`, and logs the
description as if it succeeded. Keep `Remove-AppxPackage` parallel; run de-provisioning
serially; after `EndInvoke` check `$ps.Streams.Error` and log each as WARN; re-query
`Get-AppxProvisionedPackage -Online` at the end and log anything still matching.

### 0.15 UI thread stalls and a real hang
- `Get-DescendantProcessIds` has no visited set; PID reuse can loop forever and freeze the
  GUI, and Stop can kill an unrelated reused PID. Track visited PIDs; cache the descendant
  list and refresh it every ~10 s instead of every 1.2 s tick; record each child's
  `CreationDate` and validate before killing.
- Scan This Machine runs `Get-AppxPackage -AllUsers`, `Get-ScheduledTask` and registry
  enumeration synchronously (5-20 s, window goes Not Responding). Run it in a background
  runspace and marshal the report back with `$window.Dispatcher.Invoke`.
- The direct-download branch in `Start-NextInQueue` runs `Invoke-WebRequest` on the UI
  thread. Use a background runspace (or `Start-BitsTransfer -Asynchronous`) and continue
  the queue on completion.

### 0.16 Window size on small laptops
`Height="820"` with custom chrome is not clamped to the work area; on 1366x768 or 13-inch
FHD at 150% the Install Apps action bar is off-screen. After `XamlReader.Load`, set
`$window.Height = [Math]::Min(820, [System.Windows.SystemParameters]::WorkArea.Height - 20)`
and the same for Width, or start Maximized when the work area is under 840 px tall.

### 0.17 Fixes tab output and correctness
- `sfc /scannow` writes UTF-16LE to a redirected pipe (logs as spaced letters). Set
  `[Console]::OutputEncoding = [Text.Encoding]::Unicode` around it and restore after.
- DISM streams a progress bar as hundreds of lines; use `/LogPath` and log the final status.
- `Invoke-WindowsUpdateReset` logs success without checking; verify `wuauserv` stopped and
  the rename happened; delete `SoftwareDistribution.bak` at the end of the fix.
- Add online `chkdsk /scan /perf` before sfc in System Repair, exit codes 1/2 informational.

### 0.18 Closing the window mid-job
Add a `Closing` handler: if `$script:deployProc`, `$script:fixProc` or `$script:installProc`
is running, ask "A job is still running. Stop it / keep it running / cancel". Write the
worker PID into the log header so a future "reattach" is possible (reattach itself is
`[OPTIONAL]`).

### 0.19 Stray console windows
`debloat.ps1` relaunches with `-NoExit` and starts the GUI without `-WindowStyle Hidden`;
the GUI's own self-relaunch also leaves a console. Techs see an empty elevated
"Windows PowerShell" window behind the GUI and after it closes. Add `-WindowStyle Hidden`
to the GUI launch, drop `-NoExit`; fatal errors already go to a MessageBox.

### 0.20 Tweak caveats that generate tickets later
- Reduce telemetry: `AllowTelemetry=0` + DiagTrack off breaks Windows Autopatch, Update
  Compliance and Intune Endpoint Analytics, and Microsoft documents that Smart App Control
  turns itself off when optional diagnostic data is disabled. Add both caveats to the hint;
  skip the tweak automatically (log WARN) when `HKLM:\SOFTWARE\Microsoft\Enrollments` shows
  an MDM enrolment. `[VERIFY]` the exact SAC/diagnostic-data wording against the current
  Microsoft "What is Smart App Control" support page before changing UI text.
- S3 Sleep: on Modern-Standby-only Dell firmware (no S3 exposed) `PlatformAoAcOverride=0`
  breaks sleep/wake. Gate it behind `powercfg /a` output containing `Standby (S3)`.
- Smart App Control toggle: hide it when `[Environment]::OSVersion.Version.Build -lt 22621`
  or the `CI\Policy\VerifiedAndReputablePolicyState` value is absent; show the current
  state (0 off / 1 on / 2 evaluation) next to it.

### 0.21 Log sprawl and Download Log
Sweep files in `C:\ProgramData\DellOfficeDeploy` older than 30 days at startup; delete
per-item winget temp logs after reading them; make Download Log zip `out.log` +
`err.log` + the transcript (the transcript is the one with the exact command line).

### 0.22 Docs mismatches
`Gr3ysUtilities.ps1` header says "Two tabs"; README says "Three tabs" and calls the
tab "Fixes"; README omits Non-Silent Installs and Customize Preferences/DNS/Panels; README
and `debloat.ps1` show the raw GitHub one-liner instead of `irm get.gr3y.io/debloat | iex`;
the Scan comment claims it uses the exact same patterns as a run but omits provisioned
packages and ignores the Skip toggles in its totals. Fix all of these (README rewrite is
part of Phase 4.6 - do the header/comment fixes here).

---

## 3. Phase 1 - Foundations that everything else builds on

### 1.1 Apply per-user settings to the Default User profile (highest structural value)
Every HKCU write (24 Customize toggles, telemetry HKCU halves, future Office/Edge/CDM
keys) lands in the elevated account's hive - usually the tech's - and the client's user,
created later or at Entra join, gets stock defaults. All four research tracks flagged this.
- Add to the worker a helper `Invoke-DefaultProfileRegistry { param([scriptblock]$Body) }`:
  `reg.exe load HKU\Gr3yDefault "$env:SystemDrive\Users\Default\NTUSER.DAT"`, mount the
  `HKU:` PSDrive if absent, run `$Body` with a `$DefaultRoot = 'HKU:\Gr3yDefault'` variable,
  then `[gc]::Collect(); [gc]::WaitForPendingFinalizers(); Start-Sleep -Milliseconds 300;
  reg.exe unload HKU\Gr3yDefault`. Verified working from an elevated process on 2026-09-30.
  Use `reg.exe add/query` inside `$Body` where possible to avoid lingering .NET handles
  that make `unload` fail; if `unload` fails, log WARN (it clears on reboot).
- Add `-TargetProfile Current|Default|Both` (default `Both`) to the worker. Every HKCU
  entry is applied to the current user and, for `Default`/`Both`, rewritten as
  `HKU:\Gr3yDefault\...` and applied inside the helper. Log both.
- Also log a WARN when the console user (`(Get-CimInstance Win32_ComputerSystem).UserName`)
  differs from `$env:USERNAME` (the tech elevated into a different account).
- Explorer restart: only restart Explorer for the console session and only when the
  current-user hive was changed; otherwise log "sign out to apply".
- GUI: a small "Apply to: Current user / Default profile (future users) / Both" selector on
  the Config tab, default Both, persisted into the profile (Phase 2.3).
- Test (elevated harness): write a probe value through the helper, then `reg.exe load` the
  hive again and `reg.exe query` it; assert presence; remove it.

### 1.2 tweaks.json as the single definition file (started in 0.4)
Finish moving all tweak/telemetry/Edge/Office/CDM definitions into `debloat\tweaks.json`
with on/off values and `scope: HKCU|HKLM|HKU-Default`. The GUI builds its toggle list from
it; the worker applies from it. `debloat.ps1` must download it (see 1.4 for a zip-based
bootstrap that removes the hard-coded file list).

### 1.3 Undo snapshot and "Revert last run"
Before applying any tweak, DNS, service, scheduled-task or power change, capture the live
current state into `C:\ProgramData\DellOfficeDeploy\undo_<hostname>_<stamp>.json`
(registry value + type or `<Absent>`, service StartType/Status, task State, DNS per-adapter
servers and DHCP flag, active power scheme, hibernate state). Add `-Undo <file>` to the
worker (walk in reverse) and a "Revert last run" button on the Config tab that picks the
newest undo file. Also `reg.exe export` each touched key into the same folder. Label
irreversible actions (Smart App Control off, Office removal, AppX/OEM removal) as such in
the UI so Revert never implies more than it does.

### 1.4 Version stamp, pinned downloads, hardened elevation
- `debloat.ps1`: fetch a small `latest.json` from `main` (`{version, commit, files:{name:sha256}}`),
  download each file from `https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/<full-commit-sha>/debloat/<file>`,
  verify with `Get-FileHash`, abort on mismatch. Commit-SHA URLs are immutable, which also
  removes the 5-minute CDN lag mismatch between files. Set
  `[Net.ServicePointManager]::SecurityProtocol = 'Tls12'` first. Add `-Ref <tag|sha>` to
  pin a field run. (Honest limit: this protects integrity/consistency, not against a
  compromised GitHub account - that is Phase 4.3 signing.)
- Do the download + verify in the non-elevated session, then elevate ONCE to run the
  verified local `Gr3ysUtilities.ps1 -Version <v> -Commit <sha>`; drop the second
  `irm | iex` fetch, drop `-NoExit`, purge `%TEMP%\Gr3yTools_*` older than 7 days.
- Guard PowerShell 7: if `$PSVersionTable.PSEdition -eq 'Core'`, re-exec the bootstrapper
  under `powershell.exe` and return.
- GUI: show `Gr3y Support vX.Y.Z (abc1234)` in the title bar; write version, commit,
  profile name and worker PID into the first lines of every log; optional non-blocking
  check of `releases/latest` (5 s timeout, banner only, never in-place update).
- Publish `latest.json` by a small release script (Phase 4.4 automates it).

---

## 4. Phase 2 - MSP provisioning workflow (the second half of a laptop build)

Ordered by technician time saved x frequency. Every item is a worker function + switch
+ a checkbox/field in a new "Provisioning" group on the Debloat + Office tab (or a new
tab if the panel gets crowded - `[OWNER DECISION]`). Client-specific values come from the
profile in 2.3; secrets never go in the public repo.

### 2.1 Run Dell Command Update / Lenovo System Update (apply BIOS + drivers)
Today the tool installs the updater and stops. Add opt-in "Apply OEM updates now":
- Dell: `dcu-cli.exe /configure -silent -autoSuspendBitLocker=enable -userConsent=disable`,
  then `/scan -silent -report=C:\ProgramData\DellOfficeDeploy\dcu`, then
  `/applyUpdates -silent -reboot=disable -outputLog=...`. Path: `$env:ProgramFiles\Dell\CommandUpdate\dcu-cli.exe`
  with `${env:ProgramFiles(x86)}` fallback. Exit codes: 0 ok, 1 reboot required, 5 reboot
  pending, 500 no updates, 501 scan error, 3 not Dell, 7 unsupported model.
- Lenovo: `"${env:ProgramFiles(x86)}\Lenovo\System Update\tvsu.exe" /CM` with the
  parameters in `HKLM\Software\Policies\Lenovo\System Update\UserSettings\General\AdminCommandLine`
  (REG_SZ) = `-search A -action INSTALL -includerebootpackages 0,3 -noicon -nolicense -noreboot -exporttowmi`;
  read results from `root\Lenovo\Lenovo_Updates` WMI. Call `Suspend-BitLocker -RebootCount 1`
  first when BitLocker is on.
- Require AC power (`Win32_Battery.BatteryStatus` or `Win32_SystemEnclosure`) before BIOS
  packages; stream logs into the live log; set the Reboot button visible when a reboot is
  required. Run before BitLocker enable and before Entra join.

### 2.2 Windows Update to completion (WUA COM API) + reboot-and-resume
- "Patch to current": `New-Object -ComObject Microsoft.Update.Session` ->
  `CreateUpdateSearcher().Search("IsInstalled=0 and IsHidden=0 and Type='Software'")` ->
  download -> install; opt into Microsoft Update via
  `(New-Object -ComObject Microsoft.Update.ServiceManager).AddService2('7971f918-a847-4430-9279-4a52d1efe18d',7,'')`;
  honor Dry run by stopping after Search; retry once after 60 s on `0x80240022`. Cap at
  3-4 passes. Trigger Store updates with the MDM bridge
  (`MDM_EnterpriseModernAppManagement_AppManagement01` / `UpdateScanMethod`).
- Reboot-and-resume: persist remaining stages to `C:\ProgramData\DellOfficeDeploy\state.json`,
  register a scheduled task (SYSTEM, `-AtStartup`) or `RunOnce` that re-launches a locally
  cached copy of the worker with `-Resume`; GUI shows "Resuming stage 3 of 6"; unregister on
  completion. Mark stages SYSTEM-safe vs user-context (HKCU, Explorer restart, winget for
  the user are user-context). This is the prerequisite for 2.1, 2.2 and 2.5 to finish
  unattended. `[OWNER DECISION]` - this is the largest single item in the plan.

### 2.3 Client profile JSON (save/load in the GUI; input to everything else)
`profiles\<client>.json` (private: OneDrive kit, USB, or a private URL - never the public
repo when it contains secrets): ClientCode, HostnamePattern (`ACME-{SERIAL}`),
EntraTenantId, TimeZoneId, GeoId, DnsPreset, OfficeChannel, OfficeExcludeApps,
RmmInstallerUrl + args, LocalAdminName, OneDriveKfmFolders, PrinterList, WingetAppIds,
Tweaks on/off map, PowerPlan, LockTimeoutSec, TargetProfile. "Save profile" serializes the
current GUI state; "Load profile" re-checks boxes; the bootstrapper accepts
`-Profile <path-or-URL>`. Secrets (RMM tokens, seed passwords) come from an encrypted
local file (`ConvertTo-SecureString -Key`) or a one-time prompt held in memory.

### 2.4 Hostname rename (before Entra join)
`Rename-Computer -NewName <pattern> -Force` (no immediate restart), name built from the
profile pattern and `Win32_BIOS.SerialNumber`, trimmed to 15 chars, invalid characters
stripped; show the computed name in Scan; warn instead of renaming if already Entra joined.

### 2.5 BitLocker: status, enable, escrow (never a silent "disable")
- Update 2026-10-04: at the owner's request the Panels tab also has a guarded **Disable BitLocker...**
  dialog (status first, then a written-and-checked backup of every key, then decrypt the ticked
  drives; data drives before the Windows drive; nothing is decrypted without that backup). It is
  deliberately NOT a one-click tweak, which is what "never disable" in this plan and in section 7
  was about.
- Scan shows `Get-BitLockerVolume C:` ProtectionStatus/EncryptionPercentage and `Get-Tpm`
  TpmReady/TpmPresent.
- Opt-in "Enable BitLocker": if TpmReady and ProtectionStatus Off:
  `Enable-BitLocker -MountPoint C: -EncryptionMethod XtsAes256 -UsedSpaceOnly -TpmProtector -SkipHardwareTest`,
  `Add-BitLockerKeyProtector -RecoveryPasswordProtector`; if `dsregcmd /status` shows
  AzureAdJoined, `BackupToAAD-BitLockerKeyProtector` for the RecoveryPassword protector;
  always write the recovery password to the handoff package (2.10), never to the public
  log body. "Save recovery key to USB" button.
- Opt-in "Prevent automatic device encryption" for machines that will stay on local
  accounts: `HKLM\SYSTEM\CurrentControlSet\Control\BitLocker PreventDeviceEncryption=1`
  (24H2 auto-encrypts at first Microsoft-account sign-in and the key may end up only in a
  personal account).
- Run after 2.1 (BIOS flashes need BitLocker suspended) and after Entra join.

### 2.6 Break-glass local admin (+ Windows LAPS where the tenant allows)
`New-LocalUser` with a random 20+ char password, `-PasswordNeverExpires`, add to
Administrators, disable Guest. For Entra-joined clients, write the LAPS policy keys under
`HKLM\Software\Microsoft\Policies\LAPS` (BackupDirectory=1, AdministratorAccountName,
PasswordLength=20, PasswordComplexity=4, PasswordAgeDays=30) and run
`Invoke-LapsPolicyProcessing`; otherwise the generated password goes only to the handoff
package. Never name the built-in RID-500 Administrator in LAPS.

### 2.7 Remove the end user from local Administrators after join
List `Get-LocalGroupMember Administrators`, highlight `AzureAD\user@...` and non-MSP local
accounts, remove with `Remove-LocalGroupMember`; never remove the last enabled admin;
leave unresolved Entra role SIDs (`S-1-12-1-...`) alone; log a note when MDM is present.

### 2.8 OneDrive Known Folder Move + silent sign-in (instead of any OneDrive removal)
Write `HKLM\SOFTWARE\Policies\Microsoft\OneDrive`: `SilentAccountConfig=1`,
`KFMSilentOptIn=<TenantId>` (REG_SZ), `KFMSilentOptInWithNotification=1`,
`KFMSilentOptInDesktop/Documents/Pictures=1` as chosen, `KFMBlockOptOut=1`,
`FilesOnDemandEnabled=1`; ensure the per-machine OneDrive installer is current. Tenant ID
from the profile. Only meaningful on Entra-joined devices; skip on shared/kiosk builds.

### 2.9 Regional, time, power and lock baseline
`Set-TimeZone -Id`, `tzautoupdate` service on for laptops, `Set-WinHomeLocation -GeoId`,
`Set-Culture`, `w32tm /resync` (skip NTP reconfiguration on domain members), power plan
selection, `powercfg /change monitor-timeout-ac 15`, lid action, screen lock
`HKLM\...\Policies\System InactivityTimeoutSecs=900`, fast startup off
(`HiberbootEnabled=0`, needed for WoL and clean updates). Values from the profile.

### 2.10 Validation report, inventory and handoff package
- Validate stage (read-only): activation (`SoftwareLicensingProduct` LicenseStatus, run
  `slmgr /ato` once if not licensed and online), Defender (`Get-MpComputerStatus`
  RealTimeProtectionEnabled, IsTamperProtected, signature age; report third-party AV from
  `root\SecurityCenter2` instead of failing), firewall profiles all enabled, BitLocker
  protection + recovery protector present, `dsregcmd` join/MDM state, Secure Boot, pending
  reboot, free disk, last WU success, OEM updater result.
- Inventory JSON: serial, model (Lenovo friendly name per 0.5), BIOS version, TPM
  present/ready/spec, Windows edition/build/UBR/InstallDate, RAM, disks, MACs, OA3 key
  presence, Office ProductReleaseIds/version/channel, installed programs, tweaks/apps
  applied with timestamps, tool version/commit.
- Handoff package: `<ClientCode>_<hostname>_<serial>\` with inventory.json, validation.txt,
  bitlocker-recovery.txt, autopilot.csv (if captured), the full log, plus a `report.html`
  (`ConvertTo-Html` with inline CSS) opened automatically; "Copy summary" to clipboard.
  Prompt before writing secrets to removable media.
- `[OPTIONAL]` Dell TechDirect / Lenovo warranty lookup via API keys kept in the private
  profile secret file.

### 2.11 Autopilot hardware-hash export `[OPTIONAL]`
`MDM_DevDetail_Ext01.DeviceHardwareData` -> CSV with the exact header
`Device Serial Number,Windows Product ID,Hardware Hash,Group Tag,Assigned User` (ANSI, no
quotes). Capture before Entra join.

### 2.12 Windows Hello / PIN mode `[OPTIONAL]`
Profile flag: default / suppress WHfB enrollment (`HKLM\SOFTWARE\Policies\Microsoft\PassportForWork Enabled=0`,
`DisablePostLogonProvisioning=1`) / allow convenience PIN (`AllowDomainPINLogon=1`).
Default = leave default; Intune policy overrides local keys.

### 2.13 RMM / remote-support agent install from the profile `[OPTIONAL]`
Generic "installer URL + args" stage (msiexec `/qn /norestart` for NinjaOne/Datto/Syncro
MSIs, exe + args for ScreenConnect/Splashtop); verify by service name; `Unblock-File`
after download; profile flag for first vs last in the sequence.

### 2.14 Printers from the profile `[OPTIONAL]`
`pnputil /add-driver`, `Add-PrinterDriver`, `Add-PrinterPort`, `Add-Printer` from INF
packages (never vendor setup.exe); detect Windows Protected Print on 24H2 and warn.

### 2.15 Entra join via provisioning package `[OPTIONAL, needs tenant setup]`
`Install-ProvisioningPackage -PackagePath <ClientCode>.ppkg -ForceInstall -QuietInstall`,
verify with `dsregcmd /status`; surface the ppkg age (bulk token max 180 days). Keep the
manual `ms-settings:workplace` path as fallback.

### 2.16 RDP / Wake-on-LAN toggles and legacy-protocol audit line `[OPTIONAL]`
RDP with NLA + firewall group; WoL on wired NICs + fast startup off; SMB1/LLMNR/NetBIOS
reported as PASS/FAIL on the validation sheet (do not flip SMB signing).

---

## 5. Phase 3 - Content: tweaks, policies, catalog, panels

All registry values below come from the cited upstream sources; copy them verbatim and
put them in `tweaks.json` with on/off values. Everything is opt-in unless stated.

### 3.1 Debloat that sticks (default on, next to the OEM task/service toggle)
- Consumer features: `HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent DisableWindowsConsumerFeatures=1`
  (Enterprise/Education only) PLUS the per-user ContentDeliveryManager keys from
  Win11Debloat `Regfiles/Disable_Windows_Suggestions.reg` (SilentInstalledAppsEnabled,
  SystemPaneSuggestionsEnabled, SoftLandingEnabled, SubscribedContent-310093/338388/338389/338393/353694/353696/353698 = 0),
  `Explorer\Advanced Start_IrisRecommendations=0`, `UserProfileEngagement ScoobeSystemSettingEnabled=0`,
  `AccountNotifications EnableAccountNotifications=0`, `CloudContent DisableConsumerAccountStateContent=1`,
  lock-screen tips (`SubscribedContent-338387Enabled=0`, `RotatingLockScreenOverlayEnabled=0`).
  These are HKCU-heavy - they depend on Phase 1.1.
- Device companion apps: `HKLM\SOFTWARE\Policies\Microsoft\Windows\Device Metadata PreventDeviceMetadataFromNetwork=1`
  (this is why Dell Peripheral Manager / Logitech reinstall on first dock).
- WPBT off `[OPTIONAL, opt-in]`: `HKLM\SYSTEM\CurrentControlSet\Control\Session Manager DisableWpbtExecution=1`.
  Leave off for clients using Absolute/Computrace. Log the current value in Scan.
- Add `Microsoft.Copilot` and `Microsoft.MicrosoftOfficeHub` to generic AppX patterns.

### 3.2 WinUtil Essential Tweaks port (owner-identified gap)
Port from `config/tweaks.json`: Activity History (WinUtil keeps EnableActivityFeed=1 and
only sets Publish/UploadUserActivities=0 so clipboard history keeps working - match that),
Delivery Optimization (`DODownloadMode` = 1 LAN-only for offices, not 0/100), Disk
Cleanup/Temp files (as the final worker phase, WITHOUT `/ResetBase`), End Task on
taskbar (`TaskbarDeveloperSettings TaskbarEndTask=1`), Store search results off, Start
Menu previous layout. Do NOT port: BitLocker Disable, Services to Manual (breaks Mobile
Hotspot/Offline Files; at most `MapsBroker=Manual`), Location Tracking as-is (lfsvc off
breaks auto time zone/Find My Device - offer only Find My Device off, opt-in), Storage
Sense off, Notifications off, IPv6/Teredo off.

### 3.3 Telemetry: expand to the documented set, with business exceptions
Add to the existing tweak: AdvertisingInfo Enabled=0, TailoredExperiencesWithDiagnosticDataEnabled=0,
OnlineSpeechPrivacy HasAccepted=0, TIPC Enabled=0, InputPersonalization Restrict* =1,
HarvestContacts=0, AcceptedPrivacyPolicy=0, Start_TrackProgs=0, Siuf NumberOfSIUFInPeriod=0,
Edge DiagnosticData=0 / PersonalizationReportingEnabled=0, `POWERSHELL_TELEMETRY_OPTOUT=1`.
Do NOT change `Set-MpPreference -SubmitSamplesConsent` or disable `wermgr`. Label
AllowTelemetry=0 as "minimum" (honored only on Enterprise/Education).

### 3.4 Copilot / Recall / Click to Do / AI policy bundle (opt-in, reversible)
Win11Debloat reg approach (HKLM + HKCU policies): `WindowsCopilot TurnOffWindowsCopilot=1`,
`Explorer\Advanced ShowCopilotButton=0`, `WindowsAI DisableAIDataAnalysis=1`,
`AllowRecallEnablement=0`, `TurnOffSavingSnapshots=1`, `DisableClickToDo=1`,
`WSAIFabricSvc Start=3`, Notepad/Paint AI off, Edge `CopilotPageContext=0`,
`CopilotCDPPageContext=0`, `HubsSidebarEnabled=0`, `EdgeHistoryAISearchEnabled=0`,
`ComposeInlineEnabled=0`, `NewTabPageBingChatEnabled=0`. Keep opt-in: clients with M365
Copilot licences want it on.

### 3.5 Edge first-run and nag policies (never Edge removal)
HKLM policies: `EdgeUpdate CreateDesktopShortcutDefault=0`; `Edge HideFirstRunExperience=1`,
`ShowRecommendationsEnabled=0`, `DefaultBrowserSettingsCampaignEnabled=0`,
`EdgeShoppingAssistantEnabled=0`, `ShowMicrosoftRewards=0`, `WebWidgetAllowed=0`,
`UserFeedbackAllowed=0`, `MicrosoftEdgeInsiderPromotionEnabled=0`, `WalletDonationEnabled=0`,
`ConfigureDoNotTrack=1`, `NewTabPageContentEnabled=0`, `NewTabPageHideDefaultTopSites=1`,
`SpotlightExperiencesAndRecommendationsEnabled=0`, `ShowAcrobatSubscriptionButton=0`.
Optional homepage/startup from the profile. (Shows "Managed by your organization" - fine.)

### 3.6 Office first-run/privacy policies and ODT options
HKCU (and Default profile via 1.1): `office\16.0\common\clienttelemetry SendTelemetry=3`,
`common\feedback Enabled=0, SurveyEnabled=0`, `common\ptwatson PTWOptIn=0`,
`Office\16.0\Common\General ShownFirstRunOptin=1`, `common\general OptInDisable=1`.
`[VERIFY]` each against the current Office ADMX before shipping. ODT: expose `ExcludeApp`
checkboxes (Teams, OneDrive, Access, Publisher, Lync, OneNote), `SharedComputerLicensing`
option for shared PCs. (0.13 already adds `RemoveMSI` and `Logging`.)

### 3.7 Small-office quality-of-life toggles (fit the existing Customize list)
Classic context menu (`HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32` default = empty, Explorer restart),
`LegacyDefaultPrinterMode=1` (stop Windows changing the default printer),
`EnableFirstLogonAnimation=0`, `DisableAutomaticRestartSignOn=1` (shared PCs),
`PrintScreenKeyForSnippingEnabled=1`, Explorer opens to This PC (`LaunchTo=1`),
Recycle Bin delete confirmation on, `TaskbarMn=0` (Chat), Phone Link off in Start.

### 3.8 Business Windows Update policy preset + restore defaults
From WinUtil `Invoke-WPFUpdatessecurity.ps1` / `Invoke-WPFUpdatesdefault.ps1`:
`WindowsUpdate ExcludeWUDriversInQualityUpdate=1` (let DCU/LSU own drivers),
`DeferFeatureUpdates=1` + period (180/365), `DeferQualityUpdates=1` + period (0-7),
`DriverSearching DontSearchWindowsUpdate=1`, `AU AUOptions=3`, `AU NoAutoRebootWithLoggedOnUsers=1`,
`UX\Settings IsContinuousInnovationOptedIn=0`. "Restore update defaults" button removes
exactly those. Do NOT port `Invoke-WPFUpdatesdisable` (stops wuauserv/BITS/UsoSvc).

### 3.9 Defender hardening opt-ins (the opposite of a "disable Defender" switch)
`Set-MpPreference -PUAProtection Enabled`, `-EnableNetworkProtection Enabled`,
LSA protection (`Lsa RunAsPPL=1`), keep Mark-of-the-Web, SmartScreen for apps on.
Skip all when a third-party AV is registered in `root\SecurityCenter2`. Never touch
SubmitSamplesConsent, SpyNet, or SmartScreen/SAC in the weakening direction.

### 3.10 Fixes and features additions
Time sync (`w32tm /resync`; NTP pool config only when not domain-joined) + time zone
dropdown; `chkdsk /scan` in System Repair (0.17); .NET Framework 3.5 enable
(`Enable-WindowsOptionalFeature -Online -FeatureName NetFx3 -All`); daily registry backup
(`EnablePeriodicBackup=1` + `RegIdleBackup` task); legacy F8 boot menu on/off
(`bcdedit /set bootmenupolicy legacy|standard`); post-provisioning cleanup step (temp,
`cleanmgr /VERYLOWDISK`, `StartComponentCleanup` without `/ResetBase`, SoftwareDistribution\Download,
ODT cache). Keep Storage Sense on. Do NOT remove Quick Assist.

### 3.11 Catalog: business baseline, categories, guards
- Add `"msp": true` (or a `Business` category) and `SelectedByDefault` fields; add a
  "Business Baseline" filter button that is the default filter; make Select All confirm
  (or refuse) when the active filter is All (today one click installs Tor, qBittorrent and
  auto-clickers on a client laptop).
- Add Document and Communications categories: `Adobe.Acrobat.Reader.64-bit`,
  `Foxit.FoxitReader`, `SumatraPDF.SumatraPDF`, `TrackerSoftware.PDF-XChangeEditor`,
  `geeksoftwareGmbH.PDF24Creator`, `TheDocumentFoundation.LibreOffice`, `Cyanfish.NAPS2`,
  `Zoom.Zoom`, `SlackTechnologies.Slack`, `Mozilla.Thunderbird`, `Notepad++.Notepad++`,
  `VideoLAN.VLC`, `Famatech.AdvancedIPScanner`, `PuTTY.PuTTY`, `WinSCP.WinSCP`,
  `WiresharkFoundation.Wireshark`, `REALiX.HWiNFO`, `CPUID.CPU-Z`, `RustDesk.RustDesk`.
  Verify each id with `winget show` before adding (Smart App Control blocked several
  low-reputation installers earlier; prefer well-signed vendors). `[OWNER DECISION]` which
  of the removed entries (KeePassXC, WinRAR, Tailscale, UniGetUI) to re-add for business.
- `sacRisk: true` flag on entries known to be unsigned/low-reputation; warn before
  installing them when SAC state is On (state read from `CI\Policy\VerifiedAndReputablePolicyState`).
- FreeFileSync: resolve the current `FreeFileSync_*_Windows_Setup.exe` link from
  `https://freefilesync.org/download.php` at runtime instead of the pinned 14.12 URL.

### 3.12 DNS: DoH + IPv6 for the existing presets
WinUtil `config/dns.json` carries `Primary6/Secondary6` and `DohTemplate` for every preset.
On Windows 11 (`Get-Command Add-DnsClientDohServerAddress`), register the template with
`-AllowFallbackToUdp $false -AutoUpgrade $true`; set IPv4 + IPv6 addresses. Keep the
domain guard from 0.7.

### 3.13 Default apps (PDF/browser) the supported way
Do NOT script UserChoice hashes or disable UCPD. Offer: `Dism /Online /Import-DefaultAppAssociations:<xml>`
for new profiles (pairs with 1.1) and an `ms-settings:defaultapps` launcher on the Panels
tab for the current user. `[OPTIONAL]`

### 3.14 Panels tab additions
`ms-settings:workplace`, `ms-settings:activation`, `ms-settings:windowsupdate`,
`ms-settings:bluetooth`, `ms-settings:display`, `ms-settings:printers`,
`ms-settings:network-status`, `ms-settings:defaultapps`, `devmgmt.msc`, `diskmgmt.msc`,
`services.msc`, `taskschd.msc`, `eventvwr.msc`, `lusrmgr.msc`, `netplwiz`,
`optionalfeatures`, `msinfo32`, `dxdiag`, `wf.msc`, `slui 4`, "dsregcmd /status" (to the
log), "Admin PowerShell here". Same `$quickPanels` table pattern.

### 3.15 HP as a third OEM `[OPTIONAL]`
Add an `hp` block to `bloat-patterns.json` (AppX publisher `AD2F1837.*`, Win32
`HP Support Assistant*`, `HP Wolf Security*`, `HP Connection Optimizer`, `HP Documentation`,
`HP Sure Run*`, `HP Sure Recover*`, `HP Notifications`; keep HP Image Assistant) and an HPIA
step (`HPImageAssistant.exe /Operation:Analyze /Action:Install /Selection:All /Silent`).

---

## 6. Phase 4 - Distribution, trust and operations

### 4.1 Smart App Control awareness in the GUI (small, do early)
Read `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy\VerifiedAndReputablePolicyState`
(0 off / 1 on / 2 evaluation) at startup; show it in the status bar; warn before installing
`sacRisk` catalog entries while On; add the telemetry interaction warning (0.20).

### 4.2 GitHub Releases + CI
Workflow on `windows-latest`: `Invoke-ScriptAnalyzer` with `PSUseCompatibleSyntax`
(TargetVersions 5.1 and 7.4) and `PSUseCompatibleCommands` (5.1 profile); fail on any
non-ASCII byte in `*.ps1`/`*.json`; parse every JSON file (unique wingetId, each entry has
`wingetId` or `downloadUrl`, every `-like` pattern compiles); parse the XAML here-string
with `[xml]`; Pester tests for `Get-LogSummary`, the uninstall-string parser and
`Get-SafeFileNamePart` (two of these would have caught Phase 0 bugs); write `SHA256SUMS`;
zip `debloat\` as `Gr3ySupport-vX.Y.Z.zip`; attach to a Release; `actions/attest-build-provenance`.
Point `latest.json` at the release so `main` becomes a development branch.

### 4.3 Authenticode signing `[OWNER DECISION - cost]`
Recommended: Azure Artifact Signing (formerly Trusted Signing, about $9.99/month, no
hardware token, signs from GitHub Actions). Fallback: OV cert ($150-300/yr, hardware
token required since June 2023). Skip EV (no instant SmartScreen reputation since 2024).
Self-signed only works where the cert is pushed to client trust stores and does NOT
satisfy Smart App Control. Sign with `-HashAlgorithm SHA256` and an RFC 3161 timestamp;
pin `*.ps1` line endings in `.gitattributes` (any byte change breaks the signature).
What it fixes: under SAC On / WDAC, unsigned scripts run in Constrained Language Mode
where WPF and Add-Type are blocked (the GUI cannot run at all today on such a machine);
signed scripts run in Full Language Mode; lets you drop `-ExecutionPolicy Bypass` on
hardened clients. What it does NOT fix: third-party installers blocked by SAC, or anything
run via `irm | iex` (a string is never signature-checked) - so the bootstrapper must
launch the verified local signed file (1.4).

### 4.4 Non-interactive RMM/Intune mode `[OPTIONAL, large]`
`-NonInteractive -Profile <json>` on the worker: no dialogs, skip Non-Silent Installs,
stdout progress, exit codes 0 / 3010 (reboot required) / 1641 (reboot initiated) / 2
(preflight failure) / 1 (failure). SYSTEM context: resolve winget under
`C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe`
with `--scope machine`; HKCU writes go to the Default profile (1.1); re-exec via
`%windir%\Sysnative\...\powershell.exe` when not 64-bit; write
`HKLM\SOFTWARE\Gr3y\Support\LastRun` as the Intune detection rule.

### 4.5 Offline / USB kit mode `[OPTIONAL, large]`
`-KitPath` / sibling `kit\` folder: skip downloads, show "OFFLINE KIT vX built <date>";
`Build-OfflineKit.ps1` refreshes the OneDrive kit: tool files + `latest.json`, ODT
`setup.exe /download` source (3-4 GB), winget offline bundle (DesktopAppInstaller
msixbundle + License1.xml + VCLibs + UI.Xaml), `winget download` of catalog installers,
DCU/LSU offline installers. Flag catalog entries unavailable offline.

### 4.6 Trust documentation
Regenerate README from the current feature set (four tabs, one-liner `irm get.gr3y.io/debloat | iex`,
Non-Silent Installs, Config/Panels), add "Verify before you run" (signature, SHA256SUMS,
attestation), `SECURITY.md` with a disclosure contact, `CHANGELOG.md` tied to tags, and a
generated "what this changes" table from `bloat-patterns.json`, `apps-catalog.json` and
`tweaks.json` listing every registry path/value, service and task touched, and whether
each is reversible. Generate it in the release workflow.

### 4.7 Log/report shipping `[OPTIONAL]`
POST the report JSON to a Teams Workflows webhook / ntfy / Azure Blob write-only SAS when
the profile has an endpoint. No PII beyond hostname/model/serial/actions.

### 4.8 App icon
The owner offered the gr3ylabs logo (neon blue "3>" mark). Once the PNG is saved into the
kit `debloat\` folder, set `$window.Icon` from it after `XamlReader.Load` and include the
file in `latest.json`/the bootstrapper file list. (The image was pasted into chat only; no
file exists on disk yet.)

---

## 7. Do NOT do (from the research, regardless of what upstream tools offer)
- Do not port WinUtil `WPFTweaksDisableBitLocker`, `Invoke-WPFUpdatesdisable`,
  `WPFTweaksRemoveEdge` (breaks WebView2/M365 sign-in), `WPFTweaksRemoveOneDrive`,
  `WPFTweaksServices` as-is, `WPFTweaksLocation` as-is, `WPFTweaksDisableNotifications`,
  `WPFTweaksDisableIPv6`/Teredo, `WPFTweaksStorage`; Win11Debloat `-DisableStorageSense`;
  any O&O ShutUp10 item touching Windows Update, Defender/SpyNet, KMS/activation or
  settings sync.
- Do not add `MSTeams` to bloat patterns (it is the work/school client on 23H2+).
- Do not remove Quick Assist.
- Do not script default-app associations via UserChoice hashes or disable UCPD.
- Do not weaken Smart App Control or SmartScreen beyond the existing explicit opt-in toggle;
  never change `SubmitSamplesConsent`.
- Do not put tenant IDs with secrets, RMM tokens, seed passwords, API keys or BitLocker keys
  in the public repo or in the public log body.
- Do not use PS7-only syntax; do not add non-ASCII bytes; do not use backtick-escaped quotes.
- Do not rename `Gr3ysUtilities.ps1`, rewrite git history, or deploy the network-toolkit site.

---

## 8. Owner decisions needed before Sonnet starts
1. Phase 2 scope: which of 2.1-2.16 are in (2.2 reboot-resume is the big one).
2. Dell package: Universal-first with Classic fallback, or Classic only (0.5).
3. Lenovo Vantage and Dell Peripheral Manager: keep (recommended) or keep removing (0.8).
4. Where the Provisioning controls live: a group on the Debloat + Office tab or a new tab.
5. Signing: Azure Artifact Signing (~$10/month) now, later, or not (4.3).
6. Catalog: which removed entries to re-add for business, and whether "Business Baseline"
   becomes the default filter (3.11).
7. Profile storage location for secrets (OneDrive kit vs USB vs private URL) (2.3).

## 9. Suggested order of work for the implementing session
Phase 0 in numeric order (0.1-0.3 first, they are confirmed bugs), then 4.1, 1.4, 1.1,
1.2, 1.3, then the Phase 2 items the owner picked, then Phase 3, then the rest of Phase 4.
Commit after each item; sync the OneDrive canonical copy and verify hashes before every
commit; run the syntax check and the smoke test before every push.

## 10. Research sources (for the implementer's reference)
- WinUtil: https://github.com/ChrisTitusTech/winutil (config/tweaks.json, config/feature.json,
  config/applications.json, config/dns.json, functions/public/Invoke-WPFUpdatessecurity.ps1,
  Invoke-WPFUpdatesdefault.ps1, Invoke-WPFImpex.ps1, Invoke-WPFExportEnvironmentReport.ps1)
- Win11Debloat: https://github.com/Raphire/Win11Debloat (Regfiles/, Regfiles/Sysprep/,
  Regfiles/Undo/, Config/DefaultSettings.json, Scripts/Helpers/User-HiveHelpers.ps1)
- Sophia Script: https://github.com/farag2/Sophia-Script-for-Windows
- Dell Command Update CLI: https://www.dell.com/support/manuals/en-us/command-update/dcu_rg/dell-command-update-cli-commands
  and error codes: https://www.dell.com/support/manuals/en-ca/command-update/dcu_rg/command-line-interface-error-codes
- Lenovo System Update CLI: https://docs.lenovocdrt.com/guides/sus/su_dg/su_dg_ch5/
- Microsoft: BackupToAAD-BitLockerKeyProtector, Windows LAPS (laps-management-policy-settings),
  OneDrive KFM policies (sharepoint/use-group-policy), Intune bulk enrollment, Autopilot
  add-devices, Smart App Control support article, code-signing-options, Policy CSP Experience.
- MSP checklists: NinjaOne (automating-new-device-setup, standardize-device-pre-deployment),
  Datto (automating-the-build-process), Syncro community (automating-a-new-computer-setup),
  ConnectWise onboarding checklist.

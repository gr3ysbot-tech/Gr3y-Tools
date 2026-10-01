# Gr3y Tools

One-line PowerShell utilities for field IT work. Each tool is meant to be run
directly on a target machine with a single command - no manual file copying,
no keeping a USB kit in sync across every laptop.

## Gr3yLabs Tools - Debloat + Office Deploy + App Installer + Provisioning

A native Windows GUI (WPF, no browser involved): a custom dark window chrome
with the tabs, a search box, and window controls built into the title bar
itself, and a dense two-column layout instead of a typical "settings app"
look. Five tabs:

- **Debloat + Office** - removes Dell/Lenovo OEM bloatware, McAfee trialware, and
  the Windows 11 built-in consumer Teams/Chat AppX package (not the real work/
  business Teams client, which installs separately and is untouched); optionally
  disables leftover OEM scheduled tasks/services so uninstalled apps don't silently
  reappear; optionally creates a System Restore point first; fully removes any
  existing Office install; installs Microsoft 365 Apps for business, with optional
  `ExcludeApp` checkboxes (Teams, OneDrive, Access, Publisher, Skype for Business,
  OneNote) and a Shared Computer Activation option. Live log streaming, a
  CPU-activity heartbeat across the whole process tree so you can tell it's still
  working, Stop/Reboot buttons, and a log download for later reference (logs are
  also saved locally at `C:\ProgramData\DellOfficeDeploy\`, named with the
  machine's hostname/manufacturer/model/serial tag so they're identifiable later
  across many different client laptops).
- **Install Apps** - a categorized app catalog (Browsers, Microsoft
  Tools, Documents, Communications, Utilities, Non-Silent Installs) backed by
  winget, with search, category filters, select-all/clear (with a confirmation
  when selecting across every category at once), and install/uninstall/
  upgrade-all actions. Entries known to be unsigned/low-reputation are flagged and
  trigger a warning before install if Smart App Control is On. The catalog lives
  in [`debloat/apps-catalog.json`](debloat/apps-catalog.json) - edit that file to
  add, remove, or rename entries; every future run picks up the change
  automatically, no code edits needed.
- **Config** - one-click Fixes (System File Repair, Network Reset, Windows Update
  Reset, Time Resync, .NET Framework 3.5 Enable, winget re-registration), each run
  standalone with its own log; Customize Preferences, a live-reflecting toggle
  list of opt-in registry tweaks driven by
  [`debloat/tweaks.json`](debloat/tweaks.json) (telemetry, Copilot/Recall/AI,
  Edge/Office first-run nags, Defender hardening, DNS-over-HTTPS presets, and
  more - see [`docs/what-this-changes.md`](docs/what-this-changes.md) for the
  full list); and Revert Last Run, which undoes the most recent run's
  tweak/DNS/power/Defender-preference changes from an automatically saved
  snapshot (OEM/AppX/Office removal and Smart App Control are one-way by design
  and are never covered by this).
- **Panels** - one-click launchers for the Windows settings pages, management
  consoles (Device Manager, Disk Management, Services, Task Scheduler, Event
  Viewer, Local Users and Groups, Windows Firewall) and diagnostic commands
  (`msinfo32`, `dxdiag`, `dsregcmd /status`, an elevated PowerShell prompt) a
  field tech reaches for most often.
- **Provisioning** - client-profile fields (save/load as a portable JSON file, to
  either OneDrive or a USB drive, so a batch of laptops for the same client can
  reuse the same settings); hostname rename from a configurable pattern; OneDrive
  Known Folder Move; a regional/power/lock-screen baseline (time zone, region,
  power plan, lock timeout); OEM driver/BIOS updates (Dell Command Update or
  Lenovo System Update, detected automatically); Windows Update to completion
  (loops through every available update, resuming automatically across reboots
  via a scheduled task, up to 4 passes); a validation report and handoff package
  (activation, Defender, firewall, pending-reboot and disk-space checks plus a
  machine inventory, written as an HTML report); and a post-provisioning cleanup
  step (temp folders, Windows Update download cache, ODT install cache, Disk
  Cleanup, component-store cleanup).

Run from an elevated or non-elevated PowerShell prompt (it self-elevates, one UAC
prompt, and switches to STA if needed - both handled automatically). If run under
PowerShell 7 (`pwsh`), it re-launches itself under Windows PowerShell 5.1
(`powershell.exe`), which is the only runtime this tool is verified against:

```powershell
irm get.gr3y.io/debloat | iex
```

### Verify before you run

`debloat.ps1` (the one-liner above) fetches `latest.json` from this repo, which
pins an exact commit SHA and lists the expected SHA256 hash of every tool file at
that commit. Every file is downloaded from that same immutable commit (not a
moving branch reference), hashed, and compared before anything runs - if any
file doesn't match, the bootstrap aborts and nothing executes. This guarantees
the files you get are exactly what that commit's manifest says they should be.

**What this does not protect against:** a compromised GitHub account publishing a
bad commit and a matching manifest together. This tool is not currently
Authenticode-signed - there's no publisher signature to verify independently of
GitHub itself, and a machine with Smart App Control On or under WDAC enforcement
in Constrained Language Mode will not be able to run the GUI (WPF and `Add-Type`
are blocked in that mode). Signing is a known gap, tracked for a future release.

If you want to pin a specific known-good version instead of whatever is
currently on `main`, pass `-Ref`:

```powershell
$script = irm get.gr3y.io/debloat
& ([scriptblock]::Create($script)) -Ref v1.2.0
```

Source: [`debloat/Deploy-DellOfficeSetup.ps1`](debloat/Deploy-DellOfficeSetup.ps1)
(the worker script, runnable standalone from the command line too) and
[`debloat/Gr3ysUtilities.ps1`](debloat/Gr3ysUtilities.ps1) (the GUI).
`debloat.ps1` at the repo root is the one-line entry point - it downloads the
current version of every tool file (worker script, GUI, app catalog, bloat
patterns, tweaks) from a single pinned commit and launches the GUI. A secondary
browser-based control panel, [`debloat/WebApp.ps1`](debloat/WebApp.ps1), is also
kept in the repo as an alternative if the native GUI ever can't run on a given
machine.

See [`docs/what-this-changes.md`](docs/what-this-changes.md) for a generated
reference of every registry path/value, service, scheduled task, and catalog
entry this tool can touch, and whether each is reversible.

## Contributing

See [`SECURITY.md`](SECURITY.md) for how to report a security issue, and
[`CHANGELOG.md`](CHANGELOG.md) for release history.

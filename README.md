# Gr3y Tools

One-line PowerShell utilities for field IT work. Each tool is meant to be run
directly on a target machine with a single command - no manual file copying,
no keeping a USB kit in sync across every laptop.

## Gr3y's Utilities - Debloat + Office Deploy + App Installer

A native Windows GUI (WPF, no browser involved) with two tabs:

- **Debloat + Office** - removes Dell/Lenovo OEM bloatware, McAfee trialware, and
  the Windows 11 built-in consumer Teams/Chat AppX package (not the real work/
  business Teams client, which installs separately and is untouched); optionally
  disables leftover OEM scheduled tasks/services so uninstalled apps don't silently
  reappear; optionally creates a System Restore point first; fully removes any
  existing Office install; installs Microsoft 365 Apps for business (en-us). Live
  log streaming, a CPU-activity heartbeat across the whole process tree so you can
  tell it's still working, Stop/Reboot buttons, and a log download for later
  reference (logs are also saved locally at `C:\ProgramData\DellOfficeDeploy\`,
  named with the machine's hostname/manufacturer/model/serial tag so they're
  identifiable later across many different client laptops).
- **Install Apps** - a WinUtil-style categorized app catalog (Browsers, Microsoft
  Tools, Utilities) backed by winget, with search, category filters, select-all/
  clear, and install/uninstall/upgrade-all actions. The catalog lives in
  [`debloat/apps-catalog.json`](debloat/apps-catalog.json) - edit that file to add,
  remove, or rename entries; every future run picks up the change automatically,
  no code edits needed.

Run from an elevated or non-elevated PowerShell prompt (it self-elevates, one UAC
prompt, and switches to STA if needed - both handled automatically):

```powershell
irm https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/main/debloat.ps1 | iex
```

Source: [`debloat/Deploy-DellOfficeSetup.ps1`](debloat/Deploy-DellOfficeSetup.ps1)
(the worker script, runnable standalone from the command line too) and
[`debloat/Gr3ysUtilities.ps1`](debloat/Gr3ysUtilities.ps1) (the GUI).
`debloat.ps1` at the repo root is the one-line entry point - it downloads the
current version of all three files (worker script, GUI, app catalog) and launches
the GUI. A secondary browser-based control panel, [`debloat/WebApp.ps1`](debloat/WebApp.ps1),
is also kept in the repo as an alternative if the native GUI ever can't run on a
given machine.

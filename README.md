# Gr3y Tools

One-line PowerShell utilities for field IT work. Each tool is meant to be run
directly on a target machine with a single command - no manual file copying,
no keeping a USB kit in sync across every laptop.

## Debloat + Office Deploy

Removes Dell/Lenovo OEM bloatware and McAfee trialware, fully removes any existing
Office install, and installs Microsoft 365 Apps for business (en-us). Controlled
through a local browser control panel with live log streaming, a CPU-activity
heartbeat so you can tell it's still working, Stop/Reboot buttons, and a log
download for later reference.

Run from an elevated or non-elevated PowerShell prompt (it will self-elevate,
one UAC prompt, if needed):

```powershell
irm https://raw.githubusercontent.com/gr3ysbot-tech/Gr3y-Tools/main/debloat.ps1 | iex
```

This opens `http://localhost:8787` in the default browser. Pick options, click
Start, watch it run. Logs are saved locally on the target machine at
`C:\ProgramData\DellOfficeDeploy\`, named with the machine's hostname, manufacturer,
model and serial/service tag so they're identifiable later when pulled from many
different client laptops.

Source: [`debloat/Deploy-DellOfficeSetup.ps1`](debloat/Deploy-DellOfficeSetup.ps1)
(the actual worker script, runnable standalone) and
[`debloat/WebApp.ps1`](debloat/WebApp.ps1) (the control panel).
`debloat.ps1` at the repo root is the one-line entry point - it downloads the
current version of both files and launches the control panel.

# Changelog

All notable changes to Gr3y Tools are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). There are no numbered
releases: every push to `main` that passes CI republishes `latest.json`
(version is always `beta`), so entries are grouped by date. Identify a build by
the 7-character commit shown in the window title. (Tags `v1.0.0`-`v1.0.13` and
GitHub Releases `v1.0.0`-`v1.0.6` predate this model and are not maintained.)

## [Unreleased]

The current state of `main` reflects the core of `docs/improvement-plan.md`
phases 0-3 and part of phase 4 (optional items were deliberately not built):

### Added

- **Guest-code expiry and codes you choose.** In **Manage Access Codes...** a code can expire
  on its own (1 hour, 8 hours, 1 day, 7 days, 30 days, never, or a custom number of hours), the
  new **Expires** column shows when, and an expired code is listed as *Expired* for a week. You
  can pick the code yourself (4-32 letters or digits, e.g. `9989`) instead of a random one, and
  **Edit Code...** changes the code text, its expiry, or both at any time - the old code stops
  working. A code under 8 characters must expire within 24 hours (it can be guessed), and the
  relay now slows down a connection that keeps sending wrong access codes (20 refused codes in
  10 minutes, then it waits; the admin code is never blocked). Needs the updated Worker
  (`cloudflare/export-relay-worker.js`); with the old Worker the app says so, takes back the
  random never-expiring code that Worker makes, and creates nothing.
- Moving a user to a replacement machine: **Export Installed Apps...** (saves a
  JSON inventory) and **Compare Against List...** on the Install Apps tab. The
  new machine takes the old machine's list by a one-time **pairing code**, an
  exported JSON file, or a pasted plain-text list, then checks every catalog app
  that is installed on the old machine but missing here (a Compare Results
  filter); apps already installed here are listed and not re-offered.
- A standalone `debloat/Export-InstalledApps.ps1` (`irm get.gr3y.io/debloat-export
  | iex`) for exporting from a machine with no GUI access (print JSON, save a
  file, or send to a pairing code).
- An **access-gated pairing relay** (Cloudflare Worker + KV, source in
  `cloudflare/`): pairing requires an access code (an admin code, or a guest code
  managed in-app from **Manage Access Codes...**); the old machine's side needs
  no code. File and command-line compare are unaffected.
- A "Manual Install Only" catalog category for apps with no installer
  (`url`-only entries; the `(?)` link opens the vendor page).
- Config -> **Hardware Lifecycle**: a Dell replacement-eligibility check (service
  tag -> ship date via the Dell TechDirect API -> repair / toss-up / replace).
  Dell only; needs TechDirect API credentials.
- Provisioning: BitLocker enable / prevent automatic device encryption,
  break-glass local admin + Windows LAPS, local-administrator cleanup; Panels:
  read-only BitLocker status with recovery-key save.
- Native WPF GUI (`Gr3ysUtilities.ps1`) with five tabs: Debloat + Office,
  Install Apps, Config, Panels, and Provisioning.
- One-line pinned/verified bootstrap (`debloat.ps1`, `irm get.gr3y.io/debloat
  | iex`) - downloads every tool file from a single immutable commit and
  verifies SHA256 hashes against `latest.json` before running anything.
- OEM bloatware removal for Dell and Lenovo, McAfee trialware removal,
  consumer Teams/Chat AppX removal (not the real work/school client).
- Microsoft 365 Apps for business deployment via the Office Deployment Tool,
  with `ExcludeApp` checkboxes and Shared Computer Activation.
- A winget-backed app catalog (Browsers, Microsoft Tools, Documents,
  Communications, Utilities, Non-Silent Installs) with category filters
  (Business Baseline default) and a Select-All confirmation guard.
- 46 opt-in, reversible registry tweaks (telemetry, Copilot/Recall/AI,
  Edge/Office first-run nags, Defender hardening, DNS-over-HTTPS presets,
  small office quality-of-life toggles, and more) driven by `tweaks.json`.
- Revert Last Run: an automatic undo snapshot covering the most recent run's
  tweak/DNS/power/Defender-preference changes.
- A Provisioning tab: client-profile save/load, hostname rename, OneDrive KFM,
  regional/power/lock baseline, OEM driver/BIOS updates, Windows Update to
  completion (with reboot-resume), a validation report and handoff package,
  and post-provisioning cleanup.
- 36 Panels-tab quick launchers for common Windows settings pages, management
  consoles, and diagnostic commands.
- Smart App Control awareness: a live status indicator, a warning before
  installing catalog entries known to be unsigned/low-reputation while SAC is
  On, and an informational note about SAC's diagnostic-data dependency.
- `docs/what-this-changes.md`, generated from the three catalog/tweak JSON
  files via `debloat/Generate-ChangesReference.ps1` (regenerated automatically
  by CI on every push to `main`).
- CI (`.github/workflows/ci.yml`): lint (ASCII/LF + PSScriptAnalyzer
  compatibility), Pester tests, Worker relay tests, and an `update-manifest` job
  that republishes `latest.json` on every passing push to `main`.

### Fixed

- **Tweaks and baselines no longer empty registry keys that already exist.** The engine
  made sure a key existed with `New-Item -Path <key> -Force`, which on an existing key
  deletes every value and subkey in it (checked on Windows PowerShell 5.1 and 7) before
  the one value was written. So the Customize Preferences tweaks, telemetry reduction,
  the Regional/power/lock baseline, OneDrive Known Folder Move, the LAPS and Lenovo
  System Update policy, Smart App Control, the Office first-run policy and *Prevent
  Automatic Device Encryption* could wipe other settings in keys such as
  `Policies\System` (UAC and logon policy), `Session Manager\Power`, `Control Panel\Desktop`,
  `Explorer\Advanced` or a managed machine's Edge/Office policies. Keys are now created
  only when missing (`Confirm-RegistryKey`), and a test keeps the pattern from coming back.
  Keys that an earlier run already emptied are not restored by this change.
- Windows PowerShell 5.1 could mangle non-ASCII program names when sending or
  receiving the export (a charset-less `application/json`); requests and the
  relay's responses now declare `charset=utf-8`.
- Compare Against List no longer lists already-installed catalog apps as
  "install manually"; a false "Saved" message and truncated console output from
  the export were also fixed.
- Found by driving the real GUI through UI Automation (Windows PowerShell 5.1):
  - **Manage Access Codes** showed a phantom blank row for an empty list, merged
    two or more codes into one garbled row (whose Switch/Delete then failed), and
    turned a row into the text `System.Windows.Controls.ListBoxItem` after
    Switch Off/On. Both were 5.1-only quirks the unit tests could not see.
  - A pasted access code containing a typographic dash (non-breaking hyphen,
    en-dash) or an invisible character failed as "could not reach the pairing
    relay" and stayed that way until the GUI was restarted. Codes are now cleaned
    up (look-alike dashes back to `-`, invisible characters dropped) and a code
    that still cannot be sent re-prompts with an explanation.
  - **Stop** during a scan or install was overwritten by a false "Done" status and
    threw dozens of hidden errors; **Compare** against an empty `winget list`
    ticked apps that were already installed; with exactly one app ticked the
    counter read "Selected: " with no number; a second Compare kept the first
    run's ticks and labels; a double activation of **Compare Against List...**
    stacked two dialogs.
  - Smaller: the pairing command box clipped the end of the command (the part
    with the code) - it now wraps; an empty OK in the access-code prompt closed it
    silently; prompt titles; a non-numeric "HTTP 0" in status text; a minimal
    export (no hostname or winget list) showed "1 winget app(s)"; the new code is
    scrolled into view; accessible names for list rows and the two chooser
    buttons; shorter relay timeouts so a relay that never answers freezes the
    window for seconds, not tens of seconds.

### Known gaps

- No Authenticode signing yet (tracked as improvement-plan item 4.3) - a
  machine with Smart App Control On or under WDAC Constrained Language Mode
  cannot run the GUI.

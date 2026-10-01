# Changelog

All notable changes to Gr3y Tools are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project doesn't
yet use Semantic Versioning tags (no release has been cut yet - `main` is the
only line), so entries are grouped by date instead of a version number until
the first tagged release.

## [Unreleased]

The current state of `main` reflects the full implementation of
`docs/improvement-plan.md` phases 0-3 and part of phase 4:

### Added

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
- 22 Panels-tab quick launchers for common Windows settings pages, management
  consoles, and diagnostic commands.
- Smart App Control awareness: a live status indicator, a warning before
  installing catalog entries known to be unsigned/low-reputation while SAC is
  On, and an informational note about SAC's diagnostic-data dependency.
- `docs/what-this-changes.md`, generated from the three catalog/tweak JSON
  files via `debloat/Generate-ChangesReference.ps1`.

### Known gaps

- No Authenticode signing yet (tracked as improvement-plan item 4.3) - a
  machine with Smart App Control On or under WDAC Constrained Language Mode
  cannot run the GUI.
- No CI/automated release pipeline yet (tracked as item 4.2) - releases,
  `SHA256SUMS`, and regenerating `docs/what-this-changes.md` are all manual
  for now.

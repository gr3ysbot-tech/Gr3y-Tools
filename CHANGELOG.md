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

- **Disable BitLocker... (Panels tab).** A guarded way to turn BitLocker off on any drive, in
  the order you asked for: it shows every drive's status first, then saves a backup of every
  key Windows can export (recovery passwords, key IDs, a note on each other protector, and
  Windows' own `manage-bde` output - not a PIN, a typed password or a `.BEK` file, which Windows
  cannot hand back) to a file you choose, reads the file back and checks it (including that
  each recovery password is well-formed) - and only then does the button that decrypts the
  ticked drives become available. Nothing is ever ticked for you, and a tick stays with the
  drive you ticked, not with its letter: each row remembers its drive's key IDs, size, type and
  (when Windows tells it) volume ID, and a different drive that takes over the letter (a stick
  swapped while a message box is open, or between two refreshes) is unticked and refused - on
  Refresh, at both buttons, before a recovery password is added, and again for each drive just
  before it is decrypted. The progress follower goes by size, type and volume ID too: a drive
  that was pulled and replaced by a different one is reported as gone, not as "finished" (a
  drive is reported as finished once, and only while no other drive has its letter), and an
  unplugged drive that comes back is only taken up again when its volume ID proves it is the
  same one; what the person was told when a decrypt started (auto-unlock keys cleared, a setting
  that could not be written) is kept in the status shown when the drives finish. The backup is checked
  again right before each drive is decrypted (a USB stick can be pulled, or a key added, while
  the confirmation box is open). The file is created and held locked while its permissions are
  restricted and the keys are written, an existing file is never overwritten, and a file that
  cannot be restricted on an NTFS drive is deleted instead of being left readable by others. A
  place that deserves a second thought - a drive about to be decrypted, an encrypted drive,
  OneDrive - is asked about BEFORE the keys are written there. Extras: it offers a USB stick or
  other unencrypted drive for the backup; offers (default No) to add a recovery password to a
  drive that has none; decrypts data drives before the Windows drive; clears the stored
  auto-unlock keys that stop Windows decrypting the Windows drive (and says which drives will
  then ask for a password, and that the keys of drives that are not plugged in are cleared too);
  can tell Windows not to turn device encryption back on by itself (only once the Windows
  drive's decryption has started, and never by rewriting the registry key); refuses while a
  Debloat, Fixes, install or Provisioning job is running; warns about battery power and
  policy/MDM that may re-enable encryption; and shows progress with the time each drive took and
  a rough time left. Locked, hardware-encrypted, wiping, paused and already-decrypting drives
  are listed but not offered, with the reason. A volume BitLocker cannot read is said to be
  missing from the backup, on screen and in the file. Nothing here turns BitLocker on, and no
  recovery password is ever written to a log or a message box. What was done is recorded in
  `bitlocker-actions.log` (in `C:\ProgramData\Gr3yTools-audit`, writable only by
  administrators, when the app runs elevated).
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
- OEM bloatware removal for Dell and Lenovo, McAfee software removal (every McAfee* program),
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

- **Debloat: the Dell/OEM removal (Phase 1) now checks what it did and says what stayed.** On a Dell
  Vostro 16 the owner reported "nothing was removed"; the run ended "Run complete with 5
  warning(s)/error(s)" - four from the Store-app step and one about Dell Pair - and said nothing about
  SupportAssist, Optimizer or Digital Delivery. The old engine threw every uninstaller's exit code
  away and never looked at the Apps list afterwards, so a failed uninstall looked exactly like a
  successful one. **Why SupportAssist stayed is not known** (the laptop was then cleaned by hand and
  cannot be examined), and **this change has not yet run on real Dell hardware**; the next run logs
  every command and exit code, so a failure names itself. What the log did show, and what is fixed:
  - Store apps: de-provisioning ran AFTER `Remove-AppxPackage -AllUsers`, which most likely had
    deleted the staged files DISM needs (four "cannot find the file/path" warnings). Now it runs
    first, the removal follows, and both lists are read again; a list that cannot be read is not
    taken for an empty one, and an app is one app although the installed and the provisioned list
    spell its package name differently; one that stays is named by the package that is left (the
    staged bundle may stay when the installed package went).
  - Dell Pair was skipped as "could not resolve an uninstaller" - its registry command is an unquoted
    path with spaces (Dell Peripheral Manager is expected to look the same). The parser handles it now
    (also `.bat`/`.cmd`/`.com`, upper-case extensions, quoted whole commands, `%VARIABLES%`). A command
    that starts with a bare program name (`rundll32.exe`, `cmd.exe`, `powershell.exe`) is resolved to
    the file in the Windows folder; a program found only in another PATH folder is not run on the
    strength of a registry string.
  - Dell Optimizer's InstallShield wrapper ran for 190 s with no silent switch and exited by itself;
    whether it removed Optimizer is not known. It now gets `-remove -runfromtemp /Silent` (from a Dell
    sample script that is marked as a test) and 7 minutes.
  - Every program was tried up to four times, once per matching pattern and installer layer. Now there
    is one record per program with all its layers, run in the order WiX bundle, InstallShield wrapper,
    MSI, plain EXE.
  - What the engine does now: every command line and exit code is logged and classified (success,
    restart needed, nothing to remove, Windows Installer busy, a restart from an earlier installation
    pending, cached installer missing, blocked by policy, hung, failed). A success is believed only when
    the program has left the Apps list, and a last look at the list corrects the report both ways (a
    program that went away late is not NOT REMOVED; one that is listed again is not removed).
    Windows Installer is waited for before an MSI or a bundle (about 10 minutes in all for an
    installer that is busy for good; one wait of up to 2 minutes is not cut short).
  - Direct MSI removals pass `IGNOREDEPENDENCIES=ALL`. A Burn bundle passes it to its MSIs as well, but
    only after its own check of what depends on them; this tool makes no such check, so Dell Core
    Services keeps its dependency check on. A WiX dependency check can make a quiet MSI uninstall end
    in exit 0 with nothing removed; that has not been observed on Dell's own MSIs.
  - Before an uninstaller runs, the product's services are stopped (with a 30-second deadline: Windows
    PowerShell's `Stop-Service` waits for ever on a service stuck stopping) and set to Disabled, its
    processes are ended (`productHints` in `bloat-patterns.json`), and so is whatever runs from the
    program's own folder when its Apps entry registers one - never this worker, a PowerShell host,
    msiexec, the Windows folder, Dell Command | Update or the product's own uninstaller. The log says
    what each service was set to. If the program then stays, its services stay Disabled, and its NOT
    REMOVED line says so and how to undo it (and says when a service could not be stopped and is still
    running); a service that one program disabled is named in the line of every later program of the
    run that shares it and stays. Phase 1b (leftover services and scheduled tasks) uses
    the same bounded stop, logs what each service is set to, leaves one that is stopped and disabled
    already alone, and now warns when a service cannot be stopped.
  - An installer that has not finished after its limit (10 minutes for an MSI or a bundle, 4 for a
    wrapper, 5 for any other uninstaller, 7 for Optimizer's own) is stopped together with its child
    processes and the program is reported as NOT REMOVED; what Windows Installer does with an
    interrupted transaction is not known.
  - Retries: a failed pass is followed by one more, with the services and processes stopped again. A
    layer that hung, could not be started, lost its cached installer, is blocked by a policy or said
    "not installed" is not asked again. A layer that said "restart first" is not asked again and no
    second look at the other programs is taken, but the product's other layers still get their normal
    second try. A plain failure is run up to three times (two passes plus the second look), and the
    NOT REMOVED line counts the tries of both looks. A second look at a program whose runnable layers
    all hit a wall starts nothing and is not announced.
  - An Apps entry is cleared only as a PROVEN leftover: its uninstaller FILE is gone, or an MSI or an
    InstallShield wrapper says "not installed" (1605/1614; a bundle that says it is reported, not
    cleared), AND the entry registers something that can be looked at - its install folder, the
    folder its uninstaller sat in (unless that is an installer cache), an icon file that is not a
    Windows file, a service named in the product hint - AND none of it is found. A folder counts only
    if it holds something (an empty one is what an uninstaller leaves behind); a location on a
    network share or on a drive this session cannot see, and a command that starts with a bare
    program name that cannot be found, cannot be judged and count as "still there". An entry that
    registers nothing to look at is kept and reported with its registry key, so that it can be
    removed by hand (7 of the 9 Windows Installer products on the development PC register no folder
    or icon file at all, so for them "nothing found" would mean nothing). An entry that was merely
    not listed for a moment is never cleared, and the uninstaller file is looked at once more right
    before the delete. Each key gets its own `.reg` backup in the work folder, which the 30-day
    clean-up keeps. It is counted as "leftover Apps entry cleared" unless an uninstaller of the same
    program ran successfully. A command that cannot be read, or a program that still seems to be
    installed, is reported and never deleted.
  - Everything that stays is a `NOT REMOVED` warning with the exit code (none for a hang, an
    unreadable command or a Store app); for an MSI also the failing action or error read from its
    verbose log (or the newest Application-log error), for a bundle the path of its own log (these
    logs are kept for a program that stays and deleted for one that is gone, after the last look at
    the Apps list), and a closing hint. A restart that is already pending is reported up front (a
    Burn bundle whose own earlier run asked for a restart does nothing and exits 350). The finish
    banner counts warning lines, not programs: a run in which every program was removed can still end
    "with N warnings", and a "Nothing that was targeted is left" line says so when that is all they
    were. A dry run prints the command of each uninstaller and the services and processes it would
    stop. A note says when Dell Command | Update is installed and can bring removed programs back.
  - Kept as before - for the owner to decide: the default patterns. `Dell SupportAssist*` also matches
    Dell SupportAssist for Business PCs, `McAfee*` every McAfee program, and `Dell Core Services`,
    `Waves MaxxAudio*` and `MaxxAudioPro*` stay; the research recommended making Dell Core Services and
    MaxxAudio opt-in instead. Before this change those removals could not be told from failures, now
    they really happen (see "Judgement calls" in `docs/what-this-changes.md`; the confirmation box
    before a run now says that SupportAssist for Business PCs and managed McAfee are included). No
    forced clean-up after the vendor attempts fail, and no automatic Dell Command | Update configuration.
  - New lint rules reject a function defined twice in one script and a malformed or over-broad
    `productHints` entry.
- **Create Break-Glass Admin works on Windows PowerShell 5.1.** It generated the password
  with `RandomNumberGenerator.Fill`, which .NET Framework does not have, so on the host the
  app always uses the step failed before it created the account, set the LAPS policy or wrote
  the credential file. The password now comes from `RandomNumberGenerator.Create().GetBytes`
  (same 24-character set, drawn again until it has three character classes, so a complexity
  policy cannot refuse it).
- **The 30-day clean-up of the work folder no longer deletes the break-glass credential file
  or the Revert Last Run snapshots.** On a PC that is not Entra-joined that file is the only
  copy of the password, and without its snapshot Revert Last Run silently stopped working
  after 30 days. The Create Break-Glass confirmation now says where the file is and that the
  app never deletes it.
- **Enable BitLocker (Provisioning) no longer lets the new recovery password reach the run
  log.** `Add-BitLockerKeyProtector` prints the password in the warning stream, which the run
  transcript - and so the log the app can zip - kept. The warning is now silenced; the
  password stays readable from Windows (Panels > BitLocker status, or `manage-bde`).
- **Tweaks and baselines no longer empty registry keys that already exist.** The engine
  made sure a key existed with `New-Item -Path <key> -Force`, which on an existing key
  deletes every value and subkey in it (checked on Windows PowerShell 5.1 and 7) before
  the one value was written. So the Customize Preferences tweaks, telemetry reduction,
  the Regional/power/lock baseline, OneDrive Known Folder Move, the LAPS and Lenovo
  System Update policy, Smart App Control, the Office first-run policy and *Prevent
  Automatic Device Encryption* could wipe other settings in keys such as
  `Policies\System` (UAC and logon policy), `Session Manager\Power`, `Control Panel\Desktop`,
  `Explorer\Advanced` or a managed machine's Edge/Office policies. Keys are now created
  only when missing (`Confirm-RegistryKey`, parents included), and a test keeps the
  pattern from coming back. The same bug also made a tweak that sets several values in one
  key keep only the last one (10 of the 46 tweaks, 52 of their 125 values); all of them now
  apply. OneDrive Known Folder Move sets exactly the folders you choose (an opt-in an
  earlier run left for a folder you did not choose is removed). Keys that an earlier run
  already emptied are not restored by this change.
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

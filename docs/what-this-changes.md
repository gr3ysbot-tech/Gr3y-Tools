# What This Changes

Generated from `debloat/bloat-patterns.json`, `debloat/apps-catalog.json` and
`debloat/tweaks.json` by `debloat/Generate-ChangesReference.ps1`. Regenerated
automatically by CI (`.github/workflows/ci.yml`) on every push to main and committed
back - no manual step needed for a day-to-day edit to those files.

## OEM Bloatware Removal

One-way - not covered by Revert Last Run. Applied for each OEM that is ticked in the GUI (Dell
and Lenovo both start ticked) or passed as `-Dell` / `-Lenovo`. If neither is passed - which is
also what unticking BOTH GUI boxes does - the worker takes it as both; tick Skip debloat to run no
OEM removal at all. The generic list below (McAfee, Dropbox and WildTangent promos, the consumer
Teams/Chat package, the Web Experience pack) applies on every Phase 1 run. The machine's
manufacturer and model are NOT checked. (The "commercial hardware" check applies only to
installing Dell Command | Update / Lenovo System Update.)

**Judgement calls.** These are removed by default, whatever the organisation uses; delete the
pattern from `debloat/bloat-patterns.json` to keep one. `Dell SupportAssist*` and the service
pattern `*SupportAssist*` also match Dell SupportAssist for Business PCs and its service.
`Waves MaxxAudio*` and `MaxxAudioPro*` are audio software: users report that removing it can cost
headphone-jack and microphone detection. `Dell Core Services` is a shared Dell component (Dell's
own knowledge base says other Dell agents can go into an Unknown State when it is removed): it is
removed without `IGNOREDEPENDENCIES`, so that a dependency check in its installer, where it has
one, can keep it while other software depends on it (not verified for this package, and it then
ends as a NOT REMOVED warning). `McAfee*` matches every McAfee program, trial, paid or centrally
managed. Dell Command | Update is kept.

**How a program is removed.** Its own uninstaller is run and the result is checked against the
Apps list; a program counts as removed only when it has really left that list.

- A Windows Installer product is removed with `msiexec /x <product code> IGNOREDEPENDENCIES=ALL
  /qn /norestart`, a WiX Burn bundle with its own `/uninstall /quiet /norestart`. (A Burn bundle
  passes `IGNOREDEPENDENCIES=ALL` to its MSIs itself, but only after checking what depends on
  them; this tool makes no such check, so a product marked as shared keeps the check on.)
- Before the uninstaller runs, the services and processes listed under "Per-program hints" below are
  stopped - the services are also set to Disabled, and the log says what each was before - and
  anything running from the program's own folder (when its Apps entry registers one) is ended;
  never Dell Command Update, the Windows folder, a PowerShell host or the installer itself.
- An installer that has not finished after its time limit - 10 minutes for a Windows Installer
  product or a bundle, 4 for an InstallShield wrapper, 5 for any other uninstaller, or the limit
  named below - is stopped together with its child processes, and the program is reported as NOT
  REMOVED. What Windows Installer does with an interrupted transaction is not known.
- An Apps entry is deleted only when it is a proven leftover: its uninstaller file is gone, or an MSI
  or InstallShield-wrapper layer answers "not installed" (a bundle that does is reported, not cleared),
  AND the entry declares something that can be looked at - an install folder, the folder its uninstaller
  sat in, an icon file that is not a Windows file, a service named in the hints - AND none of it is
  found (a folder counts only if it holds something; a network share or a drive this session cannot see
  cannot be checked and counts as "still there"). An entry that declares nothing to look at is kept and
  reported, with its registry key, so that it can be removed by hand. A cleared entry is counted as
  "leftover Apps entry cleared", not as a removed program - unless an uninstaller of the program ran
  successfully. A .reg backup of the deleted entry is saved first in
  `C:\ProgramData\DellOfficeDeploy` and is never deleted by the tool.
- A program that stays is listed as NOT REMOVED with the exit code and, where there is one, the
  installer's own message or log. Its services that were set to Disabled stay Disabled; the line
  says which, and how to undo it. A dry run lists the programs, the command of each uninstaller and
  the services and processes it would stop, and changes nothing.
- The finish banner counts warning lines, not programs: a run in which every program was removed
  can still end "with N warnings" (a failed first attempt counts). The "Phase 1 result" line says
  how many programs are really gone, and a "Nothing that was targeted is left" line says so when
  that is all the warnings were.

### dell

**AppX packages removed:**

- `DellInc.DellSupportAssistforPCs`
- `DellInc.DellOptimizer*`
- `DellInc.PartnerPromo*`
- `DellInc.DellCustomerConnect`
- `DellInc.MyDell`
- `DellInc.DellDigitalDelivery`
- `DellInc.DellProductRegistration`
- `DellInc.DellPremierColor`
- `DellInc.DellCinemaColor`
- `DellInc.DellPowerManager`
- `DellInc.DellPeripheralManager`
- `DellInc.DellPair`
- `DellInc.DellMobileConnect`
- `DellInc.PrivacyandSecurity`

**Win32 programs uninstalled:**

- `Dell SupportAssist*`
- `Dell SupportAssist Remediation`
- `Dell SupportAssist OS Recovery*`
- `Dell Optimizer*`
- `Dell Digital Delivery*`
- `Dell Product Registration`
- `Dell Peripheral Manager*`
- `Dell Mobile Connect*`
- `Dell Pair`
- `Dell Core Services`
- `Waves MaxxAudio*`
- `MaxxAudioPro*`

**Per-program hints: the services and processes are stopped before the matching program is uninstalled (the services are also set to Disabled, so that they should not restart in the middle of it); a silent switch and a time limit apply to the uninstaller itself:**

- `Dell SupportAssist*`: services `*SupportAssist*`; processes `SupportAssist*`, `DellSupportAssistRemedationService`
- `Dell Optimizer*`: services `Dell Optimizer*`; processes `DellOptimizer`; its uninstaller is run with `-remove -runfromtemp /Silent`; its own uninstallers (not the Windows Installer product) get a time limit of 7 minutes
- `Dell Digital Delivery*`: services `Dell Digital Delivery*`; processes `Dell.D3.WinSvc`
- `Dell Peripheral Manager*`: processes `DPM`, `DPMService`

**Kept while other software depends on them (uninstalled without `IGNOREDEPENDENCIES`; reported as NOT REMOVED when that stops the uninstall):**

- `Dell Core Services`

**Services stopped and disabled (every match, whether or not its program was removed - a program that could not be uninstalled stays installed with its service Disabled; undo with `Set-Service -Name <name> -StartupType <the type it had before - the log says which>`):**

- `*SupportAssist*`
- `*Dell Digital Delivery*`
- `*Dell Optimizer*`

**Scheduled task folders disabled (every task in them except the ones kept below, whether or not its program was removed; they are disabled, not deleted - undo in Task Scheduler):**

- `\Dell\`

**Explicitly kept even inside a disabled folder above:**

- `*CommandUpdate*`

### lenovo

**AppX packages removed:**

- `E046963F.LenovoNow`
- `E046963F.LenovoWelcome`
- `E046963F.LenovoVoice`
- `E046963F.LenovoFamilyCloud`
- `E046963F.LenovoUtility`
- `E046963F.LenovoServiceBridge`
- `MirametrixInc.GlancebyMirametrix`

**Win32 programs uninstalled:**

- `Lenovo Now`
- `Lenovo Welcome`
- `Lenovo Voice`
- `Lenovo Family Cloud`
- `Lenovo Utility*`
- `Lenovo Service Bridge`
- `Glance by Mirametrix*`

**Services stopped and disabled (every match, whether or not its program was removed - a program that could not be uninstalled stays installed with its service Disabled; undo with `Set-Service -Name <name> -StartupType <the type it had before - the log says which>`):**

- `*Lenovo Now*`
- `*Lenovo Welcome*`
- `*Lenovo Voice*`
- `*Lenovo Family Cloud*`
- `*Lenovo Utility*`
- `*Lenovo Service Bridge*`

**Scheduled task folders disabled (every task in them except the ones kept below, whether or not its program was removed; they are disabled, not deleted - undo in Task Scheduler):**

- `\Lenovo\`

**Explicitly kept even inside a disabled folder above:**

- `*Vantage*`
- `*ImController*`

### generic

**AppX packages removed:**

- `*Dropbox*`
- `*McAfee*`
- `*WildTangent*`
- `MicrosoftTeams`
- `MicrosoftWindows.Client.WebExperience`

**Win32 programs uninstalled:**

- `Dropbox Promotion`
- `McAfee*`
- `WildTangent*`

## Registry Tweaks

Opt-in, off by default, and reversible unless noted - unchecking a tweak in the
Customize Preferences panel writes back the Off column exactly.

| Tweak | Scope | Registry Path | Value Name | On | Off |
| --- | --- | --- | --- | --- | --- |
| `AutoRestartSignOnOff` | HKLM | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` | `DisableAutomaticRestartSignOn` | `1` | `<RemoveEntry>` |
| `BatteryPercentage` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `IsBatteryPercentageEnabled` | `1` | `<RemoveEntry>` |
| `BSoDVerbose` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl` | `DisplayParameters` | `1` | `0` |
| `BSoDVerbose` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl` | `DisableEmoticon` | `1` | `0` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `ExcludeWUDriversInQualityUpdate` | `1` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `DeferFeatureUpdates` | `1` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `DeferFeatureUpdatesPeriodInDays` | `365` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `DeferQualityUpdates` | `1` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` | `DeferQualityUpdatesPeriodInDays` | `4` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching` | `DontSearchWindowsUpdate` | `1` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | `AUOptions` | `3` | `<RemoveEntry>` |
| `BusinessWindowsUpdatePreset` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU` | `NoAutoRebootWithLoggedOnUsers` | `1` | `<RemoveEntry>` |
| `ClassicContextMenu` | HKCU | *(special-cased - see source code, not a plain registry entry)* | - | - | - |
| `ConsumerFeaturesOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent` | `DisableWindowsConsumerFeatures` | `1` | `<RemoveEntry>` |
| `ConsumerFeaturesOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent` | `DisableConsumerAccountStateContent` | `1` | `<RemoveEntry>` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SilentInstalledAppsEnabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SystemPaneSuggestionsEnabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SoftLandingEnabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-310093Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-338388Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-338389Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-338393Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-353694Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-353696Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager` | `SubscribedContent-353698Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_IrisRecommendations` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowSyncProviderNotifications` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Start_AccountNotifications` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement` | `ScoobeSysemSettingEnabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\SystemSettings\AccountNotifications` | `EnableAccountNotifications` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested` | `Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.BackupReminder` | `Enabled` | `0` | `1` |
| `ConsumerFeaturesOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility` | `OptedIn` | `0` | `1` |
| `CopilotRecallAiOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowCopilotButton` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot` | `TurnOffWindowsCopilot` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot` | `TurnOffWindowsCopilot` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKCU:\Software\Policies\Microsoft\Windows\WindowsAI` | `DisableAIDataAnalysis` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `DisableAIDataAnalysis` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `AllowRecallEnablement` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `TurnOffSavingSnapshots` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKCU:\Software\Policies\Microsoft\Windows\WindowsAI` | `DisableClickToDo` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI` | `DisableClickToDo` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SYSTEM\CurrentControlSet\Services\WSAIFabricSvc` | `Start` | `3` | `2` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\WindowsNotepad` | `DisableAIFeatures` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` | `DisableCocreator` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` | `DisableGenerativeFill` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` | `DisableImageCreator` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` | `DisableGenerativeErase` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint` | `DisableRemoveBackground` | `1` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `CopilotCDPPageContext` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `CopilotPageContext` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `HubsSidebarEnabled` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `EdgeEntraCopilotPageContext` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `EdgeHistoryAISearchEnabled` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `ComposeInlineEnabled` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `NewTabPageBingChatEnabled` | `0` | `<RemoveEntry>` |
| `CopilotRecallAiOff` | HKCU | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `GenAILocalFoundationalModelSettings` | `1` | `<RemoveEntry>` |
| `DarkTheme` | HKCU | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize` | `AppsUseLightTheme` | `0` | `1` |
| `DarkTheme` | HKCU | `HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize` | `SystemUsesLightTheme` | `0` | `1` |
| `DefenderHardening` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\Lsa` | `RunAsPPL` | `1` | `<RemoveEntry>` |
| `DefenderHardening` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System` | `EnableSmartScreen` | `1` | `<RemoveEntry>` |
| `DefenderHardening` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System` | `ShellSmartScreenLevel` | `Warn` | `<RemoveEntry>` |
| `DeliveryOptimizationLanOnly` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization` | `DODownloadMode` | `1` | `<RemoveEntry>` |
| `DeviceMetadataOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata` | `PreventDeviceMetadataFromNetwork` | `1` | `<RemoveEntry>` |
| `DisableLockScreen` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization` | `NoLockScreen` | `1` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `HideFirstRunExperience` | `1` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `ShowRecommendationsEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `DefaultBrowserSettingsCampaignEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `EdgeShoppingAssistantEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `ShowMicrosoftRewards` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `UserFeedbackAllowed` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `MicrosoftEdgeInsiderPromotionEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `WalletDonationEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `ConfigureDoNotTrack` | `1` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `NewTabPageContentEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `NewTabPageHideDefaultTopSites` | `1` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `SpotlightExperiencesAndRecommendationsEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `ShowAcrobatSubscriptionButton` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Edge` | `TabServicesEnabled` | `0` | `<RemoveEntry>` |
| `EdgeFirstRunNagOff` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\EdgeUpdate` | `CreateDesktopShortcutDefault` | `0` | `<RemoveEntry>` |
| `ExplorerOpensToThisPC` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `LaunchTo` | `1` | `<RemoveEntry>` |
| `F8BootMenuOn` | HKLM | *(special-cased - see source code, not a plain registry entry)* | - | - | - |
| `FirstLogonAnimationOff` | HKLM | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` | `EnableFirstLogonAnimation` | `0` | `<RemoveEntry>` |
| `GameMode` | HKCU | `HKCU:\Software\Microsoft\GameBar` | `AllowAutoGameMode` | `1` | `0` |
| `GameMode` | HKCU | `HKCU:\Software\Microsoft\GameBar` | `AutoGameModeEnabled` | `1` | `0` |
| `LogonAcrylicBlur` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\System` | `DisableAcrylicBackgroundOnLogon` | `0` | `1` |
| `LogonVerbose` | HKLM | `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System` | `VerboseStatus` | `1` | `0` |
| `LongPaths` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem` | `LongPathsEnabled` | `1` | `0` |
| `MouseAcceleration` | HKCU | `HKCU:\Control Panel\Mouse` | `MouseSpeed` | `1` | `0` |
| `MouseAcceleration` | HKCU | `HKCU:\Control Panel\Mouse` | `MouseThreshold1` | `6` | `0` |
| `MouseAcceleration` | HKCU | `HKCU:\Control Panel\Mouse` | `MouseThreshold2` | `10` | `0` |
| `NewOutlook` | HKCU | `HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Preferences` | `UseNewOutlook` | `1` | `0` |
| `NewOutlook` | HKCU | `HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General` | `HideNewOutlookToggle` | `0` | `1` |
| `NewOutlook` | HKCU | `HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General` | `DoNewOutlookAutoMigration` | `0` | `0` |
| `NewOutlook` | HKCU | `HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences` | `NewOutlookMigrationUserSetting` | `0` | `<RemoveEntry>` |
| `NumLockOnStartup` | HKCU | `HKU:\.Default\Control Panel\Keyboard` | `InitialKeyboardIndicators` | `2` | `0` |
| `NumLockOnStartup` | HKCU | `HKCU:\Control Panel\Keyboard` | `InitialKeyboardIndicators` | `2` | `0` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Policies\Microsoft\office\16.0\common\clienttelemetry` | `SendTelemetry` | `3` | `<RemoveEntry>` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Policies\Microsoft\office\16.0\common\feedback` | `Enabled` | `0` | `<RemoveEntry>` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Policies\Microsoft\office\16.0\common\feedback` | `SurveyEnabled` | `0` | `<RemoveEntry>` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Policies\Microsoft\office\16.0\common\ptwatson` | `PTWOptIn` | `0` | `<RemoveEntry>` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Policies\Microsoft\office\16.0\common\general` | `OptInDisable` | `1` | `<RemoveEntry>` |
| `OfficeFirstRunPrivacyOff` | HKCU | `HKCU:\Software\Microsoft\Office\16.0\Common\General` | `ShownFirstRunOptin` | `1` | `<RemoveEntry>` |
| `PhoneLinkStartOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Start\Companions\Microsoft.YourPhone_8wekyb3d8bbwe` | `IsEnabled` | `0` | `<RemoveEntry>` |
| `PrinterAutoManageOff` | HKCU | `HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Windows` | `LegacyDefaultPrinterMode` | `1` | `<RemoveEntry>` |
| `PrintScreenOpensSnipping` | HKCU | `HKCU:\Control Panel\Keyboard` | `PrintScreenKeyForSnippingEnabled` | `1` | `0` |
| `RecycleBinDeleteConfirmOn` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` | `ConfirmFileDelete` | `1` | `<RemoveEntry>` |
| `RegistryBackupOn` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Configuration Manager` | `EnablePeriodicBackup` | `1` | `<RemoveEntry>` |
| `S0SleepNetwork` | HKCU | `HKCU:\SOFTWARE\Policies\Microsoft\Power\PowerSettings\f15576e8-98b7-4186-b944-eafa664402d9` | `ACSettingIndex` | `1` | `0` |
| `S3Sleep` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\Power` | `PlatformAoAcOverride` | `0` | `<RemoveEntry>` |
| `ScrollbarsAlwaysVisible` | HKCU | `HKCU:\Control Panel\Accessibility` | `DynamicScrollbars` | `0` | `1` |
| `SettingsHomePage` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` | `SettingsPageVisibility` | `show:home` | `hide:home` |
| `ShowFileExt` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `HideFileExt` | `0` | `1` |
| `ShowHiddenFiles` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `Hidden` | `1` | `0` |
| `StartMenuBingSearch` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Search` | `BingSearchEnabled` | `1` | `0` |
| `StartMenuClassicLayout` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\FeatureManagement\Overrides\8\3036241548` | `EnabledState` | `1` | `<RemoveEntry>` |
| `StartMenuRecommendations` | HKLM | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start` | `HideRecommendedSection` | `0` | `1` |
| `StartMenuRecommendations` | HKLM | `HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education` | `IsEducationEnvironment` | `0` | `1` |
| `StartMenuRecommendations` | HKLM | `HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer` | `HideRecommendedSection` | `0` | `1` |
| `StickyKeys` | HKCU | `HKCU:\Control Panel\Accessibility\StickyKeys` | `Flags` | `506` | `58` |
| `TaskbarCenteredIcons` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarAl` | `1` | `0` |
| `TaskbarChatOff` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `TaskbarMn` | `0` | `<RemoveEntry>` |
| `TaskbarEndTask` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings` | `TaskbarEndTask` | `1` | `0` |
| `TaskbarSearchIcon` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Search` | `SearchboxTaskbarMode` | `1` | `0` |
| `TaskbarTaskViewIcon` | HKCU | `HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced` | `ShowTaskViewButton` | `1` | `0` |
| `WindowSnapping` | HKCU | `HKCU:\Control Panel\Desktop` | `WindowArrangementActive` | `1` | `0` |
| `WpbtOff` | HKLM | `HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager` | `DisableWpbtExecution` | `1` | `<RemoveEntry>` |

## Install Apps Catalog

| App | Category | Winget ID | SAC Risk |
| --- | --- | --- | --- |
| Brave | Browsers | `Brave.Brave` |  |
| Chrome | Browsers | `Google.Chrome` |  |
| Chromium | Browsers | `Hibbiki.Chromium` |  |
| Edge | Browsers | `Microsoft.Edge` |  |
| Firefox | Browsers | `Mozilla.Firefox` |  |
| Firefox ESR | Browsers | `Mozilla.Firefox.ESR` |  |
| Tor Browser | Browsers | `TorProject.TorBrowser` |  |
| Slack | Communications | `SlackTechnologies.Slack` |  |
| Zoom | Communications | `Zoom.Zoom` |  |
| Adobe Acrobat Reader | Documents | `Adobe.Acrobat.Reader.64-bit` |  |
| Adobe Creative Cloud | Documents | `Adobe.CreativeCloud` |  |
| Bluebeam Revu | Documents | `Bluebeam.Revu.21` |  |
| LibreOffice | Documents | `TheDocumentFoundation.LibreOffice` |  |
| PDF24 Creator | Documents | `geeksoftwareGmbH.PDF24Creator` |  |
| SumatraPDF | Documents | `SumatraPDF.SumatraPDF` |  |
| DataLink Viewer | Manual Install Only | *(manual install only - no automated download)* |  |
| Mimecast for Outlook | Manual Install Only | *(manual install only - no automated download)* |  |
| .NET Desktop Runtime 10 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.10` |  |
| .NET Desktop Runtime 8 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.8` |  |
| .NET Desktop Runtime 9 | Microsoft Tools | `Microsoft.DotNet.DesktopRuntime.9` |  |
| Autoruns | Microsoft Tools | `Microsoft.Sysinternals.Autoruns` |  |
| Microsoft Teams (work/school) | Microsoft Tools | `Microsoft.Teams` |  |
| OneDrive | Microsoft Tools | `Microsoft.OneDrive` |  |
| PowerShell | Microsoft Tools | `Microsoft.PowerShell` |  |
| PowerToys | Microsoft Tools | `Microsoft.PowerToys` |  |
| Process Explorer | Microsoft Tools | `Microsoft.Sysinternals.ProcessExplorer` |  |
| Process Monitor | Microsoft Tools | `Microsoft.Sysinternals.ProcessMonitor` |  |
| RDCMan | Microsoft Tools | `Microsoft.Sysinternals.RDCMan` |  |
| TCPView | Microsoft Tools | `Microsoft.Sysinternals.TCPView` |  |
| Visual C++ 2015-2022 32-bit | Microsoft Tools | `Microsoft.VCRedist.2015+.x86` |  |
| Visual C++ 2015-2022 64-bit | Microsoft Tools | `Microsoft.VCRedist.2015+.x64` |  |
| Windows Terminal | Microsoft Tools | `Microsoft.WindowsTerminal` |  |
| FreeFileSync | Non-Silent Installs | *(direct download, no winget package)* |  |
| 1Password | Utilities | `AgileBits.1Password` |  |
| 7-Zip | Utilities | `7zip.7zip` |  |
| Advanced IP Scanner | Utilities | `Famatech.AdvancedIPScanner` |  |
| AnyDesk | Utilities | `AnyDesk.AnyDesk` |  |
| AutoHotkey | Utilities | `AutoHotkey.AutoHotkey` |  |
| Bitwarden | Utilities | `Bitwarden.Bitwarden` |  |
| Cloudflare WARP | Utilities | `Cloudflare.Warp` |  |
| CPU-Z | Utilities | `CPUID.CPU-Z` |  |
| Crystal Disk Info | Utilities | `CrystalDewWorld.CrystalDiskInfo` |  |
| Crystal Disk Mark | Utilities | `CrystalDewWorld.CrystalDiskMark` |  |
| Deskflow | Utilities | `Deskflow.Deskflow` |  |
| Dropbox | Utilities | `Dropbox.Dropbox` |  |
| Everything | Utilities | `voidtools.Everything` |  |
| F.lux | Utilities | `flux.flux` |  |
| Files | Utilities | `FilesCommunity.Files` |  |
| GlazeWM | Utilities | `glzr-io.glazewm` |  |
| Google Drive | Utilities | `Google.GoogleDrive` |  |
| HWiNFO | Utilities | `REALiX.HWiNFO` |  |
| MiniTool Partition Wizard | Utilities | `MiniTool.PartitionWizard.Free` |  |
| MSEdgeRedirect | Utilities | `rcmaehl.MSEdgeRedirect` |  |
| NanaZip | Utilities | `M2Team.NanaZip` |  |
| Nmap | Utilities | `Insecure.Nmap` |  |
| Notepad++ | Utilities | `Notepad++.Notepad++` |  |
| NVCleanstall | Utilities | `TechPowerUp.NVCleanstall` |  |
| OFGB (Oh Frick Go Back) | Utilities | `xM4ddy.OFGB` |  |
| OpenRGB | Utilities | `OpenRGB.OpenRGB` |  |
| Oracle VirtualBox | Utilities | `Oracle.VirtualBox` |  |
| Parsec | Utilities | `Parsec.Parsec` |  |
| PeaZip | Utilities | `Giorgiotani.Peazip` |  |
| Policy Plus | Utilities | `Fleex255.PolicyPlus` |  |
| Process Lasso | Utilities | `BitSum.ProcessLasso` |  |
| PuTTY | Utilities | `PuTTY.PuTTY` |  |
| qBittorrent | Utilities | `qBittorrent.qBittorrent` |  |
| Revo Uninstaller | Utilities | `RevoUninstaller.RevoUninstaller` |  |
| Rufus Imager | Utilities | `Rufus.Rufus` |  |
| Snappy Driver Installer Origin | Utilities | `GlennDelahoy.SnappyDriverInstallerOrigin` |  |
| TeamViewer | Utilities | `TeamViewer.TeamViewer` |  |
| TightVNC | Utilities | `GlavSoft.TightVNC` |  |
| Total Commander | Utilities | `Ghisler.TotalCommander` |  |
| TranslucentTB | Utilities | `CharlesMilette.TranslucentTB` |  |
| TreeSize Free | Utilities | `JAMSoftware.TreeSize.Free` |  |
| VLC media player | Utilities | `VideoLAN.VLC` |  |
| WinSCP | Utilities | `WinSCP.WinSCP` |  |
| Wireshark | Utilities | `WiresharkFoundation.Wireshark` |  |
| Wise Program Uninstaller | Utilities | `WiseCleaner.WiseProgramUninstaller` |  |
| WizTree | Utilities | `AntibodySoftware.WizTree` |  |

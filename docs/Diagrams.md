# LazyVM diagrams

One diagram per thing you do with LazyVM. Each shows the calls in order down the middle, data read on the left and data written on the right. Every diagram is followed by the same information as a numbered list.

## How to read them

- **Blue arrows** are calls, numbered in the order they run.
- **Dashed orange arrows** are data, numbered D1, D2 and so on. An arrow into a call is data read; an arrow out of it is data written.
- Host paths are relative to the LazyVM folder (`HKLM:\SOFTWARE\LazyVM` `Root`), for example `D:\DevVM`. Inside the VM, `D:` is the SQL data disk, `W:` is the Dev Drive and `U:` is the User disk.
- Every command that works on one VM runs inside `Invoke-CommandRun`: it starts with `Initialize-CommandRun`, which builds the VM context and opens the log, and ends with `Complete-CommandRun`, which closes the guest session and the log. `Show-LazyVM`, `Set-LazyVMRoot`, `New-LazyVM`, `Export-LazyVMTemplate`, `Get-LazyVM`, `Get-LazyVMSetting`, `Get-LazyVMCredential` and `Test-LazyVM` do not.
- A call that happens only in some cases says so in its box. **Also runs** lists the functions a step calls for its work.

## Contents

- Install: [Install from the repository](#install-from-repo), [Install from a release](#install-from-release)
- Set up: [Show LazyVM and its commands](#show), [Choose the LazyVM folder](#set-root), [Create a VM profile without building](#new-profile), [Store the guest account](#set-credential)
- Build: [Build a VM](#build)
- Maintain: [Daily maintenance](#maintenance), [Schedule maintenance again](#register-maintenance), [Rebuild a VM](#rebuild)
- Tooling: [Record tooling now](#tooling-record), [See installed tooling](#tooling-view), [List tooling restore points](#restore-points), [Return to an earlier tooling version](#tooling-revert)
- State: [Capture state](#capture), [Restore state](#restore)
- Templates: [Save a VM as a config template](#export-template)
- Remove: [Remove a VM](#remove)
- Check: [List VMs](#status), [View settings](#settings), [Check the license](#license), [See the guest account](#credential-view), [Check a VM end to end](#test)

<a id="install-from-repo"></a>

## Install from the repository

`./Invoke-AnalyzerAndTest.ps1` `&& ./src/Install.ps1 -Path out`

Builds the module, checks it and runs the tests, then installs it for all users only if every check passes. Any failure stops before step 5. Install-FromRepository.cmd runs the same, as administrator.

Called by: `Install-FromRepository.cmd` (asks for administrator rights).

![Install from the repository: call order and data flow](diagrams/install-from-repo.svg)

1. `Invoke-Assemble` (build\Assemble.ps1): merges Public\ and Private\ into one .psm1, then imports it to check the exports
   - Reads D1, module source: src\LazyVM\ (Public\  Private\  Data\, LazyVM.psd1)
   - Writes D2, built module: out\LazyVM\ (<version>\)
2. `Install-BuildTool` (build\Tools.ps1): installs the pinned version when it is missing; other versions are left alone
   - Reads D3, pinned build tools: PowerShell Gallery (PSScriptAnalyzer 1.24.0, Pester 5.7.1)
   - Writes D4, build tools, if they were missing: CurrentUser modules (PSScriptAnalyzer, Pester)
3. `Invoke-Analyze` (build\Analyze.ps1): in a job of its own; any finding stops here
   - Reads D5, code and analyzer rules: Repo (src\  tests\, PSScriptAnalyzerSettings.psd1)
4. `Invoke-Test` (build\Test.ps1): any failure stops here
   - Reads D6, Pester tests: Repo (tests\*.Tests.ps1)
   - Reads D7, built module: out\LazyVM\ (<version>\)
   - Writes D8, test results: out\ (testResults.xml)
5. `Install.ps1 -Path out` (script): only when every check passed: copies the newest built version and unblocks it
   - Reads D9, built module: out\LazyVM\ (<version>\)
   - Writes D10, module installed for all users, SYSTEM included: $env:ProgramFiles\PowerShell\ (Modules\LazyVM\<version>\)

<a id="install-from-release"></a>

## Install from a release

`.\LazyVM\Install.ps1`

Copies the module from a downloaded release to where PowerShell 7 and the SYSTEM maintenance task find it, replacing an earlier copy of the same version, and unblocks it.

![Install from a release: call order and data flow](diagrams/install-from-release.svg)

1. `Copy-Item` (Install.ps1): newest version folder beside the script
   - Reads D1, module from the zip: LazyVM\LazyVM\ (<version>\)
   - Writes D2, module installed for all users: $env:ProgramFiles\PowerShell\ (Modules\LazyVM\, <version>\)
2. `Unblock-File` (Install.ps1): removes the downloaded-from-the-internet mark, which would stop PowerShell loading the module
   - Writes D3, files PowerShell will load: Modules\LazyVM\ (<version>\  (unblocked))

<a id="show"></a>

## Show LazyVM and its commands

`Show-LazyVM` `or just: LazyVM`

What typing LazyVM on its own shows: the installed version, the LazyVM folder and the VMs in it, where the module is installed, and every command with its synopsis. Reads only.

![Show LazyVM and its commands: call order and data flow](diagrams/show.svg)

1. `Resolve-LazyVMRoot` (Settings): the LazyVM folder; says so when none has been chosen yet
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Get-VMProfileName` (Settings): every VM with a profile in that folder
   - Reads D2, VM profiles: <Root>\ (*\Config\VM.json)
   - Writes D3, version, folder, VMs, module folder: Pipeline (lines of text)
3. `Get-Help` (PowerShell): the synopsis of each exported command
   - Reads D4, comment-based help: Module (each command's .SYNOPSIS)
   - Writes D5, command list: Pipeline (name and synopsis)

<a id="set-root"></a>

## Choose the LazyVM folder

`Set-LazyVMRoot` `-Path D:\DevVM`

Optional. Without it, Build-LazyVM picks LazyVM on the NTFS drive with the most free space. Nothing in the old folder is moved.

![Choose the LazyVM folder: call order and data flow](diagrams/set-root.svg)

1. `Resolve-SettingsRoot` (Settings): checks it is a full local path
2. `Get-RegisteredRoot` (Settings): warns if a different folder was in use
   - Reads D1, previous folder: HKLM:\SOFTWARE\LazyVM (Root)
3. `Set-RegisteredRoot` (Settings): creates the folder if needed and records it
   - Also runs `New-Folder`
   - Writes D2, new folder, read by every later run: HKLM:\SOFTWARE\LazyVM (Root = D:\DevVM)
4. `Initialize-ConfigFolder` (Settings): copies the schema for VS Code autocomplete; returns the folder and its settings file
   - Also runs `Get-ConfigDir`
   - Reads D3, settings schema: Module Data\ (LazyVM.Settings.schema.json)
   - Writes D4, schema copy, empty settings file: D:\DevVM\Shared\Config\ (LazyVM.Settings.schema.json, LazyVM.Settings.json (if new))

<a id="new-profile"></a>

## Create a VM profile without building

`New-LazyVM` `-Name <VM>` `-From <OtherVM> | -ConfigTemplate <Template>  (optional)`

Creates the profile only. Build-LazyVM does this by itself when the profile is missing.

![Create a VM profile without building: call order and data flow](diagrams/new-profile.svg)

1. `Resolve-LazyVMRoot` (Settings): the LazyVM folder; stops if none has been chosen yet
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `New-VMProfile` (Settings): applies -ConfigTemplate's Settings, or copies -From settings except paths, computer name, maintenance time and disk identity; schedules maintenance an hour after the latest existing VM
   - Reads D2, settings and tooling, with -From: <OtherVM>\Config\ (VM.json)
   - Reads D3, config template, with -ConfigTemplate: Config templates (Data\Templates\*.json, Shared\Templates\*.json)
   - Reads D4, shared template: Shared\Config\ (LazyVM.Settings.json)
   - Reads D5, maintenance times in use: *\Config\ (VM.json)
   - Writes D6, new profile: <VM>\Config\ (VM.json)
   - Writes D7, tooling list to build with: <VM>\Config\ (VM.json, its Tooling  (with -From))
3. `Get-LazyVM` (command): returns the new VM as LazyVM.VM

<a id="set-credential"></a>

## Store the guest account

`Set-LazyVMCredential` `-Name <VM>` `-Credential  (optional)` `-Force  (optional)`

Optional before a build: Build-LazyVM generates an account if none is stored. This does not change the password inside an existing VM.

![Store the guest account: call order and data flow](diagrams/set-credential.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Get-GuestCredential` (Credentials): the stored account, if any: asks before replacing it unless -Force
   - Reads D3, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
3. `Get-Credential` (PowerShell): prompt, if -Credential was not given
   - Reads D4, credential typed in: You (user name, password, (empty = generate one))
4. `Set-StoredGuestCredential` (Credentials): local accounts only; Save-StoredCredential encrypts with the key
   - Writes D5, encrypted credential: Credential store (Shared\Credentials\.lazyvm.key, (once; SYSTEM + Administrators), <VM>\Credentials\guest.cred)

<a id="build"></a>

## Build a VM

`Build-LazyVM` `-Name <VM>` `-ConfigTemplate <Template>  (optional)` `-FromPhase 0-8  (optional)` `-NoUnattend  (optional)`

Invoke-VMBuild runs phases 0 to 8, skipping work already done; Build-LazyVM then schedules maintenance. Running it again finishes an interrupted build.

![Build a VM: call order and data flow](diagrams/build.svg)

1. `Initialize-BuildTarget` (Settings): first run: picks the root and creates the profile, from -ConfigTemplate when given
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root, if already set)
   - Reads D2, drive with most free space: Fixed drives (NTFS, free space)
   - Reads D3, config template, with -ConfigTemplate: Config templates (Data\Templates\*.json, Shared\Templates\*.json)
   - Writes D4, LazyVM folder, first run: HKLM:\SOFTWARE\LazyVM (Root = X:\LazyVM)
   - Writes D5, settings file and profile, if new: Settings files (Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json)
2. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D6, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D7, run log: <VM>\Logs\ (<VM>.log  (appended))
3. `Sync-VMProfile` (Settings): fills in any setting VM.json lacks from the shared template
   - Reads D8, shared template: Shared\Config\ (LazyVM.Settings.json)
   - Writes D9, complete profile: <VM>\Config\ (VM.json, VM.Template.json  (first time only))
4. `Invoke-VMBuild` (Host): runs the phases from -FromPhase or the resume point, whichever is later
5. `Get-ResumePhase` (Host, called by Invoke-VMBuild): picks up after a host restart
   - Reads D10, phase to resume at: HKLM:\SOFTWARE\LazyVM\<VM> (ResumePhase)
6. `Invoke-BuildPhase` (Host, called by Invoke-VMBuild): runs each phase of Get-BuildPhase in order (steps 7-18); when a phase throws, deletes the answer-file disc first
   - Also runs `Get-BuildPhase`, `Remove-UnattendSeedDisk`
7. `Initialize-InstallationIso` (Host, called by Invoke-BuildPhase): the Windows ISO, before anything changes; opens the download page and stops if there is none
   - Reads D11, Windows ISO: Shared\ISO\  or  Downloads\ (Windows 11 Enterprise, Evaluation ISO)
   - Writes D12, Windows ISO in place: Shared\ISO\ (Win11Ent_Eval.iso, (moved from Downloads))
8. `Repair-HyperVService` and `Test-HostReadiness` (Host, called by Invoke-BuildPhase): phases 0 and 1: the Hyper-V services, then CPU, SLAT, memory and free space
   - Reads D13, host checks: This PC (vmms, vmcompute, CPU, SLAT, RAM, free space)
9. `Enable-HyperVFeature` (Host, called by Invoke-BuildPhase): phase 2; returns RestartPending when the host must restart
   - Writes D14, resume task, only if a restart is needed: Task Scheduler (LazyVM-ResumeAfterReboot-<VM>)
   - Writes D15, where to resume: HKLM:\SOFTWARE\LazyVM\<VM> (ResumePhase = 3)
10. `Initialize-HostFolder` (Host, called by Invoke-BuildPhase): phase 3
   - Writes D16, folders created if missing: <Root>\ (Shared\ ISO, Installers, Credentials, <VM>\ Disks, Credentials, Backups,, Logs, Checkpoints)
11. `Initialize-SqlServerIso` (Host, called by Invoke-BuildPhase): phase 4: downloads the SQL Server ISO if it is missing
   - Reads D17, SQL Server ISO: download.microsoft.com (SQL Server 2025 ISO, only if missing)
   - Writes D18, SQL Server ISO in place: Shared\Installers\ (SQLServer2025-x64-ENU-EntDev.iso)
12. `Initialize-SqlDataVhd`, `Initialize-DevDriveVhd` and `Initialize-UserDataVhd` (Host, called by Invoke-BuildPhase): phase 5: existing disks are never overwritten
   - Writes D19, data disk, Dev Drive and User disk: <VM>\Disks\ (<VM>-SQL.vhdx  (100 GB), <VM>-DevDrive.vhdx  (250 GB), <VM>-User.vhdx  (20 GB))
13. `Initialize-GuestCredential` (Credentials, called by Invoke-BuildPhase): phase 6, for a VM that does not exist yet, without -NoUnattend: generates the account if there is none
   - Reads D20, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D21, credential, if new: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
14. `New-UnattendSeedDisk` (Host, called by Invoke-BuildPhase): phase 6: the answer file for Setup, in the same cases
   - Writes D22, answer-file disc: <VM>\Disks\ (<VM>-Seed.iso)
15. `New-GuestVM` (Host, called by Invoke-BuildPhase): phase 6: Gen 2, Secure Boot, TPM, dynamic memory
   - Reads D23, install discs: Shared\ISO\  <VM>\Disks\ (Win11Ent_Eval.iso, <VM>-Seed.iso)
   - Writes D24, Windows disk, VM files: <VM>\ (Disks\<VM>-OS.vhdx, Virtual Machines\  (configuration))
   - Writes D25, new VM: VM <VM> (created, not started yet)
16. `Install-GuestSoftware` (Installation, called by Invoke-BuildPhase): phase 7: starts the VM, waits for Setup and deletes the answer-file disc; attaches and prepares D:, W: and U: and puts the personal folders on U:; extends C:; BitLocker; Enhanced Session; removes built-in apps and applies the appearance and Developer Mode; Sysmon; then the tooling list: Visual Studio Installer products, SQL Server, winget packages, official installers; Windows updates; records the tooling list
   - Also runs `Test-SeedDiskAttached`, `Assert-GuestCredential`, `Start-VMFromInstallMedia`, `Wait-GuestReady`, `Remove-UnattendSeedDisk`, `Add-SqlDataDisk`, `Add-DevDriveDisk`, `Add-UserDataDisk`, `Connect-Guest`, `Expand-GuestSystemDrive`, `Unlock-GuestDataDisk`, `Initialize-GuestSqlDisk`, `Initialize-GuestDevDrive`, `Initialize-GuestUserDisk`, `Protect-GuestPersistentDisk`, `Enable-GuestEnhancedSession`, `Set-GuestCustomization`, `Set-GuestSysmon`, `Get-BuildTooling`, `Wait-GuestNetwork`, `Install-ToolingProduct`, `Install-SqlServerIfMissing`, `Install-WingetPackage`, `Install-OfficialInstaller`, `Update-GuestWindows`, `Initialize-VMTooling`, `Write-ToolingReinstallReport`
   - Reads D26, tooling list: <VM>\Config\ (VM.json, its Tooling,, or the shared template's)
   - Reads D27, SQL Server media: Shared\Installers\ (SQLServer2025 ISO)
   - Reads D28, updates and packages: Internet (VS bootstrappers, Marketplace,, winget, Windows Update)
   - Writes D29, installed and configured guest: Guest (D: data disk, W: Dev Drive,, U: User disk, BitLocker, Sysmon, appearance, VS + SSMS, extensions, SQL Server 2025, winget apps, Windows updates)
   - Writes D30, tooling list, what needs a manual install: <VM>\ (Config\VM.json, State\reinstall-by-hand.txt)
17. `Complete-GuestConfiguration` (Installation, called by Invoke-BuildPhase): phase 8: 8a the SQL data disk, 8b moves SQL data files onto it, 8c answers Visual Studio's first launch and imports its settings; a step that fails does not stop the others
   - Also runs `Connect-Guest`, `Assert-GuestCredential`, `Invoke-IsolatedStep`, `Add-SqlDataDisk`, `Unlock-GuestDataDisk`, `Initialize-GuestSqlDisk`, `Move-GuestSqlDataFile`, `Restore-GuestVisualStudioSetting`
   - Reads D31, VS settings backup: <VM>\Backups\ (VisualStudio.vssettings)
   - Writes D32, configured guest: Guest (user databases on D:\SQLData, VS settings imported, or pending, for nightly maintenance)
18. `Unregister-ResumeTask` (Host, called by Invoke-VMBuild): unless the host is restarting
   - Writes D33, resume entries removed: Task Scheduler (resume task deleted, ResumePhase cleared)
19. `Register-RebuildSchedule` (Maintenance): a failure here is logged; the build still stands
   - Reads D34, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D35, daily maintenance task: Task Scheduler (LazyVM-Maintain-<VM>, daily at MaintenanceTime, runs as SYSTEM)

<a id="maintenance"></a>

## Daily maintenance

`Invoke-LazyVMMaintenance` `-Name <VM>` `-WhatIf  (optional)`

Each night: records hardware changes made in Hyper-V, looks after the disks, records what changed in the guest, backs up the databases, keeps the guest up to date, and acts on the evaluation license only when it is within RebuildThresholdDays (10) of expiry. With -WhatIf, Get-MaintenancePreview says what a run would do and nothing else runs. Returns None, Rearmed, Rebuilt or Built.

Called by: `LazyVM-Maintain-<VM>` (daily at MaintenanceTime, as SYSTEM).

![Daily maintenance: call order and data flow](diagrams/maintenance.svg)

1. `Initialize-CommandRun` (Common): builds the VM context, opens the log and records any hardware change made in Hyper-V
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Reads D2, hardware: VM <VM> (processors, memory, disk sizes, switch)
   - Writes D3, run log: <VM>\Logs\ (<VM>.log  (appended))
   - Writes D4, hardware change: <VM>\Config\ (VM.json)
2. `Sync-VMProfile` (Settings): fills in any setting VM.json lacks from the shared template
   - Reads D5, shared template: Shared\Config\ (LazyVM.Settings.json)
   - Writes D6, complete profile: <VM>\Config\ (VM.json, VM.Template.json  (first time only))
3. `Invoke-Maintenance` (Maintenance): steps 4-23 are its calls; no VM: returns Build and Invoke-Rebuild builds one instead
   - Reads D7, does the VM exist: Hyper-V (Get-VM <VM>)
4. `Open-GuestSession` (Guest, called by Invoke-Maintenance): starts the VM if it is off and waits for it, then opens the session
   - Reads D8, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D9, PowerShell Direct session: VM <VM> (running, reachable)
5. `Invoke-DailyMaintenance` (Maintenance, called by Invoke-Maintenance): steps 6-22 are its calls; a step that fails is logged and the rest still run
6. `Expand-GuestSystemDrive` (Installation, called by Invoke-DailyMaintenance): only when the OS disk has new space: checkpoint, moves the recovery partition to the end and extends C:
   - Writes D10, bigger C:: Running guest (C: over the whole OS disk)
7. `Install-UserDisk` (Disks, called by Invoke-DailyMaintenance): an older VM gets its User disk; what the personal folders hold on C: is copied to it
   - Writes D11, User disk: <VM>\Disks\ (<VM>-User.vhdx  (U:, if missing))
8. `Protect-GuestPersistentDisk` (Disks, called by Invoke-DailyMaintenance): BitLocker on C:, then on each persistent disk that does not have it
   - Writes D12, encrypted disks, recovery passwords: Guest and credential store (C:, D:, W:, U: with auto-unlock, <VM>\Credentials\)
9. `Backup-UserDisk` (Disks, called by Invoke-DailyMaintenance): one copy of the User disk, still encrypted, made only when its files changed
   - Reads D13, User disk: <VM>\Disks\ (<VM>-User.vhdx)
   - Writes D14, copy: <VM>\Backups\ (<VM>-User.vhdx  (or BackupDir))
10. `Update-ToolingRecord` (Tooling, called by Invoke-DailyMaintenance): takes a checkpoint before adopting a tooling change
   - Reads D15, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D16, last recorded tooling list: <VM>\Config\ (VM.json  Tooling)
   - Writes D17, checkpoint, only on a change: <VM>\Checkpoints\ (checkpoint "Tooling <stamp>", oldest pruned past ToolingCheckpointsToKeep (3))
   - Writes D18, new tooling version, only on a change: <VM>\Config\ (VM.json, History\VM-<stamp>.json)
11. `Update-GuestEnvironmentRecord` (Capture, called by Invoke-DailyMaintenance): environment variables, PATH, hosts entries and mapped drives; then the same for the other records
   - Also runs `Update-GuestFirewallRecord`, `Update-GuestScheduledTaskRecord`, `Update-GuestSqlRecord`, `Update-GuestAppSettingRecord`
   - Reads D19, guest settings: Running guest (environment, firewall rules, scheduled tasks, SQL logins, settings, Agent jobs, AppSettings registry values)
   - Writes D20, records, only on a change: <VM>\Config\ (VM.json  GuestEnvironment, GuestFirewallRules,, GuestScheduledTasks, GuestSql, GuestAppSettings)
   - Writes D21, secret values: Credential store (<VM>\Credentials\)
12. `Backup-GuestUserDatabase` (Capture, called by Invoke-DailyMaintenance): DBCC CHECKDB each user database and, only when it passes, backs it up: one good backup of each
   - Reads D22, databases: SQL Server (online, writable user databases)
   - Writes D23, backups: D:\SQLBackup\ (<database>.bak)
13. `Start-GuestStoreAppUpdate` (Maintenance, called by Invoke-DailyMaintenance): asks the Microsoft Store to check for app updates, as a guest task as SYSTEM
   - Writes D24, update scan: Microsoft Store (UpdateScanMethod)
14. `Set-GuestSysmon` (Installation, called by Invoke-DailyMaintenance): turns Sysmon on and installs it if it is not; applies the configuration again only when LazyVM ships a new one
   - Reads D25, configuration: Module Data\Sysmon\ (sysmonconfig.xml)
   - Writes D26, Sysmon: Running guest (Sysmon feature and service, HKLM:\SOFTWARE\LazyVM  config hash)
15. `Update-GuestVisualStudioSetting` (Maintenance, called by Invoke-DailyMaintenance): applies the captured Visual Studio settings while they are pending, once Visual Studio has been opened and is closed
   - Reads D27, settings backup: <VM>\Backups\ (VisualStudio.vssettings)
   - Writes D28, settings applied: Visual Studio (imported settings, pending flag cleared)
16. `Update-GuestWingetPackage` (Maintenance, called by Invoke-DailyMaintenance): winget upgrades, except Visual Studio, SQL Server, pinned packages and running programs
   - Writes D29, upgraded packages: Running guest (new versions; the tooling list is unchanged)
17. `Update-GuestWindows` (Maintenance, called by Invoke-DailyMaintenance): quality and security updates; restarts only when nobody can be disturbed
   - Reads D30, updates: Windows Update (quality and security updates)
   - Writes D31, patched Windows: Running guest (updates installed, restart now or left pending)
18. `Get-GuestLicenseStatus` (Maintenance, called by Invoke-DailyMaintenance): days left, rearms left
   - Reads D32, license status: Running guest (SoftwareLicensingProduct, SoftwareLicensingService)
19. `Get-MaintenanceDecision` (Maintenance, called by Invoke-DailyMaintenance): more than the threshold left, or no countdown: none; rearms left: rearm; otherwise: rebuild
   - Reads D33, threshold: VM settings (RebuildThresholdDays = 10)
20. `Test-GuestStateChanged` (Capture, called by Invoke-DailyMaintenance): decision none: has anything only a capture keeps changed since the last capture?
   - Reads D34, fingerprint now: Running guest (certificates, Visual Studio settings)
   - Reads D35, fingerprint then: <VM>\State\ (manifest.json)
21. `Save-GuestState` (Capture, called by Invoke-DailyMaintenance): on a rearm or rebuild, or when the state changed (see Capture state)
   - Reads D36, state to keep: Running guest (VS settings, SQL databases + logins, env, certs, tasks, apps)
   - Writes D37, captured state: <VM>\State\ (Captures\<stamp>\  vs\  windows\, manifest.json, D:\SQLBackup\<database>.bak)
22. `Invoke-GuestRearm` (Maintenance, called by Invoke-DailyMaintenance): decision rearm: slmgr rearm, then a restart
   - Writes D38, rearmed Windows: Running guest (evaluation reset to 90 days, one rearm used)
23. `Stop-GuestGracefully` (Maintenance, called by Invoke-Maintenance): only if the run started the VM, and not before a rebuild
   - Writes D39, VM back off: VM <VM> (off)
24. `Invoke-Rebuild -SkipCapture` (Maintenance): only when no rearms are left or the rearm failed (see Rebuild a VM); without -SkipCapture when there is no VM

<a id="register-maintenance"></a>

## Schedule maintenance again

`Register-LazyVMMaintenance` `-Name <VM>`

Build-LazyVM already does this. Use it after changing MaintenanceTime, or if scheduling failed during a build.

![Schedule maintenance again: call order and data flow](diagrams/register-maintenance.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Register-RebuildSchedule` (Maintenance): refuses without a stored credential or a valid HH:mm MaintenanceTime
   - Also runs `Assert-GuestCredential`
   - Reads D3, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D4, daily maintenance task: Task Scheduler (LazyVM-Maintain-<VM>, daily at MaintenanceTime, SYSTEM, wake to run,, 6 h limit, 2 retries)

<a id="rebuild"></a>

## Rebuild a VM

`Invoke-LazyVMRebuild` `-Name <VM>` `-SkipCapture  (optional)` `-NoUnattend  (optional)` `-Force  (optional)`

Capture, retire the old VM, build a new one, restore, verify. The old Windows disk is deleted only after the new VM builds without problems and passes verification. The data disk, Dev Drive and User disk are never touched.

Called by: `Invoke-LazyVMMaintenance` (no rearms left,, or the rearm failed).

![Rebuild a VM: call order and data flow](diagrams/rebuild.svg)

1. `Initialize-CommandRun` (Common): builds the VM context, opens the log and records any hardware change made in Hyper-V
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Sync-VMProfile` (Settings): fills in any setting VM.json lacks from the shared template
   - Reads D3, shared template: Shared\Config\ (LazyVM.Settings.json)
   - Writes D4, complete profile: <VM>\Config\ (VM.json)
3. `Invoke-Rebuild` (Maintenance): steps 4-11 are its calls
4. `Install-UserDisk` (Disks, called by Invoke-Rebuild): only if the VM exists: copies the personal folders to the User disk; nothing is retired if it cannot
   - Writes D5, personal folders: <VM>\Disks\ (<VM>-User.vhdx  (U:))
5. `Save-GuestState` (Capture, called by Invoke-Rebuild): only if the VM exists, without -SkipCapture (see Capture state)
   - Reads D6, state to keep: Running guest (VS settings, SQL databases + logins, env, certs, tasks, apps)
   - Writes D7, captured state: <VM>\State\ (Captures\<stamp>\  vs\  windows\, manifest.json, D:\SQLBackup\<database>.bak)
6. `Get-CaptureManifest` (Capture, called by Invoke-Rebuild): with -SkipCapture: the newest capture instead; stops if there is none
   - Reads D8, last capture: <VM>\State\ (manifest.json)
7. `Invoke-RetireCurrentVM` (Maintenance, called by Invoke-Rebuild): only if the VM exists: shuts down, removes checkpoints and the VM definition; keeps the disks
   - Reads D9, old VM: VM <VM> (old VM, checkpoints)
   - Writes D10, old Windows disk set aside: <VM>\ (Disks\<VM>-OS.retired-<stamp>.vhdx, Virtual Machines.retired-<stamp>\, Disks\<VM>-Seed.iso deleted)
8. `Invoke-BuildPhase -FromPhase 3` (Host, called by Invoke-Rebuild): phases 3 to 8 of Build a VM: folders, media, disks (existing ones are kept), a new VM, installs and configuration
   - Reads D11, tooling list: <VM>\Config\ (VM.json  Tooling)
   - Writes D12, new VM: VM <VM> (new Disks\<VM>-OS.vhdx, old D:, W: and U: attached)
9. `Restore-GuestState` (Restore, called by Invoke-Rebuild): when there is a capture: Windows, VS, SQL, app settings; a failed step does not stop the rest (see Restore state)
   - Reads D13, captured state: <VM>\State\ (manifest.json and, captured files)
   - Writes D14, restored state: New guest (state put back)
10. `Test-RebuiltVM` (Maintenance, called by Invoke-Rebuild): VM running and reachable, products, SQL, databases online, D: and W: mounted
   - Reads D15, products expected: <VM>\Config\ (VM.json)
   - Reads D16, databases expected: <VM>\State\ (manifest.json  Databases)
11. `Remove-RetiredVM` (Maintenance, called by Invoke-Rebuild): only when the build had no problems and verification passed; otherwise the old disk is kept and the log says how to roll back
   - Writes D17, disk space reclaimed: <VM>\ (Disks\<VM>-OS.retired-<stamp>.vhdx,, Virtual Machines.retired-<stamp>\, deleted (DeleteRetiredDiskOnSuccess))

<a id="tooling-record"></a>

## Record tooling now

`Save-LazyVMTooling` `-Name <VM>`

Does now what maintenance does every day. Get-LazyVMTooling shows the same comparison without recording anything.

![Record tooling now: call order and data flow](diagrams/tooling-record.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Open-GuestSession` (Tooling): starts the VM if it is off, connects with PowerShell Direct
   - Reads D3, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D4, VM started if it was off: VM <VM> (running)
3. `Update-ToolingRecord` (Tooling): takes the checkpoint before adopting a change
   - Reads D5, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D6, last recorded tooling list: <VM>\Config\ (VM.json)
   - Writes D7, checkpoint, only on a change: <VM>\Checkpoints\ (checkpoint "Tooling <stamp>", oldest pruned past ToolingCheckpointsToKeep (3))
   - Writes D8, new tooling version, only on a change: <VM>\Config\ (VM.json, History\VM-<stamp>.json)
4. `Stop-GuestGracefully` (Maintenance): only if this run started the VM
   - Writes D9, VM back off: VM <VM> (off)

<a id="tooling-view"></a>

## See installed tooling

`Get-LazyVMTooling` `-Name <VM>`

Lists what is installed and what the next maintenance run would record.

![See installed tooling: call order and data flow](diagrams/tooling-view.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Get-GuestToolingReport` (Tooling): opens the guest, takes the inventory and compares it with the recorded list; records nothing
   - Also runs `Open-GuestSession`, `Get-GuestToolingInventory`, `Write-TextFileAtomic`, `Read-VMTooling`, `ConvertTo-ToolingRecord`, `Add-ToolingSource`, `Merge-AwaitingReinstall`, `Compare-ToolingRecord`
   - Reads D3, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D4, last recorded tooling list: <VM>\Config\ (VM.json)
   - Writes D5, raw inventory: <VM>\State\tooling\ (inventory-<stamp>.json)
   - Writes D6, report: Pipeline (LazyVM.Tooling: products, packages,, unmatched extensions, pending changes)

<a id="restore-points"></a>

## List tooling restore points

`Get-LazyVMRestorePoint` `-Name <VM>`

Lists the recorded tooling versions you can return to.

![List tooling restore points: call order and data flow](diagrams/restore-points.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Get-ToolingRestorePoint` (Tooling): one per "Tooling" checkpoint, oldest first, with whether its tooling list is still kept
   - Also runs `Get-ToolingCheckpoint`, `Get-CheckpointStamp`, `Get-ProfileTooling`
   - Reads D3, checkpoints: <VM>\Checkpoints\ ("Tooling <stamp>")
   - Reads D4, tooling lists: <VM>\Config\History\ (VM-<stamp>.json)
   - Writes D5, restore points: Pipeline (LazyVM.RestorePoint: RestorePoint,, Taken, Checkpoint, HasToolingList)

<a id="tooling-revert"></a>

## Return to an earlier tooling version

`Restore-LazyVMTooling` `-Name <VM>` `-RestorePoint yyyyMMdd-HHmmss` `-Force  (optional)`

Returns ALL the VM's disks to that checkpoint, Dev Drive and data disk included. The revert itself can be undone.

![Return to an earlier tooling version: call order and data flow](diagrams/tooling-revert.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Invoke-ToolingRevert` (Tooling): steps 3-6 are its calls; stops before changing anything if the checkpoint or its list is missing
   - Also runs `Get-ToolingCheckpoint`, `Get-CheckpointStamp`, `Get-ProfileTooling`, `Get-ToolingStamp`, `Get-VMProfilePath`
   - Reads D3, chosen checkpoint: <VM>\Checkpoints\ ("Tooling <stamp>")
   - Reads D4, that version's list: <VM>\Config\History\ (VM-<stamp>.json)
3. `New-ToolingCheckpoint -SkipPrune` (Tooling, called by Invoke-ToolingRevert): the current state, so the revert can be undone
   - Writes D5, safety checkpoint: <VM>\Checkpoints\ ("Tooling <now> before revert")
4. `Save-ProfileVersion` (Settings, called by Invoke-ToolingRevert): keeps VM.json as it is now under the same date-time
   - Reads D6, current profile: <VM>\Config\ (VM.json)
   - Writes D7, current VM.json kept: <VM>\Config\History\ (VM-<now>.json)
5. `Restore-VMSnapshot` (Hyper-V, called by Invoke-ToolingRevert): after closing the guest session (Remove-GuestSession); starts the VM again if it was running
   - Also runs `Remove-GuestSession`
   - Writes D8, VM returned to that version: VM <VM> (every disk back to <stamp>)
6. `Restore-ProfileTooling` (Settings, called by Invoke-ToolingRevert): puts that version's tooling list back in VM.json
   - Writes D9, tooling list matches the VM: <VM>\Config\ (VM.json  Tooling)

<a id="capture"></a>

## Capture state

`Save-LazyVMState` `-Name <VM>`

Copies to the host what a rebuild must keep and the VM's records do not, into a capture folder of its own; the newest three are kept. Maintenance and rebuilds run the same capture. Environment, firewall rules, scheduled tasks, SQL logins and Agent jobs and application settings are recorded in VM.json every night instead (see Daily maintenance).

![Capture state: call order and data flow](diagrams/capture.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Save-GuestState` (Capture): steps 3-12 are its calls; each area runs isolated (Invoke-IsolatedStep): one that fails is a warning in the manifest and the rest still run
   - Also runs `Invoke-IsolatedStep`, `Get-Stamp`, `New-Folder`
   - Writes D3, capture folder: <VM>\State\Captures\ (<stamp>\)
3. `Open-GuestSession` (Guest, called by Save-GuestState): starts the VM if it is off and waits for it
   - Reads D4, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D5, PowerShell Direct session: VM <VM> (running, reachable)
4. `Initialize-GuestSqlDisk` (Installation, called by Save-GuestState): finds the data disk's letter, so backups land on it
5. `Get-GuestIdentity` (Capture, called by Save-GuestState): computer name, user, OS build, install date, time zone
   - Reads D6, guest identity: Running guest (Win32_OperatingSystem)
6. `Save-GuestVisualStudioState` (Capture, called by Save-GuestState): Visual Studio settings, NuGet.Config, .gitconfig, snippets and templates; workloads and extensions are in the tooling list
   - Reads D7, Visual Studio files: Running guest (settings per instance, NuGet.Config, .gitconfig, Documents snippets, templates)
   - Writes D8, VS files: <VM>\State\Captures\<stamp>\ (vs\)
   - Writes D9, settings for phase 8 and maintenance: <VM>\Backups\ (VisualStudio.vssettings)
7. `Save-GuestSqlState` (Capture, called by Save-GuestState): backs up every user database to the data disk and checks each backup
   - Reads D10, databases: SQL Server (user databases)
   - Writes D11, backups on the data disk: D:\SQLBackup\ (<database>.bak)
8. `Save-GuestWindowsState` (Capture, called by Save-GuestState): certificates, the private keys protected with a password kept in the credential store
   - Reads D12, certificates: Running guest (certificate stores)
   - Writes D13, Windows archive: <VM>\State\Captures\<stamp>\ (windows\winstate.zip)
   - Writes D14, certificate password: <VM>\Credentials\ (certs.cred)
9. `Save-GuestAppSetting` (Capture, called by Save-GuestState): records the AppSettings keys in VM.json; nothing goes into the capture itself
   - Reads D15, registry values: AppSettings keys (HKCU\Software\...)
   - Writes D16, application settings: <VM>\Config\ (VM.json  GuestAppSettings)
   - Writes D17, secret values: Credential store (<VM>\Credentials\)
10. `Get-GuestStateFingerprint` (Capture, called by Save-GuestState): certificate thumbprints and the Visual Studio settings hash, which nightly maintenance compares
   - Reads D18, fingerprint: Running guest (certificates, VS settings)
11. `Write-TextFileAtomic` (Common, called by Save-GuestState): the manifest, in the capture folder and as the newest capture, which restore reads
   - Also runs `Get-CaptureManifestPath`
   - Writes D19, manifest: <VM>\State\ (Captures\<stamp>\manifest.json, manifest.json)
12. `Remove-OldCapture` (Capture, called by Save-GuestState): keeps the newest 3 capture folders
   - Writes D20, older captures deleted: <VM>\State\Captures\ (all but the newest 3)

<a id="restore"></a>

## Restore state

`Restore-LazyVMState` `-Name <VM>`

Puts the newest capture and the VM's records back into the VM. A rebuild runs the same restore.

![Restore state: call order and data flow](diagrams/restore.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Restore-GuestState` (Restore): steps 3-9 are its calls; each area runs isolated (Invoke-IsolatedStep), so a failed one does not stop the rest
   - Also runs `Invoke-IsolatedStep`, `Get-CaptureManifestPath`
3. `Get-CaptureManifest` (Capture, called by Restore-GuestState): none: nothing to restore, and that is not a failure
   - Reads D3, what was captured: <VM>\State\ (manifest.json)
4. `Open-GuestSession` (Guest, called by Restore-GuestState): starts the VM if it is off and waits for it
   - Reads D4, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D5, PowerShell Direct session: VM <VM> (running, reachable)
5. `Initialize-GuestSqlDisk` (Installation, called by Restore-GuestState): finds the data disk's letter
6. `Restore-GuestWindowsState` (Restore, called by Restore-GuestState): 10a: environment, firewall rules and scheduled tasks from VM.json; certificates from the archive
   - Reads D6, records: <VM>\Config\ (VM.json  GuestEnvironment,, GuestFirewallRules, GuestScheduledTasks)
   - Reads D7, Windows archive: <VM>\State\Captures\<stamp>\ (windows\winstate.zip)
   - Reads D8, secrets, certificate password: Credential store (<VM>\Credentials\)
   - Writes D9, Windows restored: New guest (environment, firewall rules, scheduled tasks, certificates)
7. `Restore-GuestVisualStudioState` (Restore, called by Restore-GuestState): 10b: Visual Studio files
   - Reads D10, VS files: <VM>\State\Captures\<stamp>\ (vs\)
   - Writes D11, VS files restored: New guest (NuGet.Config, .gitconfig, snippets, templates)
8. `Restore-GuestSqlState` (Restore, called by Restore-GuestState): 10c: instance settings, logins with their SIDs, databases (attached from D:, or from their backups), then Agent jobs
   - Reads D12, SQL records: <VM>\Config\ (VM.json  GuestSql)
   - Reads D13, database files and backups: D: data disk (D:\SQLData\, D:\SQLBackup\<database>.bak)
   - Writes D14, SQL restored: SQL Server (settings, logins, databases, Agent jobs, operators, alerts)
9. `Restore-GuestAppSetting` (Restore, called by Restore-GuestState): 10e: the application settings VM.json records
   - Reads D15, app settings: <VM>\Config\ (VM.json  GuestAppSettings)
   - Reads D16, secret values: Credential store (<VM>\Credentials\)
   - Writes D17, app settings restored: New guest (registry values written)
10. `Restore-GuestVisualStudioSetting` (Installation): imports the Visual Studio settings; when it cannot, nightly maintenance does
   - Reads D18, VS settings backup: <VM>\Backups\ (VisualStudio.vssettings)
   - Writes D19, VS settings: Visual Studio (imported, or pending)

<a id="export-template"></a>

## Save a VM as a config template

`Export-LazyVMTemplate` `-Name <VM>` `-TemplateName <Template>  (optional)`

Saves a VM's settings and tooling list as a config template that new VMs can start from with -ConfigTemplate. The template is named after the VM unless -TemplateName says otherwise, and never replaces an existing one.

![Save a VM as a config template: call order and data flow](diagrams/export-template.svg)

1. `Resolve-LazyVMRoot` (Settings): the LazyVM folder
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Resolve-VMSelection` (Settings): the VM named, or the only one there is
   - Reads D2, VM profiles: <Root>\ (*\Config\VM.json)
3. `Assert-TemplateNameAvailable` (Settings): stops unless the name is valid and no template, built-in or yours, has it
   - Reads D3, existing templates: Config templates (Data\Templates\*.json, Shared\Templates\*.json)
4. `Export-VMTemplate` (Settings): the VM's settings and tooling list, without the ones each VM has its own of
   - Reads D4, VM configuration: <VM>\Config\ (VM.json)
   - Writes D5, config template: Shared\Templates\ (<Template>.json)
   - Writes D6, the new file: Pipeline (FileInfo)

<a id="remove"></a>

## Remove a VM

`Remove-LazyVM` `-Name <VM>` `-WhatIf  (lists everything)` `-Force  (optional)`

Deletes the VM and everything created for it, Dev Drive and User disk included. Anything another VM also uses is kept and listed with the reason.

![Remove a VM: call order and data flow](diagrams/remove.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Get-VMRemovalContext` (Maintenance): Get-VMRemovalPlan decides what to delete and keep; lists it with sizes
   - Reads D3, other VMs' paths: *\Config\ (other VMs' VM.json)
   - Reads D4, attached disks: Hyper-V (disks of <VM>, disks of other VMs)
   - Writes D5, removal list: Log and screen (what will be deleted, what is kept, and why)
3. `Invoke-VMRemoval` (Maintenance): after you confirm; stops at the VM if it cannot be removed
   - Writes D6, tasks deleted: Task Scheduler (LazyVM-Maintain-<VM>, LazyVM-ResumeAfterReboot-<VM>)
   - Writes D7, registry key deleted: HKLM:\SOFTWARE\LazyVM\<VM> (deleted)
   - Writes D8, VM deleted: Hyper-V (VM <VM> turned off, removed)
4. `Remove-PathWithRetry` (Maintenance, called by Invoke-VMRemoval): what is outside the VM folder first, then the folder; the log goes last, after Stop-Log closes it
   - Also runs `Stop-Log`
   - Writes D9, files deleted: Files outside the VM folder (Shared\Credentials\.lazyvm.key if no other VM uses it, disks, state or backups that a setting put elsewhere; anything another VM uses is kept)
   - Writes D10, VM folder deleted: VM folder (<VM>\ and everything in it: Config, Disks, Checkpoints, State, Backups, Credentials, Logs, Virtual Machines; the log last)

<a id="status"></a>

## List VMs

`Get-LazyVM` `-Name  (wildcards, default *)`

Lists the VMs in the LazyVM folder with their state and maintenance. No administrator rights needed.

![List VMs: call order and data flow](diagrams/status.svg)

1. `Resolve-LazyVMRoot` (Settings): the LazyVM folder
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Get-VMProfileName` (Settings): every VM with a profile, matching -Name
   - Also runs `Get-VMProfilePath`
   - Reads D2, profiles: *\Config\ (VM.json)
3. `Read-VMSetting` (Settings): per VM
   - Reads D3, MaintenanceTime, settings errors: Settings files (Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json)
4. `Get-VM` (Hyper-V): per VM
   - Reads D4, state: Hyper-V (VM state)
5. `Get-ScheduledTask` (ScheduledTasks): per VM
   - Also runs `Get-MaintenanceTaskName`
   - Reads D5, task registered?: Task Scheduler (LazyVM-Maintain-<VM>)
   - Writes D6, VM list: Pipeline (LazyVM.VM per VM)

<a id="settings"></a>

## View settings

`Get-LazyVMSetting` `-Name <VM>` `-Setting  (wildcards)`

Every setting as the VM uses it, where the value came from, and what it does. No administrator rights needed.

![View settings: call order and data flow](diagrams/settings.svg)

1. `Resolve-LazyVMRoot` (Settings): the LazyVM folder
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Read-VMSetting` (Settings): defaults, then host file, then VM profile; later wins
   - Reads D2, defaults: Module Data\ (LazyVM.Settings.schema.json)
   - Reads D3, your values: Settings files (Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json)
3. `Get-SettingDescription` (Settings): per setting, from the schema
   - Also runs `Get-SettingsSchema`
   - Writes D4, effective settings: Pipeline (LazyVM.Setting: Value,, Source, Description)

<a id="license"></a>

## Check the license

`Get-LazyVMLicense` `-Name <VM>`

Evaluation days and rearms left, the last capture, and what the next maintenance run will do. Starts the VM if it is off.

![Check the license: call order and data flow](diagrams/license.svg)

1. `Initialize-CommandRun` (Common): builds the VM context and opens the log
   - Reads D1, settings, VM profile, guest user name: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json, <VM>\Credentials\guest.cred)
   - Writes D2, run log: <VM>\Logs\ (<VM>.log  (appended))
2. `Get-LicenseReport` (Maintenance): steps 3-6 are its calls
3. `Open-GuestSession` (Guest, called by Get-LicenseReport): starts the VM if it is off and waits for it
   - Reads D3, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D4, PowerShell Direct session: VM <VM> (running, reachable)
4. `Get-GuestLicenseStatus` (Maintenance, called by Get-LicenseReport): days left, rearms left
   - Reads D5, license status: Running guest (SoftwareLicensingProduct)
5. `Get-CaptureManifest` (Capture, called by Get-LicenseReport): when the last capture was taken, and its databases
   - Reads D6, last capture, databases: <VM>\State\ (manifest.json)
6. `Get-MaintenanceDecision` (Maintenance, called by Get-LicenseReport): none, rearm or rebuild
   - Writes D7, license report: Pipeline (LazyVM.License: days, rearms,, last capture, next action)

<a id="credential-view"></a>

## See the guest account

`Get-LazyVMCredential` `-Name <VM>` `-AsPlainText | -ToClipboard | -RecoveryPassword  (optional)`

Returns the account LazyVM uses inside the VM. -AsPlainText shows the password; -ToClipboard puts it on the clipboard, out of clipboard history; -RecoveryPassword lists the BitLocker recovery passwords instead.

![See the guest account: call order and data flow](diagrams/credential-view.svg)

1. `Read-VMSetting` (Settings): finds the key and the credential files
   - Also runs `Resolve-LazyVMRoot`
   - Reads D1, settings: Settings files (Shared\Config\LazyVM.Settings.json, <VM>\Config\VM.json)
2. `Get-StoredCredential` (Credentials): decrypts with the key
   - Reads D2, guest credential: Credential store (Shared\Credentials\.lazyvm.key, <VM>\Credentials\guest.cred)
   - Writes D3, credential: Pipeline (PSCredential, or user name, and password as text)
3. `Get-StoredSecretTable` (Credentials): with -RecoveryPassword, instead: every disk's BitLocker recovery password
   - Reads D4, recovery passwords: Credential store (<VM>\Credentials\bitlocker.cred)
   - Writes D5, recovery passwords: Pipeline (Disk, DiskGuid, Recorded,, RecoveryPassword)
4. `Set-ClipboardSecret` (Credentials): with -ToClipboard: the password, kept out of clipboard history and sync
   - Writes D6, password: Clipboard (not in history or sync)

<a id="test"></a>

## Check a VM end to end

`Test-LazyVM` `-Name <VM>` `-ReportPath <file>  (optional)`

Checks the LazyVM folder, the ISOs, the VM, PowerShell Direct, the guest's set-up and the maintenance task, and says what to run to fix each. Reads only: a VM that is off is not started.

![Check a VM end to end: call order and data flow](diagrams/test.svg)

1. `Get-LazyVMDiagnostic` (Maintenance): every check in order; one that cannot be made is a FAIL and the rest still run
   - Also runs `Resolve-LazyVMRoot`, `Read-VMSetting`, `Get-IsoCheck`, `Get-StoredCredential`, `New-DiagnosticCheck`
   - Reads D1, folder and settings: VM context sources (HKLM:\SOFTWARE\LazyVM  Root, <VM>\Config\VM.json)
   - Reads D2, media: Shared\ (ISO\Win11Ent_Eval.iso, Installers\SQLServer2025 ISO)
   - Reads D3, VM and task: Hyper-V and Task Scheduler (VM <VM>, LazyVM-Maintain-<VM>)
   - Reads D4, guest set-up, if running: Running guest (PowerShell Direct, disks, automatic sign-in on or off)
   - Writes D5, checks: Pipeline (Status, Area, Check, Detail)
2. `Set-Content` (PowerShell): only with -ReportPath: the same checks as a text report
   - Writes D6, report: -ReportPath (<file>)

---

Drawn by `./Update-Diagram.ps1` from `docs/diagrams/source`, one source per diagram. When a command's calls change, change its source and run it: the tests fail while a diagram names a function that does not exist, leaves out a call the code it covers makes, or has not been redrawn.

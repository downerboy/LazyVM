# LazyVM diagrams

One diagram per thing you do with LazyVM. Each shows the calls in order down the middle, data read on the left and data written on the right. Every diagram is followed by the same information as a numbered list.

## How to read them

- **Blue arrows** are calls, numbered in the order they run.
- **Dashed orange arrows** are data, numbered D1, D2 and so on. An arrow into a call is data read; an arrow out of it is data written.
- Host paths are relative to the LazyVM folder (`HKLM:\SOFTWARE\LazyVM` `Root`), for example `D:\DevVM`. Inside the VM, `D:` is the SQL data disk and `W:` is the Dev Drive.
- Every command except `Get-LazyVM`, `Get-LazyVMSetting`, `New-LazyVM` and `Get-LazyVMCredential` starts with `Initialize-CommandRun` and ends with `Complete-CommandRun`, which closes the guest session and clears `$CFG`.
- A call that happens only in some cases says so in its box.

## Contents

- Install: [Install from the repository](#install-from-repo), [Install from a release](#install-from-release)
- Set up: [Choose the LazyVM folder](#set-root), [Create a VM profile without building](#new-profile), [Store the guest account](#set-credential)
- Build: [Build a VM](#build)
- Maintain: [Daily maintenance](#maintenance), [Schedule maintenance again](#register-maintenance), [Rebuild a VM](#rebuild)
- Tooling: [Record tooling now](#tooling-record), [See installed tooling](#tooling-view), [List tooling restore points](#restore-points), [Return to an earlier tooling version](#tooling-revert)
- State: [Capture state](#capture), [Restore state](#restore)
- Remove: [Remove a VM](#remove)
- Check: [List VMs](#status), [View settings](#settings), [Check the licence](#license), [See the guest account](#credential-view)

<a id="install-from-repo"></a>

## Install from the repository

`./build.ps1 -Task Install` `-Bootstrap  (first time)`

Builds the module, checks it and runs the tests, then installs it for all users only if every check passes. Any failure stops the script before step 5.

![Install from the repository: call order and data flow](diagrams/install-from-repo.svg)

1. `Invoke-Build` (build.ps1): merges Public\ and Private\ into one .psm1, then imports it to check the exports
   - Reads D1, module source: src\Massokissed.LazyVM\ (Public\  Private\  Data\, Massokissed.LazyVM.psd1)
   - Writes D2, built module: out\Massokissed.LazyVM\ (<version>\)
2. `Import-BuildTool` (build.ps1): missing and no -Bootstrap: stops with a message
   - Reads D3, pinned build tools: PowerShell Gallery (PSScriptAnalyzer 1.24.0, Pester 5.7.1)
   - Writes D4, build tools, if they were missing: CurrentUser modules (PSScriptAnalyzer, Pester)
3. `Invoke-Analyze` (build.ps1): in a job of its own; any finding stops here
   - Reads D5, code and analyzer rules: Repo (src\  tests\, PSScriptAnalyzerSettings.psd1)
4. `Invoke-Test` (build.ps1): any failure stops here
   - Reads D6, Pester tests: Repo (tests\*.Tests.ps1)
   - Writes D7, test results: out\ (testResults.xml)
5. `Install-BuiltModule` (build.ps1): replaces the same version, leaves other versions
   - Reads D8, built module: out\Massokissed.LazyVM\ (<version>\)
   - Writes D9, module installed for all users, SYSTEM included: $env:ProgramFiles\PowerShell\ (Modules\Massokissed.LazyVM\, <version>\)

<a id="install-from-release"></a>

## Install from a release

`.\LazyVM\Install.ps1` 

Copies the module from a downloaded release and unblocks it.

![Install from a release: call order and data flow](diagrams/install-from-release.svg)

1. `Copy-Item` (Install.ps1): newest version folder beside the script
   - Reads D1, module from the zip: LazyVM\Massokissed.LazyVM\ (<version>\)
   - Writes D2, module installed for all users: $env:ProgramFiles\PowerShell\ (Modules\Massokissed.LazyVM\, <version>\)
2. `Unblock-File` (Install.ps1): removes the downloaded- from-internet mark
   - Writes D3, files PowerShell will load: Modules\Massokissed.LazyVM\ (<version>\  (unblocked))

<a id="set-root"></a>

## Choose the LazyVM folder

`Set-LazyVMRoot` `-Path D:\DevVM`

Optional. Without it, Build-LazyVM picks LazyVM on the NTFS drive with the most free space. Nothing in the old folder is moved.

![Choose the LazyVM folder: call order and data flow](diagrams/set-root.svg)

1. `Resolve-SettingsRoot` (Configuration): checks it is a full local path
2. `Get-RegisteredRoot` (Configuration): warns if a different folder was in use
   - Reads D1, previous folder: HKLM:\SOFTWARE\LazyVM (Root)
3. `Set-RegisteredRoot` (Configuration)
   - Writes D2, new folder, read by every later run: HKLM:\SOFTWARE\LazyVM (Root = D:\DevVM)
4. `Initialize-ConfigFolder` (Configuration): copies the schema for VS Code autocomplete
   - Reads D3, settings schema: Module Data\ (LazyVM.Settings.schema.json)
   - Writes D4, schema copy, empty settings file: D:\DevVM\Config\ (LazyVM.Settings.schema.json, LazyVM.Settings.json (if new))
5. `Import-LegacyConfiguration` (Configuration): LazyVM 1.x kit only
   - Reads D5, 1.x settings: D:\DevVM\Scripts\Config\ (1.x settings)
   - Writes D6, settings carried across: D:\DevVM\Config\ (LazyVM.Settings.json, VMs\<VM>\VM.json)
6. `Register-RebuildSchedule` (Maintenance): only for VMs whose task still runs a 1.x script
   - Writes D7, task moved to LazyVM 2: Task Scheduler (LazyVM-Maintain-<VM>, old 1.x task removed)

<a id="new-profile"></a>

## Create a VM profile without building

`New-LazyVM` `-Name <VM>` `-From <OtherVM>  (optional)`

Creates the profile only. Build-LazyVM does this by itself when the profile is missing.

![Create a VM profile without building: call order and data flow](diagrams/new-profile.svg)

1. `Resolve-LazyVMRoot` (Configuration)
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `New-VMProfile` (Configuration): copies -From settings except paths, computer name and maintenance time; schedules maintenance an hour after the latest existing VM
   - Reads D2, settings and tooling to copy: Config\VMs\<OtherVM>\ (VM.json, Tooling.json  (with -From))
   - Reads D3, maintenance times in use: Config\VMs\*\ (VM.json)
   - Writes D4, new profile: Config\VMs\<VM>\ (VM.json)
   - Writes D5, tooling list to build with: Config\VMs\<VM>\ (Tooling.json  (with -From))
3. `Get-LazyVM` (Public): returns LazyVM.VM

<a id="set-credential"></a>

## Store the guest account

`Set-LazyVMCredential` `-Name <VM>` `-Credential  (optional)`

Optional before a build: Build-LazyVM generates an account if none is stored. This does not change the password inside an existing VM.

![Store the guest account: call order and data flow](diagrams/set-credential.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Get-StoredCredential` (Credentials): asks before replacing unless -Force
   - Reads D3, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
3. `Get-Credential` (PowerShell): prompt, if -Credential was not given
   - Reads D4, credential typed in: You (user name, password, (empty = generate one))
4. `Set-StoredGuestCredential` (Credentials): local accounts only; Save-StoredCredential encrypts with the key
   - Writes D5, encrypted credential: Backup\ (.lazyvm.key  (created once,, SYSTEM + Administrators), <VM>\guest.cred)

<a id="build"></a>

## Build a VM

`Build-LazyVM` `-Name <VM>` `-FromPhase 0-8  (optional)` `-NoUnattend  (optional)`

Invoke-VMBuild runs phases 0 to 8, skipping work already done; Build-LazyVM then schedules maintenance. Running it again finishes an interrupted build.

![Build a VM: call order and data flow](diagrams/build.svg)

1. `Initialize-BuildTarget` (Configuration): first run: picks the root and creates the profile
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root, if already set)
   - Reads D2, drive with most free space: Fixed drives (NTFS, free space)
   - Writes D3, LazyVM folder, first run: HKLM:\SOFTWARE\LazyVM (Root = X:\LazyVM)
   - Writes D4, settings file and profile, if new: Config\ (LazyVM.Settings.json, VMs\<VM>\VM.json)
2. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D5, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D6, run log: Logs\ (<VM>.log  (appended))
3. `Invoke-VMBuild` (Host): runs phases 0-8, starting at -FromPhase or the resume point; steps 4-15 are its calls
4. `Get-ResumePhase` (Host, called by Invoke-VMBuild): picks up after a restart
   - Reads D7, phase to resume at: HKLM:\SOFTWARE\LazyVM\<VM> (ResumePhase)
5. `Repair-HyperVService` (Host, called by Invoke-VMBuild): phases 0-1, with Test-HostReadiness
   - Reads D8, host checks: This PC (vmms, vmcompute, CPU, SLAT, RAM, free space)
6. `Enable-HyperVFeature` (Host, called by Invoke-VMBuild): phase 2; returns RestartPending if needed
   - Writes D9, resume task, only if a restart is needed: Task Scheduler (LazyVM-ResumeAfterReboot-<VM>)
   - Writes D10, where to resume: HKLM:\SOFTWARE\LazyVM\<VM> (ResumePhase = 3)
7. `Initialize-HostFolder` (Host, called by Invoke-VMBuild): phase 3
   - Writes D11, folders created if missing: <Root>\ (ISO, Installers, VMs, SQLDisk, DevDrive, Backup, Logs, Checkpoints\<VM>)
8. `Confirm-InstallMedia` (Host, called by Invoke-VMBuild): phase 4: Resolve-InstallationIso and Resolve-SqlServerIso
   - Reads D12, Windows ISO: ISO\  or  Downloads\ (Windows 11 Enterprise, Evaluation ISO)
   - Reads D13, SQL Server ISO: download.microsoft.com (SQL Server 2025 ISO, only if missing)
   - Writes D14, Windows ISO in place: ISO\ (Win11Ent_Eval.iso, (moved from Downloads))
   - Writes D15, SQL Server ISO in place: Installers\ (SQLServer2025-x64-ENU-, EntDev.iso)
9. `Initialize-SqlDataVhd` (Host, called by Invoke-VMBuild): phase 5; also Initialize- DevDriveVhd. Existing disks are never overwritten
   - Writes D16, data disk and Dev Drive: SQLDisk\  DevDrive\ (<VM>.vhdx  (100 GB), <VM>.vhdx  (250 GB))
10. `Get-GuestCredential` (Credentials, called by Invoke-VMBuild): -CreateIfMissing; skipped with -NoUnattend or if the VM exists
   - Reads D17, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D18, credential, if new: Backup\ (.lazyvm.key, <VM>\guest.cred)
11. `New-UnattendSeedDisk` (Host, called by Invoke-VMBuild): answer file for Setup; skipped in the same cases
   - Writes D19, answer-file disc: VMs\ (<VM>-Seed.iso)
12. `New-GuestVM` (Host, called by Invoke-VMBuild): phase 6: Gen 2, Secure Boot, TPM, dynamic memory
   - Reads D20, install discs: ISO\  VMs\ (Win11Ent_Eval.iso, <VM>-Seed.iso)
   - Writes D21, Windows disk, VM files: VMs\ (<VM>-OS.vhdx, <VM>\  (VM configuration))
   - Writes D22, new VM: VM <VM> (started from the ISO,, Windows installs unattended)
13. `Install-GuestSoftware` (Installation, called by Invoke-VMBuild): phase 7: waits for Setup, attaches D: and W:, customizes Windows, installs the tooling list
   - Reads D23, tooling list: Config\VMs\<VM>\ (Tooling.json, or the module's, Data\Tooling.Default.json)
   - Reads D24, SQL Server media: Installers\ (SQLServer2025 ISO)
   - Writes D25, installed tooling: Guest (D: data disk, W: Dev Drive, VS + SSMS, extensions, SQL Server 2025, winget apps)
   - Writes D26, what needs a manual install: State\<VM>\ (reinstall-by-hand.txt)
14. `Complete-GuestConfiguration` (Installation, called by Invoke-VMBuild): phase 8: SQL files to D:, VS settings, databases
   - Reads D27, VS settings backup: Backup\<VM>\ (VisualStudio.vssettings)
   - Reads D28, database backups: D:\SQLBackup\ (<database>.bak)
   - Writes D29, configured guest: Guest (SQL data on D:\SQLData, VS settings imported, databases restored)
15. `Unregister-ResumeTask` (Host, called by Invoke-VMBuild)
   - Writes D30, resume entries removed: Task Scheduler (resume task deleted, ResumePhase cleared)
16. `Register-RebuildSchedule` (Maintenance): a failure here is logged, the build still stands
   - Reads D31, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D32, daily maintenance task: Task Scheduler (LazyVM-Maintain-<VM>, daily at MaintenanceTime, runs as SYSTEM)

<a id="maintenance"></a>

## Daily maintenance

`Invoke-LazyVMMaintenance` `-Name <VM>`

Records tooling changes every day, then acts on the evaluation licence only when it is within RebuildThresholdDays (10) of expiry.

Called by: `LazyVM-Maintain-<VM>` (daily at MaintenanceTime, as SYSTEM).

![Daily maintenance: call order and data flow](diagrams/maintenance.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Invoke-Maintenance` (Maintenance): steps 3-9 are its calls; no VM: returns "build" and Invoke-Rebuild runs instead
   - Reads D3, does the VM exist: Hyper-V (Get-VM <VM>)
3. `Connect-Guest` (Guest, called by Invoke-Maintenance): starts the VM first if off (Wait-GuestReady)
   - Reads D4, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D5, PowerShell Direct session: VM <VM> (running, reachable)
4. `Update-ToolingRecord` (Tooling, called by Invoke-Maintenance): takes the checkpoint before adopting a change; a failure does not stop the run
   - Reads D6, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D7, last recorded tooling list: Config\VMs\<VM>\ (Tooling.json)
   - Writes D8, today's copy, always: Config\VMs\<VM>\History\ (Daily\Tooling-<date>.json)
   - Writes D9, checkpoint, only on a change: Checkpoints\<VM>\ (checkpoint "Tooling <stamp>", oldest pruned past 3)
   - Writes D10, new tooling version, only on a change: Config\VMs\<VM>\ (Tooling.json, History\Tooling-<stamp>.json)
5. `Get-GuestLicenseStatus` (Maintenance, called by Invoke-Maintenance): days left, rearms left
   - Reads D11, licence status: Running guest (SoftwareLicensingProduct, SoftwareLicensingService)
6. `Get-MaintenanceDecision` (Maintenance, called by Invoke-Maintenance): > threshold or no countdown: none; rearms left: rearm; otherwise: rebuild
   - Reads D12, threshold: $CFG (RebuildThresholdDays = 10)
7. `Save-GuestState` (Capture, called by Invoke-Maintenance): only on rearm or rebuild (see Capture state)
   - Reads D13, state to keep: Running guest (VS settings, .vsconfig, SQL databases + logins, env, certs, tasks, apps)
   - Writes D14, captured state: State\<VM>\ (vs\  windows\  sql\, projects\  apps\, manifest.json, manifest-<stamp>.json)
8. `Invoke-GuestRearm` (Maintenance, called by Invoke-Maintenance): slmgr rearm, then Restart-GuestAndWait
   - Writes D15, rearmed Windows: Running guest (evaluation reset to 90 days, one rearm used)
9. `Stop-GuestGracefully` (Maintenance, called by Invoke-Maintenance): only if the VM was off before the run
   - Writes D16, VM back off: VM <VM> (off)
10. `Invoke-Rebuild -SkipCapture` (Maintenance): only when no rearms are left or the rearm failed (see Rebuild)

<a id="register-maintenance"></a>

## Schedule maintenance again

`Register-LazyVMMaintenance` `-Name <VM>`

Build-LazyVM already does this. Use it after changing MaintenanceTime, or if scheduling failed during a build.

![Schedule maintenance again: call order and data flow](diagrams/register-maintenance.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Register-RebuildSchedule` (Maintenance): refuses without a stored credential or a valid HH:mm MaintenanceTime
   - Reads D3, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D4, daily maintenance task: Task Scheduler (LazyVM-Maintain-<VM>, daily at MaintenanceTime, SYSTEM, wake to run,, 6 h limit, 2 retries)

<a id="rebuild"></a>

## Rebuild a VM

`Invoke-LazyVMRebuild` `-Name <VM>` `-SkipCapture, -NoUnattend`

Capture, retire the old VM, build a new one, restore, verify. The old Windows disk is deleted only after the new VM passes verification. The data disk and Dev Drive are never touched.

Called by: `Invoke-LazyVMMaintenance` (no rearms left).

![Rebuild a VM: call order and data flow](diagrams/rebuild.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Invoke-Rebuild` (Maintenance): steps 3-15 are its calls
3. `Save-GuestState` (Capture, called by Invoke-Rebuild): skipped with -SkipCapture: the last manifest is used
   - Reads D3, state to keep: Running guest (VS settings, .vsconfig, SQL databases + logins, env, certs, tasks, apps)
   - Writes D4, captured state: State\<VM>\ (vs\  windows\  sql\, projects\  apps\, manifest.json, manifest-<stamp>.json)
   - Writes D5, database backups on the data disk: D:\SQLBackup\ (<database>.bak)
4. `Invoke-RetireCurrentVM` (Maintenance, called by Invoke-Rebuild): only if the VM exists; shuts down, removes checkpoints and the VM definition; keeps disks
   - Reads D6, old VM: VM <VM> (old VM, checkpoints)
   - Writes D7, old Windows disk set aside: VMs\ (<VM>-OS.retired-<stamp>.vhdx, <VM>.retired-<stamp>\, <VM>-Seed.iso deleted)
5. `Initialize-HostFolder` (Host, called by Invoke-Rebuild): phase 3
   - Writes D8, folders created if missing: <Root>\ (ISO, Installers, VMs, SQLDisk, DevDrive, Backup, Logs, Checkpoints\<VM>)
6. `Confirm-InstallMedia` (Host, called by Invoke-Rebuild): phase 4: Resolve-InstallationIso and Resolve-SqlServerIso
   - Reads D9, Windows ISO: ISO\  or  Downloads\ (Windows 11 Enterprise, Evaluation ISO)
   - Reads D10, SQL Server ISO: download.microsoft.com (SQL Server 2025 ISO, only if missing)
   - Writes D11, Windows ISO in place: ISO\ (Win11Ent_Eval.iso, (moved from Downloads))
   - Writes D12, SQL Server ISO in place: Installers\ (SQLServer2025-x64-ENU-, EntDev.iso)
7. `Initialize-SqlDataVhd` (Host, called by Invoke-Rebuild): phase 5; also Initialize- DevDriveVhd. Existing disks are kept: they hold your data
   - Writes D13, data disk and Dev Drive: SQLDisk\  DevDrive\ (<VM>.vhdx  (100 GB), <VM>.vhdx  (250 GB))
8. `Get-GuestCredential` (Credentials, called by Invoke-Rebuild): -CreateIfMissing; skipped with -NoUnattend
   - Reads D14, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D15, credential, if new: Backup\ (.lazyvm.key, <VM>\guest.cred)
9. `New-UnattendSeedDisk` (Host, called by Invoke-Rebuild): answer file for Setup; skipped in the same cases
   - Writes D16, answer-file disc: VMs\ (<VM>-Seed.iso)
10. `New-GuestVM` (Host, called by Invoke-Rebuild): phase 6: Gen 2, Secure Boot, TPM, dynamic memory
   - Reads D17, install discs: ISO\  VMs\ (Win11Ent_Eval.iso, <VM>-Seed.iso)
   - Writes D18, Windows disk, VM files: VMs\ (<VM>-OS.vhdx, <VM>\  (VM configuration))
   - Writes D19, new VM: VM <VM> (started from the ISO,, Windows installs unattended)
11. `Install-GuestSoftware` (Installation, called by Invoke-Rebuild): phase 7: waits for Setup, attaches D: and W:, customizes Windows, installs the tooling list
   - Reads D20, tooling list: Config\VMs\<VM>\ (Tooling.json, or the module's, Data\Tooling.Default.json)
   - Reads D21, SQL Server media: Installers\ (SQLServer2025 ISO)
   - Writes D22, installed tooling: Guest (D: data disk, W: Dev Drive, VS + SSMS, extensions, SQL Server 2025, winget apps)
   - Writes D23, what needs a manual install: State\<VM>\ (reinstall-by-hand.txt)
12. `Complete-GuestConfiguration` (Installation, called by Invoke-Rebuild): phase 8: SQL files to D:, VS settings, databases
   - Reads D24, VS settings backup: Backup\<VM>\ (VisualStudio.vssettings)
   - Reads D25, database backups: D:\SQLBackup\ (<database>.bak)
   - Writes D26, configured guest: Guest (SQL data on D:\SQLData, VS settings imported, databases restored)
13. `Restore-GuestState` (Restore, called by Invoke-Rebuild): Windows, VS, SQL, projects, app settings; a failed step does not stop the rest
   - Reads D27, captured state: State\<VM>\ (manifest.json and, captured files)
   - Writes D28, restored state: New guest (state put back)
14. `Test-RebuiltVM` (Maintenance, called by Invoke-Rebuild): VM running and reachable, products, SQL, databases online, D: and W: mounted
   - Reads D29, products expected: Config\VMs\<VM>\ (Tooling.json)
   - Reads D30, databases expected: State\<VM>\ (manifest.json  Databases)
15. `Remove-RetiredVM` (Maintenance, called by Invoke-Rebuild): passed: deletes the retired disk (DeleteRetiredDisk- OnSuccess). Failed: keeps it and logs how to roll back
   - Writes D31, disk space reclaimed: VMs\ (<VM>-OS.retired-<stamp>.vhdx, <VM>.retired-<stamp>\, deleted)

<a id="tooling-record"></a>

## Record tooling now

`Save-LazyVMTooling` `-Name <VM>`

Does now what maintenance does every day. Get-LazyVMTooling shows the same comparison without recording anything.

![Record tooling now: call order and data flow](diagrams/tooling-record.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Open-GuestSession` (Tooling): starts the VM if it is off, connects with PowerShell Direct
   - Reads D3, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D4, VM started if it was off: VM <VM> (running)
3. `Update-ToolingRecord` (Tooling): takes the checkpoint before adopting a change
   - Reads D5, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D6, last recorded tooling list: Config\VMs\<VM>\ (Tooling.json)
   - Writes D7, today's copy, always: Config\VMs\<VM>\History\ (Daily\Tooling-<date>.json)
   - Writes D8, checkpoint, only on a change: Checkpoints\<VM>\ (checkpoint "Tooling <stamp>", oldest pruned past 3)
   - Writes D9, new tooling version, only on a change: Config\VMs\<VM>\ (Tooling.json, History\Tooling-<stamp>.json)
4. `Stop-GuestGracefully` (Maintenance): only if it was started here
   - Writes D10, VM back off: VM <VM> (off)

<a id="tooling-view"></a>

## See installed tooling

`Get-LazyVMTooling` `-Name <VM>`

Lists what is installed and what the next maintenance run would record.

![See installed tooling: call order and data flow](diagrams/tooling-view.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Get-GuestToolingReport` (Tooling): inventory, then Compare-ToolingRecord against the recorded list
   - Reads D3, what is installed: Guest tooling (vswhere + vs_installer export, winget export, Marketplace extensions)
   - Reads D4, last recorded tooling list: Config\VMs\<VM>\ (Tooling.json)
   - Writes D5, raw inventory: State\<VM>\tooling\ (inventory-<stamp>.json)
   - Writes D6, report: Pipeline (LazyVM.Tooling, pending changes)

<a id="restore-points"></a>

## List tooling restore points

`Get-LazyVMRestorePoint` `-Name <VM>`

Lists the recorded tooling versions you can return to.

![List tooling restore points: call order and data flow](diagrams/restore-points.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Get-ToolingRestorePoint` (Tooling): one per "Tooling" checkpoint
   - Reads D3, checkpoints: Checkpoints\<VM>\ ("Tooling <stamp>")
   - Reads D4, tooling lists: Config\VMs\<VM>\History\ (Tooling-<stamp>.json)
   - Writes D5, restore points: Pipeline (LazyVM.RestorePoint: stamp,, taken, HasToolingList)

<a id="tooling-revert"></a>

## Return to an earlier tooling version

`Restore-LazyVMTooling` `-Name <VM>` `-RestorePoint yyyyMMdd-HHmmss`

Returns ALL the VM's disks to that checkpoint, Dev Drive and data disk included. The revert itself can be undone.

![Return to an earlier tooling version: call order and data flow](diagrams/tooling-revert.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Invoke-ToolingRevert` (Tooling): steps 3-5 are its calls; stops if the checkpoint or its list is missing
   - Reads D3, chosen checkpoint: Checkpoints\<VM>\ ("Tooling <stamp>")
   - Reads D4, that version's list: Config\VMs\<VM>\History\ (Tooling-<stamp>.json)
3. `New-ToolingCheckpoint` (Tooling, called by Invoke-ToolingRevert): -SkipPrune: the current state, so the revert can be undone
   - Reads D5, current list: Config\VMs\<VM>\ (Tooling.json)
   - Writes D6, safety checkpoint: Checkpoints\<VM>\ ("Tooling <now> before revert")
   - Writes D7, current list kept: Config\VMs\<VM>\History\ (Tooling-<now>.json)
4. `Restore-VMSnapshot` (Hyper-V, called by Invoke-ToolingRevert): starts the VM again if it was running
   - Writes D8, VM returned to that version: VM <VM> (every disk back to <stamp>)
5. `Write-TextFileAtomic` (Common, called by Invoke-ToolingRevert)
   - Writes D9, tooling list matches the VM: Config\VMs\<VM>\ (Tooling.json)

<a id="capture"></a>

## Capture state

`Save-LazyVMState` `-Name <VM>`

Copies everything a rebuild must keep to the host. Maintenance and rebuilds run the same capture.

![Capture state: call order and data flow](diagrams/capture.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Save-GuestState` (Capture): steps 3-11 are its calls; a failed step is logged and the rest still run
3. `Connect-Guest` (Guest, called by Save-GuestState): starts the VM first if off (Wait-GuestReady)
   - Reads D3, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D4, PowerShell Direct session: VM <VM> (running, reachable)
4. `Initialize-GuestSqlDisk` (Installation, called by Save-GuestState): makes sure D: is online
5. `Get-GuestIdentity` (Capture, called by Save-GuestState): computer name, OS build
   - Reads D5, guest identity: Guest (identity)
6. `Save-GuestVisualStudioState` (Capture, called by Save-GuestState)
   - Reads D6, Visual Studio: Guest (VS settings, .vsconfig, per instance)
   - Writes D7, VS state: State\<VM>\vs\ (settings, vs.vsconfig)
   - Writes D8, settings used by phase 8: Backup\<VM>\ (VisualStudio.vssettings)
7. `Save-GuestSqlState` (Capture, called by Save-GuestState): BACKUP DATABASE per user database, plus logins
   - Reads D9, databases: SQL Server (user databases, logins)
   - Writes D10, backups on the data disk: D:\SQLBackup\ (<database>.bak)
   - Writes D11, SQL state: State\<VM>\sql\ (logins, database list)
8. `Save-GuestWindowsState` (Capture, called by Save-GuestState): certificates encrypted with certs.cred
   - Reads D12, Windows environment: Guest (environment, certificates, scheduled tasks, settings)
   - Writes D13, Windows state: State\<VM>\windows\ (zip of the export)
   - Writes D14, certificate password: Backup\<VM>\ (certs.cred)
9. `Save-GuestProjectFolder` (Capture, called by Save-GuestState): skips bin, obj, .git ... up to MaxProjectCaptureGB
   - Reads D15, project files: GuestProjectPaths (source\repos, Documents ...)
   - Writes D16, project files: State\<VM>\projects\ (zip)
10. `Save-GuestAppSetting` (Capture, called by Save-GuestState)
   - Reads D17, registry keys: AppSettings keys (HKCU\Software\...)
   - Writes D18, application settings: State\<VM>\apps\ (<Name>.reg)
11. `Write-TextFileAtomic` (Common, called by Save-GuestState): failed steps are listed as warnings
   - Writes D19, manifest: State\<VM>\ (manifest.json, manifest-<stamp>.json)

<a id="restore"></a>

## Restore state

`Restore-LazyVMState` `-Name <VM>`

Applies the last capture to the VM. A rebuild runs this after installing.

![Restore state: call order and data flow](diagrams/restore.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Restore-GuestState` (Restore): steps 3-10 are its calls; a failed step is logged and the rest still run
3. `Get-CaptureManifest` (Capture, called by Restore-GuestState): none: nothing to restore
   - Reads D3, what was captured: State\<VM>\ (manifest.json)
4. `Connect-Guest` (Guest, called by Restore-GuestState): starts the VM first if off
   - Reads D4, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D5, PowerShell Direct session: VM <VM> (running, reachable)
5. `Initialize-GuestSqlDisk` (Installation, called by Restore-GuestState): makes sure D: is online
6. `Restore-GuestWindowsState` (Restore, called by Restore-GuestState): 10a
   - Reads D6, Windows state: State\<VM>\windows\ (zip)
   - Writes D7, Windows restored: Guest (environment, certificates)
7. `Restore-GuestVisualStudioState` (Restore, called by Restore-GuestState): 10b
   - Reads D8, VS state: State\<VM>\vs\ (settings, vs.vsconfig)
   - Writes D9, VS restored: Guest (VS settings imported)
8. `Restore-GuestSqlState` (Restore, called by Restore-GuestState): 10c
   - Reads D10, backups: D:\SQLBackup\ (<database>.bak)
   - Reads D11, logins: State\<VM>\sql\ (logins)
   - Writes D12, SQL restored: SQL Server (databases and logins)
9. `Restore-GuestProjectFolder` (Restore, called by Restore-GuestState): 10d, under GuestRestoreRoot
   - Reads D13, project files: State\<VM>\projects\ (zip)
   - Writes D14, projects restored: Guest (%USERPROFILE%\source)
10. `Restore-GuestAppSetting` (Restore, called by Restore-GuestState): 10e
   - Reads D15, app settings: State\<VM>\apps\ (<Name>.reg)
   - Writes D16, app settings restored: Guest (HKCU keys imported)

<a id="remove"></a>

## Remove a VM

`Remove-LazyVM` `-Name <VM>` `-WhatIf lists everything`

Deletes the VM and everything created for it, Dev Drive included. Anything another VM also uses is kept and listed with the reason.

![Remove a VM: call order and data flow](diagrams/remove.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Get-VMRemovalContext` (Maintenance): Get-VMRemovalPlan decides what to delete and keep; lists it with sizes
   - Reads D3, other VMs' paths: Config\VMs\*\ (other VMs' VM.json)
   - Reads D4, attached disks: Hyper-V (disks of <VM>, disks of other VMs)
   - Writes D5, removal list: Log and screen (what will be deleted, what is kept, and why)
3. `Invoke-VMRemoval` (Maintenance): after you confirm; stops at the VM if it cannot be removed
   - Writes D6, tasks deleted: Task Scheduler (LazyVM-Maintain-<VM>, LazyVM-ResumeAfterReboot-<VM>)
   - Writes D7, registry key deleted: HKLM:\SOFTWARE\LazyVM\<VM> (deleted)
   - Writes D8, VM deleted: Hyper-V (VM <VM> turned off, removed)
4. `Remove-PathWithRetry` (Maintenance, called by Invoke-VMRemoval): files, then folders; the log goes last
   - Writes D9, files deleted: Files (SQLDisk\<VM>.vhdx, DevDrive\<VM>.vhdx, VMs\<VM>-OS.vhdx, -Seed.iso, Backup\<VM>\*.cred, .vssettings, .lazyvm.key if no other VM, Logs\<VM>.log)
   - Writes D10, folders deleted: Folders (Checkpoints\<VM>, State\<VM>, VMs\<VM>, Config\VMs\<VM>)

<a id="status"></a>

## List VMs

`Get-LazyVM` `-Name  (wildcards, default *)`

No administrator rights needed.

![List VMs: call order and data flow](diagrams/status.svg)

1. `Resolve-LazyVMRoot` (Configuration)
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Get-VMProfileName` (Configuration)
   - Reads D2, profiles: Config\VMs\*\ (VM.json)
3. `Read-VMSetting` (Configuration): per VM
   - Reads D3, MaintenanceTime, settings errors: Config\ (LazyVM.Settings.json, VMs\<VM>\VM.json)
4. `Get-VM` (Hyper-V): per VM
   - Reads D4, state: Hyper-V (VM state)
5. `Get-ScheduledTask` (ScheduledTasks): per VM
   - Reads D5, task registered?: Task Scheduler (LazyVM-Maintain-<VM>)
   - Writes D6, VM list: Pipeline (LazyVM.VM per VM)

<a id="settings"></a>

## View settings

`Get-LazyVMSetting` `-Name <VM>` `-Setting  (wildcards)`

Every setting as the VM uses it, where the value came from, and what it does. No administrator rights needed.

![View settings: call order and data flow](diagrams/settings.svg)

1. `Resolve-LazyVMRoot` (Configuration)
   - Reads D1, LazyVM folder: HKLM:\SOFTWARE\LazyVM (Root)
2. `Read-VMSetting` (Configuration): defaults, then host file, then VM profile; later wins
   - Reads D2, defaults: Module Data\ (LazyVM.Settings.schema.json)
   - Reads D3, your values: Config\ (LazyVM.Settings.json, VMs\<VM>\VM.json)
3. `Get-SettingDescription` (Configuration): per setting, from the schema
   - Writes D4, effective settings: Pipeline (LazyVM.Setting: Value,, Source, Description)

<a id="license"></a>

## Check the licence

`Get-LazyVMLicense` `-Name <VM>`

Evaluation days and rearms left, the last capture, and what the next maintenance run will do. Starts the VM if it is off.

![Check the licence: call order and data flow](diagrams/license.svg)

1. `Initialize-CommandRun` (Common): loads the settings into $CFG and opens the log
   - Reads D1, settings, VM profile, guest user name: $CFG sources (HKLM:\SOFTWARE\LazyVM  Root, Config\LazyVM.Settings.json, Config\VMs\<VM>\VM.json, Backup\<VM>\guest.cred)
   - Writes D2, run log: Logs\ (<VM>.log  (appended))
2. `Get-LicenseReport` (Maintenance): steps 3-6 are its calls
3. `Connect-Guest` (Guest, called by Get-LicenseReport): starts the VM first if off
   - Reads D3, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D4, PowerShell Direct session: VM <VM> (running, reachable)
4. `Get-GuestLicenseStatus` (Maintenance, called by Get-LicenseReport)
   - Reads D5, licence status: Running guest (SoftwareLicensingProduct)
5. `Get-CaptureManifest` (Capture, called by Get-LicenseReport)
   - Reads D6, last capture, databases: State\<VM>\ (manifest.json)
6. `Get-MaintenanceDecision` (Maintenance, called by Get-LicenseReport): none, rearm or rebuild
   - Writes D7, licence report: Pipeline (LazyVM.License: days, rearms,, last capture, next action)

<a id="credential-view"></a>

## See the guest account

`Get-LazyVMCredential` `-Name <VM>` `-AsPlainText  (optional)`

Returns the account LazyVM uses inside the VM. -AsPlainText shows the password.

![See the guest account: call order and data flow](diagrams/credential-view.svg)

1. `Read-VMSetting` (Configuration): finds the key and the credential file
   - Reads D1, settings: Config\ (LazyVM.Settings.json, VMs\<VM>\VM.json)
2. `Get-StoredCredential` (Credentials): decrypts with the key
   - Reads D2, guest credential: Backup\ (.lazyvm.key, <VM>\guest.cred)
   - Writes D3, credential: Pipeline (PSCredential, or user name, and password as text)

---

Generated from the source in `src/`. When a command changes, update the diagram with it.

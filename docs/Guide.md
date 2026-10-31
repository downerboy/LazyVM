# LazyVM guide

Automated build, maintenance and 90-day rebuild of Hyper-V development VMs, one or more per host.

Examples use `D:\DevVM` as the LazyVM folder and `DevBox` as the VM's name. Read them as your own throughout.

## Contents

1. [What LazyVM does](#1-what-lazyvm-does)
2. [Before you start](#2-before-you-start)
3. [Commands](#3-commands)
4. [Everyday use](#4-everyday-use)
5. [The 90-day cycle](#5-the-90-day-cycle)
6. [What each phase does](#6-what-each-phase-does)
7. [Files and folders](#7-files-and-folders)
8. [Settings](#8-settings)
9. [Tooling, and going back](#9-tooling-and-going-back)
10. [Several VMs on one host](#10-several-vms-on-one-host)
11. [Moving files between host and VM](#11-moving-files-between-host-and-vm)
12. [Troubleshooting](#12-troubleshooting)
13. [Habits worth keeping](#13-habits-worth-keeping)

## 1. What LazyVM does

LazyVM builds and looks after Hyper-V development VMs: Windows 11 machines with Visual Studio, SQL Server 2025 Standard Developer and whatever other tools you install. One host can run several, each with its own tools.

The VM runs Windows 11 Enterprise Evaluation, which expires after 90 days. LazyVM exists to make that expiry a non-event. It watches the license and extends it when Windows allows. When extensions run out, it captures everything you care about, rebuilds the VM from scratch and puts your state back.

### The three jobs it does

- **Build.** Create the VM and install Windows unattended. Then install everything in the VM's tooling list (Visual Studio, SSMS, SQL Server, winget packages) with no input from you.
- **Configure.** Attach and prepare the SQL data disk, the Dev Drive and the User disk, encrypt them and `C:` with BitLocker, and relocate databases onto the data disk.
- **Maintain.** Every day, record any tools you have added or removed in the VM, taking a checkpoint first so you can go back. Then check the license. Extend it when possible, and rebuild and restore when it cannot be extended any further.

### What survives a rebuild

A rebuild destroys the VM's operating system. These are carried across it:

- **SQL Server**: user databases (their files stay on the SQL data disk and are attached to the new instance; one that cannot be attached is restored from its backup), plus logins with their original SIDs and password hashes so database users are not orphaned, their server roles, the instance settings, and SQL Agent jobs (with their steps and schedules), operators and alerts, recorded in `VM.json` whenever they change. A job step's command is copied as written, so keep secrets out of it.
- **Visual Studio**: the products you actually have installed (2026, 2022 or both, and SSMS), their workloads and components, Marketplace extensions, your settings, NuGet and Git configuration, snippets and templates.
- **Windows**: environment variables, PATH entries, hosts file entries, mapped drives, and the firewall rules and scheduled tasks you added, recorded in `VM.json` whenever they change (a variable whose name looks secret, such as `GITHUB_TOKEN`, is kept encrypted in `Credentials\environment.cred` instead), plus certificates.
- **The User disk**: a separate persistent disk holding Documents, Desktop, Downloads, `.ssh` and `source\repos`. It is never destroyed, so its contents need no capture. A rebuilt VM's new account is given its folders. [Section 11](#11-moving-files-between-host-and-vm) explains it.
- **Your tools**: every winget package you installed is reinstalled from the VM's tooling list, and application settings such as WinMerge's are carried across. [Section 9](#9-tooling-and-going-back) explains the tooling list.
- **The Dev Drive**: a separate persistent disk holding your working source. It is never destroyed, so its contents need no capture. Source control remains the backup for the code on it. [Section 11](#11-moving-files-between-host-and-vm) explains it.

> **Note**
> Source code belongs on the Dev Drive (`W:`), with source control as its backup. Commit and push regularly. Then a rebuild, or even a lost disk, costs nothing that a fresh clone cannot bring back.

### What it deliberately does not carry across

These are detected and reported by name rather than migrated. Doing them correctly is a project of its own, and a half-working migration is worse than a clear warning.

- Linked servers, SQL credentials, SQL Agent proxies and maintenance plans. A job step that runs as a proxy needs the proxy recreated first.
- The `master`, `model` and `msdb` system databases, which are rebuilt fresh.
- Programs winget cannot install, and Visual Studio extensions not found on the Visual Studio Marketplace. These are listed in a file for you to reinstall by hand ([section 9](#9-tooling-and-going-back)).

## 2. Before you start

### Requirements

- PowerShell 7.6 or later, **run as administrator**. Every command that touches Hyper-V, the registry or scheduled tasks checks for this and says so if it is missing.
- Windows Pro, Enterprise or Education on the host. Hyper-V is not available on Home editions, and LazyVM stops with a clear message if it detects one.
- A genuine Windows 11 Enterprise Evaluation ISO, downloaded by hand ([see below](#the-windows-iso-must-be-supplied-by-hand)). Leaving it in Downloads is enough.

### Installing LazyVM

LazyVM is a PowerShell module. The simplest way to install it is from a [release](https://github.com/downerboy/LazyVM/releases): download the zip, then, in an elevated PowerShell 7, in the folder you saved it to:

```powershell
Unblock-File .\LazyVM-*.zip
Expand-Archive .\LazyVM-*.zip -DestinationPath .\LazyVM -Force
.\LazyVM\Install.ps1
```

`Unblock-File` matters: Windows marks downloaded files, and PowerShell will not run a marked script. To update, do the same with the newer release.

Or build it from the repository, in an elevated PowerShell 7:

```powershell
git clone https://github.com/downerboy/LazyVM S:\Source\LazyVM
cd S:\Source\LazyVM
./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out
```

Instead of typing those, you can double-click `Install-FromRepository.cmd` in the repository folder. It asks for administrator rights, runs the same two commands in PowerShell 7, and keeps its window open so you can read the result.

`Invoke-AnalyzerAndTest.ps1` assembles the module, checks it with PSScriptAnalyzer and runs the Pester tests; only if they all pass does `Install.ps1` install it for all users: the scheduled maintenance runs as SYSTEM and has to be able to find it. The first time, it also installs the versions of Pester and PSScriptAnalyzer it uses. Once installed, PowerShell loads it by itself the first time you use one of its commands.

Make sure it is PowerShell 7 (`pwsh`): Windows PowerShell 5.1 cannot see the module, and reports its commands as not recognized. To update, pull the repository and run the same commands again. The scheduled tasks pick up the new version on their next run.

### Choosing the LazyVM folder

Everything LazyVM creates on the host lives under one folder, the **LazyVM folder** (sometimes called the root):
- a folder for each VM, named after it, with its disks, configuration, profile, logs, encrypted passwords and captured state;
- `Shared`, with the ISO, installers, your settings and the credential key.

The first `Build-LazyVM` chooses it for you: a `LazyVM` folder on the local NTFS drive with the most free space, leaving out drives on a virtual disk. It says which folder it chose. To choose your own, run this before the first build:

```powershell
Set-LazyVMRoot -Path D:\DevVM
```

Either way it is recorded in the registry, under `HKLM:\SOFTWARE\LazyVM`, for every later command and for the scheduled tasks. The folder is created if needed. So are `Shared\Config\LazyVM.Settings.json`, your settings file, and a copy of the settings schema beside it ([section 8](#8-settings)).

> **Important**
> Choose the LazyVM folder before the first build. The VM disks, the credential key and the captured state all live under it, so moving it later means moving those files too.

### The Windows ISO must be supplied by hand

Microsoft's Windows 11 Enterprise evaluation download sits behind a registration form, so it cannot be fetched unattended. An automated attempt returns an HTML page, not an image.

LazyVM therefore **verifies** the ISO rather than downloading it. It reads the ISO 9660 signature at offset 0x8001, so a disguised HTML page is rejected whatever it is named. It looks in three places, in order: the configured path (`Shared\ISO\Win11Ent_Eval.iso` in the LazyVM folder), any other real image in the `Shared\ISO` folder, then a Windows 11 or Enterprise Evaluation ISO in your Downloads folder, which it moves into place. If there is none, the build stops before changing anything on the host and opens the download page in your browser.

Download from <https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise>, leave it in Downloads, and run `Build-LazyVM` again.

The SQL Server ISO is downloaded for you.

### The account LazyVM uses inside the VM

LazyVM talks to the VM over PowerShell Direct, which connects across the Hyper-V VMBus rather than the network. That is what makes it reliable: it keeps working even if the VM has no working network. But PowerShell Direct **always** needs an explicit account and password.

For a VM LazyVM builds, there is nothing to do. `Build-LazyVM` creates the administrator account (`devadmin`) with a generated password and stores both, encrypted, in the LazyVM folder. To see them, for signing in to the VM yourself:

```powershell
Get-LazyVMCredential -Name DevBox -AsPlainText
```

VMConnect does not let you paste into the Windows sign-in box. To sign in without typing the password by hand:

1. Put it on the clipboard: `Get-LazyVMCredential -Name DevBox -ToClipboard`. It is left out of clipboard history (Win+V) and never synced to your other devices.
2. In a basic session, click the password box, then choose **Clipboard > Type clipboard text** in VMConnect's menu. VMConnect types it for you, which also works with a screen reader. In an enhanced session, press Ctrl+V.
3. Once you are signed in, clear the clipboard: `Set-Clipboard -Value $null`.

To choose the account name or the password before the first build, or to tell LazyVM about a VM you set up by hand:

```powershell
Set-LazyVMCredential -Name DevBox
```

It asks for the account and password. Leave the password empty to have one generated.

> **Important**
> For a VM that already exists, type the account's **real** password. A generated one is only right for a VM LazyVM is about to build, which creates the account with it. Storing a new password never changes the password inside an existing VM.

## 3. Commands

Every command has full help, with examples: `Get-Help New-LazyVM -Full`. While the host has one VM, `-Name` can be left out. With several, `-Name` is needed, and LazyVM will not guess. Pressing Tab after `-Name` offers the VMs on this host.

| Command | What it does |
|---|---|
| `LazyVM` | Shows the installed version, the LazyVM folder and each VM in it, the folder the module is installed in, and every command with its synopsis. The same as `Show-LazyVM`. |
| `Set-LazyVMRoot -Path D:\DevVM` | Chooses the LazyVM folder. |
| `New-LazyVM -Name DevBox` | Creates the VM's profile, ready to build. `-From OtherVM` starts from another VM's settings and tooling list. |
| `Build-LazyVM` | Runs phases 0 to 8. Builds the VM if it does not exist. Otherwise it brings an existing VM up to spec: it installs anything missing from its tooling list, attaches and prepares the SQL data disk, and relocates databases. Safe to run again. |
| `Build-LazyVM -FromPhase 7` | Starts at a phase, skipping earlier ones, after fixing what stopped a build. |
| `Build-LazyVM -NoUnattend` | No answer file: Windows Setup has to be completed by hand in VMConnect. |
| `Get-LazyVM` | Lists the VMs, their state in Hyper-V, and their maintenance time and task. |
| `Get-LazyVMSetting` | Every setting as the VM uses it, where the value came from, and what it does. `-Setting Mem*` narrows it. |
| `Set-LazyVMCredential` | Stores the administrator account LazyVM uses inside the VM. |
| `Get-LazyVMCredential` | Gets it. `-AsPlainText` shows the password, and `-ToClipboard` puts it on the clipboard for VMConnect's sign-in box. `-RecoveryPassword` shows the BitLocker recovery password of each disk. |
| `Get-LazyVMLicense` | Evaluation days left, rearms left, and what maintenance will do. Read-only. |
| `Get-LazyVMTooling` | What is installed in the VM, and what the next maintenance run would record. Read-only. |
| `Save-LazyVMTooling` | Records tooling changes now, as the daily run does, with a checkpoint first. |
| `Get-LazyVMRestorePoint` | The recorded tooling versions that can be returned to. |
| `Restore-LazyVMTooling -RestorePoint 20261008-201746` | Returns the VM to a recorded tooling version. All its disks go back, the Dev Drive included. |
| `Save-LazyVMState` | Captures the VM's state to the host: your restore point for a rebuild. |
| `Restore-LazyVMState` | Puts a capture back into the VM. A rebuild does this by itself. |
| `Invoke-LazyVMRebuild` | The full cycle: capture, retire the old VM, build a new one, restore, verify. `-SkipCapture` reuses the last capture. |
| `Invoke-LazyVMMaintenance` | What the scheduled task runs. Not usually run by hand. |
| `Register-LazyVMMaintenance` | Schedules the VM's daily maintenance, or schedules it again. |
| `Remove-LazyVM` | Deletes the VM and everything created for it ([section 10](#removing-a-vm)). |

Commands that change something support `-WhatIf`, to see what would happen without doing it, and `-Confirm`. `Invoke-LazyVMMaintenance -WhatIf` reads the VM's evaluation and says whether the run would only do the daily checks, rearm, rebuild, or build the VM, without starting a VM that is off. The ones that cannot be undone (`Remove-LazyVM`, `Restore-LazyVMTooling`, `Restore-LazyVMState`, `Invoke-LazyVMRebuild`) ask before acting; `-Force` skips the question.

Get commands return objects, so they work with the rest of PowerShell:

```powershell
Get-LazyVMSetting | Where-Object Source -ne 'Default'       # only what you have changed
(Get-LazyVMTooling).PendingChanges                          # what the next run would record
Get-LazyVMRestorePoint | Select-Object -Last 1 | Restore-LazyVMTooling
Get-LazyVM | Get-LazyVMLicense                              # every VM's license at once
'DevBox', 'TestBox' | Save-LazyVMState                       # VM names work too
```

Every command that works on a VM takes the VM from the pipeline: a name, or anything with a `Name` property. If one VM fails, the commands after it in the pipeline do not run.

## 4. Everyday use

### Checking where you stand

```powershell
Get-LazyVMLicense
```

It starts the VM if it is off, reads the license and returns something like:

```
Name              : DevBox
OperatingSystem   : Windows 11 Enterprise Evaluation (build 26100)
License           : Windows(R), Enterprise edition, TIMEBASED_EVAL channel
Status            : Initial grace period
DaysLeft          : 47
RearmsLeft        : 5
NextAction        : None until 10 days are left
LastCapture       : 2026-10-01 02:14:07
CapturedDatabases : 3
```

The number that matters is **RearmsLeft**. Each rearm resets the 90-day evaluation clock for the cost of one restart. While that count is above zero, no rebuild is needed.

### Taking a restore point

```powershell
Save-LazyVMState
```

Two things to do first:

1. Close Visual Studio. It writes its settings backup on exit, and that file is what the capture collects.
2. Stay signed in to the VM's desktop. Some steps run in your interactive session.

Expect it to take between five and thirty minutes, depending on database size. Watch for lines marked `[!]`: anything reported as not migrated automatically will not come back on its own.

> **Note**
> Database backups stay on the SQL data disk at `D:\SQLBackup`, not on the host: one good backup of each database, replaced only by a newer one that has passed `DBCC CHECKDB` and verified. That disk is never destroyed by a rebuild, so there is no reason to copy tens of gigabytes across the VMBus.

### The daily watch

`Build-LazyVM` schedules it when the build succeeds. If that step fails, the build still succeeds and warns you; fix the cause and run `Register-LazyVMMaintenance`. Running that again at any time is harmless.

This registers the VM's own task, `LazyVM-Maintain-DevBox`. It runs daily as SYSTEM at the VM's `MaintenanceTime` (02:00 for the first VM), whether or not anyone is signed in. It wakes the host if needed and catches up if the host was off. Each run records in `VM.json` any change made to the VM's hardware in Hyper-V (processors, memory, disk sizes, switch) and any tooling change ([section 9](#9-tooling-and-going-back)). It turns BitLocker on for `C:` and each persistent disk that does not have it yet ([BitLocker](#bitlocker)). It checks every user database with `DBCC CHECKDB` and, only when the check passes, backs it up to `D:\SQLBackup`, keeping one good, verified backup of each: a database that fails its check keeps the backup it had, and the log says so with `[X]`. It then compares the VM's certificates and Visual Studio settings with the fingerprint the newest capture recorded, and takes a full capture when either has changed, so a change is captured the night after it is made, not only when the evaluation is about to expire. Then it reads the license. On almost every day it finds plenty of time remaining and finishes within a few minutes, depending on database size.

A daily task is used rather than a 90-day one on purpose. A task that fires exactly every 90 days drifts past the expiry date, and misses it entirely if the host happens to be off that day.

To check it:

```powershell
Get-LazyVM
Get-ScheduledTaskInfo -TaskName LazyVM-Maintain-DevBox | Select-Object LastRunTime, LastTaskResult, NextRunTime
```

`LastTaskResult` is 0 when the last run succeeded and 1 when it failed; the log says why. To test it without waiting:

```powershell
Start-ScheduledTask -TaskName LazyVM-Maintain-DevBox
Get-Content D:\DevVM\DevBox\Logs\DevBox.log -Tail 30
```

With plenty of days left, it decides no action is needed and stops.

### A first run, start to finish

```powershell
Build-LazyVM -Name DevBox
```

For a VM that already exists, which LazyVM did not build, store its account first. Then capture before the first `Build-LazyVM`: that pass can relocate your SQL databases, and a capture taken beforehand is a genuine safety net.

```powershell
New-LazyVM -Name DevBox
Set-LazyVMCredential
Get-LazyVMLicense
Save-LazyVMState
Build-LazyVM
```

## 5. The 90-day cycle

Each night the maintenance run records any hardware change, extends `C:` into any space added to the OS disk, records any tooling change, then does this:

| Situation | What happens |
|---|---|
| More than 10 days left | Nothing more. The run reads the license, logs it and finishes. |
| Within 10 days, rearms available | Captures the VM's state, runs the Windows rearm and restarts the VM. The evaluation clock resets to another 90 days. No rebuild, nothing to migrate. |
| Within 10 days, no rearms left | Captures the VM's state, retires the old VM, builds a new one unattended, restores the capture and verifies the result. |
| No evaluation countdown | Nothing. A fully licensed Windows is never rebuilt. |
| The VM does not exist | Builds it. |

The 10-day threshold is `RebuildThresholdDays` ([section 8](#8-settings)).

### Why rearm first

Windows allows an evaluation period to be reset a limited number of times. Each reset buys another full 90 days for the price of a restart, with no rebuild and nothing to migrate. With five rearms available, that is roughly 450 days before a rebuild is needed at all. Checking this first is the difference between a restart and a multi-hour rebuild.

### What a rebuild does

1. Captures the VM's state to `D:\DevVM\DevBox\State` on the host.
2. Shuts the VM down gracefully.
3. Renames the old Windows disk aside. It is never deleted at this stage.
4. Builds a new VM and installs Windows unattended from a generated answer file.
5. Unlocks the SQL data disk, the Dev Drive and the User disk with their stored BitLocker recovery passwords, and turns on auto-unlock for the new `C:`. If a disk stays locked, the rebuild stops here, before anything is restored onto it, and the old disk is kept.
6. Installs everything in the VM's tooling list, and lists anything that has to be installed by hand.
7. Runs post-configuration: data disk, SQL data, Visual Studio settings, databases.
8. Restores the capture.
9. Verifies the result against the capture.
10. Deletes the retired disk only if verification passes.

> **Important**
> If verification fails, the old disk is kept, and the log gives the exact commands to roll back to it. A failed rebuild is recoverable. The old disk's `C:` is BitLocker-encrypted for the old VM's TPM, so on the first start after rolling back it asks for its recovery password: the `OS disk` one recorded before the rebuild, from `Get-LazyVMCredential -Name DevBox -RecoveryPassword`.

Verification checks that:
- the VM exists, is running and can be reached;
- every Visual Studio Installer product in the tooling list, and SQL Server, is installed;
- every captured database is back online;
- the data disk and the Dev Drive are mounted.

### Running a rebuild by hand

```powershell
Invoke-LazyVMRebuild -Name DevBox
```

It asks for confirmation first. Budget a couple of hours: the Windows install and Visual Studio are the bulk of it.

## 6. What each phase does

`Build-LazyVM` runs phases 0 to 8 in order, skipping work that is already done. Use `-FromPhase` to start partway through.

| # | Phase | What it does |
|---|---|---|
| 0 | Service check | Verifies the Hyper-V host services. Fixes only `vmms` and `vmcompute`. The guest-side integration services are reported, not reconfigured, because Manual is correct for them on a host. |
| 1 | Readiness | CPU, SLAT, memory and free space. Space is measured on the volumes actually used, and sized from the settings. |
| 2 | Hyper-V | Turns Hyper-V on if needed. If the host must restart, a startup task resumes the build at phase 3 by itself. |
| 3 | Folders | Creates the folders under the LazyVM folder. |
| 4 | Installation media | Verifies the Windows ISO by its file signature. Downloads the SQL Server ISO if it is missing, checking it before replacing any existing copy. Visual Studio and SSMS are downloaded inside the VM in phase 7, from their channel's bootstrapper. |
| 5 | SQL data disk | Creates the VM's SQL data disk if missing. An existing disk is never overwritten. |
| 5b | Dev Drive disk | Creates the Dev Drive disk if missing. An existing one is never overwritten. |
| 5c | User disk | Creates the User disk if missing. An existing one is never overwritten. |
| 6 | VM | A Generation 2 VM with Secure Boot, a TPM, 4 processors and dynamic memory, plus a disc carrying the unattended Setup answer file. |
| 7 | Installs | In this order: <ol><li>Waits for Windows to finish installing.</li><li>Makes `C:` use the whole OS disk: moves the recovery partition to the end of the disk and extends `C:` up to it, after taking a checkpoint. This works with BitLocker on.</li><li>Attaches and prepares the data disk, the Dev Drive and the User disk, marks the Dev Drive as trusted again, puts the personal folders on the User disk, and turns on Enhanced Session Mode. A disk BitLocker has locked, as after a rebuild, is unlocked first with its stored recovery password.</li><li>Turns BitLocker on for `C:`, then for the data disk, the Dev Drive and the User disk, with auto-unlock ([BitLocker](#bitlocker)).</li><li>Installs the VM's tooling list: Visual Studio Installer products with their workloads, components and extensions, then SQL Server, then winget packages.</li></ol>Anything already present is skipped, and anything that must be installed by hand is listed. SQL Server is installed from its ISO, placed in the VM's DVD drive for the install. |
| 8 | Configuration | Relocates SQL data onto the data disk, restores Visual Studio settings, and attaches the databases (or restores them from their backups). |

Capture (`Save-LazyVMState`) and restore (`Restore-LazyVMState`) run on their own, and as part of a rebuild.

## 7. Files and folders

On the host, everything lives under the LazyVM folder: one folder for each VM, named after it, and `Shared` for what every VM uses. The table shows the default layout under `D:\DevVM`. An item you have moved by giving its setting a full path is wherever you put it.

```
D:\DevVM\
  Shared\
    Config\         LazyVM.Settings.json and the schema
    ISO\            Win11Ent_Eval.iso
    Installers\     the SQL Server ISO
    Credentials\    .lazyvm.key
  DevBox\
    Config\         VM.json, VM.Template.json, History\
    Virtual Machines\
    Checkpoints\
    Disks\          DevBox-OS.vhdx, DevBox-SQL.vhdx, DevBox-DevDrive.vhdx, DevBox-Seed.iso
    State\          manifest.json, Captures\<stamp>\ (the newest three)
    Backups\        VisualStudio.vssettings
    Credentials\    guest.cred, certs.cred, environment.cred, appsettings.cred, bitlocker.cred
    Logs\           DevBox.log
```

| Path | Purpose |
|---|---|
| `D:\DevVM\Shared\Config` | The shared template `LazyVM.Settings.json`, used to create new VMs, and the schema beside it. |
| `D:\DevVM\Shared\ISO` | The Windows installation ISO. |
| `D:\DevVM\Shared\Installers` | The SQL Server ISO. |
| `D:\DevVM\Shared\Credentials` | `.lazyvm.key`, the key that encrypts every VM's stored passwords. |
| `D:\DevVM\DevBox` | Everything that belongs to the VM DevBox. Removing the VM deletes this folder. |
| `D:\DevVM\DevBox\Config` | The VM's configuration (`VM.json`), which includes its tooling list, the one it was first built from (`VM.Template.json`), and `History`: the three latest versions of `VM.json`, plus any older one a tooling restore point still needs. |
| `D:\DevVM\DevBox\Virtual Machines` | The VM's Hyper-V configuration. |
| `D:\DevVM\DevBox\Checkpoints` | The VM's checkpoints: the tooling restore points and any you take by hand. Automatic checkpoints are off. |
| `D:\DevVM\DevBox\Disks` | The Windows disk, the 100 GB SQL data disk, the Dev Drive, the 20 GB User disk and the answer-file disc, with the checkpoint disks (`.avhdx`) Hyper-V keeps beside them. The SQL data disk, the Dev Drive and the User disk persist across rebuilds: they carry the databases and their backups, your working source, and your personal folders. |
| `D:\DevVM\DevBox\State` | Captured state: each capture in a folder of its own, `Captures\<stamp>`, with its own manifest, and the newest three kept. `manifest.json` is a copy of the newest capture's manifest, the one a restore reads. Also application settings, `reinstall-by-hand.txt`, and the inventories `Get-LazyVMTooling` saves. Never touched by a rebuild. |
| `D:\DevVM\DevBox\Backups` | The Visual Studio settings backup. |
| `D:\DevVM\DevBox\Credentials` | The VM's encrypted account and certificate credentials, and its disks' BitLocker recovery passwords. |
| `D:\DevVM\DevBox\Logs` | `DevBox.log`: every run for that VM appends here. Set aside at 5 MB. |

`Shared` cannot be used as a VM name.

The module itself is installed in `C:\Program Files\PowerShell\Modules\LazyVM`. Nothing of yours is kept there.

### Inside the VM

| Path | Purpose |
|---|---|
| `C:` | Windows, Visual Studio, SQL Server binaries. |
| `D:` | The SQL data disk: `SQLData`, `SQLLog` and `SQLBackup`. `tempdb` stays on C:, since SQL Server recreates it at every start. |
| `W:` | The Dev Drive: working repositories, package caches, build output. |
| `U:` | The User disk: `Documents`, `Desktop` and `Downloads` are redirected here, and `%USERPROFILE%\.ssh` and `%USERPROFILE%\source\repos` are links to folders here. |
| `C:\LazyVMSetup` | The folder LazyVM uses for installers and staging. |

### Credential storage

Account and certificate passwords are encrypted with a 256-bit key in `D:\DevVM\Shared\Credentials\.lazyvm.key`, which only SYSTEM and Administrators can read.

A key file is used rather than Windows DPAPI on purpose. The scheduled task runs as SYSTEM and has to read credentials stored by an interactive administrator, which DPAPI would prevent. The trade-off is that any local administrator on the host can recover these passwords. That is acceptable for a disposable lab VM, and not appropriate for anything holding real secrets.

### BitLocker

Every persistent disk is encrypted with BitLocker, so each VM's data stays its own, except when it is handed to the VM that replaces it in a rebuild.

- `C:` is encrypted with the VM's virtual TPM, so it unlocks itself when the VM starts. It has to be: a data disk can unlock itself only once `C:` is encrypted. BitLocker will not use the TPM while a DVD drive holds bootable media, so LazyVM first ejects the Windows ISO the build attached, and the log says so. The drive itself stays.
- The SQL data disk, the Dev Drive and the User disk are each protected by a recovery password and unlock themselves once `C:` is unlocked (auto-unlock).
- Windows 11 may have encrypted the disks already, with its protection left off ("waiting for activation"). LazyVM then gives each disk its recovery password, adds the TPM to `C:`, and turns protection on, and the log says so for each disk. A `C:` that Windows Update has suspended until the next restart is left for Windows to resume.
- A disk formatted in the same run, such as a new VM's, has only its used space encrypted. A disk that already holds data, such as an older VM's on its first maintenance run after LazyVM gained BitLocker, is encrypted whole. Either way, encryption runs in the background in the VM, and nothing needs editing in `VM.json`.
- Auto-unlock belongs to the `C:` that turned it on, so a rebuilt VM cannot unlock the disks by itself. It unlocks each one with its stored recovery password, then turns auto-unlock on for its own `C:`. If a disk stays locked, the rebuild stops before restoring anything onto it.
- If BitLocker cannot be turned on for a disk, the disk is left as it was, the log says why, and the next run tries again. Nothing else stops. While `C:` cannot be encrypted, for example in a VM without a TPM, the data disks are left unencrypted.

Each recovery password is made on the host and stored, encrypted, in `Credentials\bitlocker.cred` before the disk is encrypted with it, keyed by the disk's GPT disk GUID. The passwords of earlier OS disks are kept too, so a retired disk can still be opened. They are never written to `VM.json` or the log. To read them, as an administrator:

```powershell
Get-LazyVMCredential -Name DevBox -RecoveryPassword
```

Windows keeps its recovery tools (Windows RE) on a partition of their own after `C:`, because it refuses them on a BitLocker-encrypted volume. Extending `C:` keeps it that way.

## 8. Settings

Settings live in two kinds of JSON file:

- **The shared template**, `Shared\Config\LazyVM.Settings.json`. Every setting has a default; list here only the ones you want to change. It is used only to create a VM: changing it never affects a VM that already exists.
- **Each VM's configuration**, `<Name>\Config\VM.json`. It holds every setting for that one VM, filled in from the shared template when the VM is created, and is the VM's one source of truth from then on. A rebuild uses it, and `New-LazyVM -From` copies it. To change a setting for an existing VM, change it here.

A shared template changing two settings looks like this:

```json
{
  "$schema": "./LazyVM.Settings.schema.json",
  "MemMaxGB": 24,
  "DevDriveSizeGB": 300
}
```

In a VM's `VM.json`, the first line is `"$schema": "../../Shared/Config/LazyVM.Settings.schema.json"`. Leave the `$schema` line as it is: it points your editor at the schema.

### A VM's configuration is kept up to date

LazyVM keeps `VM.json` describing the VM as it is, so you never have to:

- Before every build, maintenance run and rebuild, any setting `VM.json` lacks is filled in from the shared template. That covers a VM created before `VM.json` held every setting, and a setting added by a newer LazyVM. The log says which.
- Every time LazyVM changes `VM.json`, the version it writes is kept in `<Name>\Config\History\VM-<date>-<time>.json`, so you can see what changed and go back. The three latest versions are kept, and any older one a tooling restore point still needs ([section 9](#9-tooling-and-going-back)).
- A `VM.json` that cannot be read is never written over. The run uses the last copy that loaded cleanly and logs the problem.
- It records which disk inside the VM is the SQL data disk, which is the Dev Drive and which is the User disk (see below).

### How LazyVM finds the SQL data disk, the Dev Drive and the User disk

Preparing these disks can initialise and format them, so LazyVM finds each one by what `VM.json` records about it, never by its size:

1. **Its GPT disk GUID** (`SQLDiskGuid`, `DevDriveGuid`, `UserDiskGuid`), recorded the first time the VM prepares the disk.
2. **Its SCSI location** (`SQLDiskScsiLocation`, `DevDriveScsiLocation`, `UserDiskScsiLocation`), recorded when LazyVM attaches the disk to the VM. This is how a new, empty disk is found. Windows in the VM reports it as the disk's LUN.
3. **Only as a last resort, its `.vhdx` file**: where Hyper-V shows that file attached right now. This is how a VM built before LazyVM recorded disks finds them once; from then on it has a GPT disk GUID.

If no disk matches, or the disk at the recorded location has a different GPT disk GUID, the run stops and says so. It initialises or formats nothing. Check in Hyper-V Manager that the disk is attached to the VM's SCSI controller.

Leave these six settings as they are. `New-LazyVM -From` never copies them, because the new VM's disks are its own.

### What the VM was built from

The first time a VM is built (or, for a VM made before this existed, its next build, maintenance or rebuild), its `VM.json` is copied to `VM.Template.json` beside it. That copy is never changed, so you can compare it with the living file to see everything that has changed since:

```powershell
code --diff D:\DevVM\DevBox\Config\VM.Template.json D:\DevVM\DevBox\Config\VM.json
```

### Editing settings

Open the files in VS Code (or any editor that understands JSON Schema). The schema, `Shared\Config\LazyVM.Settings.schema.json`, holds every setting, its default and a description:

- **Autocomplete.** Start typing inside the braces and the setting names are offered.
- **Descriptions.** Hover over a setting's name to see what it does and its default.
- **Checking.** A misspelled name, a value of the wrong kind or out of range, is underlined as you type.

LazyVM keeps that schema up to date whenever it runs. It never changes the shared template; it changes a VM's `VM.json` only as described below, keeping the earlier version.

To see every setting as a VM uses it, with where each value came from:

```powershell
Get-LazyVMSetting -Name DevBox
Get-LazyVMSetting -Name DevBox -Setting Dev*
Get-LazyVMSetting -Name DevBox | Where-Object Source -ne 'DevBox\Config\VM.json'
```

### Forgiving by design

- Setting names are matched whatever their case: `memmaxgb` works.
- A single value where a list belongs counts as a one-item list.
- Every problem in a file is reported together, with the file and the setting, and nothing from a file with problems is used.
- Each time a file loads cleanly, a copy is kept beside it (`LazyVM.Settings.lastgood.json`, `VM.lastgood.json`). If the scheduled maintenance finds a file broken, it uses that copy and writes the problem to the log, so a typo never stops maintenance. When you run a command yourself, the problem is reported straight away so you can fix it.

### Settings that change after a VM is built

Most settings are applied when a VM is built: changing `vCPU` or `MemMaxGB` in its `VM.json` does nothing to the running VM until it is rebuilt. Equally, a change made in Hyper-V Manager is not written back to the file, so a rebuild returns the VM to what the files say. Tooling is the exception: changes you make inside the VM are recorded automatically ([section 9](#9-tooling-and-going-back)).

### The settings most worth knowing

`Get-LazyVMSetting` lists them all, with descriptions. These are the ones that most often need changing.

| Setting | Default | Meaning |
|---|---|---|
| `DiskDir`, `StateDir` and the other folder settings | in the VM's folder or `Shared` | Where each item goes on the host. A relative path such as `{VM}\Disks` sits under the LazyVM folder; a full path such as `F:\Hyper-V` puts that one item anywhere. |
| `RebuildThresholdDays` | 10 | How many days before expiry maintenance acts. |
| `MoveSqlDataToDataDisk` | true | Whether phase 8 relocates existing databases from `C:` onto the data disk. |
| `DeleteRetiredDiskOnSuccess` | true | Whether the old Windows disk is deleted after a verified rebuild. `false` keeps every generation, which uses disk quickly. |
| `MaintenanceTime` | 02:00 | When the VM's daily maintenance runs. Run `Register-LazyVMMaintenance` after changing it. |
| `ToolingCheckpointsToKeep` | 3 | How many tooling checkpoints to keep. |
| `ToolingWingetExclude` | Windows built-ins | winget packages never recorded. Your list replaces the default, so copy it and add to it. |
| `AppSettings` | WinMerge | Registry keys a capture exports and a restore imports, so an application's settings survive a rebuild. |
| `InstallerBootstrappers` | 5 channels | The bootstrapper for each Visual Studio Installer channel. Add one if a tooling list uses a channel not listed. |
| `UnsignedExtensions` | none | Marketplace extensions, by item name (`Publisher.Name`), that may be installed even though they are not signed. Any other unsigned extension is refused by the installer and named in the log; Visual Studio and its other extensions install anyway. |
| `vCPU`, `MemStartGB`, `MemMaxGB` | 4, 8, 16 | VM sizing, applied when the VM is built. 8 GB to start is the Dev Drive minimum. |
| `OSDiskSizeGB`, `SQLDiskSizeGB`, `DevDriveSizeGB`, `UserDiskSizeGB` | 120, 100, 250, 20 | Disk sizes, applied when each disk is created. All grow as needed up to this size. To give `C:` more room later, make the VM's OS disk bigger in Hyper-V Manager or with `Resize-VHD`; the next maintenance run extends `C:` into the new space, after taking a checkpoint it removes once all went well. If it fails, the checkpoint is kept, the log says how to go back to it, and `C:` is not extended again until you delete that checkpoint. |
| `UseDevDrive` | true | Whether to create, attach and designate the Dev Drive. |
| `DevDriveLetter` | W | Where the Dev Drive appears in the VM. |
| `UserDiskLetter` | U | Where the User disk appears in the VM. |
| `BackupDir` | none | Where the daily maintenance keeps its one copy of the User disk, such as a folder on an external disk. Unset, the copy is `<VM>\Backups\<VM>-User.vhdx`. The copy is made from a checkpoint while the VM runs, only when the files on the disk changed and once BitLocker has encrypted all of it, so it is still encrypted. When the folder is not there, the copy is skipped with a warning. To restore, swap the copy for the User disk's VHDX while the VM is off. |
| `SQLIsoUrl` | SQL Server 2025 Enterprise Developer | Where the SQL Server ISO is downloaded from. LazyVM installs the Standard Developer edition from it, so code can't come to depend on Enterprise-only features. |
| `SwitchName` | Default Switch | The virtual switch. See the note below. |
| `GuestRemoveApps` | News, Microsoft 365, Xbox | Built-in apps removed at every build, so they stay gone after a rebuild. Your list replaces the default, so copy it and add to it. |
| `GuestRemoveOneDrive` | true | Removes OneDrive and stops it installing for new users. |
| `GuestDarkMode`, `GuestShowFileExtensions`, `GuestTaskbarLeft`, `GuestHideWidgets`, `GuestHideTaskbarSearch` | true | Windows appearance in the VM, applied for every user at every build. |

### Adding tools to a VM

Install it inside the VM, the way you normally would: winget, an installer, or Manage Extensions in Visual Studio. The next daily maintenance run finds it and adds it to the VM's tooling list, and every later build of that VM installs it.

A VM with no tooling list of its own is built from the default list that ships with LazyVM:

- Visual Studio Community 2026, with the ASP.NET and web, .NET desktop, .NET MAUI, Azure, data storage and processing, data science, Python and Windows application workloads.
- SQL Server Management Studio 22.
- Visual Studio extensions: EF Core Power Tools, SQLite and SQL Server Compact Toolbox, Template Studio for WinUI and the Visual Studio Theme Pack. All are signed, so the Visual Studio Installer takes them without `UnsignedExtensions`.
- Tools from winget: Git, GitHub CLI, GitHub Desktop, Visual Studio Code, Windows Terminal, PowerShell 7, WSL, LINQPad 9, Notepad++, WinMerge and 7-Zip.
- SDKs and runtimes from winget: the Windows SDK, the SQL Server ODBC and OLE DB drivers, System CLR Types, the Visual C++ redistributables and Web Deploy.

To give a VM less, before its first build, remove what you don't need from the `Tooling` section of its `<Name>\Config\VM.json`. For every new VM, copy the default list from the module's `Data\Tooling.Default.json` into `LazyVM.Settings.json` as `"Tooling"` and trim it there. To build a new VM with another VM's tools instead, create it with `New-LazyVM -From` ([section 10](#10-several-vms-on-one-host)).

### A note on networking

The Default Switch is managed by Windows. Its address range **cannot** be set; Windows assigns it. The `NatSubnet` and `NatHostIP` settings are a fallback, used only if the configured switch does not exist. In that case LazyVM creates its own internal switch and NAT network at those addresses.

## 9. Tooling, and going back

Each VM has a tooling list, the `Tooling` section of `DevBox\Config\VM.json`: what is installed in it, without version numbers. It is what a build installs, so a rebuilt VM comes back with the tools the old one had, not the ones it started with.

### What the list holds

- **Visual Studio Installer products.** Each Visual Studio and SSMS installation, by product, edition and channel, with its workloads and components. Replace Visual Studio 2022 with 2026 and the list follows.
- **Visual Studio extensions**, including per-user ones installed from Manage Extensions. Each is matched to its Visual Studio Marketplace entry by exact name and publisher, so a build can install it.
- **winget packages**, by identifier. Packages that come with Windows are left out (`ToolingWingetExclude`).
- **Other programs**: everything else in the Windows list of installed programs, by name.

### How changes are picked up

Every day the VM's maintenance takes an inventory of the VM and compares it with the list. When nothing has changed, it does nothing more. When something has, it:

- takes a Hyper-V checkpoint of the VM, named `Tooling <date-time>`;
- saves the new list in `VM.json`, and keeps that version of `VM.json` in `History` under the same date and time;
- logs each addition and removal.

If the checkpoint cannot be taken, nothing is recorded and the next run tries again: a change is never adopted without a way back.

Only additions and removals count. Updating Visual Studio, an SDK or a runtime never takes a checkpoint.

To see what is installed without recording anything, or to record a change straight away instead of waiting for the night's run:

```powershell
Get-LazyVMTooling
Save-LazyVMTooling
```

### What a build installs, and what it cannot

Phase 7 installs the whole list, in this order:
1. Each Visual Studio Installer product from its channel's bootstrapper (`InstallerBootstrappers`), with its workloads and components. Then its Marketplace extensions are added, as a separate step, so an extension the installer refuses never stops the product itself from installing.
2. SQL Server.
3. Every winget package.

Anything already present is skipped.

`DevBox\Config\VM.Template.json` keeps the list the first build installed. See [What the VM started with](#what-the-vm-started-with).

The Visual Studio Installer refuses an unsigned extension unless its item name is in `UnsignedExtensions`. When it refuses some of a product's extensions, the rest are still added, one at a time, and the log names each refused one.

Programs winget does not provide, and extensions with no Marketplace match, cannot be installed automatically. After a build they are logged and written to `DevBox\State\reinstall-by-hand.txt`. The list marks them as awaiting reinstall, so they are not mistaken for removals. Each one leaves that list once you install it.

### What the VM started with

The `Tooling` section of `VM.json` changes as you work: maintenance adds what you install and drops what you remove. `VM.Template.json`, beside it, is `VM.json` as the VM was first built, tooling list included. It is written once and never changed:

- maintenance, `Save-LazyVMTooling` and `Restore-LazyVMTooling` change only `VM.json`;
- running `Build-LazyVM` again, or a rebuild of a replacement VM, keeps the copy that is there;
- `Remove-LazyVM` deletes it with the rest of the VM's folder.

Both files are written the same way, so a diff lines up entry by entry and shows what has changed since the build, along with when the list was recorded (`RecordedAt`). With Visual Studio Code or Git:

```powershell
code --diff D:\DevVM\DevBox\Config\VM.Template.json D:\DevVM\DevBox\Config\VM.json
git diff --no-index D:\DevVM\DevBox\Config\VM.Template.json D:\DevVM\DevBox\Config\VM.json
```

WinMerge, from the default list, compares them too.

A VM set up before LazyVM kept the list in `VM.json` has it in `Tooling.json`, `Tooling.Template.json` and `History\Tooling-<date>-<time>.json`. The first command run on it folds each into `VM.json`, `VM.Template.json` and `History\VM-<date>-<time>.json`, and deletes the old file once the new one reads back with the same list. One that cannot be folded in stays, and the log says why.

### Application settings

Reinstalling an application does not bring back its settings. For one that keeps them in the registry, add its key to `AppSettings`: the key's values, subkeys included, are recorded in `VM.json` as `GuestAppSettings` whenever they change, and a restore writes them back after the application is back. A value whose name looks secret, such as `SyncPassword`, is kept encrypted in `Credentials\appsettings.cred` instead. WinMerge is included by default.

### Going back to an earlier version

List the versions that still have their checkpoint, then return to one by its date and time:

```powershell
Get-LazyVMRestorePoint
Restore-LazyVMTooling -RestorePoint 20261008-201746
```

This applies the checkpoint and puts the matching tooling list back into `VM.json`; every other setting stays as it is now. A checkpoint of the current state is taken first, and the log gives the command that undoes the revert.

> **Important**
> A checkpoint covers all of the VM's disks, including the Dev Drive and the SQL data disk. Reverting loses code you have not pushed and database changes made since. Push your work first.

The three most recent tooling checkpoints are kept (`ToolingCheckpointsToKeep`); older ones are merged away.

## 10. Several VMs on one host

Each VM has its own profile, `<Name>\Config\VM.json`, in its own folder. With it come its own disks, captured state, log, credentials, tooling list, checkpoints and maintenance task. A new VM's `VM.json` starts from the shared template (the defaults, then `LazyVM.Settings.json`); from then on it holds all of that VM's settings.

### Adding a VM

```powershell
New-LazyVM -Name WebDev -From DevBox
Build-LazyVM -Name WebDev
```

`-From` copies the existing VM's `VM.json` and its tooling list, so the new VM is built the same way with the same tools. The settings that must differ between VMs (file locations, the computer name, the maintenance time and the recorded identity of its disks) come from the shared template instead. From then on, each list follows its own VM. Leave out `New-LazyVM` and just run `Build-LazyVM -Name WebDev` to start from the defaults and the default tooling list.

Once there is more than one VM, every command needs `-Name`. LazyVM will not guess, because a wrong guess would maintain or rebuild the wrong machine.

### Maintenance times

Each VM has its own task, `LazyVM-Maintain-<Name>`. `New-LazyVM` sets each new VM's `MaintenanceTime` an hour after the latest one in use, so two VMs are never maintained at once. To change it, set `MaintenanceTime` in the VM's `VM.json` and run `Register-LazyVMMaintenance` for that VM.

> **Note**
> Every VM needs its own memory and disk space on the host. Check the host can run the VMs you plan to use at the same time: each one takes `MemStartGB` when it starts.

### Removing a VM

```powershell
Remove-LazyVM -Name WebDev -WhatIf     # see exactly what would be deleted
Remove-LazyVM -Name WebDev
```

This deletes the VM and everything created for it:
- the Hyper-V VM with its checkpoints;
- its folder, `D:\DevVM\WebDev`, with everything in it: its disks and checkpoint disks, configuration, profile and tooling history, credentials, Visual Studio settings backup, captured state and logs;
- anything you moved out of that folder with a full path in a setting, such as a Dev Drive on another drive;
- its scheduled tasks and its registry key.

Before anything is deleted, it lists everything with sizes and asks you to confirm. `-Force` skips the question.

The Dev Drive goes too, and with it any source code not yet pushed, and so does the User disk, with Documents, Desktop, Downloads, `.ssh` and `source\repos`. Push or copy your work first.

What every VM uses is never touched: the LazyVM folder and `Shared`, with the ISOs and your settings file. Anything another VM also uses is kept as well, such as the credential key, and the list says why. If the VM's folder holds something another VM uses, nothing is removed and you are told what to move out first.

## 11. Moving files between host and VM

There are two mechanisms, each with its own job, and neither depends on the VM's network.

| Mechanism | Path | Use it for |
|---|---|---|
| Dev Drive | Local disk | Working repositories, package caches, build output. Fastest by a wide margin, and nothing in the path can break. |
| User disk | Local disk | Documents, Desktop, Downloads, `.ssh` and `source\repos`, kept across rebuilds. |
| Enhanced Session Mode | VMBus (RDP) | Ad-hoc copying in either direction, drag and drop, clipboard. Works while you are connected in VMConnect. |

### The Dev Drive

A Dev Drive is a ReFS volume carrying a per-machine *trusted* designation, which tells Windows to detach every file system filter except antivirus. That is where the build speed comes from, along with ReFS block cloning, which turns file copies into metadata operations.

Its disk lives on the host, beside the SQL data disk, and is attached to the VM as a second disk. A rebuild never touches it.

> **Important**
> Do not create a Dev Drive from inside the VM with Settings > Create Dev Drive > "Create new VHD". That puts the disk on the VM's `C:`, which is the disk a rebuild deletes. The disk must live on the host.

Trust is stored per machine and does not travel with the disk, so after a rebuild the volume comes back as plain ReFS. Phase 7 designates it again automatically. That is a metadata change, not a reformat: your files are not touched. If the designation is ever refused, LazyVM formats the volume as NTFS instead and says so in the log. The drive still works and still persists across rebuilds; only the ReFS speed-ups are missing.

To check its state from inside the VM:

```powershell
fsutil devdrv query W:
```

### The User disk

Your personal folders live on the User disk, `U:`, so that nothing of yours is on the Windows disk a rebuild replaces. Like the Dev Drive, its disk lives on the host and a rebuild never touches it. It is a plain NTFS volume, not a Dev Drive: Defender's performance mode suits source and builds, not Downloads.

- **Documents, Desktop and Downloads** are redirected to `U:\Documents`, `U:\Desktop` and `U:\Downloads`. File Explorer shows the new place after you next sign in.
- **`%USERPROFILE%\.ssh` and `%USERPROFILE%\source\repos`** are links to `U:\.ssh` and `U:\repos`, so programs that look for them there still find them. Visual Studio's default projects folder is `source\repos`.
- **A VM built before the User disk** gets it at the next maintenance run. What its folders hold on `C:` is copied to the User disk, never moved, and copied again each night until you next sign in: the copies on `C:` go only when a rebuild replaces that disk. A link you made yourself, say from `source\repos` to the Dev Drive, is left as it is.
- **A rebuild** first copies the folders onto the User disk once more, and stops before retiring anything if it cannot. The rebuilt VM's account is then given the folders: its account is new to Windows, so only it, SYSTEM and Administrators can open them.

### Enhanced Session Mode

Enhanced Session Mode carries clipboard and drive redirection over the VMBus using RDP, not over the VM's network. It has no IP address, no account and no firewall rule to go wrong.

To share host drives into the VM: in VMConnect, choose Show Options, then Local Resources, then More, and tick the drives you want. They appear in the VM under This PC as redirected drives. Files copy and paste in both directions.

LazyVM sets this up: it turns on the host setting, sets the VM's transport to VMBus, and turns on Remote Desktop Services in the VM.

For scripted copies, `Copy-VMFile` copies files from the host into the VM, and `Copy-Item -FromSession` copies them out over PowerShell Direct. Both travel over the VMBus, which is how LazyVM itself moves files.

## 12. Troubleshooting

The log is the first place to look: `D:\DevVM\DevBox\Logs\DevBox.log`. Every line is prefixed: `[+]` success, `[!]` warning, `[X]` error, `[ ]` information. The start of each run records the module version, the VM, the LazyVM folder and which settings you have changed.

| Symptom | Cause and fix |
|---|---|
| "LazyVM does not know which folder to keep its VMs in yet" | Run `Build-LazyVM -Name DevBox`, which chooses one, or `Set-LazyVMRoot -Path D:\DevVM`. |
| "The term 'Build-LazyVM' is not recognized" | You are in Windows PowerShell 5.1, or the module is not installed. Open PowerShell 7 (`pwsh`) as administrator; if it persists, run `./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out` again. |
| "The token '&&' is not a valid statement separator in this version" | You are in Windows PowerShell 5.1, which has no `&&`. The title bar says "Windows PowerShell" and `$PSVersionTable.PSVersion` shows 5.1. Open PowerShell 7 (`pwsh`) as administrator and run the command there. |
| A path like `S:SourceLazyVM` appears, or "No such file or directory", after cloning or running commands in Git Bash | Git Bash (MINGW) treats `\` as an escape character, so `S:\Source\LazyVM` loses its backslashes. Run the commands in PowerShell 7 instead, or in Git Bash write the path as `/s/Source/LazyVM`. |
| "LazyVM needs an elevated PowerShell" | Start PowerShell 7 with Run as administrator. |
| "No stored guest credential" | Store one with `Set-LazyVMCredential`, for an account that is a local administrator inside the VM. |
| The VM never becomes reachable | Open the VM's console. Windows Setup may be waiting on something, or the stored password may not match the account. Check by signing in at the console with the password `Get-LazyVMCredential -AsPlainText` shows. |
| The password cannot be pasted into the VM's sign-in box | A basic VMConnect session has no clipboard. Copy the password on the host, then in VMConnect choose Clipboard > Type clipboard text: it types the text as keystrokes, so the VM's keyboard layout must match the host's. Or connect with an [enhanced session](#enhanced-session-mode), whose sign-in dialog accepts a paste. |
| "No valid Windows installation ISO" | The file at the configured path is not a real ISO, most often the registration page saved with an `.iso` name. Download the image by hand and save it in the `Shared\ISO` folder. |
| "SQL Server ISO - download failed" | The download address may have changed. Download the SQL Server 2025 Enterprise Developer ISO by hand and save it as the path the message gives, or set `SQLIsoUrl`. |
| "This settings file has N problem(s), so none of it was used" | The message lists every problem, with the file and the setting. Open the file in VS Code: the same problems are underlined. |
| A warning that a last good copy of a settings file was used | The scheduled maintenance found the file broken and used the copy from the last time it loaded cleanly. Fix the file; the next run uses it. |
| A rebuild failed verification | The old Windows disk was kept, and the log gives the exact rollback commands. Nothing is lost. |
| Databases did not come back | The log says, for each database, whether it was attached or restored from its backup, and why not. `VM.json` records each database's files under `GuestSql`; the files and backups live on the SQL data disk (`D:\SQLData`, `D:\SQLLog`, `D:\SQLBackup`). `Get-LazyVMLicense` shows how many backups the last capture made. |
| SSMS says "The certificate chain was issued by an authority that is not trusted" | SSMS 21 and later encrypt the connection by default, and SQL Server in the VM uses a self-signed certificate. In the connection dialog, tick **Trust server certificate**. The VM's administrator is a sysadmin, so SSMS run normally (not as administrator) signs in with Windows authentication. |
| The scheduled task never runs, or `LastTaskResult` is 1 | Check `Get-LazyVM` shows it registered, and read the log. It runs as SYSTEM, so it needs a stored credential and the module installed for all users. |
| The Dev Drive is not trusted | Run `fsutil devdrv enable` then `fsutil devdrv trust W:` in the VM as administrator. Trust does not survive a rebuild by design, and phase 7 normally reapplies it. |
| "The SQL data disk was not found in the guest" (or the Dev Drive disk) | No disk in the VM matches what `VM.json` records for it, so nothing was formatted. Check in Hyper-V Manager that the `.vhdx` file is attached to the VM's SCSI controller 0. If you replaced the disk on purpose, clear its `...Guid` and `...ScsiLocation` settings in `VM.json` and run the build again. |
| The Dev Drive came back as NTFS | The designation was refused on this disk. The volume still works and still persists; only the ReFS speed-ups are missing. The log records the exact refusal. |
| "This host has several VMs" | Add `-Name` and the VM's name. |
| "Could not take the checkpoint, so the changes were NOT recorded" | Hyper-V refused the checkpoint, most often over access to a disk's folder. The log carries Hyper-V's own message. Run `Save-LazyVMTooling` to try again; nothing is lost. |
| "extension(s) refused by the Visual Studio Installer" | The extension is not signed. To let LazyVM install it, add its item name (shown in the log, `Publisher.Name`) to `UnsignedExtensions` in the VM's `VM.json`; otherwise install it by hand from Extensions > Manage Extensions. The installer's own logs are in the VM's `C:\Windows\SystemTemp\dd_*.log` (`C:\Windows\Temp` before Windows 11 24H2). |
| An extension is listed in `reinstall-by-hand.txt` | No Visual Studio Marketplace entry matched its name and publisher exactly, usually because the vendor distributes it elsewhere. Install it from the vendor; the next daily run takes it off the list. |

### Useful checks

On the host:

```powershell
Get-LazyVM
Get-VMHardDiskDrive -VMName DevBox | Select-Object Path, ControllerLocation
Get-VMSnapshot -VMName DevBox | Select-Object Name, CreationTime
Get-Content D:\DevVM\DevBox\Logs\DevBox.log -Tail 40
```

Inside the VM:

```powershell
Get-PSDrive -PSProvider FileSystem | Select-Object Name, Root
Get-Service MSSQLSERVER | Select-Object Name, Status
```

## 13. Habits worth keeping

- **Keep source on the Dev Drive (`W:`), and in source control.** The Dev Drive is fast, persists across rebuilds, and nothing in its path can break. Commit and push regularly, so that a clone, not a capture, is the backup for your code. This is the single most useful habit.
- **Capture after meaningful changes**: new databases, settings you care about, certificates. The daily run captures new certificates and Visual Studio settings the night after they change, and maintenance captures before it acts, but a capture of your own costs nothing.
- **Close Visual Studio before a capture**, so its settings backup is current.
- **Read the `[!]` lines after a capture.** Anything reported as not migrated has to be recreated by hand after a rebuild.
- **Check `Get-LazyVMLicense` occasionally**, so the rearm count is never a surprise.
- **Install tools inside the VM, the normal way.** The daily run records them, so they come back after a rebuild. `Save-LazyVMTooling` records them at once.
- **Push before you revert.** A revert takes every disk back, the Dev Drive included.
- **Take a checkpoint before risky work.** Tooling changes get one automatically; take your own before anything else risky.

Everything LazyVM does is written to the VM's log. When something is unclear, that file is the record of what actually happened.

# Massokissed.LazyVM

A PowerShell module that builds and looks after Hyper-V development VMs on a Windows host, unattended: Windows 11 Enterprise Evaluation, Visual Studio, SQL Server 2025 Enterprise Developer and whatever other tools you install, with the 90-day evaluation handled for you.

## What it does

- **Builds a VM with no input from you.** It creates the VM, installs Windows from an answer file, then installs everything in the VM's tooling list: Visual Studio and SSMS with their workloads and Marketplace extensions, SQL Server, and winget packages.
- **Keeps the VM's tooling list current.** Every day it records what you have added or removed in the VM, taking a Hyper-V checkpoint first, so any recorded version can be returned to.
- **Makes the 90-day evaluation a non-event.** It watches the licence and rearms Windows while it can. When it can't, it captures your state, rebuilds the VM and puts everything back: databases, logins, Visual Studio settings, certificates, environment and application settings.
- **Keeps your source safe across rebuilds.** Source lives on a Dev Drive whose disk a rebuild never touches.
- **Runs several VMs on one host**, each with its own tools, disks, schedule and restore points.
- **Never stops over a typo.** If a settings file breaks, the scheduled maintenance uses the last version that worked and says so in the log.

## Requirements

- Windows 10 or 11 Pro, Enterprise or Education on the host (Hyper-V is not available on Home).
- [PowerShell 7.4 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), run as administrator: `winget install Microsoft.PowerShell`.
- A Windows 11 Enterprise Evaluation ISO, downloaded by hand from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise). LazyVM opens that page for you if it can't find one.
- Memory and disk for each VM. By default a VM starts with 8 GB of memory and can grow to 16 GB. Its disks are 120 GB for Windows, 100 GB for SQL data and 250 GB for the Dev Drive, all dynamically expanding.

## Install

Until LazyVM is published to the PowerShell Gallery, build it from this repository. Open **PowerShell 7** (`pwsh`, not Windows PowerShell) as administrator:

```powershell
git clone https://github.com/downerboy/Massokissed.LazyVM S:\Source\Massokissed.LazyVM
cd S:\Source\Massokissed.LazyVM
./build.ps1 -Bootstrap -Task Install
```

This builds, tests and installs the module for all users, which the scheduled maintenance needs because it runs as SYSTEM. Open a new PowerShell 7 window afterwards.

## Quick start

```powershell
Build-LazyVM -Name DevBox
```

That is all. The first time, it:

- chooses a folder for LazyVM (`LazyVM` on the local drive with the most free space) and says where; run `Set-LazyVMRoot` first to choose your own;
- creates the VM's profile;
- finds the Windows ISO. Leave it in your Downloads folder and LazyVM moves it into place. If there is none it opens the download page and stops; run the command again once it has downloaded;
- turns Hyper-V on if needed, restarting the host and carrying on by itself;
- downloads SQL Server, installs Windows, then everything in the tooling list;
- schedules the daily maintenance.

It takes an hour or two and needs no input. Running it again finishes an interrupted build.

To sign in to the VM yourself, `Get-LazyVMCredential -Name DevBox -AsPlainText` shows the account and the password LazyVM generated.

## Commands

Every command has full help: `Get-Help Build-LazyVM -Full`. `-Name` can be left out while the host has only one VM, and it tab-completes.

| Command | What it does |
|---|---|
| `Set-LazyVMRoot` | Chooses your own folder for LazyVM instead of the automatic one. Brings a 1.x kit across. |
| `New-LazyVM` | Creates a VM's profile without building it. `-From` starts from another VM's settings and tools. |
| `Build-LazyVM` | Builds the VM, setting up whatever is missing first, and schedules its maintenance. Safe to run again. |
| `Get-LazyVM` | Lists the VMs, their state and their maintenance. |
| `Get-LazyVMSetting` | Every setting as a VM uses it, where the value came from, and what it does. |
| `Set-LazyVMCredential` / `Get-LazyVMCredential` | The administrator account LazyVM uses inside the VM. |
| `Get-LazyVMLicense` | Evaluation days and rearms left, and what maintenance will do. |
| `Get-LazyVMTooling` | What is installed in the VM, and what the next maintenance run would record. |
| `Save-LazyVMTooling` | Records tooling changes now, with a checkpoint. |
| `Get-LazyVMRestorePoint` / `Restore-LazyVMTooling` | Lists recorded tooling versions, and returns to one. |
| `Save-LazyVMState` / `Restore-LazyVMState` | Captures the VM's state to the host, and puts it back. |
| `Invoke-LazyVMRebuild` | Rebuilds the VM from scratch, keeping your work. |
| `Invoke-LazyVMMaintenance` / `Register-LazyVMMaintenance` | The daily maintenance run, and scheduling it. |
| `Remove-LazyVM` | Deletes a VM and everything created for it. `-WhatIf` lists it all first. |

Commands that change something support `-WhatIf` and `-Confirm`.

## Settings

Your settings are JSON files in the LazyVM folder. An update never touches them:

- `Config\LazyVM.Settings.json` applies to every VM.
- `Config\VMs\<Name>\VM.json` applies to one VM, and overrides the host-wide file.

List only what you want to change:

```json
{
  "$schema": "./LazyVM.Settings.schema.json",
  "MemMaxGB": 24,
  "DevDriveSizeGB": 300
}
```

Open them in VS Code. The schema beside them gives autocomplete, shows each setting's description and default when you hover over it, and underlines mistakes as you type. `Get-LazyVMSetting` lists every setting with its current value.

## Upgrading from LazyVM 1.x

Install the module, then point `Set-LazyVMRoot` at the folder that held the 1.x kit, the one with `Scripts` in it:

```powershell
Set-LazyVMRoot -Path S:\Source\Massokissed.LazyVM-1.0.0
```

The command brings everything across:
- It converts your settings and VM profiles to JSON.
- It copies the tooling lists and their history.
- It moves the scheduled maintenance tasks over to the new commands.

Nothing existing is overwritten, and the old files are left as they are. The VMs, their disks and their stored passwords carry on where they are.

## Documentation

The [guide](docs/Guide.md) covers every command, setting and phase, and what to do when something goes wrong.

## Development

```
src/Massokissed.LazyVM/
  Massokissed.LazyVM.psd1, .psm1   the module
  Public/                          one file per command
  Private/<Area>/                  everything else, by area
  Data/                            the settings schema and the default tooling list
tests/                             Pester tests
build.ps1                          build, analyze and test
```

`./build.ps1` merges the module into `out\`, runs PSScriptAnalyzer (any finding fails the build) and runs the Pester tests. GitHub Actions runs the same on Windows for every push.

## Licence

LazyVM is free for personal and other noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). Using it for a commercial purpose needs a separate commercial licence; contact the author through GitHub.

# LazyVM

> **Alpha.** LazyVM works, and I use it myself, but much of its behaviour is still being worked on.

LazyVM is a PowerShell module that builds, looks after and disposes of Hyper-V virtual machines on a Windows host, unattended. Today it makes development VMs: Windows 11 Enterprise Evaluation with Visual Studio, SQL Server Standard Developer and whatever other tools you install, with the 90-day evaluation handled for you. Windows lets an evaluation be rearmed a limited number of times, each for another 90 days. LazyVM uses every rearm Windows allows, then rebuilds the VM and puts your work back.

### Where it is heading

The aim is free, reliable tooling that makes creating, maintaining and disposing of Hyper-V VMs effortless, and not only for development:

- **Everything you change is kept.** Tools, settings and the VM's look and feel (dark mode, text size, File Explorer options) are recorded in the VM's configuration, so a rebuilt VM comes back as you left it. Credentials and other secrets are the exception: they are never written to the configuration.
- **Templates that keep up.** Changes made in a VM can update a matching config template, keeping only the latest version, so templates do not multiply.
- **Beyond developer VMs.** An independent contractor, such as a bookkeeper, could keep an isolated VM for each client. That lightens disaster recovery, and helps meet ethical and legal obligations such as HIPAA and HITECH for a health provider's business associates.

Still needed: a code-signing certificate, and a good deal more.

### How it is being built

*An experiment in vibe coding, done the hard way. Herding the AI is herding cats: the code starts as spaghetti, gets refactored into gumbo, and some of the spaghetti never gets served. Copilot's output proved too erratic, so it was let go. Claude can be a little too creative too, but given the project's patterns and practices, its code runs and follows the specs.*

## What it does

- **Builds a VM with no input from you.** It creates the VM, installs Windows from an answer file, then installs everything in the VM's tooling list: Visual Studio and SSMS with their workloads and Marketplace extensions, SQL Server, winget packages and official installers.
- **Keeps the VM's tooling list current.** Every day it records what you have added or removed in the VM, taking a Hyper-V checkpoint first, so any recorded version can be returned to.
- **Makes the 90-day evaluation a non-event.** It watches the license and rearms Windows while it can. When it can't, it captures your state, rebuilds the VM and puts everything back: databases, logins, Visual Studio settings, certificates, environment and application settings.
- **Keeps the VM up to date.** Every night it installs Windows updates, upgrades winget packages, asks the Store to update its apps and keeps Sysmon set up, restarting the VM only when nobody is using it.
- **Records what you change.** Your environment, firewall rules, scheduled tasks, SQL logins and application settings are recorded in the VM's configuration whenever they change, and the databases are checked and backed up every night.
- **Keeps your source and files safe across rebuilds.** Source lives on a Dev Drive, and Documents, Desktop, Downloads and `.ssh` on a User disk, whose disks a rebuild never touches.
- **Runs several VMs on one host**, each with its own tools, disks, schedule and restore points.
- **Never stops over a typo.** If a settings file breaks, the scheduled maintenance uses the last version that worked and says so in the log.

## Requirements

- Windows 10 or 11 Pro, Enterprise or Education on the host (Hyper-V is not available on Home).
- [PowerShell 7.6 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), run as administrator: `winget install Microsoft.PowerShell`.
- A Windows 11 Enterprise Evaluation ISO, downloaded by hand from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise). LazyVM opens that page for you if it can't find one.
- Memory and disk for each VM. By default a VM starts with 8 GB of memory and can grow to 16 GB. Its disks are 120 GB for Windows, 100 GB for SQL data, 250 GB for the Dev Drive and 20 GB for the User disk, all dynamically expanding.

## Install

Open **PowerShell 7** (`pwsh`, not Windows PowerShell) as administrator.

**From a release** (no Git needed): download `LazyVM-<version>.zip` from the [latest release](https://github.com/downerboy/LazyVM/releases), then, in the folder you saved it to:

```powershell
Unblock-File .\LazyVM-*.zip
Expand-Archive .\LazyVM-*.zip -DestinationPath .\LazyVM -Force
.\LazyVM\Install.ps1
```

**From the repository:**

```powershell
git clone https://github.com/downerboy/LazyVM S:\Source\LazyVM
cd S:\Source\LazyVM
./Invoke-AnalyzerAndTest.ps1 && ./src/Install.ps1 -Path out
```

Or double-click `Install-FromRepository.cmd` in the repository folder: it asks for administrator rights and runs the same two commands.

This builds the module, checks it with PSScriptAnalyzer, runs the Pester tests and, only if they all pass, installs it for all users, which the scheduled maintenance needs because it runs as SYSTEM. The first time, it also installs the versions of Pester and PSScriptAnalyzer it uses. Open a new PowerShell 7 window afterwards.

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

Type `LazyVM` on its own to see the installed version, the LazyVM folder and the VMs in it, where the module is installed, and every command with a one-line summary. Every command has full help: `Get-Help Build-LazyVM -Full`. `-Name` can be left out while the host has only one VM, and it tab-completes.

| Command                                                       | What it does                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `LazyVM` (`Show-LazyVM`)                                    | The version, the LazyVM folder and its VMs, where the module is installed, and the command list.      |
| `Set-LazyVMRoot`                                            | Chooses your own folder for LazyVM instead of the automatic one.                                       |
| `New-LazyVM`                                                | Creates a VM's profile without building it. `-From` starts from another VM's settings and tools; `-ConfigTemplate` from a config template. |
| `Build-LazyVM`                                              | Builds the VM, setting up whatever is missing first, and schedules its maintenance. Safe to run again. `-ConfigTemplate` picks a new VM's config template. |
| `Export-LazyVMTemplate`                                     | Saves a VM's configuration as a config template that new VMs can start from.                          |
| `Get-LazyVM`                                                | Lists the VMs, their state and their maintenance.                                                      |
| `Get-LazyVMSetting`                                         | Every setting as a VM uses it, where the value came from, and what it does.                            |
| `Set-LazyVMCredential` / `Get-LazyVMCredential`           | The administrator account LazyVM uses inside the VM.                                                   |
| `Get-LazyVMLicense`                                         | Evaluation days and rearms left, and what maintenance will do.                                         |
| `Get-LazyVMTooling`                                         | What is installed in the VM, and what the next maintenance run would record.                           |
| `Save-LazyVMTooling`                                        | Records tooling changes now, with a checkpoint.                                                        |
| `Test-LazyVM`                                               | Checks the folder, ISOs, VM, PowerShell Direct, guest set-up and maintenance task. Read-only.         |
| `Get-LazyVMRestorePoint` / `Restore-LazyVMTooling`        | Lists recorded tooling versions, and restore to specified version.                                    |
| `Save-LazyVMState` / `Restore-LazyVMState`                | Captures the VM's state to the host, and puts it back.                                                 |
| `Invoke-LazyVMRebuild`                                      | Rebuilds the VM from scratch, keeping your work.                                                       |
| `Invoke-LazyVMMaintenance` / `Register-LazyVMMaintenance` | The daily maintenance run, and scheduling it.                                                          |
| `Remove-LazyVM`                                             | Deletes a VM and everything created for it. `-WhatIf` lists it all first.                            |

Commands that change something support `-WhatIf` and `-Confirm`.

## Settings

Your settings are JSON files in the LazyVM folder. An update never touches them:

- `Shared\Config\LazyVM.Settings.json` is the shared template for new VMs. List only what you want to change from the defaults.
- `<Name>\Config\VM.json` is one VM's complete, living configuration: created from the shared template, kept up to date by LazyVM, and used to rebuild the VM or copy it with `New-LazyVM -From`.
- Config templates are named starting points for new VMs: `Build-LazyVM -Name Clean -ConfigTemplate PlainWindows`. LazyVM comes with `Developer` (Visual Studio, SQL Server, Dev Drive) and `PlainWindows` (no developer tools); your own go in `Shared\Templates`, where `Export-LazyVMTemplate` saves a VM's configuration as one. Press Tab after `-ConfigTemplate` to list them.

A shared template looks like this:

```json
{
  "$schema": "./LazyVM.Settings.schema.json",
  "MemMaxGB": 24,
  "DevDriveSizeGB": 300
}
```

Open them in VS Code. The schema beside them gives autocomplete, shows each setting's description and default when you hover over it, and underlines mistakes as you type. `Get-LazyVMSetting` lists every setting with its current value.

## Documentation

The [guide](docs/Guide.md) covers every command, setting and phase, and what to do when something goes wrong.

The [use case diagrams](docs/UseCases.md) show who does what with LazyVM, in UML. The [flow diagrams](docs/Diagrams.md) show, for each thing you do with LazyVM, which functions run in what order and what each one reads and writes.

## Development

```
src/LazyVM/
  LazyVM.psd1, .psm1   the module
  Public/                          one file per command
  Private/<Area>/                  everything else, by area
  Data/                            the settings and template schemas, the default tooling list and the built-in config templates
tests/                             Pester tests
Invoke-AnalyzerAndTest.ps1         check a change: assemble, analyze, test
Install-FromRepository.cmd         double-click: check, then install if all passed
New-ReleasePackage.ps1             make the release zip
Update-Diagram.ps1                 redraw docs/Diagrams.md and its SVGs from docs/diagrams/source
build/                             the steps these use
```

`./Invoke-AnalyzerAndTest.ps1` assembles the module into `out\`, runs PSScriptAnalyzer (any finding fails) and runs the Pester tests. GitHub Actions runs the same on Windows for every push.

Each flow diagram in `docs/Diagrams.md` is drawn from one source, `docs/diagrams/source/<id>.psd1`. When a command's calls change, change its source and run `./Update-Diagram.ps1`. The tests fail while a diagram names a function that no longer exists, leaves out a call the code it covers makes, or has not been redrawn, so the diagrams cannot drift from the code unnoticed.

## License

LazyVM is free for personal and other noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). Using it for a commercial purpose needs a separate commercial license; contact the author through GitHub.

### ALPHA - A masochistic exploration into Vibe Coding the wrong way.

<br/>
Motivation:
<br/>
<i>I lost my eyesight nine years ago and am finally at a point where I can regularly use a computer with almost the same ease as before the accident. I was a full-stack developer. My go-to tools were C#, Visual Studio, SQL Server, and other tooling capable of wreaking havoc to the only semi-accessible setup I have access to.

*A lot has changed, and I have a lot of catching up to do. Installing Visual Studio, SQL Server, and other heavy tooling on the only machine I rely on seemed like a good way to end up blocked from dealing with life's obligations while troubleshooting development issues. It also increases the machine's attack surface.*

*I decided to use Hyper-V and put Visual Studio and other tooling in VMs. An opportunity to try vibe coding with Copilot and Claude.*

*Vibe coding is proving to be an exercise in herding cats. The code starts as spaghetti, gets refactored into gumbo, and eventually I realize some of the spaghetti never got served.*

*Copilot was let go.  Both Copilot and Claude are a wee bit way too creative, but Claude's work output runs and tends to be aligned with the specs following the patterns and practices it has been provided.  Copilot's behavior and work output was discerning and I am concerned Copilot may have a substance use disorder.

# LazyVM

Currently this is a tool for setting up educational Visual Studio dev environment VMs on Windows using Hyper-V.  

PowerShell has always been a weak point for me.  My history with PowerShell consists of me hacking a few lines into a script when needing tooling for soemting as ridiculous as a one-liners invoke-webrequest "IIS application" by a schedule task to prevent IIS from timing and recycling the worker processor.  Otherwise, there would be help request tickets every morning, after lunch, and after staff events reporting an app was down or an app was taking too long.  The joys of web froms back in the day.

If I master herding cats this will be a tool for deploying, maintainin and destroying Hyper-V virtual machine in Windows. VM templated configuration will be provided with this tool, changes to made to harnessed VMs created by this tool will create matching config templates in a qausi-green manner, to migitage template prolferation only the latest VM changes will be written to the corresponding template.  The goal is persist all environment changes, including changes to the VM's UI eg. dark mode, text size, Explorer.exe settings, tooling settings and etc with the exception of sensitive information like credentials, on the VM's configuration file.  Hopefully, this will support VMs that are not educational dev environments coupled to Windows Enterprise evaluation, Visual Sttudio, MsSQL and other tooling.

Entities, like a independent contracdtors, will benefit having free reliable tooling that is intuitive, effortless and reliable for creating and maintaining VMs eg a bookkeeper needing to a dedicated isolated work environment for each customer.. The intention is lightening the load for disaster recovery, ethical a legally mandated  requiredments, e.g. HITECH/HIPAA requirements for health provider's business associate.

What it needs

` A cert for signing code

## Currently What is it:

-A PowerShell module that builds and looks after Hyper-V development VMs on a Windows host, unattended: Windows 11 Enterprise Evaluation, Visual Studio, SQL Server Enterprise Developer and whatever other tools you install, with the 90-day evaluation handled for you.  The reset flag has a lifespan of being flipped three times.  <code>4 * 90 = 360</code>

## What it does

- **Builds a VM with no input from you.** It creates the VM, installs Windows from an answer file, then installs everything in the VM's tooling list: Visual Studio and SSMS with their workloads and Marketplace extensions, SQL Server, and winget packages.
- **Keeps the VM's tooling list current.** Every day it records what you have added or removed in the VM, taking a Hyper-V checkpoint first, so any recorded version can be returned to.
- **Makes the 90-day evaluation a non-event.** It watches the license and rearms Windows while it can. When it can't, it captures your state, rebuilds the VM and puts everything back: databases, logins, Visual Studio settings, certificates, environment and application settings.
- **Keeps your source safe across rebuilds.** Source lives on a Dev Drive whose disk a rebuild never touches.
- **Runs several VMs on one host**, each with its own tools, disks, schedule and restore points.
- **Never stops over a typo.** If a settings file breaks, the scheduled maintenance uses the last version that worked and says so in the log.

## Requirements

- Windows 10 or 11 Pro, Enterprise or Education on the host (Hyper-V is not available on Home).
- [PowerShell 7.4 or later](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows), run as administrator: `winget install Microsoft.PowerShell`.
- A Windows 11 Enterprise Evaluation ISO, downloaded by hand from the [Microsoft Evaluation Center](https://www.microsoft.com/en-us/evalcenter/evaluate-windows-11-enterprise). LazyVM opens that page for you if it can't find one.
- Memory and disk for each VM. By default a VM starts with 8 GB of memory and can grow to 16 GB. Its disks are 120 GB for Windows, 100 GB for SQL data and 250 GB for the Dev Drive, all dynamically expanding.

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

Every command has full help: `Get-Help Build-LazyVM -Full`. `-Name` can be left out while the host has only one VM, and it tab-completes.

| Command                                                       | What it does                                                                                           |
| ------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------ |
| `Set-LazyVMRoot`                                            | Chooses your own folder for LazyVM instead of the automatic one.                                       |
| `New-LazyVM`                                                | Creates a VM's profile without building it. `-From` starts from another VM's settings and tools.     |
| `Build-LazyVM`                                              | Builds the VM, setting up whatever is missing first, and schedules its maintenance. Safe to run again. |
| `Get-LazyVM`                                                | Lists the VMs, their state and their maintenance.                                                      |
| `Get-LazyVMSetting`                                         | Every setting as a VM uses it, where the value came from, and what it does.                            |
| `Set-LazyVMCredential` / `Get-LazyVMCredential`           | The administrator account LazyVM uses inside the VM.                                                   |
| `Get-LazyVMLicense`                                         | Evaluation days and rearms left, and what maintenance will do.                                         |
| `Get-LazyVMTooling`                                         | What is installed in the VM, and what the next maintenance run would record.                           |
| `Save-LazyVMTooling`                                        | Records tooling changes now, with a checkpoint.                                                        |
| `Get-LazyVMRestorePoint` / `Restore-LazyVMTooling`        | Lists recorded tooling versions, and restore to specified version.                                    |
| `Save-LazyVMState` / `Restore-LazyVMState`                | Captures the VM's state to the host, and puts it back.                                                 |
| `Invoke-LazyVMRebuild`                                      | Rebuilds the VM from scratch, keeping your work.                                                       |
| `Invoke-LazyVMMaintenance` / `Register-LazyVMMaintenance` | The daily maintenance run, and scheduling it.                                                          |
| `Remove-LazyVM`                                             | Deletes a VM and everything created for it. `-WhatIf` lists it all first.                            |

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

## Documentation

The [guide](docs/Guide.md) covers every command, setting and phase, and what to do when something goes wrong.

The [use case diagrams](docs/UseCases.md) show who does what with LazyVM, in UML. The [flow diagrams](docs/Diagrams.md) show, for each thing you do with LazyVM, which functions run in what order and what each one reads and writes.

## Development

```
src/LazyVM/
  LazyVM.psd1, .psm1   the module
  Public/                          one file per command
  Private/<Area>/                  everything else, by area
  Data/                            the settings schema and the default tooling list
tests/                             Pester tests
Invoke-AnalyzerAndTest.ps1         check a change: assemble, analyze, test
New-ReleasePackage.ps1             make the release zip
build/                             the steps both use
```

`./Invoke-AnalyzerAndTest.ps1` assembles the module into `out\`, runs PSScriptAnalyzer (any finding fails) and runs the Pester tests. GitHub Actions runs the same on Windows for every push.

## License

LazyVM is free for personal and other noncommercial use under the [PolyForm Noncommercial License 1.0.0](LICENSE.md). Using it for a commercial purpose needs a separate commercial license; contact the author through GitHub.

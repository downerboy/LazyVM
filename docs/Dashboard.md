<p align="center"><img src="images/logo.svg" alt="LazyVM logo" width="240"></p>

# LazyVM Dashboard — specification

Status: Draft. Tracks [#305](https://github.com/downerboy/LazyVM/issues/305). The module command (section 3) is built. The window has its main list, the read-only VM window, the Checks and Log windows (delivery plan steps 3 and 4), and step 5: the Build window with build progress and Cancel, a build from a chosen phase, and run maintenance now. Step 6, deleting a VM and restoring it to a restore point, is built too. Of step 7, the recovery key status and the Recovery keys window are built; the password window is not yet, nor is step 8. Updated 2026-11-18 with the Recovery keys window.

## 1. Purpose

A desktop window for people who are not comfortable with the command line. It shows every LazyVM VM on this host in one place, so you can see at a glance which ones are healthy, which need attention and what each one holds, and it builds, restores and disposes of VMs, runs maintenance, shows credentials and recovery keys, and shows and approves security findings. It wraps the module's commands: anything the window does, the command line does too.

The settings editor, upgrade and migration, and import of existing VMs (#303) come in later versions (section 8).

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| UI framework | WPF on .NET 10 (LTS), C# | Visual Studio XAML designer, built-in `DataGrid`, UI Automation support, and a fit for data-driven dashboards. WinUI 3 has no designer or first-party `DataGrid`. |
| Structure | One WPF project, `LazyVM.UI.Wpf`, that wraps the module's commands, and one test project, `LazyVM.UI.Wpf.Tests`, with unit tests for the behavior | A wrapper needs no extra layers. No business-object, data or service layers and no abstract-class seams. |
| Pattern | MVVM, constructor injection, no code-behind logic | Testable without a window (TDD, SOLID). |
| Commands first | A feature ships as a command in the module first, then gets a screen | The module stays the single source of truth. The GUI never reads `VM.json` or Hyper-V on its own. |
| Running the commands | In-process through the PowerShell SDK for reads and short actions; each build in its own elevated `pwsh` process | A build outlives the window. |
| Permissions | The app runs elevated (a UAC prompt when it opens) | Hyper-V actions need administrator rights, as the commands do today. See section 5. |
| Network | None. No listener, no web service | LazyVM is per-user. A port on the host would be reachable by other users. |
| Look | The [brand spec](Brand.md), mapped to XAML (section 6) | One look across the findings page, console and GUI. |
| Accessibility target | Narrator | The screen reader the author uses. See section 7. |

WinUI 3 stays possible later: only `LazyVM.UI.Wpf` depends on WPF.

## 3. What the dashboard shows

One row per VM in the main list. The details open in the VM's own window.

`Get-LazyVMDashboard` returns all of it as one `LazyVM.Dashboard` object per VM, so the GUI makes one call, not many. It only reads.

| Field | Property | Source |
|---|---|---|
| VM name | `Name` | The VM's profile |
| State (Running, Off, Not built…) | `State` | Hyper-V |
| When it was created | `Created` | Hyper-V `CreationTime`. A rebuild makes a new VM, so this is when the current one was built. |
| Memory in use | `MemoryAssigned` (bytes) | Hyper-V. 0 while the VM is off. Shown against `MemoryMaximum`, for example "6 GB of 16 GB" (#420). |
| Most memory the VM can use | `MemoryMaximum` (bytes) | Hyper-V. The dynamic memory maximum, or the startup memory when dynamic memory is off. |
| Attached disks | `Disks`: `Name`, `Path`, `Used`, `Maximum` (bytes) | Hyper-V. `Used` includes the disk's checkpoint files. |
| Total disk space used | `DiskSpaceUsed` (bytes) | The sum of `Disks.Used` |
| Maintenance schedule and task | `MaintenanceTime`, `MaintenanceTask` | The VM's settings, Task Scheduler |
| Last maintenance run and result | `LastMaintenance`, `LastMaintenanceResult` (Succeeded, Failed (0x…), Not run yet) | Task Scheduler. Runs started by hand are not counted. |
| Last security scan, findings still open | `LastSecurityScan`, `OpenFindings` | `Logs\SecurityFindings.json`, less approved and resolved findings |
| Configuration it was first built from | `OriginalConfig` | `Config\VM.Template.json` |
| Config template it was created from | `CreatedFromTemplate` | `VM.json`, recorded when the profile is created with `-ConfigTemplate` (#421). Empty when there was none, and for profiles made before LazyVM recorded it. |
| Green template | `GreenTemplate`, `GreenTemplateUpdated` | `Shared\Templates\<VM>-latest.json` |
| Recovery keys stored, not exported, last export | `RecoveryKeys`, `UnexportedRecoveryKeys`, `RecoveryKeysExported` | The key IDs in `Credentials\bitlocker.cred` and `Config\RecoveryKeyExport.json`, from `Export-LazyVMRecoveryKey` (#467). `UnexportedRecoveryKeys` counts the keys the last export did not hold. `RecoveryKeysExported` is empty when the keys were never exported. No password is read into the row. |
| Settings problem | `Settings` | The VM's settings files |
| What could not be read | `Problems` | One line per part that failed, such as `Disks: access denied` |

The green template is the config template LazyVM keeps up to date every time the VM changes (#292), so there is always a template to build another VM just like it. "Green" as in evergreen.

The VM window names the config template the VM was created from, or says "None recorded" when the VM was made without one or before LazyVM recorded it (#421). `OriginalConfig` gives the configuration itself.


## 4. What the window does

### Step 1 scope

1. **App shell.** The VM list; the Windows evaluation expiry date and renewals left; first-run checks (`Test-LazyVM`) with plain-language fixes; a log viewer; Connect. Buttons are disabled, with an explanation, while maintenance or another build is running.
2. **Build.** A form with the VM name, the template (Developer, PlainWindows, saved templates such as `DevEnv-latest`) and an optional user name. Progress by phase, each shown as its number and goal (for example "Phase 6: Create the VM and its answer-file disc"), cancel, and run from phase N after a failure. A manual "run maintenance now". A build keeps running if the window closes.
3. **Dispose and restore.** Dispose first shows what will be deleted, with sizes, and the Dev Drive and User disk warnings, then asks "Do you really want to delete this VM?" with Yes and No, and No is the default. Restore lists the VM's restore points (the tooling checkpoints) and puts one back, after a question that says all its disks go back, the Dev Drive and SQL data disk included. Decided 2026-11-17.
4. **Credentials.** Recovery key export and a "keys not exported" notice. The guest password is hidden by default, revealed only on request, never written to a log, and the clipboard is cleared three minutes after a copy.
5. **Security findings.** View, approve and revoke.

### Windows

- **Main window:** the list of VMs, one per row: name, state, open findings, last maintenance and result. Enter or a double-click opens the VM's window. A **Build new VM** button sits in the header.
- **VM window:** one per VM, with the full details (section 3) and every action for that VM. Opening a VM whose window is already open brings that window to the front. When an action finishes, the main list updates.
- **Dialogs:** first-run checks, build, build progress, restore, recovery keys and password, log, security findings, delete confirmation.

### Behavior

- **Needs attention.** The open-findings badges, plus a "Needs attention" marker in the State column when the last maintenance failed or a settings problem exists. Every badge and marker has text for screen readers, for example "High 1 open finding" and "Needs attention: last maintenance failed".
- **Refresh.** On open, on F5 or a Refresh button, and after any action. No live polling in this step; a running build updates its own progress.
- **Builds.** Each build runs in its own elevated `pwsh` process, started with `-File` and a script in the module folder (`Scripts\Start-AppBuild.ps1`), its arguments passed as a list, never as script text. pwsh 7.6 or later comes from `%ProgramFiles%\PowerShell\7`, or else from its Microsoft Store package in `%ProgramFiles%\WindowsApps`, never from PATH, and the script loads modules only from folders administrators control. Its output is not redirected, so a closed window cannot stall the build; the script writes how the build ended to a result file, which says why when a build ends before it records a run, such as when the Windows ISO is missing. Closing or crashing the window never stops a build. The window shows progress from the run state the module records (#425), not by reading the log's text, so it also follows a build the app did not start, such as one carrying on after a host restart. Other actions run in-process.
- **Cancel.** Asks the build to stop (#426). It stops at the next safe point: between phases, between steps, or in a wait. The failed-build clean-up runs, so the answer-file disc is removed. Work already started inside the VM, such as an install, finishes by itself. The window says so. `Stop-LazyVMBuild` does this, and the dashboard's `Run.StopRequested` shows the build is stopping. The process is never killed, since that would skip the clean-up.
- **Run from phase N** (#428). The VM window lists the phases, each as its number and goal, and **Build from this phase** builds the VM from the one chosen, with its progress in a window of its own. After a build that failed, stopped or ended unexpectedly, the phase it was in is chosen, and the window says why. That build's progress window offers **Carry on from phase N** too. Both say to let any install still running inside the VM finish first.
- **Run maintenance now** starts the VM's maintenance task, so it runs exactly as the nightly run does. `Start-LazyVMMaintenance` does this (#428). It starts nothing while a build, maintenance or rebuild of the VM is running, or when maintenance is not scheduled, and says why.
- **Busy.** While a build, maintenance or rebuild of the VM is running (the dashboard's `Run`), Build from this phase and Run maintenance now are disabled, and the VM window says why in text of its own, since a disabled button cannot take focus for Narrator to read it. Checks, Log and Build progress stay available. The list is read again after a run starts, so the buttons follow; the module's run lock and `Start-LazyVMMaintenance`'s own checks still refuse a second run started in the moment before that.
- **Delete** (#455). **Delete this VM...** in the VM window reads `Get-LazyVMRemovalPlan` and opens a dialog listing what goes: the Dev Drive and User disk warnings first, then the Hyper-V VM with its state and checkpoints, its scheduled tasks, each file and folder with its size, the total, and what is kept and why. It then asks "Do you really want to delete this VM?" with Yes and No. No is the default and the cancel button, and focus starts on the first line of the list, so Enter and Esc both answer No. Yes runs `Remove-LazyVM -Force` in the app's runspace, off the UI thread, and never cancels it. When it is done, the VM window closes and the list is read again. A delete that did not finish keeps the window open, gives the module's reason, and names what is still there, from the removal plan read again. Delete is disabled while any run of the VM is going, with a note of its own saying why. While a delete runs, other calls to the module wait for it.
- **Restore** (#456). **Restore...** in the VM window opens the VM's Restore window, one per VM, listing its restore points (`Get-LazyVMRestorePoint`) newest first, each with the date it was taken and whether its tooling list is kept; with none, it says so. **Restore to this point...** asks first, with Yes and No, No the default and focused: all of the VM's disks go back to then, including the Dev Drive and the SQL data disk, so code not yet pushed and database changes since then are lost, and a checkpoint of how it is now is taken first, so the restore can be undone. Yes runs `Restore-LazyVMTooling -Force` in the app's runspace, off the UI thread, and never cancels it; the points and the main list are read again afterwards, however it ended. Restore is disabled while any run of the VM is going, and for a point whose tooling list is missing, with a note saying why.
- **Recovery keys** (#468). **Recovery keys...** in the VM window opens the VM's Recovery keys window, one per VM. It lists each disk LazyVM encrypted (`Get-LazyVMRecoveryKey`): C: and earlier OS disks, the SQL data disk, the Dev Drive and the User disk, each with the key ID BitLocker's recovery screen shows, the date it was recorded, and whether it is exported. Each disk's recovery password is hidden: its row says "Recovery password hidden", with a **Show** button. Show reads that one password then, from `Get-LazyVMCredential -RecoveryPassword`, and **Hide** masks it again; closing the window forgets every password shown. A password is never in the status line, an error message or a log. **Export...** asks for a file with a Save dialog, and when the file exists asks whether to replace it, with No the default, saying that nothing in it is kept. It then runs `Export-LazyVMRecoveryKey -Name <VM> -Path <file>`, with `-Force` only after a Yes, off the UI thread. Each warning the module gives, such as for a file in OneDrive or inside the LazyVM folder, is text of its own, read by Narrator, and the status line says where the keys went. The keys and the main list are read again afterwards. With no key stored, Export is disabled and a note says why. When keys are not exported (`UnexportedRecoveryKeys`), the VM window shows a notice saying how many, beside the Recovery keys button, its details say how many are stored and when they were last exported, and the main list's row needs attention.
- **Checks.** On open, after the list, the app runs `Test-LazyVM -HostOnly`, or plain `Test-LazyVM` while there are no VMs, so the note on making the first one shows. The Checks window opens by itself only when there are no VMs, a check failed, or the checks could not run. A **Checks** button in the main window checks the host, and one in each VM window checks that VM. Each row reads as status, check, what was found, then the fix; Ctrl+C copies the fix.
- **Log.** A **Log** button in each VM window shows the last 1000 entries of its log (`Get-LazyVMLog -Tail 1000`), oldest first, with the newest selected. Each entry reads as level, time, message. F8 and Shift+F8 go to the next and previous warning or error. The text is shown as plain text only, since the log is in the data folder.
- Calls run off the UI thread and can be cancelled. A failure on one VM shows on that VM's row and does not blank the list.

### Structure

```
src/LazyVM.slnx
src/LazyVM.UI.Wpf/           WPF app: views (XAML), view models, one small class that runs the module's commands
src/LazyVM.UI.Wpf.Tests/     xUnit: view-model behavior against a fake command runner, no window
```

- View models take the command-runner class through their constructor and never see PowerShell. Members a test replaces are `virtual`.
- `ViewModelBase` implements `INotifyPropertyChanged` once. Other framework interfaces are implemented once, in base classes.
- **Hosting PowerShell.** The runner opens one runspace and imports the installed module by full path from `%ProgramFiles%\LazyVM\Modules`. Calls use `PowerShell.InvokeAsync()`; Cancel uses `StopAsync()`. A runspace runs one pipeline at a time, so a second refresh waits for the first. The PowerShell version the app ships must be one the module supports, and the release build checks it.
- The module's own C# classes, such as `VMContext`, live in the module, in `src/LazyVM/Classes`, and are not part of the solution. The window does not depend on them.
- Every project of the solution, tests included, sits in `src`. The repository's `tests` folder keeps only the module's Pester tests.
- Names follow the .NET guidelines: two-letter acronyms in capitals (`UI`), longer ones in Pascal case (`Wpf`).


## 5. Security

The app runs elevated, because the commands it runs need administrator rights. It adds no privilege the user does not already use in an administrator PowerShell, and it must not give a non-administrator a way to run code as an administrator:

1. The app and every DLL it loads sit in `%ProgramFiles%\LazyVM\App`, with the module's access rule: administrators and SYSTEM can change them, and only the user who installed LazyVM can read and run them. `Assert-TrustedCode` checks that folder too.
2. The module is imported by full path from `%ProgramFiles%\LazyVM\Modules`, never found through `PSModulePath`. No PowerShell profile scripts run.
3. The data folder in `%USERPROFILE%\LazyVM` is untrusted: any process running as the user can change it. Settings are read through the module's checks (`Read-TrustedVMSetting`) and never become script text. Commands are fixed commands with fixed parameters.
4. No listener, no named pipe, no remote calls.
5. No secrets on disk or in logs. The password is hidden until asked for, and the clipboard is cleared after a copy. A recovery key export warns when the chosen folder is inside OneDrive.
6. The Start menu shortcut is in a place only administrators can change, so no other program can repoint a shortcut that then asks for elevation.
7. A user without Hyper-V rights sees State as "Unknown", as `Get-LazyVM` already reports.

## 6. Look and feel

Mapped from the [brand spec](Brand.md); that document stays the source for values.

- **Tokens**: the `--lv-*` colors become a XAML `ResourceDictionary` (`Light.xaml`, `Dark.xaml`) with the same names, for example `LvNavy`. Brushes come from those only.
- **Theme**: follows the Windows light/dark setting. High Contrast uses system colors and drops the custom colors.
- **Severity and status**: the same icon and word as the brand (▲ High, ◆ Medium, ● Low, ■ Info). Never color alone.
- **Buttons**: one style: yellow, 2px navy border, minimum 44×44 px, 3px navy focus outline with 2px offset.
- **Type**: Segoe UI body, Cascadia Mono for commands, sentence case.
- **Grid**: alternate rows use the tint color. Row height holds at large text sizes.
- **Scaling**: WPF does not follow the Windows text-size setting on its own. The window honors it, and Ctrl+plus/minus/0 zoom the content from 100% to 400% with no sideways scrolling at 400%.
- **Status line**: a text line at the bottom says what the last refresh did ("Refreshed 3 VMs at 14:52").

## 7. Accessibility

1. Every control has an `AutomationProperties.Name`. The grid exposes row and column headers to UI Automation.
2. Full keyboard use: Tab order matches reading order, arrow keys move in the grid, Enter opens a VM's window, F5 refreshes, Esc closes a window or dialog.
3. Narrator is the test target. Each row reads as one sentence, for example "DevBox, Running, last maintenance succeeded 12 November, 2 findings".
4. State changes (refresh finished, error) are announced through a live-region automation event.
5. No animation. Respect the Windows "show animations" setting.
6. Tested at 200% and 400% zoom and in High Contrast, as the brand spec requires for the findings page.


## 8. Later versions

Not in the first step. The first step leaves the seams for them.

- **Settings editor.** View and change a VM's settings before a build, with validation at each field (the schema already names each problem's place).
- **Upgrade and migration.** Updating LazyVM from the window, and `Convert-LazyVMInstallation`.
- **Import of existing VMs** (#303), once the command exists.
- **Remote hosts.** Calling the module through PowerShell remoting, so one window shows several Hyper-V hosts.
- **Live numbers.** Memory use, processor load, uptime and heartbeat read straight from Hyper-V's WMI namespace (`root\virtualization\v2`, `GetSummaryInformation`) through `Microsoft.Management.Infrastructure`, many VMs per call, refreshed on a timer apart from F5. It reads only numbers Hyper-V owns, so it holds no LazyVM logic and cannot drift from the module. It needs the same Hyper-V rights as `Get-LazyVM`.
- **Roles.** Viewer and operator, from Windows groups.
- **Central view.** An optional collector service. It would be a separate component with its own security design, not part of the per-user app.
- **Installer.** A signed setup program, and policy-driven settings.

The module is per-user by design. Any multi-user mode must be an explicit, administrator-controlled opt-in, never the default.

## 9. Installing and starting it

- It ships in the same release zip as the module, and `Install.ps1` installs both: the module in `%ProgramFiles%\LazyVM\Modules` and the app in `%ProgramFiles%\LazyVM\App`.
- The zip includes a double-click **Install LazyVM** launcher that runs `Install.ps1` elevated, so a user never opens a console. `Install-FromRepository.cmd` stays the developer's shortcut.
- `Install.ps1` adds a **LazyVM** shortcut in a Start menu folder that only administrators can change (section 5, rule 6). Uninstalling removes it.
- Updating means installing the newer release the same way. The app does not update itself in the first step.
- Code signing (#4) is deferred until the first beta release. Until then Windows SmartScreen warns about the app.

### Decided questions

Decided 2026-11-16:

1. Memory is shown as use against the maximum the VM can use (#420). Done.
2. LazyVM records the config template a VM was created from, and the window names it (#421). Done.
3. A copied password stays on the clipboard for three minutes, then it is cleared.
4. Build progress shows each phase's number with its goal. The goals come from the module (`Get-LazyVMBuildPhase`, #422), the single list of phases.

## 10. Delivery plan (TDD, small pull requests)

Each screen needs its command first. Where a command is missing (for example the evaluation expiry or recovery key status), a module pull request comes before the screen.

1. This spec.
2. `Get-LazyVMDashboard` in the module, with tests, help, diagram and guide. Done.
3. `LazyVM.UI.Wpf`: the command-runner class, theme dictionaries, the main list and the VM window (read-only), view-model tests first. Done.
4. First-run checks and the log viewer. Done.
5. Build, build progress and cancel, with each build in its own `pwsh` process; run from phase N; run maintenance now. Module pull requests first, then the app. Done:
   1. Each phase's goal, and `Get-LazyVMBuildPhase` (#422).
   2. `Get-LazyVMConfigTemplate`, the config templates to choose from (#423).
   3. `Build-LazyVM -UserName` for a new VM's account (#424).
   4. The run state: a running build or maintenance recorded, reported by `Get-LazyVMDashboard`, and a second build refused (#425).
   5. A clean stop of a running build (#426).
   6. The app: the Build window, progress and Cancel (#427). Done.
   7. The app: run from phase N, and run maintenance now (#428). Done.
6. Dispose and restore. Module pull requests first, then the app:
   1. `Remove-LazyVM` and `Restore-LazyVMTooling` hold the run lock, so neither runs while a build, maintenance or rebuild of the VM does (#453). Done.
   2. What `Remove-LazyVM` would delete, returned as objects (#454). Done.
   3. The app: delete a VM, after showing what goes (#455). Done.
   4. The app: restore a VM to a restore point (#456). Done.
7. Recovery keys and the password. Module pull request first, then the app. Every password, the guest password and the disks' recovery passwords alike, is hidden by default and shown only when asked for. Decided 2026-11-18.
   1. `Get-LazyVMDashboard` reports each VM's recovery key export status: how many keys are stored, how many are not exported, and when they were last exported. It never reads a password (#467).
   2. The app: a VM's recovery keys, each disk's recovery password hidden until shown, export to a file, and a "keys not exported" notice (#468). The module gets `Get-LazyVMRecoveryKey` first, in the same pull request: each disk's key without its password, and whether it is exported.
   3. The app: the VM's password, hidden until shown, and Copy, which keeps it out of clipboard history and clears it after three minutes (#469).
8. Security findings: view, approve, revoke.
9. Accessibility pass with Narrator, and zoom and High Contrast checks.
10. Packaging: the release zip, `Install.ps1`, the launcher and the Start menu shortcut.

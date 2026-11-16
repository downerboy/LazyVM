<p align="center"><img src="images/logo.svg" alt="LazyVM logo" width="240"></p>

# LazyVM Dashboard — specification

Status: Draft. Tracks [#305](https://github.com/downerboy/LazyVM/issues/305). The module command (section 3) is built. The window has its main list and the VM window, read-only (delivery plan step 3); the rest is not built yet. Updated 2026-11-14 to the design decided for the first step.

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
| Memory in use | `MemoryAssigned` (bytes) | Hyper-V. 0 while the VM is off. |
| Attached disks | `Disks`: `Name`, `Path`, `Used`, `Maximum` (bytes) | Hyper-V. `Used` includes the disk's checkpoint files. |
| Total disk space used | `DiskSpaceUsed` (bytes) | The sum of `Disks.Used` |
| Maintenance schedule and task | `MaintenanceTime`, `MaintenanceTask` | The VM's settings, Task Scheduler |
| Last maintenance run and result | `LastMaintenance`, `LastMaintenanceResult` (Succeeded, Failed (0x…), Not run yet) | Task Scheduler. Runs started by hand are not counted. |
| Last security scan, findings still open | `LastSecurityScan`, `OpenFindings` | `Logs\SecurityFindings.json`, less approved and resolved findings |
| Configuration it was first built from | `OriginalConfig` | `Config\VM.Template.json` |
| Green template | `GreenTemplate`, `GreenTemplateUpdated` | `Shared\Templates\<VM>-latest.json` |
| Settings problem | `Settings` | The VM's settings files |
| What could not be read | `Problems` | One line per part that failed, such as `Disks: access denied` |

The green template is the config template LazyVM keeps up to date every time the VM changes (#292), so there is always a template to build another VM just like it. "Green" as in evergreen.

Not yet available: the name of the config template a VM was first created from. `VM.json` does not record it. `OriginalConfig` gives the configuration itself.


## 4. What the window does

### Step 1 scope

1. **App shell.** The VM list; the Windows evaluation expiry date and renewals left; first-run checks (`Test-LazyVM`) with plain-language fixes; a log viewer; Connect. Buttons are disabled, with an explanation, while maintenance or another build is running.
2. **Build.** A form with the VM name, the template (Developer, PlainWindows, saved templates such as `DevEnv-latest`) and an optional user name. Progress by phase, cancel, and run from phase N after a failure. A manual "run maintenance now". A build keeps running if the window closes.
3. **Dispose and restore.** Dispose asks "Do you really want to delete this VM?" with Yes and No, and No is the default. Restore shows the last backups and puts one back.
4. **Credentials.** Recovery key export and a "keys not exported" notice. The guest password is hidden by default, revealed only on request, never written to a log, and the clipboard is cleared a short time after a copy.
5. **Security findings.** View, approve and revoke.

### Windows

- **Main window:** the list of VMs, one per row: name, state, open findings, last maintenance and result. Enter or a double-click opens the VM's window. A **Build new VM** button sits in the header.
- **VM window:** one per VM, with the full details (section 3) and every action for that VM. Opening a VM whose window is already open brings that window to the front. When an action finishes, the main list updates.
- **Dialogs:** first-run checks, build, build progress, restore, recovery keys and password, log, security findings, delete confirmation.

### Behavior

- **Needs attention.** The open-findings badges, plus a "Needs attention" marker in the State column when the last maintenance failed or a settings problem exists. Every badge and marker has text for screen readers, for example "High 1 open finding" and "Needs attention: last maintenance failed".
- **Refresh.** On open, on F5 or a Refresh button, and after any action. No live polling in this step; a running build updates its own progress.
- **Builds.** Each build runs in its own elevated `pwsh` process and the window shows its progress from the VM's log, so closing or crashing the window never stops a build. Other actions run in-process.
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

### Open questions

1. Is memory shown as current use only, or with the assigned maximum?
2. Should LazyVM record which config template a VM was created from, so the window can name it?
3. How long does a copied password stay on the clipboard before it is cleared?
4. The names and number of the build phases shown on the progress screen (the mockup uses placeholders).

## 10. Delivery plan (TDD, small pull requests)

Each screen needs its command first. Where a command is missing (for example the evaluation expiry or recovery key status), a module pull request comes before the screen.

1. This spec.
2. `Get-LazyVMDashboard` in the module, with tests, help, diagram and guide. Done.
3. `LazyVM.UI.Wpf`: the command-runner class, theme dictionaries, the main list and the VM window (read-only), view-model tests first. Done.
4. First-run checks and the log viewer. Done.
5. Build, build progress and cancel, with each build in its own `pwsh` process; run from phase N; run maintenance now.
6. Dispose and restore.
7. Recovery keys and the password.
8. Security findings: view, approve, revoke.
9. Accessibility pass with Narrator, and zoom and High Contrast checks.
10. Packaging: the release zip, `Install.ps1`, the launcher and the Start menu shortcut.

<p align="center"><img src="images/logo.svg" alt="LazyVM logo" width="240"></p>

# LazyVM Dashboard — specification

Status: Draft. Tracks [#305](https://github.com/downerboy/LazyVM/issues/305). The module command (section 3) is built; the window is not.

## 1. Purpose

A desktop window that shows every LazyVM VM on this host in one place, so you can see at a glance which ones are healthy, which need attention and what each one holds. It reads and reports. In its first version it changes nothing in any VM.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| UI framework | WPF on .NET 10 (LTS), C# | Visual Studio XAML designer, built-in `DataGrid`, UI Automation support, and a fit for data-driven dashboards. WinUI 3 has no designer or first-party `DataGrid`. |
| Pattern | MVVM, constructor injection, no code-behind logic | Testable without a window (TDD, SOLID). |
| Data source | The LazyVM PowerShell module, run in-process through the PowerShell SDK | The module stays the single source of truth. The GUI never reads `VM.json` or Hyper-V on its own. |
| Network | None. No listener, no web service | LazyVM is per-user. A port on the host would be reachable by other users. |
| Look | The [brand spec](Brand.md), mapped to XAML (section 6) | One look across the findings page, console and GUI. |

WinUI 3 stays possible later: only `DownerBoy.LazyVM.UI.Wpf` depends on WPF.

## 3. What the dashboard shows

One row per VM. Details open in a panel beside or below the list.

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

## 4. Architecture

Two projects. `DownerBoy.LazyVM.Api` is a layered class library: business objects, a data layer, and a service layer on top that holds the business logic. `DownerBoy.LazyVM.UI.Wpf` is the window: a thin wrapper that knows the business objects and calls only the service layer. Another presentation layer (WinUI 3, a web front end) can replace it without touching the library.

```
DownerBoy.LazyVM.UI.Wpf        Views (XAML), view models          calls the service layer only
        │
        ▼
DownerBoy.LazyVM.Api
  DownerBoy.LazyVM.Services    DashboardService, LazyVMDashboardService     ← top layer
  DownerBoy.LazyVM             VmSummary, DiskSummary, and any class PowerShell consumes
  DownerBoy.LazyVM.Data        VmInventory, PowerShellVmInventory           → LazyVM module
```

- **Business objects** (`DownerBoy.LazyVM`): immutable records such as `VmSummary` and `DiskSummary`. Classes written later for PowerShell to consume go in this namespace too.
- **Data layer** (`DownerBoy.LazyVM.Data`): `VmInventory` (abstract) and `PowerShellVmInventory`, which runs `Get-LazyVMDashboard` in-process and maps its output to business objects. A fake subclass stands in for it in tests.
- **Service layer** (`DownerBoy.LazyVM.Services`): `DashboardService` (abstract) and `LazyVMDashboardService`. `GetVmsAsync(CancellationToken)` returns the VMs. The business rules live here, such as whether a VM needs attention (failed maintenance, open findings, a `Problems` entry).
- **UI** (`DownerBoy.LazyVM.UI.Wpf`): XAML views with bindings and styles, and view models for the list, sorting, selection, refresh and error state. `ViewModelBase` (abstract) implements `INotifyPropertyChanged` once. The view models take a `DashboardService` through their constructor; they never see PowerShell.
- **Abstract classes, not interfaces**, for the project's own seams. Framework interfaces (`INotifyPropertyChanged`, `ICommand`, `IDisposable`) are implemented once, in the base classes. Members a test replaces are `abstract` or `virtual`.
- **Hosting PowerShell**: `PowerShellVmInventory` opens one runspace and imports the installed LazyVM module from `%ProgramFiles%\LazyVM\Modules`. Calls use `PowerShell.InvokeAsync()`; Cancel uses `StopAsync()`. A runspace runs one pipeline at a time, so a second refresh waits for the first. The PowerShell version the app ships must be one the module supports, and the release build checks it.
- **Loaded by PowerShell too**: because PowerShell will load `DownerBoy.LazyVM.Api` for its own classes, the library references `System.Management.Automation` for compiling only. The WPF app brings the PowerShell SDK it runs on. Inside `pwsh`, PowerShell's own copy is used, so the two never clash.
- Calls run off the UI thread and can be cancelled. A failure on one VM shows on that VM's row and does not blank the list.
- Refresh on open, on a Refresh button and on F5. No background polling in version 1.

### Solution layout

```
src/DownerBoy.LazyVM.slnx
src/DownerBoy.LazyVM.Api/              class library: business objects, Data, Services
src/DownerBoy.LazyVM.UI.Wpf/           WPF app, namespace DownerBoy.LazyVM.UI.Wpf
src/DownerBoy.LazyVM.Api.Tests/        xUnit: mapping and service rules, against a fake VmInventory
src/DownerBoy.LazyVM.UI.Wpf.Tests/     xUnit: view models against a fake DashboardService, no window
```

Every project of the solution, tests included, sits in `src`. The repository's `tests` folder keeps only the module's Pester tests.

Names follow the .NET guidelines: two-letter acronyms in capitals (`UI`), longer ones in Pascal case (`Api`, `Wpf`).

## 5. Security

1. Runs as the signed-in user. Its files sit beside the module in `%ProgramFiles%\LazyVM`, with the same access rule: only the user who installed LazyVM can read them.
2. No listener, no named pipe, no remote calls.
3. Runs the module through the user's own PowerShell. It adds no privileges. A user without Hyper-V rights sees State as "Unknown", as `Get-LazyVM` already reports.
4. Shows no credentials, recovery keys or findings commands' secrets. It can say where to find them.
5. The module call is a fixed command with fixed parameters. No user text is put into script text.

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
2. Full keyboard use: Tab order matches reading order, arrow keys move in the grid, Enter opens details, F5 refreshes, Esc closes details.
3. Narrator and NVDA: each row reads as one sentence, for example "DevBox, Running, last maintenance succeeded 12 November, 2 findings".
4. State changes (refresh finished, error) are announced through a live-region automation event.
5. No animation. Respect the Windows "show animations" setting.
6. Tested at 200% and 400% zoom and in High Contrast, as the brand spec requires for the findings page.

## 8. Enterprise and later phases

Not in version 1. Version 1 leaves the seams for them.

- **Remote hosts**: another `VmInventory` subclass that calls the module through PowerShell remoting, so one dashboard shows several Hyper-V hosts.
- **Live numbers**: an abstract `VmMetrics` in the data layer, with a `CimVmMetrics` that reads memory use, processor load, uptime and heartbeat straight from Hyper-V's WMI namespace (`root\virtualization\v2`, `GetSummaryInformation`) through `Microsoft.Management.Infrastructure`, many VMs per call. It refreshes on its own timer, apart from F5. It reads only numbers Hyper-V owns, so it holds no LazyVM logic and cannot drift from the module. It needs the same Hyper-V rights as `Get-LazyVM`.
- **Roles**: viewer and operator, from Windows groups.
- **Central view**: an optional collector service. It would be a separate component with its own security design. It is not part of the per-user app.
- **Actions**: build, rebuild, remove and approve from the window. They need confirmation steps and `-WhatIf` support, and get their own specification.
- **Packaging**: MSIX or MSI, and policy-driven settings.

The module is per-user by design. Any multi-user mode must be an explicit, administrator-controlled opt-in, never the default.

## 9. Installing and starting it

- It ships in the same release zip as the module, and `Install.ps1` installs both.
- `Install.ps1` adds a **LazyVM Dashboard** shortcut to the installing user's own Start menu (`%APPDATA%\Microsoft\Windows\Start Menu\Programs\LazyVM`), not the all-users one. Uninstalling removes it.

### Open questions

1. Is memory shown as current use only, or with the assigned maximum?
2. Does version 1 include any action, even "Open VM connection"?
3. Should LazyVM record which config template a VM was created from, so the dashboard can name it?

## 10. Delivery plan (TDD, small pull requests)

1. This spec.
2. `Get-LazyVMDashboard` in the module, with tests, help, diagram and guide. Done.
3. `DownerBoy.LazyVM.Api`: business objects, `VmInventory`, `DashboardService` and its rules, tests against a fake inventory.
4. `PowerShellVmInventory` with mapping tests.
5. `DownerBoy.LazyVM.UI.Wpf`: theme dictionaries, window, grid, details panel, view-model tests.
6. Accessibility pass and zoom/High Contrast checks.
7. Packaging: the release zip, `Install.ps1` and the per-user Start menu shortcut.

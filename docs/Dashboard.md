<p align="center"><img src="images/logo.svg" alt="LazyVM logo" width="240"></p>

# LazyVM Dashboard — specification

Status: Draft for discussion. Tracks [#305](https://github.com/downerboy/LazyVM/issues/305). Nothing here is built yet.

## 1. Purpose

A desktop window that shows every LazyVM VM on this host in one place, so you can see at a glance which ones are healthy, which need attention and what each one holds. It reads and reports. In its first version it changes nothing in any VM.

## 2. Decisions

| Decision | Choice | Why |
|---|---|---|
| UI framework | WPF on current LTS .NET, C# | Visual Studio XAML designer, built-in `DataGrid`, UI Automation support, and a fit for data-driven dashboards. WinUI 3 has no designer or first-party `DataGrid`. |
| Pattern | MVVM, constructor injection, no code-behind logic | Testable without a window (TDD, SOLID). |
| Data source | The LazyVM PowerShell module, called from C# | The module stays the single source of truth. The GUI never reads `VM.json` or Hyper-V on its own. |
| Network | None. No listener, no web service | LazyVM is per-user. A port on the host would be reachable by other users. |
| Look | The [brand spec](Brand.md), mapped to XAML (section 6) | One look across the findings page, console and GUI. |

WinUI 3 stays possible later because the view models and data layer do not depend on WPF.

## 3. What the dashboard shows

One row per VM. Details open in a panel beside or below the list.

| Field | Source today | Gap |
|---|---|---|
| VM name | `Get-LazyVM` → `Name` | None |
| State (Running, Off, Not built…) | `Get-LazyVM` → `State` | None |
| Maintenance schedule and task registered | `Get-LazyVM` → `MaintenanceTime`, `MaintenanceTask` | None |
| Settings problem | `Get-LazyVM` → `Settings` | None |
| Last maintenance run and its result | Maintenance log | Needs a command that returns it |
| Creation date | Profile or first-build record | Needs a command that returns it |
| Attached disks (Dev Drive, SQL data, User) | Hyper-V and `VM.json` | Needs a command that returns it |
| Memory in use | Hyper-V (`Get-VM`) | Only meaningful while the VM runs; show "Off" otherwise |
| Total disk space used | Hyper-V (VHDX file size and maximum) | Needs a command that returns it |
| Template it was built from | `VM.Template.json` | Needs a command that returns it |
| Latest template ("green template") | `Shared\Templates\<VM>-latest.json` | Meaning to confirm (section 9) |
| Open security findings | `Get-LazyVMSecurityFinding` | None |

The module gains one read-only command that returns all of the above as one object per VM (working name `Get-LazyVMDashboard`), so the GUI makes one call, not many. It follows the module's own rules: help, tests, diagram and guide updates in the same pull request.

## 4. Architecture

```
Views (XAML)  →  ViewModels  →  IVmInventory  →  PowerShellVmInventory  →  LazyVM module
```

- **Views**: XAML only. Bindings and styles, no logic.
- **ViewModels**: list, sorting, selection, refresh state, error state. No reference to WPF types.
- **`IVmInventory`**: `Task<IReadOnlyList<VmSummary>> GetAllAsync(CancellationToken)`. The only seam to the outside.
- **`PowerShellVmInventory`**: runs the module command and maps its output to `VmSummary` records. A fake `IVmInventory` stands in for it in tests.
- Calls run off the UI thread and can be cancelled. A failure on one VM shows on that VM's row and does not blank the list.
- Refresh on open, on a Refresh button and on F5. No background polling in version 1.

### Projects

```
src/LazyVM.Dashboard/             WPF app (Views, App.xaml)
src/LazyVM.Dashboard.Core/        ViewModels, IVmInventory, VmSummary
tests/LazyVM.Dashboard.Tests/     xUnit, view-model and mapping tests, no UI
```

## 5. Security

1. Runs as the signed-in user and is installed to that user's profile, like the module.
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

- **Remote hosts**: another `IVmInventory` that calls the module through PowerShell remoting, so one dashboard shows several Hyper-V hosts.
- **Roles**: viewer and operator, from Windows groups.
- **Central view**: an optional collector service. It would be a separate component with its own security design. It is not part of the per-user app.
- **Actions**: build, rebuild, remove and approve from the window. They need confirmation steps and `-WhatIf` support, and get their own specification.
- **Packaging**: MSIX or MSI, and policy-driven settings.

The module is per-user by design. Any multi-user mode must be an explicit, administrator-controlled opt-in, never the default.

## 9. Open questions

1. What exactly is the "green template"? The latest template that follows the VM (`<VM>-latest.json`), or a template that has passed a check?
2. How is the GUI hosted against the module: in-process through the PowerShell SDK, or by starting `pwsh` and reading JSON? In-process is faster; out-of-process isolates crashes and module versions.
3. Where does it install and ship: in the existing release zip beside the module, or as its own download?
4. Is memory shown as current use only, or with the assigned maximum?
5. Does version 1 include any action, even "Open VM connection"?

## 10. Delivery plan (TDD, small pull requests)

1. This spec.
2. `Get-LazyVMDashboard` in the module, with tests, help, diagram and guide.
3. `Dashboard.Core`: `VmSummary`, `IVmInventory`, view models, tests against a fake.
4. `PowerShellVmInventory` with mapping tests.
5. WPF shell: theme dictionaries, window, grid, details panel.
6. Accessibility pass and zoom/High Contrast checks.
7. Packaging and release integration.

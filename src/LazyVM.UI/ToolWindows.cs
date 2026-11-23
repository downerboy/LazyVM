using LazyVM.UI.ViewModels;

namespace LazyVM.UI;

/// <summary>
/// Opens the app's windows, each with its view model: one VM window per VM;
/// one Checks window for the host and one per VM; one Log, Restore, Recovery
/// keys, Password, Security findings and build progress window per VM; and
/// one Build window. Opening one that is open brings it to the front instead.
/// The windows are tracked by a <see cref="WindowTracker"/>. It gives each
/// view model the runners, dialogs and clipboard it works with, and starts
/// the build of a VM a VM window offers, shown in its progress window. A
/// command about a VM takes its Hyper-V Id, empty for a VM not built yet, so
/// it runs in the VM's own PowerShell session.
/// </summary>
public class ToolWindows(
    Runners runners, WindowTracker windows, Dialogs dialogs, BuildStarter starter, SecretClipboard clipboard, ListChanges changes, TimeProvider clock)
{
    private const string _BUILD_KEY = "build";

    /// <summary>
    /// Starts building an existing VM, such as from the phase a failed build
    /// was in, in a pwsh process of its own, and shows its progress. Throws
    /// when it could not start.
    /// </summary>
    public virtual async Task StartBuildAsync(Guid? vmId, BuildRequest request)
    {
        var build = await starter.StartAsync(request, CancellationToken.None);
        OpenProgress(vmId, request.Name, build);
        changes.Raise();
    }

    /// <summary>
    /// Shows the VM's restore points, or brings its open window to the front,
    /// and returns the window's view model, so a refresh can reach it.
    /// </summary>
    public RestoreViewModel OpenRestore(LazyVMDashboard entry)
    {
        var key = "restore:" + entry.Name;
        if (windows.Activate<RestoreViewModel>(key) is { } open)
        {
            return open;
        }
        var restore = new RestoreViewModel(entry, runners.Restore, dialogs, changes);
        windows.Track(key, restore);
        _ = restore.LoadAsync();
        return restore;
    }

    /// <summary>
    /// Shows the VM's recovery keys, or brings its open window to the front.
    /// Closing the window forgets every password it showed.
    /// </summary>
    public RecoveryKeysViewModel OpenRecoveryKeys(LazyVMDashboard entry)
    {
        var key = "recovery-keys:" + entry.Name;
        if (windows.Activate<RecoveryKeysViewModel>(key) is { } open)
        {
            return open;
        }
        var keys = new RecoveryKeysViewModel(entry, runners.RecoveryKeys, dialogs, changes);
        windows.Track(key, keys, keys.Forget);
        _ = keys.LoadAsync();
        return keys;
    }

    /// <summary>Shows the account LazyVM signs in to the VM with, or brings its open window to the front. Closing the window forgets the password.</summary>
    public PasswordViewModel OpenPassword(LazyVMDashboard entry)
    {
        var key = "password:" + entry.Name;
        if (windows.Activate<PasswordViewModel>(key) is { } open)
        {
            return open;
        }
        var password = new PasswordViewModel(entry, runners.Credentials, clipboard);
        windows.Track(key, password, password.Forget);
        _ = password.LoadAsync();
        return password;
    }

    /// <summary>
    /// Shows the VM's security findings and approved findings, or brings its
    /// open window to the front, and returns the window's view model, so a
    /// refresh can reach it.
    /// </summary>
    public SecurityFindingsViewModel OpenSecurityFindings(LazyVMDashboard entry)
    {
        var key = "security-findings:" + entry.Name;
        if (windows.Activate<SecurityFindingsViewModel>(key) is { } open)
        {
            return open;
        }
        var findings = new SecurityFindingsViewModel(entry, runners.SecurityFindings, dialogs, changes);
        windows.Track(key, findings);
        _ = findings.LoadAsync();
        return findings;
    }

    /// <summary>Shows the checks of the VM <paramref name="vmName"/>, or of the host, and runs them.</summary>
    public void OpenChecks(Guid? vmId, string? vmName, bool hostOnly)
    {
        if (windows.Activate<ChecksViewModel>(ChecksKey(vmName)) is not null)
        {
            return;
        }
        var checks = new ChecksViewModel(runners.Checks, vmId, vmName, hostOnly);
        windows.Track(ChecksKey(vmName), checks);
        _ = checks.RunAsync();
    }

    /// <summary>Shows checks that have already run, such as the ones made when the app starts.</summary>
    public void ShowChecks(ChecksViewModel checks)
    {
        if (windows.Activate<ChecksViewModel>(ChecksKey(checks.VMName)) is null)
        {
            windows.Track(ChecksKey(checks.VMName), checks);
        }
    }

    /// <summary>Shows the VM's log and reads it.</summary>
    public void OpenLog(Guid? vmId, string vmName)
    {
        var key = "log:" + vmName;
        if (windows.Activate<LogViewModel>(key) is not null)
        {
            return;
        }
        var log = new LogViewModel(runners.Log, vmId, vmName);
        windows.Track(key, log);
        _ = log.LoadAsync();
    }

    /// <summary>Shows the Build new VM window. <paramref name="existingNames"/> are the VMs there are already.</summary>
    public void OpenBuild(IEnumerable<string> existingNames)
    {
        if (windows.Activate<BuildViewModel>(_BUILD_KEY) is not null)
        {
            return;
        }
        // A new VM has no Hyper-V Id until its build creates it.
        var build = new BuildViewModel(runners.Build, starter, existingNames, (name, started) => OpenProgress(null, name, started));
        windows.Track(_BUILD_KEY, build);
        _ = build.LoadAsync();
    }

    /// <summary>Shows the VM's window, or brings its open window to the front. A VM that is deleted closes its window.</summary>
    public void OpenVM(LazyVMDashboard entry)
    {
        var key = VMKey(entry.Name);
        if (windows.Activate<VMViewModel>(key) is not null)
        {
            return;
        }
        var viewModel = new VMViewModel(entry, this, dialogs, runners.Build, runners.Removal, changes);
        // A deleted VM has nothing left to show.
        viewModel.Deletion.Removed += (_, _) => windows.Close(viewModel);
        windows.Track(key, viewModel);
        _ = viewModel.LoadAsync();
    }

    /// <summary>Shows what a refresh read in the VM windows that are open.</summary>
    public void UpdateVMs(IEnumerable<LazyVMDashboard> entries)
    {
        foreach (var entry in entries)
        {
            windows.Find<VMViewModel>(VMKey(entry.Name))?.Update(entry);
        }
    }

    /// <summary>
    /// Shows the progress of the VM's build: of <paramref name="started"/>,
    /// the build the app has just started, or with none, of the build
    /// running now. Closing the window stops only the following.
    /// </summary>
    public void OpenProgress(Guid? vmId, string vmName, StartedRun? started)
    {
        var key = "progress:" + vmName;
        if (windows.Find<BuildProgressViewModel>(key) is { } existing)
        {
            if (started is null || !existing.IsFinished)
            {
                windows.Activate<BuildProgressViewModel>(key);
                return;
            }
            // A new build of the same VM: the window of the last one makes way for it.
            windows.Close(key);
        }
        var progress = new BuildProgressViewModel(runners.Dashboard, runners.Build, vmId, vmName, started, clock,
            phase => StartBuildAsync(vmId, new BuildRequest(vmName, null, null, phase)));
        progress.Ended += (_, _) => changes.Raise();
        windows.Track(key, progress, progress.StopFollowing);
        _ = progress.FollowAsync();
    }

    private static string ChecksKey(string? vmName)
    {
        return "checks:" + (vmName ?? string.Empty);
    }

    private static string VMKey(string vmName)
    {
        return "vm:" + vmName;
    }
}

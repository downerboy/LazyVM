using LazyVM.UI.Wpf.ViewModels;
using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Opens the Checks, Log, Build and build progress windows: one Checks window
/// for the host and one per VM, one Log window per VM, one Build window, and
/// one progress window per VM. Opening one that is open brings it to the
/// front instead. It also starts the runs a VM window offers: a build from
/// a chosen phase, shown in its progress window, and maintenance; and
/// deletes a VM, once its delete dialog has had a Yes. One Restore window
/// per VM lists its restore points, and returns the VM to one after asking.
/// </summary>
public class ToolWindows(CommandRunner runner, BuildLauncher launcher, TimeProvider clock)
{
    private const string BuildKey = "build";
    private readonly Dictionary<string, ViewModelBase> _Open = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Raised when a build followed in a progress window has ended, so the list can be read again.</summary>
    public event EventHandler? BuildEnded;

    /// <summary>Raised when a build or maintenance has started from a VM or progress window, so the list can be read again.</summary>
    public event EventHandler? RunStarted;

    /// <summary>Every phase of a build, for choosing the one a build starts at.</summary>
    public virtual Task<IReadOnlyList<BuildPhase>> GetBuildPhasesAsync(CancellationToken cancellationToken)
    {
        return runner.GetBuildPhasesAsync(cancellationToken);
    }

    /// <summary>
    /// Starts building an existing VM, such as from the phase a failed build
    /// was in, in a pwsh process of its own, and shows its progress. Throws
    /// when it could not start.
    /// </summary>
    public virtual async Task StartBuildAsync(BuildRequest request)
    {
        var moduleFolder = await runner.GetModuleFolderAsync(CancellationToken.None);
        var build = launcher.Start(request, moduleFolder);
        OpenProgress(request.Name, build);
        RunStarted?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Starts the VM's maintenance task, as the nightly run does. Throws with the reason when it did not start.</summary>
    public virtual async Task StartMaintenanceAsync(string vmName)
    {
        await runner.StartMaintenanceAsync(vmName, CancellationToken.None);
        RunStarted?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Raised when a delete has ended, even one that removed only part of the VM, so the list can be read again.</summary>
    public event EventHandler? VMRemoved;

    /// <summary>What deleting the VM would delete and keep. Throws with the reason when it cannot be deleted.</summary>
    public virtual Task<RemovalPlan> GetRemovalPlanAsync(string vmName)
    {
        return runner.GetRemovalPlanAsync(vmName, CancellationToken.None);
    }

    /// <summary>Deletes the VM, without asking: <see cref="ConfirmRemoval"/> has. Throws with what went wrong, such as what is left.</summary>
    public virtual async Task RemoveVMAsync(string vmName)
    {
        try
        {
            await runner.RemoveVMAsync(vmName);
        }
        finally
        {
            VMRemoved?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Shows what deleting the VM deletes, and asks "Do you really want to
    /// delete this VM?", in a dialog over the VM's window. True for Yes.
    /// </summary>
    public virtual bool ConfirmRemoval(RemovalViewModel removal)
    {
        var owner = Application.Current.Windows.OfType<VMWindow>()
            .FirstOrDefault(window => window.DataContext is VMViewModel vm && string.Equals(vm.Name, removal.Name, StringComparison.OrdinalIgnoreCase));
        var dialog = new RemovalWindow { DataContext = removal, Owner = owner ?? Application.Current.MainWindow };
        return dialog.ShowDialog() == true;
    }

    /// <summary>Raised when a restore has ended, even one that failed, so the list can be read again.</summary>
    public event EventHandler? ToolingRestored;

    /// <summary>The VM's restore points, oldest first.</summary>
    public virtual Task<IReadOnlyList<VMRestorePoint>> GetRestorePointsAsync(string vmName)
    {
        return runner.GetRestorePointsAsync(vmName, CancellationToken.None);
    }

    /// <summary>Returns the VM to a restore point, without asking: <see cref="ConfirmRestore"/> has. Throws with the module's reason when it did not.</summary>
    public virtual async Task RestoreToolingAsync(string vmName, string stamp)
    {
        try
        {
            await runner.RestoreToolingAsync(vmName, stamp);
        }
        finally
        {
            ToolingRestored?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Shows the VM's restore points, or brings its open window to the front,
    /// and returns the window's view model, so a refresh can reach it.
    /// </summary>
    public RestoreViewModel OpenRestore(VMDashboard entry)
    {
        var key = "restore:" + entry.Name;
        if (_Open.TryGetValue(key, out var existing) && existing is RestoreViewModel open)
        {
            BringToFront(open);
            return open;
        }
        var restore = new RestoreViewModel(entry, this);
        Track(key, restore);
        _ = restore.LoadAsync();
        return restore;
    }

    /// <summary>Asks <paramref name="question"/> with Yes and No, No the default, over the restore window. True for Yes.</summary>
    public virtual bool ConfirmRestore(RestoreViewModel restore, string question)
    {
        var dialog = new QuestionWindow
        {
            DataContext = new QuestionViewModel($"Restore {restore.Name} - LazyVM", question),
            Owner = WindowOf(restore),
        };
        return dialog.ShowDialog() == true;
    }

    /// <summary>Shows the checks of the VM <paramref name="vmName"/>, or of the host, and runs them.</summary>
    public void OpenChecks(string? vmName, bool hostOnly)
    {
        if (BringToFrontIfOpen(ChecksKey(vmName)))
        {
            return;
        }
        var checks = new ChecksViewModel(runner, vmName, hostOnly);
        Track(ChecksKey(vmName), checks);
        _ = checks.RunAsync();
    }

    /// <summary>Shows checks that have already run, such as the ones made when the app starts.</summary>
    public void ShowChecks(ChecksViewModel checks)
    {
        if (!BringToFrontIfOpen(ChecksKey(checks.VMName)))
        {
            Track(ChecksKey(checks.VMName), checks);
        }
    }

    /// <summary>Shows the VM's log and reads it.</summary>
    public void OpenLog(string vmName)
    {
        var key = "log:" + vmName;
        if (BringToFrontIfOpen(key))
        {
            return;
        }
        var log = new LogViewModel(runner, vmName);
        Track(key, log);
        _ = log.LoadAsync();
    }

    /// <summary>Shows the Build new VM window. <paramref name="existingNames"/> are the VMs there are already.</summary>
    public void OpenBuild(IEnumerable<string> existingNames)
    {
        if (BringToFrontIfOpen(BuildKey))
        {
            return;
        }
        var build = new BuildViewModel(runner, launcher, existingNames, (name, started) => OpenProgress(name, started));
        Track(BuildKey, build);
        _ = build.LoadAsync();
    }

    /// <summary>
    /// Shows the progress of the VM's build: of <paramref name="started"/>,
    /// the build the app has just started, or with none, of the build
    /// running now. Closing the window stops only the following.
    /// </summary>
    public void OpenProgress(string vmName, StartedBuild? started)
    {
        var key = "progress:" + vmName;
        if (_Open.TryGetValue(key, out var existing))
        {
            if (started is null || existing is BuildProgressViewModel { IsFinished: false })
            {
                BringToFront(existing);
                return;
            }
            // A new build of the same VM: the window of the last one makes way for it.
            _Open.Remove(key);
            CloseWindow(existing);
        }
        var progress = new BuildProgressViewModel(runner, vmName, started, clock,
            phase => StartBuildAsync(new BuildRequest(vmName, null, null, phase)));
        progress.Ended += (_, _) => BuildEnded?.Invoke(this, EventArgs.Empty);
        Track(key, progress, progress.StopFollowing);
        _ = progress.FollowAsync();
    }

    /// <summary>Shows a new window for <paramref name="viewModel"/> and calls <paramref name="closed"/> when it closes.</summary>
    protected virtual void Show(ViewModelBase viewModel, Action closed)
    {
        Window window = viewModel switch
        {
            ChecksViewModel => new ChecksWindow(),
            LogViewModel => new LogWindow(),
            BuildViewModel => new BuildWindow(),
            BuildProgressViewModel => new BuildProgressWindow(),
            RestoreViewModel => new RestoreWindow(),
            _ => throw new ArgumentException($"There is no window for {viewModel.GetType().Name}.", nameof(viewModel)),
        };
        window.DataContext = viewModel;
        window.Closed += (_, _) => closed();
        window.Show();
    }

    protected virtual void BringToFront(ViewModelBase viewModel)
    {
        var window = WindowOf(viewModel);
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
    }

    /// <summary>Closes the window of <paramref name="viewModel"/>.</summary>
    protected virtual void CloseWindow(ViewModelBase viewModel)
    {
        WindowOf(viewModel).Close();
    }

    private static Window WindowOf(ViewModelBase viewModel)
    {
        return Application.Current.Windows.OfType<Window>().First(window => window.DataContext == viewModel);
    }

    private static string ChecksKey(string? vmName)
    {
        return "checks:" + (vmName ?? string.Empty);
    }

    private bool BringToFrontIfOpen(string key)
    {
        if (!_Open.TryGetValue(key, out var existing))
        {
            return false;
        }
        BringToFront(existing);
        return true;
    }

    private void Track(string key, ViewModelBase viewModel, Action? closed = null)
    {
        _Open.Add(key, viewModel);
        Show(viewModel, () =>
        {
            // Only this window's own entry: a newer window may have taken its key.
            if (_Open.TryGetValue(key, out var current) && current == viewModel)
            {
                _Open.Remove(key);
            }
            closed?.Invoke();
        });
    }
}

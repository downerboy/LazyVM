using System.Windows;
using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Opens the Checks, Log, Build and build progress windows: one Checks window
/// for the host and one per VM, one Log window per VM, one Build window, and
/// one progress window per VM. Opening one that is open brings it to the
/// front instead.
/// </summary>
public class ToolWindows(CommandRunner runner, BuildLauncher launcher, TimeProvider clock)
{
    private const string BuildKey = "build";
    private readonly Dictionary<string, ViewModelBase> open = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Raised when a build followed in a progress window has ended, so the list can be read again.</summary>
    public event EventHandler? BuildEnded;

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
        if (open.TryGetValue(key, out var existing))
        {
            if (started is null || existing is BuildProgressViewModel { IsFinished: false })
            {
                BringToFront(existing);
                return;
            }
            // A new build of the same VM: the window of the last one makes way for it.
            open.Remove(key);
            CloseWindow(existing);
        }
        var progress = new BuildProgressViewModel(runner, vmName, started, clock);
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
    protected virtual void CloseWindow(ViewModelBase viewModel) => WindowOf(viewModel).Close();

    private static Window WindowOf(ViewModelBase viewModel) =>
        Application.Current.Windows.OfType<Window>().First(window => window.DataContext == viewModel);

    private static string ChecksKey(string? vmName) => "checks:" + (vmName ?? string.Empty);

    private bool BringToFrontIfOpen(string key)
    {
        if (!open.TryGetValue(key, out var existing))
        {
            return false;
        }
        BringToFront(existing);
        return true;
    }

    private void Track(string key, ViewModelBase viewModel, Action? closed = null)
    {
        open.Add(key, viewModel);
        Show(viewModel, () =>
        {
            // Only this window's own entry: a newer window may have taken its key.
            if (open.TryGetValue(key, out var current) && current == viewModel)
            {
                open.Remove(key);
            }
            closed?.Invoke();
        });
    }
}

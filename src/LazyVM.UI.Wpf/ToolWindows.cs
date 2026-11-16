using System.Windows;
using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Opens the Checks and Log windows: one Checks window for the host and one
/// per VM, and one Log window per VM. Opening one that is open brings it to
/// the front instead.
/// </summary>
public class ToolWindows(CommandRunner runner)
{
    private readonly Dictionary<string, ViewModelBase> open = new(StringComparer.OrdinalIgnoreCase);

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

    /// <summary>Shows a new window for <paramref name="viewModel"/> and calls <paramref name="closed"/> when it closes.</summary>
    protected virtual void Show(ViewModelBase viewModel, Action closed)
    {
        Window window = viewModel switch
        {
            ChecksViewModel => new ChecksWindow(),
            LogViewModel => new LogWindow(),
            _ => throw new ArgumentException($"There is no window for {viewModel.GetType().Name}.", nameof(viewModel)),
        };
        window.DataContext = viewModel;
        window.Closed += (_, _) => closed();
        window.Show();
    }

    protected virtual void BringToFront(ViewModelBase viewModel)
    {
        var window = Application.Current.Windows.OfType<Window>().First(window => window.DataContext == viewModel);
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
    }

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

    private void Track(string key, ViewModelBase viewModel)
    {
        open.Add(key, viewModel);
        Show(viewModel, () => open.Remove(key));
    }
}

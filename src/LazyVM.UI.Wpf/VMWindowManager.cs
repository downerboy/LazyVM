using LazyVM.UI.Wpf.ViewModels;
using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>Keeps one window per VM: opening a VM whose window is open brings that window to the front.</summary>
public class VMWindowManager(ToolWindows tools)
{
    private readonly Dictionary<string, VMViewModel> _Open = new(StringComparer.OrdinalIgnoreCase);

    public void Open(VMDashboard entry)
    {
        if (_Open.TryGetValue(entry.Name, out var existing))
        {
            BringToFront(existing);
            return;
        }
        var viewModel = new VMViewModel(entry, tools);
        _Open.Add(entry.Name, viewModel);
        // A deleted VM has nothing left to show.
        viewModel.Removed += (_, _) => CloseWindow(viewModel);
        Show(viewModel, () => _Open.Remove(entry.Name));
        _ = viewModel.LoadAsync();
    }

    /// <summary>Shows what a refresh read in the windows that are open.</summary>
    public void Update(IEnumerable<VMDashboard> entries)
    {
        foreach (var entry in entries.Where(entry => _Open.ContainsKey(entry.Name)))
        {
            _Open[entry.Name].Update(entry);
        }
    }

    /// <summary>Shows a new window for <paramref name="viewModel"/> and calls <paramref name="closed"/> when it closes.</summary>
    protected virtual void Show(VMViewModel viewModel, Action closed)
    {
        var window = new VMWindow { DataContext = viewModel };
        window.Closed += (_, _) => closed();
        window.Show();
    }

    protected virtual void BringToFront(VMViewModel viewModel)
    {
        var window = WindowOf(viewModel);
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
    }

    /// <summary>Closes the window of <paramref name="viewModel"/>.</summary>
    protected virtual void CloseWindow(VMViewModel viewModel)
    {
        WindowOf(viewModel).Close();
    }

    private static VMWindow WindowOf(VMViewModel viewModel)
    {
        return Application.Current.Windows.OfType<VMWindow>().First(window => window.DataContext == viewModel);
    }
}

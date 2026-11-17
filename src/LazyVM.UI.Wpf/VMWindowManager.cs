using System.Windows;
using LazyVM.UI.Wpf.ViewModels;

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
        Show(viewModel, () => _Open.Remove(entry.Name));
        _ = viewModel.LoadAsync();
    }

    /// <summary>Shows what a refresh read in the windows that are open.</summary>
    public void Update(IEnumerable<VMDashboard> entries)
    {
        foreach (var entry in entries)
        {
            if (_Open.TryGetValue(entry.Name, out var viewModel))
            {
                viewModel.Update(entry);
            }
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
        var window = Application.Current.Windows.OfType<VMWindow>().First(window => window.DataContext == viewModel);
        if (window.WindowState == WindowState.Minimized)
        {
            window.WindowState = WindowState.Normal;
        }
        window.Activate();
    }
}

using System.Windows;
using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>Keeps one window per VM: opening a VM whose window is open brings that window to the front.</summary>
public class VMWindowManager
{
    private readonly Dictionary<string, VMViewModel> open = new(StringComparer.OrdinalIgnoreCase);

    public void Open(VMDashboard entry)
    {
        if (open.TryGetValue(entry.Name, out var existing))
        {
            BringToFront(existing);
            return;
        }
        var viewModel = new VMViewModel(entry);
        open.Add(entry.Name, viewModel);
        Show(viewModel, () => open.Remove(entry.Name));
    }

    /// <summary>Shows what a refresh read in the windows that are open.</summary>
    public void Update(IEnumerable<VMDashboard> entries)
    {
        foreach (var entry in entries)
        {
            if (open.TryGetValue(entry.Name, out var viewModel))
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

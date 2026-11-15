using System.Collections.ObjectModel;
using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>The main window: the list of VMs, refreshing it, and opening a VM's window.</summary>
public sealed class MainViewModel : ViewModelBase
{
    private readonly CommandRunner runner;
    private readonly VMWindowManager windows;
    private readonly TimeProvider clock;
    private readonly RelayCommand refreshCommand;
    private readonly RelayCommand cancelRefreshCommand;
    private readonly RelayCommand openVMCommand;
    private CancellationTokenSource? refreshing;
    private VMRowViewModel? selectedVM;
    private string status = string.Empty;

    public MainViewModel(CommandRunner runner, VMWindowManager windows, TimeProvider clock)
    {
        this.runner = runner;
        this.windows = windows;
        this.clock = clock;
        refreshCommand = new RelayCommand(() => _ = RefreshAsync(), () => !IsRefreshing);
        cancelRefreshCommand = new RelayCommand(() => refreshing?.Cancel(), () => IsRefreshing);
        openVMCommand = new RelayCommand(OpenSelectedVM, () => SelectedVM is not null);
    }

    public ObservableCollection<VMRowViewModel> VMs { get; } = [];

    public VMRowViewModel? SelectedVM
    {
        get => selectedVM;
        set
        {
            if (SetProperty(ref selectedVM, value))
            {
                openVMCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>What the last refresh did, such as "Refreshed 3 VMs at 14:52".</summary>
    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public bool IsRefreshing => refreshing is not null;

    /// <summary>Reads every VM again (F5).</summary>
    public RelayCommand RefreshCommand => refreshCommand;

    public RelayCommand CancelRefreshCommand => cancelRefreshCommand;

    /// <summary>Opens the selected VM's window, or brings it to the front when it is open (Enter, double-click).</summary>
    public RelayCommand OpenVMCommand => openVMCommand;

    /// <summary>
    /// Reads every VM and updates the list and the open VM windows. A failure
    /// or a cancel keeps the list as it was and says so in <see cref="Status"/>.
    /// </summary>
    public async Task RefreshAsync()
    {
        if (refreshing is not null)
        {
            return;
        }
        using var cancel = new CancellationTokenSource();
        SetRefreshing(cancel);
        Status = "Refreshing";
        try
        {
            var entries = await runner.GetDashboardAsync(cancel.Token);
            ShowInList(entries);
            windows.Update(entries);
            var count = entries.Count == 1 ? "1 VM" : $"{entries.Count} VMs";
            Status = $"Refreshed {count} at {clock.GetLocalNow().ToString("t", CultureInfo.CurrentCulture)}";
        }
        catch (OperationCanceledException)
        {
            Status = "Refresh cancelled";
        }
        catch (Exception exception)
        {
            // The view shows any failure the same way; the list is kept.
            Status = "Refresh failed: " + exception.Message;
        }
        finally
        {
            SetRefreshing(null);
        }
    }

    private void SetRefreshing(CancellationTokenSource? value)
    {
        refreshing = value;
        OnPropertyChanged(nameof(IsRefreshing));
        refreshCommand.RaiseCanExecuteChanged();
        cancelRefreshCommand.RaiseCanExecuteChanged();
    }

    /// <summary>Updates the rows in place, so the selection and keyboard focus stay where they were.</summary>
    private void ShowInList(IReadOnlyList<VMDashboard> entries)
    {
        var names = entries.Select(entry => entry.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        for (var index = VMs.Count - 1; index >= 0; index--)
        {
            if (!names.Contains(VMs[index].Name))
            {
                VMs.RemoveAt(index);
            }
        }

        for (var index = 0; index < entries.Count; index++)
        {
            var entry = entries[index];
            var row = VMs.FirstOrDefault(row => string.Equals(row.Name, entry.Name, StringComparison.OrdinalIgnoreCase));
            if (row is null)
            {
                VMs.Insert(index, new VMRowViewModel(entry));
                continue;
            }
            row.Update(entry);
            var current = VMs.IndexOf(row);
            if (current != index)
            {
                VMs.Move(current, index);
            }
        }
    }

    private void OpenSelectedVM()
    {
        if (SelectedVM is { } row)
        {
            windows.Open(row.Entry);
        }
    }
}

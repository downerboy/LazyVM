using System.Collections.ObjectModel;
using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>The main window: the list of VMs, refreshing it, and opening a VM's window.</summary>
public sealed class MainViewModel : ViewModelBase
{
    private readonly PowerShellCommandRunner _Runner;
    private readonly VMWindowManager _Windows;
    private readonly ToolWindows _Tools;
    private readonly TimeProvider _Clock;
    private readonly RelayCommand _RefreshCommand;
    private readonly RelayCommand _CancelRefreshCommand;
    private readonly RelayCommand _OpenVMCommand;
    private readonly RelayCommand _BuildProgressCommand;
    private CancellationTokenSource? _Refreshing;
    private VMRowViewModel? _SelectedVM;
    private string _Status = string.Empty;
    private bool _ListIsKnown;

    public MainViewModel(PowerShellCommandRunner runner, VMWindowManager windows, ToolWindows tools, TimeProvider clock)
    {
        _Runner = runner;
        _Windows = windows;
        _Tools = tools;
        _Clock = clock;
        HostChecksCommand = new RelayCommand(() => tools.OpenChecks(null, HostOnly()));
        BuildCommand = new RelayCommand(() => tools.OpenBuild(VMs.Select(row => row.Name).ToList()));
        // A build that ended, a build or maintenance that started, a delete, a restore or an export of recovery keys changed the list: read it again.
        tools.BuildEnded += (_, _) => _ = RefreshAsync();
        tools.RunStarted += (_, _) => _ = RefreshAsync();
        tools.VMRemoved += (_, _) => _ = RefreshAsync();
        tools.ToolingRestored += (_, _) => _ = RefreshAsync();
        tools.RecoveryKeysExported += (_, _) => _ = RefreshAsync();
        tools.SecurityFindingsChanged += (_, _) => _ = RefreshAsync();
        _RefreshCommand = new RelayCommand(() => _ = RefreshAsync(), () => !IsRefreshing);
        _CancelRefreshCommand = new RelayCommand(() => _Refreshing?.Cancel(), () => IsRefreshing);
        _OpenVMCommand = new RelayCommand(OpenSelectedVM, () => SelectedVM is not null);
        _BuildProgressCommand = new RelayCommand(() => tools.OpenProgress(SelectedVM!.Name, started: null), () => SelectedVMIsBuilding);
    }

    public ObservableCollection<VMRowViewModel> VMs { get; } = [];

    public VMRowViewModel? SelectedVM
    {
        get => _SelectedVM;
        set
        {
            if (SetProperty(ref _SelectedVM, value))
            {
                _OpenVMCommand.RaiseCanExecuteChanged();
                SelectedVMChanged();
            }
        }
    }

    /// <summary>What the last refresh did, such as "Refreshed 3 VMs at 14:52".</summary>
    public string Status
    {
        get => _Status;
        private set => SetProperty(ref _Status, value);
    }

    public bool IsRefreshing => _Refreshing is not null;

    /// <summary>Reads every VM again (F5).</summary>
    public RelayCommand RefreshCommand => _RefreshCommand;

    public RelayCommand CancelRefreshCommand => _CancelRefreshCommand;

    /// <summary>True while a build of the selected VM runs, so its progress window can be opened again from the list.</summary>
    public bool SelectedVMIsBuilding => SelectedVM is { IsBuilding: true };

    /// <summary>Opens the progress window of the selected VM's build, or brings it to the front when it is open.</summary>
    public RelayCommand BuildProgressCommand => _BuildProgressCommand;

    /// <summary>Opens the selected VM's window, or brings it to the front when it is open (Enter, double-click).</summary>
    public RelayCommand OpenVMCommand => _OpenVMCommand;

    /// <summary>Opens the checks of this host (Test-LazyVM).</summary>
    public RelayCommand HostChecksCommand
    {
        get;
    }

    /// <summary>Opens the Build new VM window.</summary>
    public RelayCommand BuildCommand
    {
        get;
    }

    /// <summary>
    /// Reads the list, then checks the host. The checks show by themselves
    /// only when they are needed: before the first VM, when a host check
    /// failed, or when the checks could not run.
    /// </summary>
    public async Task StartAsync()
    {
        await RefreshAsync();
        var checks = new ChecksViewModel(_Runner, null, HostOnly());
        await checks.RunAsync();
        if (NoVMs() || checks.HasFailures || checks.CouldNotRun)
        {
            _Tools.ShowChecks(checks);
        }
    }

    /// <summary>True only once a refresh has found no VMs; a failed refresh says nothing about them.</summary>
    private bool NoVMs()
    {
        return _ListIsKnown && VMs.Count == 0;
    }

    /// <summary>
    /// The host alone, unless there are no VMs: then Test-LazyVM adds a
    /// note that there are none yet, saying how to make the first.
    /// </summary>
    private bool HostOnly()
    {
        return !NoVMs();
    }

    /// <summary>
    /// Reads every VM and updates the list and the open VM windows. A failure
    /// or a cancel keeps the list as it was and says so in <see cref="Status"/>.
    /// </summary>
    public async Task RefreshAsync()
    {
        if (_Refreshing is not null)
        {
            return;
        }
        using var cancel = new CancellationTokenSource();
        SetRefreshing(cancel);
        Status = "Refreshing";
        _ListIsKnown = false;
        try
        {
            var entries = await WorkAsync("Reading your VMs", () => _Runner.GetLazyVMDashboardAsync(cancel.Token));
            ShowInList(entries);
            // The selected VM may have started or stopped building.
            SelectedVMChanged();
            _ListIsKnown = true;
            _Windows.Update(entries);
            var count = entries.Count == 1 ? "1 VM" : $"{entries.Count} VMs";
            Status = $"Refreshed {count} at {_Clock.GetLocalNow().ToString("t", CultureInfo.CurrentCulture)}";
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
        _Refreshing = value;
        OnPropertyChanged(nameof(IsRefreshing));
        _RefreshCommand.RaiseCanExecuteChanged();
        _CancelRefreshCommand.RaiseCanExecuteChanged();
    }

    /// <summary>Updates the rows in place, so the selection and keyboard focus stay where they were.</summary>
    private void ShowInList(IReadOnlyList<LazyVMDashboard> entries)
    {
        var names = entries.Select(entry => entry.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var gone in VMs.Where(row => !names.Contains(row.Name)).ToList())
        {
            VMs.Remove(gone);
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

    private void SelectedVMChanged()
    {
        OnPropertyChanged(nameof(SelectedVMIsBuilding));
        _BuildProgressCommand.RaiseCanExecuteChanged();
    }

    private void OpenSelectedVM()
    {
        if (SelectedVM is { } row)
        {
            _Windows.Open(row.Entry);
        }
    }
}

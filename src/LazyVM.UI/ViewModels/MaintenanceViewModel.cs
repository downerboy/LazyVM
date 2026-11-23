namespace LazyVM.UI.ViewModels;

/// <summary>Running a VM's maintenance now, in its window, by starting its maintenance task as the nightly run does.</summary>
public sealed class MaintenanceViewModel : VMPartViewModel
{
    private const string _NOT_SCHEDULED = "Not registered";

    private readonly LazyVMBuildRunner _Builds;
    private readonly ListChanges _Changes;

    public MaintenanceViewModel(VMRunGate gate, LazyVMBuildRunner builds, ListChanges changes)
        : base(gate)
    {
        _Builds = builds;
        _Changes = changes;
        RunCommand = new RelayCommand(() => _ = RunAsync(), () => Gate.CanStart && IsScheduled);
    }

    /// <summary>Starts the VM's maintenance task, so maintenance runs as the nightly run does.</summary>
    public RelayCommand RunCommand
    {
        get;
    }

    /// <summary>False only when the dashboard says the maintenance task is not registered.</summary>
    public bool IsScheduled => Gate.Entry.MaintenanceTask != _NOT_SCHEDULED;

    /// <summary>
    /// What running maintenance now does, including the rearm or rebuild it
    /// may do near the end of the evaluation. The window shows it and gives
    /// it to Run maintenance now as its help text, so Narrator reads the same.
    /// </summary>
    public string Help => "Runs the VM's nightly maintenance now: it records what changed in the VM, backs up its databases, installs updates and scans it for security problems. Near the end of the evaluation it also rearms Windows and restarts the VM, or, with no rearms left, rebuilds it.";

    /// <summary>Why maintenance cannot run, and how to schedule it, when its task is not registered; empty otherwise.</summary>
    public string Note => IsScheduled
        ? string.Empty
        : $"Maintenance of {Name} is not scheduled, so it cannot run now. In PowerShell, run Register-LazyVMMaintenance -Name {Name}";

    /// <summary>Starts the VM's maintenance task, as the nightly run does.</summary>
    public async Task RunAsync()
    {
        if (!Gate.CanStart || !IsScheduled)
        {
            return;
        }
        Gate.IsStarting = true;
        Status = $"Starting the maintenance of {Name}";
        try
        {
            await WorkAsync("Starting the maintenance", StartAsync);
            Status = $"The maintenance of {Name} has started, as its nightly run does. Running now shows it once it has begun, and the Log says how it goes.";
        }
        catch (Exception exception)
        {
            Status = "Maintenance did not start: " + exception.Message;
        }
        finally
        {
            Gate.IsStarting = false;
        }
    }

    protected override void GateChanged()
    {
        RunCommand.RaiseCanExecuteChanged();
        base.GateChanged();
    }

    /// <summary>Starts the maintenance task, then tells the list, so it shows the run once it has begun.</summary>
    private async Task StartAsync()
    {
        await _Builds.StartLazyVMMaintenanceAsync(Gate.Entry.Id, Name, CancellationToken.None);
        _Changes.Raise();
    }
}

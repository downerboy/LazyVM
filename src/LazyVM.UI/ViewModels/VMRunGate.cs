namespace LazyVM.UI.ViewModels;

/// <summary>
/// The VM as last read, and whether a run of it can start: none starts while
/// another run of the VM is going, or while its window is starting a build
/// or maintenance or deleting it. The parts of the VM's window share one, so
/// every button that starts a run follows the same rule.
/// </summary>
public sealed class VMRunGate(LazyVMDashboard entry)
{
    private bool _IsStarting;
    private bool _IsDeleting;

    /// <summary>Raised when the VM has been read again, and when a run of it starts or ends here.</summary>
    public event EventHandler? Changed;

    /// <summary>The VM as the last refresh read it.</summary>
    public LazyVMDashboard Entry
    {
        get; private set;
    } = entry;

    /// <summary>True while a build, maintenance, rebuild, delete or restore of the VM is running.</summary>
    public bool IsBusy => Entry.Run is { IsRunning: true };

    /// <summary>What is running now, such as "A build"; empty when nothing is.</summary>
    public string RunningName => IsBusy ? DashboardText.RunName(Entry.Run!.Command) : string.Empty;

    /// <summary>True while a build or maintenance the window asked for is starting.</summary>
    public bool IsStarting
    {
        get => _IsStarting;
        set
        {
            if (_IsStarting != value)
            {
                _IsStarting = value;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// <summary>True from reading what a delete would delete until the delete has ended.</summary>
    public bool IsDeleting
    {
        get => _IsDeleting;
        set
        {
            if (_IsDeleting != value)
            {
                _IsDeleting = value;
                Changed?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// <summary>True when a build, maintenance or delete may start.</summary>
    public bool CanStart => !IsBusy && !IsStarting && !IsDeleting;

    /// <summary>Takes what a newer refresh read for the VM.</summary>
    public void Update(LazyVMDashboard entry)
    {
        Entry = entry;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}

namespace LazyVM.UI.ViewModels;

/// <summary>
/// A part of a VM's window that starts a run of the VM, such as a build or a
/// delete. Every part of the window shares one <see cref="VMRunGate"/>, so
/// no run starts while another is going, and the window shows the latest
/// <see cref="Status"/> of any part in one status line.
/// </summary>
public abstract class VMPartViewModel : ViewModelBase
{
    private string _Status = string.Empty;

    protected VMPartViewModel(VMRunGate gate)
    {
        Gate = gate;
        gate.Changed += (_, _) => GateChanged();
    }

    public string Name => Gate.Entry.Name;

    /// <summary>
    /// What happened when this part's run was asked for, such as why it did
    /// not start. It is raised each time it is set, even to the same text, so
    /// the window always shows the latest of any part.
    /// </summary>
    public string Status
    {
        get => _Status;
        protected set
        {
            _Status = value;
            OnPropertyChanged();
        }
    }

    protected VMRunGate Gate
    {
        get;
    }

    /// <summary>Called when the VM has been read again, or a run of it starts or ends here: anything the part shows may have changed.</summary>
    protected virtual void GateChanged()
    {
        OnPropertyChanged(string.Empty);
    }
}

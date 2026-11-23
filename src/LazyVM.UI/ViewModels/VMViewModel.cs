namespace LazyVM.UI.ViewModels;

/// <summary>
/// A VM's own window: every detail the dashboard has about it, the windows
/// it opens, such as its checks and log, and its parts that start a run:
/// <see cref="BuildFromPhase"/>, <see cref="Maintenance"/> and
/// <see cref="Deletion"/>. They share one <see cref="VMRunGate"/>, so none
/// starts while another run of the VM is going, and the window shows their
/// work in one progress bar and the latest of their statuses in one line.
/// </summary>
public sealed class VMViewModel : ViewModelBase
{
    private readonly VMRunGate _Gate;
    private string _Status = string.Empty;
    private RestoreViewModel? _Restore;
    private SecurityFindingsViewModel? _Findings;

    public VMViewModel(LazyVMDashboard entry, ToolWindows tools, Dialogs dialogs, LazyVMBuildRunner builds, LazyVMRemovalRunner removals, ListChanges changes)
    {
        _Gate = new VMRunGate(entry);
        BuildFromPhase = new BuildFromPhaseViewModel(_Gate, builds, tools);
        Maintenance = new MaintenanceViewModel(_Gate, builds, changes);
        Deletion = new VMDeletionViewModel(_Gate, removals, dialogs, changes);
        Hold(BuildFromPhase);
        Hold(Maintenance);
        Hold(Deletion);
        Details = VMDetails.Read(entry);
        ChecksCommand = new RelayCommand(() => tools.OpenChecks(Entry.Id, Name, hostOnly: false));
        LogCommand = new RelayCommand(() => tools.OpenLog(Entry.Id, Name));
        BuildProgressCommand = new RelayCommand(() => tools.OpenProgress(Entry.Id, Name, started: null), () => IsBuilding);
        RestorePointsCommand = new RelayCommand(() => _Restore = tools.OpenRestore(Entry));
        RecoveryKeysCommand = new RelayCommand(() => tools.OpenRecoveryKeys(Entry));
        PasswordCommand = new RelayCommand(() => tools.OpenPassword(Entry));
        SecurityFindingsCommand = new RelayCommand(() => _Findings = tools.OpenSecurityFindings(Entry));
    }

    /// <summary>Building the VM again from a chosen phase.</summary>
    public BuildFromPhaseViewModel BuildFromPhase
    {
        get;
    }

    /// <summary>Running the VM's maintenance now.</summary>
    public MaintenanceViewModel Maintenance
    {
        get;
    }

    /// <summary>Deleting the VM, after showing what goes.</summary>
    public VMDeletionViewModel Deletion
    {
        get;
    }

    private LazyVMDashboard Entry => _Gate.Entry;

    /// <summary>Opens what the VM's last security scan found, and the findings approved.</summary>
    public RelayCommand SecurityFindingsCommand
    {
        get;
    }

    /// <summary>Opens the account LazyVM signs in to the VM with, its password hidden until asked for.</summary>
    public RelayCommand PasswordCommand
    {
        get;
    }

    /// <summary>Opens the VM's recovery keys, to see one or export them.</summary>
    public RelayCommand RecoveryKeysCommand
    {
        get;
    }

    /// <summary>How many recovery passwords are not exported yet, with what to do; empty when none, or when that is not known.</summary>
    public string RecoveryKeyNotice => Entry.UnexportedRecoveryKeys switch
    {
        null or <= 0 => string.Empty,
        1 => $"1 BitLocker recovery password of {Name} is not exported yet. Keep a copy offline, such as on a USB drive: choose Recovery keys.",
        var count => $"{count} BitLocker recovery passwords of {Name} are not exported yet. Keep a copy offline, such as on a USB drive: choose Recovery keys.",
    };

    public bool HasRecoveryKeyNotice => RecoveryKeyNotice.Length > 0;

    /// <summary>Opens the VM's restore points, to return it to one. Always available: the Restore window itself says when a restore cannot start.</summary>
    public RelayCommand RestorePointsCommand
    {
        get;
    }

    /// <summary>True while a build of the VM is running.</summary>
    public bool IsBuilding => Entry.IsBuilding;

    /// <summary>True while a build, maintenance, rebuild, delete or restore of the VM is running: no other may start.</summary>
    public bool IsBusy => _Gate.IsBusy;

    /// <summary>Opens the progress of the build running now, including one the app did not start.</summary>
    public RelayCommand BuildProgressCommand
    {
        get;
    }

    /// <summary>
    /// Why a run cannot start now, or which phase is chosen and why, as text
    /// on the window: a disabled button cannot take focus, so a screen reader
    /// would never read a reason given only on it.
    /// </summary>
    public string RunNote => IsBusy
        ? $"{_Gate.RunningName} of {Name} is running now. A build or maintenance can start once it has ended."
        : string.Join(" ", new[] { BuildFromPhase.SuggestionNote, Maintenance.Note }.Where(text => text.Length > 0));

    public bool HasRunNote => RunNote.Length > 0;

    /// <summary>What happened when a build, maintenance or delete was last asked for, such as why it did not start.</summary>
    public string Status
    {
        get => _Status;
        private set
        {
            if (SetProperty(ref _Status, value))
            {
                OnPropertyChanged(nameof(HasStatus));
            }
        }
    }

    public bool HasStatus => Status.Length > 0;

    /// <summary>Reads the build's phases to choose from, and chooses the one to carry on from.</summary>
    public Task LoadAsync()
    {
        return BuildFromPhase.LoadAsync();
    }

    /// <summary>Shows the work of <paramref name="part"/> in the window's progress bar, and its status in the window's status line.</summary>
    private void Hold(VMPartViewModel part)
    {
        Include(part);
        part.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(VMPartViewModel.Status))
            {
                Status = part.Status;
            }
        };
    }

    /// <summary>Opens the VM's checks (Test-LazyVM).</summary>
    public RelayCommand ChecksCommand
    {
        get;
    }

    /// <summary>Opens the VM's log.</summary>
    public RelayCommand LogCommand
    {
        get;
    }

    public string Name => Entry.Name;

    public string Title => $"{Entry.Name} - LazyVM";

    public string State => Entry.State;

    /// <summary>The details, in the order the window shows them.</summary>
    public IReadOnlyList<VMDetail> Details
    {
        get; private set;
    }

    /// <summary>Shows what a newer refresh read for this VM, in the window and each of its parts.</summary>
    public void Update(LazyVMDashboard entry)
    {
        _Gate.Update(entry);
        Details = VMDetails.Read(entry);
        OnPropertyChanged(string.Empty);
        BuildProgressCommand.RaiseCanExecuteChanged();
        // Its Restore window, if it has opened one, follows the runs too; one since closed just keeps it.
        _Restore?.Update(entry);
        // So does its Security findings window, reading the findings again after a newer scan.
        _ = _Findings?.Update(entry);
    }
}

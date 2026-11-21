namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// A VM's own window: every detail the dashboard has about it, its checks
/// and log, the runs it can start: a build from a chosen phase, and
/// maintenance now, and deleting it, after showing what goes. None starts
/// while another run of the VM is going.
/// </summary>
public sealed class VMViewModel : ViewModelBase
{
    private const string _MAINTENANCE_NOT_SCHEDULED = "Not registered";
    private const string _MAINTENANCE_HELP = "Runs the VM's nightly maintenance now: it records what changed in the VM, backs up its databases, installs updates and scans it for security problems. Near the end of the evaluation it also rearms Windows and restarts the VM, or, with no rearms left, rebuilds it.";

    private readonly ToolWindows _Tools;
    private LazyVMDashboard _Entry;
    private IReadOnlyList<PhaseOption> _Phases = [];
    private PhaseOption? _SelectedPhase;
    private int? _SuggestedPhase;
    private string _Status = string.Empty;
    private bool _IsStarting;
    private bool _IsDeleting;
    private RestoreViewModel? _Restore;
    private SecurityFindingsViewModel? _Findings;

    public VMViewModel(LazyVMDashboard entry, ToolWindows tools)
    {
        _Entry = entry;
        _Tools = tools;
        Details = ReadDetails(entry);
        _SuggestedPhase = CarryOnPhase(entry.LastBuild);
        ChecksCommand = new RelayCommand(() => tools.OpenChecks(Name, hostOnly: false));
        LogCommand = new RelayCommand(() => tools.OpenLog(Name));
        BuildProgressCommand = new RelayCommand(() => tools.OpenProgress(Name, started: null), () => IsBuilding);
        BuildFromPhaseCommand = new RelayCommand(() => _ = BuildFromPhaseAsync(), () => CanStart && SelectedPhase is not null);
        MaintenanceCommand = new RelayCommand(() => _ = RunMaintenanceAsync(), () => CanStart && IsMaintenanceScheduled);
        DeleteCommand = new RelayCommand(() => _ = DeleteAsync(), () => CanStart);
        RestorePointsCommand = new RelayCommand(() => _Restore = tools.OpenRestore(_Entry));
        RecoveryKeysCommand = new RelayCommand(() => tools.OpenRecoveryKeys(_Entry));
        PasswordCommand = new RelayCommand(() => tools.OpenPassword(_Entry));
        SecurityFindingsCommand = new RelayCommand(() => _Findings = tools.OpenSecurityFindings(_Entry));
    }

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
    public string RecoveryKeyNotice => _Entry.UnexportedRecoveryKeys switch
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

    /// <summary>Raised when the VM has been deleted, so its window closes.</summary>
    public event EventHandler? Removed;

    /// <summary>Shows what deleting the VM deletes, asks, and on Yes deletes it.</summary>
    public RelayCommand DeleteCommand
    {
        get;
    }

    /// <summary>True from reading what a delete would delete until the delete has ended.</summary>
    public bool IsDeleting
    {
        get => _IsDeleting;
        private set
        {
            if (SetProperty(ref _IsDeleting, value))
            {
                RaiseRunCommandsChanged();
            }
        }
    }

    /// <summary>Why Delete is disabled, as text of its own beside it; empty when it is not.</summary>
    public string DeleteNote => IsBusy
        ? $"{RunName(_Entry.Run!.Command)} of {Name} is running now, so {Name} cannot be deleted until it has ended."
        : string.Empty;

    public bool HasDeleteNote => DeleteNote.Length > 0;

    private bool CanStart => !IsBusy && !IsStarting && !IsDeleting;

    /// <summary>Opens the progress of the build running now, including one the app did not start.</summary>
    public RelayCommand BuildProgressCommand
    {
        get;
    }

    /// <summary>Builds the VM from <see cref="SelectedPhase"/>, in a pwsh process of its own, and shows its progress.</summary>
    public RelayCommand BuildFromPhaseCommand
    {
        get;
    }

    /// <summary>Starts the VM's maintenance task, so maintenance runs as the nightly run does.</summary>
    public RelayCommand MaintenanceCommand
    {
        get;
    }

    /// <summary>True while a build of the VM is running.</summary>
    public bool IsBuilding => _Entry.IsBuilding;

    /// <summary>True while a build, maintenance or rebuild of the VM is running: no other may start.</summary>
    public bool IsBusy => _Entry.Run is { IsRunning: true };

    /// <summary>False only when the dashboard says the maintenance task is not registered.</summary>
    public bool IsMaintenanceScheduled => _Entry.MaintenanceTask != _MAINTENANCE_NOT_SCHEDULED;

    /// <summary>True while a build or maintenance this window asked for is starting.</summary>
    public bool IsStarting
    {
        get => _IsStarting;
        private set
        {
            if (SetProperty(ref _IsStarting, value))
            {
                RaiseRunCommandsChanged();
            }
        }
    }

    /// <summary>Every phase of a build, to choose the one it starts at.</summary>
    public IReadOnlyList<PhaseOption> Phases
    {
        get => _Phases;
        private set => SetProperty(ref _Phases, value);
    }

    /// <summary>The phase a build starts at: the one the last build stopped or failed in, or else the first.</summary>
    public PhaseOption? SelectedPhase
    {
        get => _SelectedPhase;
        set
        {
            if (SetProperty(ref _SelectedPhase, value))
            {
                BuildFromPhaseCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(PhaseHelp));
                OnPropertyChanged(nameof(HasPhaseHelp));
                OnPropertyChanged(nameof(BuildFromPhaseHelp));
            }
        }
    }

    /// <summary>
    /// Build from this phase's help text: <see cref="PhaseHelp"/> for the
    /// phase chosen, then how the build runs. Focus moves from the phase list
    /// to the button, and Narrator reads the button's help, not the list's,
    /// so the button says what the chosen phase does too.
    /// </summary>
    public string BuildFromPhaseHelp => string.Join(" ",
        new[] { PhaseHelp, "Starts the build in its own process, and shows its progress. Closing the app does not stop it." }.Where(text => text.Length > 0));

    /// <summary>
    /// What building from <see cref="SelectedPhase"/> skips, what it runs
    /// again and what it keeps, and when to use it; empty when no phase is
    /// chosen. The window shows it and gives it to the phase list as its
    /// help text, so Narrator reads the same.
    /// </summary>
    public string PhaseHelp
    {
        get
        {
            if (SelectedPhase is not { } chosen)
            {
                return string.Empty;
            }
            var number = chosen.Number;
            var runs = number == Phases[0].Number
                ? "Runs every phase again"
                : number == Phases[^1].Number
                    ? $"Skips the phases before phase {number}, then runs only phase {number} again"
                    : $"Skips the phases before phase {number}, then runs phase {number} and those after it again";
            return runs + ", skipping work already done: the VM, its disks and what is installed are kept. Use it after fixing what stopped a build, from the phase it stopped in.";
        }
    }

    public bool HasPhaseHelp => PhaseHelp.Length > 0;

    /// <summary>
    /// What running maintenance now does, including the rearm or rebuild it
    /// may do near the end of the evaluation. The window shows it and gives
    /// it to Run maintenance now as its help text, so Narrator reads the same.
    /// </summary>
    public string MaintenanceHelp => _MAINTENANCE_HELP;

    /// <summary>
    /// What deleting the VM takes with it, including the work on its Dev
    /// Drive and User disk, and what is kept. The window shows it and gives
    /// it to Delete as its help text, so Narrator reads the same. The
    /// template is named only when the VM has one.
    /// </summary>
    public string DeleteHelp => string.Join(" ", new[]
    {
        $"Deletes {Name} and everything LazyVM made for it: its disks, tasks and folder.",
        @"That includes the Dev Drive, with any code not yet pushed, and the User disk, with Documents, Desktop, Downloads, .ssh and source\repos, so push or copy your work first.",
        "It cannot be undone.",
        string.IsNullOrEmpty(_Entry.GreenTemplate) ? string.Empty : $"Its template, {_Entry.GreenTemplate}, is kept, to build a matching VM from later.",
        "A list of what goes comes first, and you are asked before anything is deleted.",
    }.Where(text => text.Length > 0));

    /// <summary>
    /// Why a run cannot start now, or which phase is chosen and why, as text
    /// on the window: a disabled button cannot take focus, so a screen reader
    /// would never read a reason given only on it.
    /// </summary>
    public string RunNote
    {
        get
        {
            if (IsBusy)
            {
                return $"{RunName(_Entry.Run!.Command)} of {Name} is running now. A build or maintenance can start once it has ended.";
            }
            var notes = new[]
            {
                _SuggestedPhase is { } phase && _Entry.LastBuild is { } last
                    ? $"The last build {EndedText(last.Status)} in phase {phase}, so phase {phase} is chosen. Let any install still running inside the VM finish first."
                    : null,
                IsMaintenanceScheduled
                    ? null
                    : $"Maintenance of {Name} is not scheduled, so it cannot run now. In PowerShell, run Register-LazyVMMaintenance -Name {Name}",
            }.OfType<string>();
            return string.Join(" ", notes);
        }
    }

    public bool HasRunNote => RunNote.Length > 0;

    /// <summary>What happened when a build or maintenance was asked for, such as why it did not start.</summary>
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
    public async Task LoadAsync()
    {
        try
        {
            var found = await WorkAsync("Reading the build phases", () => _Tools.GetBuildPhasesAsync(CancellationToken.None));
            Phases = found.Select(phase => new PhaseOption(phase)).ToList();
            SelectSuggestedPhase();
        }
        catch (Exception exception)
        {
            Status = "The build phases could not be read, so a build cannot start here: " + exception.Message;
        }
    }

    /// <summary>Builds the VM from the chosen phase, and shows the build's progress.</summary>
    public async Task BuildFromPhaseAsync()
    {
        if (!CanStart || SelectedPhase is not { } phase)
        {
            return;
        }
        IsStarting = true;
        Status = $"Starting the build of {Name} from phase {phase.Number}";
        try
        {
            await WorkAsync($"Starting the build from phase {phase.Number}", () => _Tools.StartBuildAsync(new BuildRequest(Name, null, null, phase.Number)));
            Status = $"The build of {Name} has started from phase {phase.Number}. Its progress is in its own window.";
        }
        catch (Exception exception)
        {
            Status = "The build could not start: " + exception.Message;
        }
        finally
        {
            IsStarting = false;
        }
    }

    /// <summary>Starts the VM's maintenance task, as the nightly run does.</summary>
    public async Task RunMaintenanceAsync()
    {
        if (!CanStart || !IsMaintenanceScheduled)
        {
            return;
        }
        IsStarting = true;
        Status = $"Starting the maintenance of {Name}";
        try
        {
            await WorkAsync("Starting the maintenance", () => _Tools.StartMaintenanceAsync(Name));
            Status = $"The maintenance of {Name} has started, as its nightly run does. Running now shows it once it has begun, and the Log says how it goes.";
        }
        catch (Exception exception)
        {
            Status = "Maintenance did not start: " + exception.Message;
        }
        finally
        {
            IsStarting = false;
        }
    }

    /// <summary>
    /// Shows what deleting the VM deletes and asks; on Yes, deletes it with
    /// Remove-LazyVM -Force. A delete that did not finish says why, as the
    /// module reports it, and what is still there.
    /// </summary>
    public async Task DeleteAsync()
    {
        if (!CanStart)
        {
            return;
        }
        IsDeleting = true;
        Status = $"Reading what deleting {Name} would delete";
        try
        {
            RemovalPlan plan;
            try
            {
                plan = await WorkAsync("Reading what deleting the VM removes", () => _Tools.GetRemovalPlanAsync(Name));
            }
            catch (Exception exception)
            {
                Status = $"{Name} cannot be deleted now: {exception.Message}";
                return;
            }
            if (!_Tools.ConfirmRemoval(new RemovalViewModel(plan)))
            {
                Status = $"{Name} was not deleted.";
                return;
            }
            Status = $"Deleting {Name}";
            try
            {
                await WorkAsync($"Deleting {Name}", () => _Tools.RemoveVMAsync(Name));
            }
            catch (Exception exception)
            {
                var left = await LeftAsync();
                Status = string.Join(" ", new[] { $"Deleting {Name} did not finish: {exception.Message}", left }.Where(text => text.Length > 0));
                return;
            }
            Status = $"{Name} has been deleted.";
            Removed?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            IsDeleting = false;
        }
    }

    /// <summary>What a delete that did not finish left, read again; empty when that cannot be read, such as once the VM's settings are gone.</summary>
    private async Task<string> LeftAsync()
    {
        try
        {
            return RemovalViewModel.Left(await WorkAsync("Checking what is left of the VM", () => _Tools.GetRemovalPlanAsync(Name)));
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }

    /// <summary>The phase a build that stopped, failed or ended unexpectedly can carry on from; empty otherwise.</summary>
    internal static int? CarryOnPhase(VMRun? lastBuild)
    {
        return lastBuild is { Status: VMRun.FAILED or VMRun.STOPPED or VMRun.ENDED_UNEXPECTEDLY }
            ? lastBuild.UnfinishedPhase ?? lastBuild.Phase
            : null;
    }

    private void SelectSuggestedPhase()
    {
        SelectedPhase = Phases.FirstOrDefault(option => option.Number == _SuggestedPhase) ?? Phases.FirstOrDefault();
    }

    private void RaiseRunCommandsChanged()
    {
        BuildFromPhaseCommand.RaiseCanExecuteChanged();
        MaintenanceCommand.RaiseCanExecuteChanged();
        DeleteCommand.RaiseCanExecuteChanged();
    }

    private static string RunName(string? command)
    {
        return DashboardText.RunName(command);
    }

    private static string EndedText(string? status)
    {
        return status switch
        {
            VMRun.STOPPED => "stopped",
            VMRun.ENDED_UNEXPECTEDLY => "ended unexpectedly",
            _ => "failed",
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

    public string Name => _Entry.Name;

    public string Title => $"{_Entry.Name} - LazyVM";

    public string State => _Entry.State;

    /// <summary>The details, in the order the window shows them.</summary>
    public IReadOnlyList<VMDetail> Details
    {
        get; private set;
    }

    /// <summary>Shows what a newer refresh read for this VM.</summary>
    public void Update(LazyVMDashboard entry)
    {
        _Entry = entry;
        Details = ReadDetails(entry);
        // A build that has failed or stopped since: choose the phase to carry on from, as on opening.
        var suggested = CarryOnPhase(entry.LastBuild);
        if (suggested != _SuggestedPhase)
        {
            _SuggestedPhase = suggested;
            SelectSuggestedPhase();
        }
        OnPropertyChanged(string.Empty);
        BuildProgressCommand.RaiseCanExecuteChanged();
        RaiseRunCommandsChanged();
        // Its Restore window, if it has opened one, follows the runs too; one since closed just keeps it.
        _Restore?.Update(entry);
        // So does its Security findings window, reading the findings again after a newer scan.
        _ = _Findings?.Update(entry);
    }

    /// <summary>Memory in use against the most the VM can use, for example "6 GB of 16 GB" (#420).</summary>
    private static string MemoryText(LazyVMDashboard vm, string missing)
    {
        var inUse = vm.MemoryAssigned switch
        {
            null => missing,
            0 => "None",
            { } bytes => DashboardText.Size(bytes),
        };
        return vm.MemoryAssigned is not null && vm.MemoryMaximum is { } maximum
            ? $"{inUse} of {DashboardText.Size(maximum)}"
            : inUse;
    }

    private static List<VMDetail> ReadDetails(LazyVMDashboard vm)
    {
        // Hyper-V has nothing to say about a VM that is not built yet; say why.
        var missing = vm.State == "Not built" ? "Not built yet" : DashboardText.NOT_KNOWN;
        return
        [
            new("State", vm.State),
            new("Running now", RunningText(vm.Run)),
            new("Created", vm.Created is { } created ? DashboardText.When(created) : missing),
            new("Memory in use", MemoryText(vm, missing)),
            new("Disk space used", vm.DiskSpaceUsed is { } used
                ? $"{DashboardText.Size(used)} on {vm.Disks.Count} {(vm.Disks.Count == 1 ? "disk" : "disks")}"
                : missing),
            // UsedDiskSpace counts the disk's checkpoint files too, so it can be more than the disk's size; say why then.
            .. vm.Disks.Select(disk => new VMDetail(
                "Disk " + disk.DiskName,
                disk.UsedDiskSpace > disk.MaximumDiskSpace
                    ? $"{DashboardText.Size(disk.UsedDiskSpace)} used with its checkpoints, disk size {DashboardText.Size(disk.MaximumDiskSpace)}, {disk.DiskPath}"
                    : $"{DashboardText.Size(disk.UsedDiskSpace)} used of {DashboardText.Size(disk.MaximumDiskSpace)}, {disk.DiskPath}")),
            new("Maintenance", MaintenanceText(vm)),
            new("Last maintenance", DashboardText.LastMaintenance(vm, DashboardText.When)),
            new("Last security scan", vm.LastSecurityScan is { } scanned
                ? $"{DashboardText.When(scanned)}, {DashboardText.InSentence(DashboardText.OpenFindings(vm.OpenFindings))}"
                : "Not scanned yet"),
            // Empty both for a VM made without a template and for one made before LazyVM recorded it (#421).
            new("Created from config template", vm.CreatedFromTemplate ?? "None recorded"),
            new("Configuration first built from", vm.OriginalConfig ?? DashboardText.NOT_KNOWN),
            new("Green template", GreenTemplateText(vm)),
            new("Recovery keys", RecoveryKeysText(vm)),
            new("Settings", vm.Settings),
            .. vm.Problems.Select(problem => new VMDetail("Could not read", problem)),
        ];
    }

    /// <summary>Such as "Build, in phase 7 (Windows)", "Build, stopping" or "Nothing".</summary>
    private static string RunningText(VMRun? run)
    {
        if (run is not { IsRunning: true })
        {
            return "Nothing";
        }
        var what = run.Command ?? "A run, just starting";
        return run.StopRequested
            ? $"{what}, stopping"
            : run.Phase is { } phase
            ? $"{what}, in phase {phase}" + (run.PhaseName is { Length: > 0 } name ? $" ({name})" : string.Empty)
            : what;
    }

    private static string MaintenanceText(LazyVMDashboard vm)
    {
        var time = vm.MaintenanceTime is null ? DashboardText.NOT_KNOWN : $"Daily at {vm.MaintenanceTime}";
        var task = vm.MaintenanceTask is null ? "task not known" : "task " + DashboardText.InSentence(vm.MaintenanceTask);
        return $"{time}, {task}";
    }

    /// <summary>Such as "3 stored, 1 not exported yet, last exported 15 November 2026 10:05", or "None stored yet".</summary>
    private static string RecoveryKeysText(LazyVMDashboard vm)
    {
        if (vm.RecoveryKeys is not { } stored || vm.UnexportedRecoveryKeys is not { } unexported)
        {
            return DashboardText.NOT_KNOWN;
        }
        if (stored == 0)
        {
            return "None stored yet";
        }
        var exported = unexported == 0 ? "all exported" : $"{unexported} not exported yet";
        var last = vm.RecoveryKeysExported is { } when ? "last exported " + DashboardText.When(when) : "never exported";
        return $"{stored} stored, {exported}, {last}";
    }

    private static string GreenTemplateText(LazyVMDashboard vm)
    {
        return (vm.GreenTemplate, vm.GreenTemplateUpdated) switch
        {
            (null, _) => "None yet",
            ({ } name, { } updated) => $"{name}, updated {DashboardText.When(updated)}",
            ({ } name, null) => name,
        };
    }
}

/// <summary>One line of a VM's details, such as "Memory in use: 8 GB".</summary>
public sealed record VMDetail(string Label, string Value)
{
    /// <summary>The line as a screen reader reads it.</summary>
    public string AutomationName => $"{Label}: {Value}";
}

/// <summary>A phase a build can start at, in the list to choose from.</summary>
public sealed class PhaseOption(BuildPhase phase)
{
    public int Number => phase.Number;

    /// <summary>Such as "Phase 7: Install Windows, then the tools and Windows updates".</summary>
    public string Text => phase.Goal.Length > 0 ? $"Phase {phase.Number}: {phase.Goal}" : $"Phase {phase.Number}";

    public override string ToString()
    {
        return Text;
    }
}

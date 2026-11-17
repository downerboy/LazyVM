namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// A VM's own window: every detail the dashboard has about it, its checks
/// and log, and the runs it can start: a build from a chosen phase, and
/// maintenance now. Neither starts while a build, maintenance or rebuild of
/// the VM is running.
/// </summary>
public sealed class VMViewModel : ViewModelBase
{
    private const string MaintenanceNotScheduled = "Not registered";

    private readonly ToolWindows tools;
    private VMDashboard entry;
    private IReadOnlyList<PhaseOption> phases = [];
    private PhaseOption? selectedPhase;
    private int? suggestedPhase;
    private string status = string.Empty;
    private bool isStarting;

    public VMViewModel(VMDashboard entry, ToolWindows tools)
    {
        this.entry = entry;
        this.tools = tools;
        Details = ReadDetails(entry);
        suggestedPhase = CarryOnPhase(entry.LastBuild);
        ChecksCommand = new RelayCommand(() => tools.OpenChecks(Name, hostOnly: false));
        LogCommand = new RelayCommand(() => tools.OpenLog(Name));
        BuildProgressCommand = new RelayCommand(() => tools.OpenProgress(Name, started: null), () => IsBuilding);
        BuildFromPhaseCommand = new RelayCommand(() => _ = BuildFromPhaseAsync(), () => !IsBusy && !IsStarting && SelectedPhase is not null);
        MaintenanceCommand = new RelayCommand(() => _ = RunMaintenanceAsync(), () => !IsBusy && !IsStarting && IsMaintenanceScheduled);
    }

    /// <summary>Opens the progress of the build running now, including one the app did not start.</summary>
    public RelayCommand BuildProgressCommand { get; }

    /// <summary>Builds the VM from <see cref="SelectedPhase"/>, in a pwsh process of its own, and shows its progress.</summary>
    public RelayCommand BuildFromPhaseCommand { get; }

    /// <summary>Starts the VM's maintenance task, so maintenance runs as the nightly run does.</summary>
    public RelayCommand MaintenanceCommand { get; }

    /// <summary>True while a build of the VM is running.</summary>
    public bool IsBuilding => entry.Run is { IsRunning: true, Command: null or VMRun.Build };

    /// <summary>True while a build, maintenance or rebuild of the VM is running: no other may start.</summary>
    public bool IsBusy => entry.Run is { IsRunning: true };

    /// <summary>False only when the dashboard says the maintenance task is not registered.</summary>
    public bool IsMaintenanceScheduled => entry.MaintenanceTask != MaintenanceNotScheduled;

    /// <summary>True while a build or maintenance this window asked for is starting.</summary>
    public bool IsStarting
    {
        get => isStarting;
        private set
        {
            if (SetProperty(ref isStarting, value))
            {
                RaiseRunCommandsChanged();
            }
        }
    }

    /// <summary>Every phase of a build, to choose the one it starts at.</summary>
    public IReadOnlyList<PhaseOption> Phases
    {
        get => phases;
        private set => SetProperty(ref phases, value);
    }

    /// <summary>The phase a build starts at: the one the last build stopped or failed in, or else the first.</summary>
    public PhaseOption? SelectedPhase
    {
        get => selectedPhase;
        set
        {
            if (SetProperty(ref selectedPhase, value))
            {
                BuildFromPhaseCommand.RaiseCanExecuteChanged();
            }
        }
    }

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
                return $"{RunName(entry.Run!.Command)} of {Name} is running now. A build or maintenance can start once it has ended.";
            }
            var notes = new List<string>();
            if (suggestedPhase is { } phase && entry.LastBuild is { } last)
            {
                notes.Add($"The last build {EndedText(last.Status)} in phase {phase}, so phase {phase} is chosen. Let any install still running inside the VM finish first.");
            }
            if (!IsMaintenanceScheduled)
            {
                notes.Add($"Maintenance of {Name} is not scheduled, so it cannot run now. In PowerShell, run Register-LazyVMMaintenance -Name {Name}");
            }
            return string.Join(" ", notes);
        }
    }

    public bool HasRunNote => RunNote.Length > 0;

    /// <summary>What happened when a build or maintenance was asked for, such as why it did not start.</summary>
    public string Status
    {
        get => status;
        private set
        {
            if (SetProperty(ref status, value))
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
            var found = await tools.GetBuildPhasesAsync(CancellationToken.None);
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
        if (IsBusy || IsStarting || SelectedPhase is not { } phase)
        {
            return;
        }
        IsStarting = true;
        Status = $"Starting the build of {Name} from phase {phase.Number}";
        try
        {
            await tools.StartBuildAsync(new BuildRequest(Name, null, null, phase.Number));
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
        if (IsBusy || IsStarting || !IsMaintenanceScheduled)
        {
            return;
        }
        IsStarting = true;
        Status = $"Starting the maintenance of {Name}";
        try
        {
            await tools.StartMaintenanceAsync(Name);
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

    /// <summary>The phase a build that stopped, failed or ended unexpectedly can carry on from; empty otherwise.</summary>
    internal static int? CarryOnPhase(VMRun? lastBuild) =>
        lastBuild is { Status: VMRun.Failed or VMRun.Stopped or VMRun.EndedUnexpectedly }
            ? lastBuild.UnfinishedPhase ?? lastBuild.Phase
            : null;

    private void SelectSuggestedPhase() =>
        SelectedPhase = Phases.FirstOrDefault(option => option.Number == suggestedPhase) ?? Phases.FirstOrDefault();

    private void RaiseRunCommandsChanged()
    {
        BuildFromPhaseCommand.RaiseCanExecuteChanged();
        MaintenanceCommand.RaiseCanExecuteChanged();
    }

    private static string RunName(string? command) => command switch
    {
        VMRun.Build => "A build",
        "Maintenance" => "Maintenance",
        "Rebuild" => "A rebuild",
        _ => "A run",
    };

    private static string EndedText(string? status) => status switch
    {
        VMRun.Stopped => "stopped",
        VMRun.EndedUnexpectedly => "ended unexpectedly",
        _ => "failed",
    };

    /// <summary>Opens the VM's checks (Test-LazyVM).</summary>
    public RelayCommand ChecksCommand { get; }

    /// <summary>Opens the VM's log.</summary>
    public RelayCommand LogCommand { get; }

    public string Name => entry.Name;

    public string Title => $"{entry.Name} - LazyVM";

    public string State => entry.State;

    /// <summary>The details, in the order the window shows them.</summary>
    public IReadOnlyList<VMDetail> Details { get; private set; }

    /// <summary>Shows what a newer refresh read for this VM.</summary>
    public void Update(VMDashboard entry)
    {
        this.entry = entry;
        Details = ReadDetails(entry);
        // A build that has failed or stopped since: choose the phase to carry on from, as on opening.
        var suggested = CarryOnPhase(entry.LastBuild);
        if (suggested != suggestedPhase)
        {
            suggestedPhase = suggested;
            SelectSuggestedPhase();
        }
        OnPropertyChanged(string.Empty);
        BuildProgressCommand.RaiseCanExecuteChanged();
        RaiseRunCommandsChanged();
    }

    /// <summary>Memory in use against the most the VM can use, for example "6 GB of 16 GB" (#420).</summary>
    private static string MemoryText(VMDashboard vm, string missing)
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

    private static List<VMDetail> ReadDetails(VMDashboard vm)
    {
        // Hyper-V has nothing to say about a VM that is not built yet; say why.
        var missing = vm.State == "Not built" ? "Not built yet" : DashboardText.NotKnown;
        var details = new List<VMDetail>
        {
            new("State", vm.State),
            new("Running now", RunningText(vm.Run)),
            new("Created", vm.Created is { } created ? DashboardText.When(created) : missing),
            new("Memory in use", MemoryText(vm, missing)),
            new("Disk space used", vm.DiskSpaceUsed is { } used
                ? $"{DashboardText.Size(used)} on {vm.Disks.Count} {(vm.Disks.Count == 1 ? "disk" : "disks")}"
                : missing),
        };

        // Used counts the disk's checkpoint files too, so it can be more than the disk's size; say why then.
        details.AddRange(vm.Disks.Select(disk => new VMDetail(
            "Disk " + disk.Name,
            disk.Used > disk.Maximum
                ? $"{DashboardText.Size(disk.Used)} used with its checkpoints, disk size {DashboardText.Size(disk.Maximum)}, {disk.Path}"
                : $"{DashboardText.Size(disk.Used)} used of {DashboardText.Size(disk.Maximum)}, {disk.Path}")));

        details.Add(new("Maintenance", MaintenanceText(vm)));
        details.Add(new("Last maintenance", DashboardText.LastMaintenance(vm, DashboardText.When)));
        details.Add(new("Last security scan", vm.LastSecurityScan is { } scanned
            ? $"{DashboardText.When(scanned)}, {DashboardText.InSentence(DashboardText.OpenFindings(vm.OpenFindings))}"
            : "Not scanned yet"));
        // Empty both for a VM made without a template and for one made before LazyVM recorded it (#421).
        details.Add(new("Created from config template", vm.CreatedFromTemplate ?? "None recorded"));
        details.Add(new("Configuration first built from", vm.OriginalConfig ?? DashboardText.NotKnown));
        details.Add(new("Green template", GreenTemplateText(vm)));
        details.Add(new("Settings", vm.Settings));
        details.AddRange(vm.Problems.Select(problem => new VMDetail("Could not read", problem)));
        return details;
    }

    /// <summary>Such as "Build, in phase 7 (Windows)", "Build, stopping" or "Nothing".</summary>
    private static string RunningText(VMRun? run)
    {
        if (run is not { IsRunning: true })
        {
            return "Nothing";
        }
        var what = run.Command ?? "A run, just starting";
        if (run.StopRequested)
        {
            return $"{what}, stopping";
        }
        return run.Phase is { } phase
            ? $"{what}, in phase {phase}" + (run.PhaseName is { Length: > 0 } name ? $" ({name})" : string.Empty)
            : what;
    }

    private static string MaintenanceText(VMDashboard vm)
    {
        var time = vm.MaintenanceTime is null ? DashboardText.NotKnown : $"Daily at {vm.MaintenanceTime}";
        var task = vm.MaintenanceTask is null ? "task not known" : "task " + DashboardText.InSentence(vm.MaintenanceTask);
        return $"{time}, {task}";
    }

    private static string GreenTemplateText(VMDashboard vm) => (vm.GreenTemplate, vm.GreenTemplateUpdated) switch
    {
        (null, _) => "None yet",
        ({ } name, { } updated) => $"{name}, updated {DashboardText.When(updated)}",
        ({ } name, null) => name,
    };
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

    public override string ToString() => Text;
}

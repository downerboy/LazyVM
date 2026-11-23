namespace LazyVM.UI.ViewModels;

/// <summary>
/// Building a VM again from a chosen phase, in a VM's window: every phase to
/// choose from, the one the last build stopped or failed in chosen first,
/// what building from it does, and starting the build, in a pwsh process of
/// its own, with its progress shown.
/// </summary>
public sealed class BuildFromPhaseViewModel : VMPartViewModel
{
    private readonly LazyVMBuildRunner _Builds;
    private readonly ToolWindows _Tools;
    private IReadOnlyList<PhaseOption> _Phases = [];
    private PhaseOption? _SelectedPhase;
    private int? _SuggestedPhase;

    public BuildFromPhaseViewModel(VMRunGate gate, LazyVMBuildRunner builds, ToolWindows tools)
        : base(gate)
    {
        _Builds = builds;
        _Tools = tools;
        _SuggestedPhase = CarryOnPhase(gate.Entry.LastBuild);
        BuildCommand = new RelayCommand(() => _ = BuildAsync(), () => Gate.CanStart && SelectedPhase is not null);
    }

    /// <summary>Builds the VM from <see cref="SelectedPhase"/>, in a pwsh process of its own, and shows its progress.</summary>
    public RelayCommand BuildCommand
    {
        get;
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
                BuildCommand.RaiseCanExecuteChanged();
                OnPropertyChanged(nameof(PhaseHelp));
                OnPropertyChanged(nameof(HasPhaseHelp));
                OnPropertyChanged(nameof(BuildHelp));
            }
        }
    }

    /// <summary>
    /// Build from this phase's help text: <see cref="PhaseHelp"/> for the
    /// phase chosen, then how the build runs. Focus moves from the phase list
    /// to the button, and Narrator reads the button's help, not the list's,
    /// so the button says what the chosen phase does too.
    /// </summary>
    public string BuildHelp => string.Join(" ",
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

    /// <summary>Which phase is chosen and why, after a build that did not finish; empty otherwise.</summary>
    public string SuggestionNote => _SuggestedPhase is { } phase && Gate.Entry.LastBuild is { } last
        ? $"The last build {EndedText(last.Status)} in phase {phase}, so phase {phase} is chosen. Let any install still running inside the VM finish first."
        : string.Empty;

    /// <summary>Reads the build's phases to choose from, and chooses the one to carry on from.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var found = await WorkAsync("Reading the build phases", () => _Builds.GetLazyVMBuildPhasesAsync(CancellationToken.None));
            Phases = found.Select(phase => new PhaseOption(phase)).ToList();
            SelectSuggestedPhase();
        }
        catch (Exception exception)
        {
            Status = "The build phases could not be read, so a build cannot start here: " + exception.Message;
        }
    }

    /// <summary>Builds the VM from the chosen phase, and shows the build's progress.</summary>
    public async Task BuildAsync()
    {
        if (!Gate.CanStart || SelectedPhase is not { } phase)
        {
            return;
        }
        Gate.IsStarting = true;
        Status = $"Starting the build of {Name} from phase {phase.Number}";
        try
        {
            await WorkAsync($"Starting the build from phase {phase.Number}", () => _Tools.StartBuildAsync(Gate.Entry.Id, new BuildRequest(Name, null, null, phase.Number)));
            Status = $"The build of {Name} has started from phase {phase.Number}. Its progress is in its own window.";
        }
        catch (Exception exception)
        {
            Status = "The build could not start: " + exception.Message;
        }
        finally
        {
            Gate.IsStarting = false;
        }
    }

    /// <summary>The phase a build that stopped, failed or ended unexpectedly can carry on from; empty otherwise.</summary>
    internal static int? CarryOnPhase(VMRun? lastBuild)
    {
        return lastBuild is { Status: VMRun.FAILED or VMRun.STOPPED or VMRun.ENDED_UNEXPECTEDLY }
            ? lastBuild.UnfinishedPhase ?? lastBuild.Phase
            : null;
    }

    /// <summary>A build that has failed or stopped since: chooses the phase to carry on from, as on opening.</summary>
    protected override void GateChanged()
    {
        var suggested = CarryOnPhase(Gate.Entry.LastBuild);
        if (suggested != _SuggestedPhase)
        {
            _SuggestedPhase = suggested;
            SelectSuggestedPhase();
        }
        BuildCommand.RaiseCanExecuteChanged();
        base.GateChanged();
    }

    private void SelectSuggestedPhase()
    {
        SelectedPhase = Phases.FirstOrDefault(option => option.Number == _SuggestedPhase) ?? Phases.FirstOrDefault();
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
}

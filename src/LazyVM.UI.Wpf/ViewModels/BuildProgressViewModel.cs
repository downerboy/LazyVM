namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The build progress window: each phase as its number and its goal, the
/// phase the build is in, and Cancel. It follows the run state the module
/// records (<c>Get-LazyVMDashboard</c> Run), never the log's text, so it
/// also follows a build the app did not start, such as one carrying on
/// after a host restart. Closing the window stops only the following: the
/// build carries on.
/// </summary>
public sealed class BuildProgressViewModel : ViewModelBase
{
    /// <summary>How often the run state is read while the window is open.</summary>
    internal static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(3);

    private readonly CommandRunner _Runner;
    private readonly StartedBuild? _Started;
    private readonly TimeProvider _Clock;
    private readonly RelayCommand _CancelCommand;
    private readonly Func<int, Task>? _StartFromPhase;
    private readonly RelayCommand _CarryOnCommand;
    private CancellationTokenSource? _Following;
    private IReadOnlyList<BuildPhase> _Phases = [];
    private IReadOnlyList<PhaseRowViewModel> _PhaseRows = [];
    private VMRun? _Run;
    private int? _FollowedProcess;
    private string _Status;
    private string? _Advice;
    private int? _CarryOnPhase;
    private bool _IsFinished;
    private bool _IsStopRequested;
    private bool _IsCancelling;
    private bool _IsCarryingOn;

    /// <param name="vmName">The VM whose build is followed.</param>
    /// <param name="started">The build process the app started; empty to follow the VM's build that is running now.</param>
    /// <param name="startFromPhase">Starts a new build of the VM from the phase it is given, and shows it; empty offers no Carry on.</param>
    public BuildProgressViewModel(CommandRunner runner, string vmName, StartedBuild? started, TimeProvider clock, Func<int, Task>? startFromPhase = null)
    {
        _Runner = runner;
        _Started = started;
        _Clock = clock;
        _StartFromPhase = startFromPhase;
        VMName = vmName;
        _FollowedProcess = started?.ProcessId;
        _Status = $"Starting the build of {vmName}";
        _CancelCommand = new RelayCommand(() => _ = CancelAsync(), CanCancel);
        _CarryOnCommand = new RelayCommand(() => _ = CarryOnAsync(), () => CarryOnPhase is not null && !_IsCarryingOn);
    }

    /// <summary>
    /// The phase a build that stopped, failed or ended unexpectedly can carry
    /// on from; empty while the build runs, after one that completed, and
    /// when the phase is not known.
    /// </summary>
    public int? CarryOnPhase
    {
        get => _CarryOnPhase;
        private set
        {
            if (SetProperty(ref _CarryOnPhase, value))
            {
                OnPropertyChanged(nameof(CanCarryOn));
                OnPropertyChanged(nameof(CarryOnText));
                _CarryOnCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public bool CanCarryOn => CarryOnPhase is not null;

    /// <summary>The button's text, such as "Carry on from phase 7".</summary>
    public string CarryOnText => CarryOnPhase is { } phase ? $"Carry on from phase {phase}" : string.Empty;

    /// <summary>Starts a new build of the VM from <see cref="CarryOnPhase"/>, in a window of its own.</summary>
    public RelayCommand CarryOnCommand => _CarryOnCommand;

    /// <summary>Raised once, when the build has ended.</summary>
    public event EventHandler? Ended;

    public string VMName
    {
        get;
    }

    public string Title => $"Build of {VMName} - LazyVM";

    public string Heading => $"Build of {VMName}";

    /// <summary>Every phase, each with its number, its goal and how far it has got.</summary>
    public IReadOnlyList<PhaseRowViewModel> Phases
    {
        get => _PhaseRows;
        private set => SetProperty(ref _PhaseRows, value);
    }

    /// <summary>Where the build is, such as "Phase 7: Install Windows and the tools", or how it ended.</summary>
    public string Status
    {
        get => _Status;
        private set => SetProperty(ref _Status, value);
    }

    /// <summary>What to do next after a build that stopped or failed; empty otherwise.</summary>
    public string? Advice
    {
        get => _Advice;
        private set
        {
            if (SetProperty(ref _Advice, value))
            {
                OnPropertyChanged(nameof(HasAdvice));
            }
        }
    }

    public bool HasAdvice => Advice is not null;

    public bool IsFinished
    {
        get => _IsFinished;
        private set
        {
            if (SetProperty(ref _IsFinished, value))
            {
                _CancelCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>True once the build has been asked to stop, until it has.</summary>
    public bool IsStopping
    {
        get => _IsStopRequested && !IsFinished;
        private set
        {
            if (_IsStopRequested != value)
            {
                _IsStopRequested = value;
                OnPropertyChanged();
                _CancelCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>Asks the build to stop at its next safe point (Stop-LazyVMBuild). The process is never killed.</summary>
    public RelayCommand CancelCommand => _CancelCommand;

    /// <summary>
    /// Reads the phases, then the run state every few seconds until the build
    /// ends or <see cref="StopFollowing"/> is called.
    /// </summary>
    public async Task FollowAsync()
    {
        if (_Following is not null || IsFinished)
        {
            return;
        }
        using var cancel = new CancellationTokenSource();
        _Following = cancel;
        try
        {
            await LoadPhasesAsync(cancel.Token);
            while (!IsFinished)
            {
                await PollAsync(cancel.Token);
                if (IsFinished)
                {
                    break;
                }
                // Read again sooner when the process ends, but once it has, wait as usual, so a failing read never spins.
                var wait = Task.Delay(PollInterval, _Clock, cancel.Token);
                await (_Started is null || _Started.Ended.IsCompleted ? wait : Task.WhenAny(wait, _Started.Ended));
                cancel.Token.ThrowIfCancellationRequested();
            }
        }
        catch (OperationCanceledException)
        {
            // The window closed; the build carries on.
        }
        finally
        {
            _Following = null;
        }
    }

    /// <summary>Stops reading the run state, as when the window closes. The build carries on.</summary>
    public void StopFollowing()
    {
        _Following?.Cancel();
    }

    internal async Task LoadPhasesAsync(CancellationToken cancellationToken)
    {
        try
        {
            _Phases = await _Runner.GetBuildPhasesAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            // The progress still shows, with the phase numbers alone.
            _Phases = [];
        }
        ShowPhases();
    }

    /// <summary>Reads the VM's run once and shows where the build is, or how it ended.</summary>
    internal async Task PollAsync(CancellationToken cancellationToken)
    {
        VMRun? latest;
        try
        {
            latest = (await _Runner.GetVMAsync(VMName, cancellationToken))?.Run;
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            Status = $"The build's progress could not be read: {exception.Message} Trying again.";
            return;
        }

        if (_Started is not null)
        {
            ShowStartedBuild(latest);
        }
        else
        {
            ShowRunningBuild(latest);
        }
    }

    /// <summary>A build the app started: only the run of its own process counts, never the one before it.</summary>
    private void ShowStartedBuild(VMRun? latest)
    {
        var processEnded = _Started!.Ended.IsCompleted;
        var result = processEnded ? _Started.Ended.Result : null;
        if (latest?.ProcessId == _Started.ProcessId)
        {
            Show(latest, result);
        }
        else if (processEnded)
        {
            // It ended before it recorded a run, such as when the Windows ISO is missing or another run is going.
            Finish(result!.Outcome == BuildResult.COMPLETED
                ? $"The build of {VMName} ended."
                : $"The build of {VMName} did not start: {result.Message}", null);
        }
        else
        {
            Status = $"Starting the build of {VMName}";
        }
    }

    /// <summary>A build already running: the one running when the window opened.</summary>
    private void ShowRunningBuild(VMRun? latest)
    {
        if (_FollowedProcess is null && latest is { IsRunning: true, ProcessId: { } process } && latest.Command is null or VMRun.BUILD)
        {
            _FollowedProcess = process;
        }
        if (_FollowedProcess is null)
        {
            if (latest is { IsRunning: true, ProcessId: null })
            {
                Status = $"A run of {VMName} is just starting";
                return;
            }
            Finish($"No build of {VMName} is running.", null);
            return;
        }
        if (latest is null || latest.ProcessId != _FollowedProcess)
        {
            Finish($"The build of {VMName} has ended.", null);
            return;
        }
        Show(latest, null);
    }

    private void Show(VMRun latest, BuildResult? result)
    {
        _Run = latest;
        IsStopping = latest.StopRequested;
        ShowPhases();
        if (!latest.IsRunning)
        {
            Ending(latest, result);
            return;
        }
        Status = latest switch
        {
            { StopRequested: true } => $"Stopping at the next safe point{InPhase(latest.Phase)}. An install already started inside the VM finishes by itself.",
            { Phase: { } phase } => PhaseText(phase),
            _ => $"Starting the build of {VMName}",
        };
    }

    /// <summary>How the build ended, and for a build that stopped or failed, how to carry on.</summary>
    private void Ending(VMRun ended, BuildResult? result)
    {
        var phase = ended.UnfinishedPhase ?? ended.Phase;
        var carryOn = phase switch
        {
            null => string.Empty,
            { } number when _StartFromPhase is not null => $" Then choose Carry on from phase {number}.",
            { } number => $" Then carry on from phase {number}: in PowerShell, run Build-LazyVM -Name {VMName} -FromPhase {number}",
        };
        switch (ended.Status)
        {
            case VMRun.COMPLETED:
                Finish($"The build of {VMName} is complete. {VMName} is ready.", null);
                break;
            case VMRun.COMPLETED_WITH_PROBLEMS:
                Finish($"All phases ran, but some steps failed. {VMName} can be used.", "The log says which steps failed and how to fix them.");
                break;
            case VMRun.WAITING_FOR_RESTART:
                Finish("The host is restarting to finish turning on Hyper-V.", "The build carries on by itself after the restart.");
                break;
            case VMRun.STOPPED:
                Finish($"The build of {VMName} stopped{InPhase(phase)}, as asked.",
                    "Let any install still running inside the VM finish first, so two installers do not run at once." + carryOn, phase);
                break;
            case VMRun.ENDED_UNEXPECTEDLY:
                Finish($"The build of {VMName} ended unexpectedly{InPhase(phase)}: its process was closed, crashed or lost power.",
                    "The log says how far it got." + carryOn, phase);
                break;
            default:
                var reason = result?.Message is { Length: > 0 } message ? $": {message}" : ".";
                Finish($"The build of {VMName} failed{InPhase(phase)}{reason}", "The log says why. Fix the problem first." + carryOn, phase);
                break;
        }
    }

    /// <param name="carryOnFrom">The phase the build can carry on from, for one that stopped or failed.</param>
    private void Finish(string text, string? next, int? carryOnFrom = null)
    {
        Status = text;
        Advice = next;
        IsFinished = true;
        CarryOnPhase = _StartFromPhase is null ? null : carryOnFrom;
        OnPropertyChanged(nameof(IsStopping));
        ShowPhases();
        Ended?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>Starts the build again from <see cref="CarryOnPhase"/>; its progress shows in a new window.</summary>
    internal async Task CarryOnAsync()
    {
        if (CarryOnPhase is not { } phase || _StartFromPhase is null || _IsCarryingOn)
        {
            return;
        }
        _IsCarryingOn = true;
        _CarryOnCommand.RaiseCanExecuteChanged();
        Status = $"Starting the build of {VMName} from phase {phase}";
        try
        {
            await _StartFromPhase(phase);
        }
        catch (Exception exception)
        {
            Status = "The build could not start: " + exception.Message;
        }
        finally
        {
            _IsCarryingOn = false;
            _CarryOnCommand.RaiseCanExecuteChanged();
        }
    }

    private async Task CancelAsync()
    {
        _IsCancelling = true;
        _CancelCommand.RaiseCanExecuteChanged();
        try
        {
            var stopping = await _Runner.StopBuildAsync(VMName, CancellationToken.None);
            if (stopping is null)
            {
                Status = $"No build of {VMName} is running, so there is nothing to stop.";
                return;
            }
            Show(stopping, null);
        }
        catch (Exception exception)
        {
            Status = "The build could not be stopped: " + exception.Message;
        }
        finally
        {
            _IsCancelling = false;
            _CancelCommand.RaiseCanExecuteChanged();
        }
    }

    /// <summary>Only a build that has recorded its process can be asked to stop, and only once.</summary>
    private bool CanCancel()
    {
        return !IsFinished && !_IsCancelling && !_IsStopRequested && _Run is { IsRunning: true, IsBuild: true, ProcessId: not null };
    }

    private void ShowPhases()
    {
        var current = _Run?.Phase;
        var finished = IsFinished && _Run is not null;
        Phases = _Phases.Select(phase => new PhaseRowViewModel(phase, PhaseState(phase.Number))).ToList();

        string PhaseState(int number)
        {
            return _Run is null || current is null
                ? PhaseRowViewModel.NOT_STARTED
                : finished && _Run.Status is VMRun.COMPLETED or VMRun.COMPLETED_WITH_PROBLEMS
                ? _Run.Status == VMRun.COMPLETED_WITH_PROBLEMS && number == current ? PhaseRowViewModel.DONE_WITH_PROBLEMS : PhaseRowViewModel.DONE
                : number < current
                ? PhaseRowViewModel.DONE
                : number > current
                ? PhaseRowViewModel.NOT_STARTED
                : _Run.Status switch
                {
                    VMRun.RUNNING when _Run.StopRequested => PhaseRowViewModel.STOPPING,
                    VMRun.RUNNING => PhaseRowViewModel.IN_PROGRESS,
                    VMRun.WAITING_FOR_RESTART => PhaseRowViewModel.WAITING_FOR_RESTART,
                    VMRun.STOPPED => PhaseRowViewModel.STOPPED,
                    _ => PhaseRowViewModel.FAILED,
                };
        }
    }

    private string PhaseText(int number)
    {
        return _Phases.FirstOrDefault(phase => phase.Number == number) is { } phase
            ? $"Phase {number}: {phase.Goal}"
            : $"Phase {number}";
    }

    private static string InPhase(int? phase)
    {
        return phase is { } number ? $" in phase {number}" : string.Empty;
    }
}

/// <summary>One phase of the build: its number, its goal and how far it has got.</summary>
public sealed class PhaseRowViewModel(BuildPhase phase, string state)
{
    public const string NOT_STARTED = "Not started";
    public const string IN_PROGRESS = "In progress";
    public const string STOPPING = "Stopping";
    public const string DONE = "Done";
    public const string DONE_WITH_PROBLEMS = "Done, with problems";
    public const string WAITING_FOR_RESTART = "Waiting for the host to restart";
    public const string STOPPED = "Stopped";
    public const string FAILED = "Failed";

    public int Number => phase.Number;

    public string Goal => phase.Goal;

    public string State => state;

    /// <summary>True for the phase the build is in, or ended in.</summary>
    public bool IsCurrent => state is not (NOT_STARTED or DONE);

    /// <summary>A shape for the state, so it is never told by color alone.</summary>
    public string Symbol => state switch
    {
        DONE => "✓",
        NOT_STARTED => "○",
        IN_PROGRESS or STOPPING or WAITING_FOR_RESTART => "▶",
        DONE_WITH_PROBLEMS => "▲",
        _ => "✖",
    };

    /// <summary>The phase as a screen reader reads it, such as "Phase 7, Install Windows and the tools: In progress".</summary>
    public string AutomationName => $"Phase {Number}, {Goal}: {State}";
}

using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// A command runner that answers from memory instead of PowerShell. Each
/// command has its own queue of answers, and each call's parameters are kept.
/// </summary>
internal sealed class FakeCommandRunner : CommandRunner
{
    private readonly Answers<VMDashboard> _Dashboards = new();
    private readonly Answers<VMCheck> _Checks = new();
    private readonly Answers<VMLogEntry> _Logs = new();

    public int DashboardCalls
    {
        get; private set;
    }

    public List<(string? Name, bool HostOnly)> CheckCalls { get; } = [];

    public List<(string Name, int Tail)> LogCalls { get; } = [];

    public void Returns(params VMDashboard[] entries)
    {
        _Dashboards.Returns(entries);
    }

    public void Throws(Exception exception)
    {
        _Dashboards.Throws(exception);
    }

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel()
    {
        _Dashboards.WaitsForCancel();
    }

    public void ReturnsChecks(params VMCheck[] results)
    {
        _Checks.Returns(results);
    }

    public void ChecksThrow(Exception exception)
    {
        _Checks.Throws(exception);
    }

    public void ChecksWaitForCancel()
    {
        _Checks.WaitsForCancel();
    }

    public void ReturnsLog(params VMLogEntry[] entries)
    {
        _Logs.Returns(entries);
    }

    public void LogThrows(Exception exception)
    {
        _Logs.Throws(exception);
    }

    public override Task<IReadOnlyList<VMDashboard>> GetDashboardAsync(CancellationToken cancellationToken)
    {
        DashboardCalls++;
        return _Dashboards.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMCheck>> GetChecksAsync(string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        CheckCalls.Add((name, hostOnly));
        return _Checks.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMLogEntry>> GetLogAsync(string name, int tail, CancellationToken cancellationToken)
    {
        LogCalls.Add((name, tail));
        return _Logs.Next(cancellationToken);
    }

    private readonly Answers<VMDashboard> _VMs = new();
    private readonly Answers<VMRun> _Stops = new();

    public IReadOnlyList<BuildPhase> Phases
    {
        get; set;
    } =
    [
        new(0, "HyperVHealth", "Check Hyper-V is working"),
        new(1, "Readiness", "Check the host is ready"),
        new(7, "Windows", "Install Windows and the tools"),
        new(8, "Finish", "Finish SQL Server and Visual Studio"),
    ];

    public IReadOnlyList<ConfigTemplate> Templates
    {
        get; set;
    } =
    [
        new("DevBox-latest", BuiltIn: false, Automatic: true),
        new("Developer", BuiltIn: true, Automatic: false),
        new("PlainWindows", BuiltIn: true, Automatic: false),
    ];

    public Exception? TemplatesFail
    {
        get; set;
    }

    public Exception? ModuleFolderFails
    {
        get; set;
    }

    public List<string> VMCalls { get; } = [];

    public List<string> StopCalls { get; } = [];

    /// <summary>The next Get-LazyVMDashboard -Name finds the VM with this run.</summary>
    public void ReturnsRun(VMRun? run, string name = "DevBox")
    {
        _VMs.Returns([Sample.VM(name) with { Run = run }]);
    }

    public void VMThrows(Exception exception)
    {
        _VMs.Throws(exception);
    }

    /// <summary>The next Stop-LazyVMBuild returns this run.</summary>
    public void StopReturns(VMRun? run)
    {
        _Stops.Returns(run is null ? [] : [run]);
    }

    public void StopThrows(Exception exception)
    {
        _Stops.Throws(exception);
    }

    public override async Task<VMDashboard?> GetVMAsync(string name, CancellationToken cancellationToken)
    {
        VMCalls.Add(name);
        return (await _VMs.Next(cancellationToken)).FirstOrDefault();
    }

    public override Task<IReadOnlyList<BuildPhase>> GetBuildPhasesAsync(CancellationToken cancellationToken)
    {
        return PhasesFail is { } failure ? Task.FromException<IReadOnlyList<BuildPhase>>(failure) : Task.FromResult(Phases);
    }

    public override Task<IReadOnlyList<ConfigTemplate>> GetConfigTemplatesAsync(CancellationToken cancellationToken)
    {
        return TemplatesFail is { } failure ? Task.FromException<IReadOnlyList<ConfigTemplate>>(failure) : Task.FromResult(Templates);
    }

    public override async Task<VMRun?> StopBuildAsync(string name, CancellationToken cancellationToken)
    {
        StopCalls.Add(name);
        return (await _Stops.Next(cancellationToken)).FirstOrDefault();
    }

    public List<string> MaintenanceCalls { get; } = [];

    /// <summary>Start-LazyVMMaintenance fails with this, as the module does when it starts nothing.</summary>
    public Exception? MaintenanceFails
    {
        get; set;
    }

    public Exception? PhasesFail
    {
        get; set;
    }

    public override Task StartMaintenanceAsync(string name, CancellationToken cancellationToken)
    {
        MaintenanceCalls.Add(name);
        return MaintenanceFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }

    private readonly Answers<RemovalPlan> _RemovalPlans = new();

    public List<string> RemovalPlanCalls { get; } = [];

    public List<string> RemoveCalls { get; } = [];

    /// <summary>Remove-LazyVM fails with this, as the module does for a partial removal.</summary>
    public Exception? RemoveFails
    {
        get; set;
    }

    /// <summary>When set, Remove-LazyVM runs until the test completes it.</summary>
    public TaskCompletionSource? RemoveGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRemovalPlan returns this plan.</summary>
    public void ReturnsRemovalPlan(RemovalPlan plan)
    {
        _RemovalPlans.Returns([plan]);
    }

    public void RemovalPlanThrows(Exception exception)
    {
        _RemovalPlans.Throws(exception);
    }

    public override async Task<RemovalPlan> GetRemovalPlanAsync(string name, CancellationToken cancellationToken)
    {
        RemovalPlanCalls.Add(name);
        return (await _RemovalPlans.Next(cancellationToken))[0];
    }

    public override async Task RemoveVMAsync(string name)
    {
        RemoveCalls.Add(name);
        if (RemoveGate is { } gate)
        {
            await gate.Task;
        }
        if (RemoveFails is { } failure)
        {
            throw failure;
        }
    }

    private readonly Answers<VMRestorePoint> _RestorePoints = new();

    public List<string> RestorePointCalls { get; } = [];

    public List<(string Name, string Stamp)> RestoreCalls { get; } = [];

    /// <summary>Restore-LazyVMTooling fails with this.</summary>
    public Exception? RestoreFails
    {
        get; set;
    }

    /// <summary>When set, Restore-LazyVMTooling runs until the test completes it.</summary>
    public TaskCompletionSource? RestoreGate
    {
        get; set;
    }

    /// <summary>The next Get-LazyVMRestorePoint returns these points, oldest first as the module does.</summary>
    public void ReturnsRestorePoints(params VMRestorePoint[] points)
    {
        _RestorePoints.Returns(points);
    }

    public void RestorePointsThrow(Exception exception)
    {
        _RestorePoints.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRestorePoint>> GetRestorePointsAsync(string name, CancellationToken cancellationToken)
    {
        RestorePointCalls.Add(name);
        return _RestorePoints.Next(cancellationToken);
    }

    public override async Task RestoreToolingAsync(string name, string stamp)
    {
        RestoreCalls.Add((name, stamp));
        if (RestoreGate is { } gate)
        {
            await gate.Task;
        }
        if (RestoreFails is { } failure)
        {
            throw failure;
        }
    }

    private readonly Answers<VMRecoveryKey> _RecoveryKeys = new();

    public List<string> RecoveryKeyCalls { get; } = [];

    /// <summary>The recovery password Get-LazyVMCredential -RecoveryPassword gives for each disk GUID.</summary>
    public Dictionary<string, string> RecoveryPasswords { get; } = new(StringComparer.OrdinalIgnoreCase);

    public List<(string Name, string DiskGuid)> RecoveryPasswordCalls { get; } = [];

    /// <summary>Get-LazyVMCredential -RecoveryPassword fails with this.</summary>
    public Exception? RecoveryPasswordFails
    {
        get; set;
    }

    public List<(string Name, string Path, bool Force)> ExportCalls { get; } = [];

    /// <summary>Export-LazyVMRecoveryKey fails with this.</summary>
    public Exception? ExportFails
    {
        get; set;
    }

    /// <summary>The warnings Export-LazyVMRecoveryKey writes.</summary>
    public IReadOnlyList<string> ExportWarnings { get; set; } = [];

    /// <summary>The next Get-LazyVMRecoveryKey returns these keys.</summary>
    public void ReturnsRecoveryKeys(params VMRecoveryKey[] keys)
    {
        _RecoveryKeys.Returns(keys);
    }

    public void RecoveryKeysThrow(Exception exception)
    {
        _RecoveryKeys.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRecoveryKey>> GetRecoveryKeysAsync(string name, CancellationToken cancellationToken)
    {
        RecoveryKeyCalls.Add(name);
        return _RecoveryKeys.Next(cancellationToken);
    }

    public override Task<string> GetRecoveryPasswordAsync(string name, string diskGuid, CancellationToken cancellationToken)
    {
        RecoveryPasswordCalls.Add((name, diskGuid));
        return RecoveryPasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(RecoveryPasswords[diskGuid]);
    }

    public override Task<RecoveryKeyExport> ExportRecoveryKeysAsync(string name, string path, bool force)
    {
        ExportCalls.Add((name, path, force));
        return ExportFails is { } failure
            ? Task.FromException<RecoveryKeyExport>(failure)
            : Task.FromResult(new RecoveryKeyExport(path, ExportWarnings));
    }

    /// <summary>The user name Get-LazyVMCredential gives; empty for a VM with no credential stored, which fails as the module does.</summary>
    public string? UserName { get; set; } = "devadmin";

    /// <summary>The password Get-LazyVMCredential -AsPlainText gives.</summary>
    public string Password { get; set; } = "Correct-Horse-9";

    /// <summary>Get-LazyVMCredential -AsPlainText fails with this.</summary>
    public Exception? PasswordFails
    {
        get; set;
    }

    public List<string> UserNameCalls { get; } = [];

    public List<string> PasswordCalls { get; } = [];

    public override Task<string> GetUserNameAsync(string name, CancellationToken cancellationToken)
    {
        UserNameCalls.Add(name);
        return UserName is { } userName
            ? Task.FromResult(userName)
            : Task.FromException<string>(new InvalidOperationException(
                $"No credential is stored for '{name}' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name {name}"));
    }

    public override Task<string> GetPasswordAsync(string name, CancellationToken cancellationToken)
    {
        PasswordCalls.Add(name);
        return PasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(Password);
    }

    public override Task<string> GetModuleFolderAsync(CancellationToken cancellationToken)
    {
        return ModuleFolderFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0");
    }

    private sealed class Answers<T>
    {
        private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<T>>>> _Queue = new();

        public void Returns(T[] values)
        {
            _Queue.Enqueue(_ => Task.FromResult<IReadOnlyList<T>>(values));
        }

        public void Throws(Exception exception)
        {
            _Queue.Enqueue(_ => Task.FromException<IReadOnlyList<T>>(exception));
        }

        public void WaitsForCancel()
        {
            _Queue.Enqueue(async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return [];
            });
        }

        public Task<IReadOnlyList<T>> Next(CancellationToken cancellationToken)
        {
            return _Queue.Dequeue()(cancellationToken);
        }
    }
}

/// <summary>Records the builds it is asked to start, without starting a process. Each build ends when the test says.</summary>
internal sealed class FakeBuildLauncher : BuildLauncher
{
    public List<(BuildRequest Request, string ModuleFolder)> Started { get; } = [];

    public TaskCompletionSource<BuildResult> Ending { get; private set; } = new();

    public Exception? Fails
    {
        get; set;
    }

    public int ProcessId { get; set; } = 4242;

    public override StartedBuild Start(BuildRequest request, string moduleFolder)
    {
        if (Fails is { } failure)
        {
            throw failure;
        }
        Started.Add((request, moduleFolder));
        Ending = new();
        return new StartedBuild(ProcessId, Ending.Task);
    }
}

/// <summary>Records the windows shown, brought to the front and closed, without making windows.</summary>
internal sealed class FakeToolWindows(CommandRunner runner, BuildLauncher? launcher = null, FakeSecretClipboard? clipboard = null)
    : ToolWindows(runner, launcher ?? new FakeBuildLauncher(), new FixedClock(DateTimeOffset.UnixEpoch),
        clipboard ?? new FakeSecretClipboard(new ManualClock(DateTimeOffset.UnixEpoch)))
{
    private readonly Dictionary<ViewModelBase, Action> _Closers = [];

    public List<ViewModelBase> Shown { get; } = [];

    public List<ViewModelBase> BroughtToFront { get; } = [];

    public List<ViewModelBase> Closed { get; } = [];

    /// <summary>The answer to "Do you really want to delete this VM?": Yes when true.</summary>
    public bool ConfirmsRemoval
    {
        get; set;
    }

    /// <summary>Every delete dialog shown, with what it listed.</summary>
    public List<RemovalViewModel> RemovalsAsked { get; } = [];

    public override bool ConfirmRemoval(RemovalViewModel removal)
    {
        RemovalsAsked.Add(removal);
        return ConfirmsRemoval;
    }

    /// <summary>The answer to the restore question: Yes when true.</summary>
    public bool ConfirmsRestore
    {
        get; set;
    }

    /// <summary>Every restore question asked.</summary>
    public List<string> RestoreQuestions { get; } = [];

    public override bool ConfirmRestore(RestoreViewModel restore, string question)
    {
        RestoreQuestions.Add(question);
        return ConfirmsRestore;
    }

    /// <summary>The file the Save dialog gives back; empty for Cancel.</summary>
    public string? ChosenExportFile
    {
        get; set;
    }

    /// <summary>The file name each Save dialog suggested.</summary>
    public List<string> ExportFileSuggestions { get; } = [];

    public override string? ChooseExportFile(RecoveryKeysViewModel keys, string suggestedName)
    {
        ExportFileSuggestions.Add(suggestedName);
        return ChosenExportFile;
    }

    /// <summary>The files there are already.</summary>
    public HashSet<string> ExistingFiles { get; } = new(StringComparer.OrdinalIgnoreCase);

    public override bool FileExists(string path)
    {
        return ExistingFiles.Contains(path);
    }

    /// <summary>The answer to "Do you want to replace it?": Yes when true.</summary>
    public bool ConfirmsReplace
    {
        get; set;
    }

    /// <summary>Every replace question asked.</summary>
    public List<string> ReplaceQuestions { get; } = [];

    public override bool ConfirmReplace(RecoveryKeysViewModel keys, string question)
    {
        ReplaceQuestions.Add(question);
        return ConfirmsReplace;
    }

    public void Close(ViewModelBase window)
    {
        _Closers[window]();
    }

    protected override void CloseWindow(ViewModelBase viewModel)
    {
        Closed.Add(viewModel);
        _Closers[viewModel]();
    }

    protected override void Show(ViewModelBase viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(ViewModelBase viewModel)
    {
        BroughtToFront.Add(viewModel);
    }
}

/// <summary>Records the VM windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeVMWindowManager(ToolWindows tools) : VMWindowManager(tools)
{
    private readonly Dictionary<VMViewModel, Action> _Closers = [];

    public List<VMViewModel> Shown { get; } = [];

    public List<VMViewModel> BroughtToFront { get; } = [];

    public List<VMViewModel> Closed { get; } = [];

    public void Close(VMViewModel window)
    {
        _Closers[window]();
    }

    protected override void CloseWindow(VMViewModel viewModel)
    {
        Closed.Add(viewModel);
        _Closers[viewModel]();
    }

    protected override void Show(VMViewModel viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(VMViewModel viewModel)
    {
        BroughtToFront.Add(viewModel);
    }
}

/// <summary>A clock that moves only when a test says, firing the timers that are due then.</summary>
internal sealed class ManualClock(DateTimeOffset start) : TimeProvider
{
    private readonly List<ManualTimer> _Timers = [];
    private DateTimeOffset _Now = start;

    public override DateTimeOffset GetUtcNow()
    {
        return _Now.ToUniversalTime();
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;

    public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
    {
        var timer = new ManualTimer(this, callback, state);
        timer.Change(dueTime, period);
        _Timers.Add(timer);
        return timer;
    }

    /// <summary>Moves the clock on by <paramref name="by"/>, firing each timer that falls due.</summary>
    public void Advance(TimeSpan by)
    {
        _Now += by;
        foreach (var timer in _Timers.Where(timer => timer.Due is { } due && due <= _Now).ToList())
        {
            timer.Fire();
        }
    }

    private sealed class ManualTimer(ManualClock clock, TimerCallback callback, object? state) : ITimer
    {
        public DateTimeOffset? Due
        {
            get; private set;
        }

        public bool Change(TimeSpan dueTime, TimeSpan period)
        {
            Due = dueTime == Timeout.InfiniteTimeSpan ? null : clock._Now + dueTime;
            return true;
        }

        public void Fire()
        {
            Due = null;
            callback(state);
        }

        public void Dispose()
        {
            Due = null;
            clock._Timers.Remove(this);
        }

        public ValueTask DisposeAsync()
        {
            Dispose();
            return ValueTask.CompletedTask;
        }
    }
}

/// <summary>A clipboard in memory: what Windows' clipboard would hold, and every secret put on it.</summary>
internal sealed class FakeSecretClipboard(TimeProvider clock) : SecretClipboard(clock)
{
    /// <summary>What the clipboard holds now; empty when it is clear.</summary>
    public string? Holding
    {
        get; set;
    }

    public List<string> Written { get; } = [];

    /// <summary>Putting a secret on the clipboard fails with this.</summary>
    public Exception? WriteFails
    {
        get; set;
    }

    protected override void Write(string secret)
    {
        if (WriteFails is { } failure)
        {
            throw failure;
        }
        Written.Add(secret);
        Holding = secret;
    }

    protected override bool Holds(string secret)
    {
        return Holding == secret;
    }

    protected override void Erase()
    {
        Holding = null;
    }

    protected override void OnUIThread(Action action)
    {
        action();
    }
}

/// <summary>A clock that always says the same time.</summary>
internal sealed class FixedClock(DateTimeOffset now) : TimeProvider
{
    public override DateTimeOffset GetUtcNow()
    {
        return now.ToUniversalTime();
    }

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
}

internal static class Sample
{
    public static VMDashboard VM(string name = "DevBox", string state = "Running")
    {
        return new()
        {
            Name = name,
            State = state,
            MaintenanceTask = "Registered",
            LastMaintenance = new DateTime(2026, 11, 12, 2, 10, 0),
            LastMaintenanceResult = "Succeeded",
            OpenFindings = 0,
        };
    }

    public static VMCheck Check(string status = VMCheck.OK, string check = "LazyVM folder", string detail = @"C:\Users\me\LazyVM", string fix = "")
    {
        return new("Host", check, status, detail, fix);
    }

    public static VMLogEntry Log(string level, string message, int minute = 0)
    {
        return new(new DateTime(2026, 11, 12, 2, minute, 5), level, message);
    }
}

/// <summary>Runs a test with a fixed culture, so dates and numbers read the same on every machine.</summary>
internal sealed class CultureScope : IDisposable
{
    private readonly System.Globalization.CultureInfo _Culture = System.Globalization.CultureInfo.CurrentCulture;
    private readonly System.Globalization.CultureInfo _UiCulture = System.Globalization.CultureInfo.CurrentUICulture;

    public CultureScope(string name)
    {
        var chosen = System.Globalization.CultureInfo.GetCultureInfo(name);
        System.Globalization.CultureInfo.CurrentCulture = chosen;
        System.Globalization.CultureInfo.CurrentUICulture = chosen;
    }

    public void Dispose()
    {
        System.Globalization.CultureInfo.CurrentCulture = _Culture;
        System.Globalization.CultureInfo.CurrentUICulture = _UiCulture;
    }
}

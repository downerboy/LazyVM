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

    public int DashboardCalls { get; private set; }

    public List<(string? Name, bool HostOnly)> CheckCalls { get; } = [];

    public List<(string Name, int Tail)> LogCalls { get; } = [];

    public void Returns(params VMDashboard[] entries) => _Dashboards.Returns(entries);

    public void Throws(Exception exception) => _Dashboards.Throws(exception);

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel() => _Dashboards.WaitsForCancel();

    public void ReturnsChecks(params VMCheck[] results) => _Checks.Returns(results);

    public void ChecksThrow(Exception exception) => _Checks.Throws(exception);

    public void ChecksWaitForCancel() => _Checks.WaitsForCancel();

    public void ReturnsLog(params VMLogEntry[] entries) => _Logs.Returns(entries);

    public void LogThrows(Exception exception) => _Logs.Throws(exception);

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

    public IReadOnlyList<BuildPhase> Phases { get; set; } =
    [
        new(0, "HyperVHealth", "Check Hyper-V is working"),
        new(1, "Readiness", "Check the host is ready"),
        new(7, "Windows", "Install Windows and the tools"),
        new(8, "Finish", "Finish SQL Server and Visual Studio"),
    ];

    public IReadOnlyList<ConfigTemplate> Templates { get; set; } =
    [
        new("DevBox-latest", BuiltIn: false, Automatic: true),
        new("Developer", BuiltIn: true, Automatic: false),
        new("PlainWindows", BuiltIn: true, Automatic: false),
    ];

    public Exception? TemplatesFail { get; set; }

    public Exception? ModuleFolderFails { get; set; }

    public List<string> VMCalls { get; } = [];

    public List<string> StopCalls { get; } = [];

    /// <summary>The next Get-LazyVMDashboard -Name finds the VM with this run.</summary>
    public void ReturnsRun(VMRun? run, string name = "DevBox") => _VMs.Returns([Sample.VM(name) with { Run = run }]);

    public void VMThrows(Exception exception) => _VMs.Throws(exception);

    /// <summary>The next Stop-LazyVMBuild returns this run.</summary>
    public void StopReturns(VMRun? run) => _Stops.Returns(run is null ? [] : [run]);

    public void StopThrows(Exception exception) => _Stops.Throws(exception);

    public override async Task<VMDashboard?> GetVMAsync(string name, CancellationToken cancellationToken)
    {
        VMCalls.Add(name);
        return (await _VMs.Next(cancellationToken)).FirstOrDefault();
    }

    public override Task<IReadOnlyList<BuildPhase>> GetBuildPhasesAsync(CancellationToken cancellationToken) =>
        PhasesFail is { } failure ? Task.FromException<IReadOnlyList<BuildPhase>>(failure) : Task.FromResult(Phases);

    public override Task<IReadOnlyList<ConfigTemplate>> GetConfigTemplatesAsync(CancellationToken cancellationToken) =>
        TemplatesFail is { } failure ? Task.FromException<IReadOnlyList<ConfigTemplate>>(failure) : Task.FromResult(Templates);

    public override async Task<VMRun?> StopBuildAsync(string name, CancellationToken cancellationToken)
    {
        StopCalls.Add(name);
        return (await _Stops.Next(cancellationToken)).FirstOrDefault();
    }

    public List<string> MaintenanceCalls { get; } = [];

    /// <summary>Start-LazyVMMaintenance fails with this, as the module does when it starts nothing.</summary>
    public Exception? MaintenanceFails { get; set; }

    public Exception? PhasesFail { get; set; }

    public override Task StartMaintenanceAsync(string name, CancellationToken cancellationToken)
    {
        MaintenanceCalls.Add(name);
        return MaintenanceFails is { } failure ? Task.FromException(failure) : Task.CompletedTask;
    }

    public override Task<string> GetModuleFolderAsync(CancellationToken cancellationToken) =>
        ModuleFolderFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(@"C:\Program Files\LazyVM\Modules\LazyVM\6.20.0");

    private sealed class Answers<T>
    {
        private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<T>>>> _Queue = new();

        public void Returns(T[] values) => _Queue.Enqueue(_ => Task.FromResult<IReadOnlyList<T>>(values));

        public void Throws(Exception exception) => _Queue.Enqueue(_ => Task.FromException<IReadOnlyList<T>>(exception));

        public void WaitsForCancel() =>
            _Queue.Enqueue(async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return [];
            });

        public Task<IReadOnlyList<T>> Next(CancellationToken cancellationToken) => _Queue.Dequeue()(cancellationToken);
    }
}

/// <summary>Records the builds it is asked to start, without starting a process. Each build ends when the test says.</summary>
internal sealed class FakeBuildLauncher : BuildLauncher
{
    public List<(BuildRequest Request, string ModuleFolder)> Started { get; } = [];

    public TaskCompletionSource<BuildResult> Ending { get; private set; } = new();

    public Exception? Fails { get; set; }

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
internal sealed class FakeToolWindows(CommandRunner runner, BuildLauncher? launcher = null) : ToolWindows(runner, launcher ?? new FakeBuildLauncher(), new FixedClock(DateTimeOffset.UnixEpoch))
{
    private readonly Dictionary<ViewModelBase, Action> _Closers = [];

    public List<ViewModelBase> Shown { get; } = [];

    public List<ViewModelBase> BroughtToFront { get; } = [];

    public List<ViewModelBase> Closed { get; } = [];

    public void Close(ViewModelBase window) => _Closers[window]();

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

    protected override void BringToFront(ViewModelBase viewModel) => BroughtToFront.Add(viewModel);
}

/// <summary>Records the VM windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeVMWindowManager(ToolWindows tools) : VMWindowManager(tools)
{
    private readonly Dictionary<VMViewModel, Action> _Closers = [];

    public List<VMViewModel> Shown { get; } = [];

    public List<VMViewModel> BroughtToFront { get; } = [];

    public void Close(VMViewModel window) => _Closers[window]();

    protected override void Show(VMViewModel viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(VMViewModel viewModel) => BroughtToFront.Add(viewModel);
}

/// <summary>A clock that always says the same time.</summary>
internal sealed class FixedClock(DateTimeOffset now) : TimeProvider
{
    public override DateTimeOffset GetUtcNow() => now.ToUniversalTime();

    public override TimeZoneInfo LocalTimeZone => TimeZoneInfo.Utc;
}

internal static class Sample
{
    public static VMDashboard VM(string name = "DevBox", string state = "Running") => new()
    {
        Name = name,
        State = state,
        MaintenanceTask = "Registered",
        LastMaintenance = new DateTime(2026, 11, 12, 2, 10, 0),
        LastMaintenanceResult = "Succeeded",
        OpenFindings = 0,
    };

    public static VMCheck Check(string status = VMCheck.OK, string check = "LazyVM folder", string detail = @"C:\Users\me\LazyVM", string fix = "") =>
        new("Host", check, status, detail, fix);

    public static VMLogEntry Log(string level, string message, int minute = 0) =>
        new(new DateTime(2026, 11, 12, 2, minute, 5), level, message);
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

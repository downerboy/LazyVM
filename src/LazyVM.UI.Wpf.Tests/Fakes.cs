using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// A command runner that answers from memory instead of PowerShell. Each
/// command has its own queue of answers, and each call's parameters are kept.
/// </summary>
internal sealed class FakeCommandRunner : CommandRunner
{
    private readonly Answers<VMDashboard> dashboards = new();
    private readonly Answers<VMCheck> checks = new();
    private readonly Answers<VMLogEntry> logs = new();

    public int DashboardCalls { get; private set; }

    public List<(string? Name, bool HostOnly)> CheckCalls { get; } = [];

    public List<(string Name, int Tail)> LogCalls { get; } = [];

    public void Returns(params VMDashboard[] entries) => dashboards.Returns(entries);

    public void Throws(Exception exception) => dashboards.Throws(exception);

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel() => dashboards.WaitsForCancel();

    public void ReturnsChecks(params VMCheck[] results) => checks.Returns(results);

    public void ChecksThrow(Exception exception) => checks.Throws(exception);

    public void ChecksWaitForCancel() => checks.WaitsForCancel();

    public void ReturnsLog(params VMLogEntry[] entries) => logs.Returns(entries);

    public void LogThrows(Exception exception) => logs.Throws(exception);

    public override Task<IReadOnlyList<VMDashboard>> GetDashboardAsync(CancellationToken cancellationToken)
    {
        DashboardCalls++;
        return dashboards.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMCheck>> GetChecksAsync(string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        CheckCalls.Add((name, hostOnly));
        return checks.Next(cancellationToken);
    }

    public override Task<IReadOnlyList<VMLogEntry>> GetLogAsync(string name, int tail, CancellationToken cancellationToken)
    {
        LogCalls.Add((name, tail));
        return logs.Next(cancellationToken);
    }

    private sealed class Answers<T>
    {
        private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<T>>>> queue = new();

        public void Returns(T[] values) => queue.Enqueue(_ => Task.FromResult<IReadOnlyList<T>>(values));

        public void Throws(Exception exception) => queue.Enqueue(_ => Task.FromException<IReadOnlyList<T>>(exception));

        public void WaitsForCancel() =>
            queue.Enqueue(async token =>
            {
                await Task.Delay(Timeout.Infinite, token);
                return [];
            });

        public Task<IReadOnlyList<T>> Next(CancellationToken cancellationToken) => queue.Dequeue()(cancellationToken);
    }
}

/// <summary>Records the check and log windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeToolWindows(CommandRunner runner) : ToolWindows(runner)
{
    private readonly Dictionary<ViewModelBase, Action> closers = [];

    public List<ViewModelBase> Shown { get; } = [];

    public List<ViewModelBase> BroughtToFront { get; } = [];

    public void Close(ViewModelBase window) => closers[window]();

    protected override void Show(ViewModelBase viewModel, Action closed)
    {
        Shown.Add(viewModel);
        closers[viewModel] = closed;
    }

    protected override void BringToFront(ViewModelBase viewModel) => BroughtToFront.Add(viewModel);
}

/// <summary>Records the VM windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeVMWindowManager(ToolWindows tools) : VMWindowManager(tools)
{
    private readonly Dictionary<VMViewModel, Action> closers = [];

    public List<VMViewModel> Shown { get; } = [];

    public List<VMViewModel> BroughtToFront { get; } = [];

    public void Close(VMViewModel window) => closers[window]();

    protected override void Show(VMViewModel viewModel, Action closed)
    {
        Shown.Add(viewModel);
        closers[viewModel] = closed;
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
    private readonly System.Globalization.CultureInfo culture = System.Globalization.CultureInfo.CurrentCulture;
    private readonly System.Globalization.CultureInfo uiCulture = System.Globalization.CultureInfo.CurrentUICulture;

    public CultureScope(string name)
    {
        var chosen = System.Globalization.CultureInfo.GetCultureInfo(name);
        System.Globalization.CultureInfo.CurrentCulture = chosen;
        System.Globalization.CultureInfo.CurrentUICulture = chosen;
    }

    public void Dispose()
    {
        System.Globalization.CultureInfo.CurrentCulture = culture;
        System.Globalization.CultureInfo.CurrentUICulture = uiCulture;
    }
}

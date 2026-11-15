using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>A command runner that answers from memory instead of PowerShell.</summary>
internal sealed class FakeCommandRunner : CommandRunner
{
    private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<VMDashboard>>>> answers = new();

    public int DashboardCalls { get; private set; }

    public void Returns(params VMDashboard[] entries) =>
        answers.Enqueue(_ => Task.FromResult<IReadOnlyList<VMDashboard>>(entries));

    public void Throws(Exception exception) =>
        answers.Enqueue(_ => Task.FromException<IReadOnlyList<VMDashboard>>(exception));

    /// <summary>The next call waits until it is cancelled.</summary>
    public void WaitsForCancel() =>
        answers.Enqueue(async token =>
        {
            await Task.Delay(Timeout.Infinite, token);
            return [];
        });

    public override Task<IReadOnlyList<VMDashboard>> GetDashboardAsync(CancellationToken cancellationToken)
    {
        DashboardCalls++;
        return answers.Dequeue()(cancellationToken);
    }
}

/// <summary>Records the VM windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeVMWindowManager : VMWindowManager
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

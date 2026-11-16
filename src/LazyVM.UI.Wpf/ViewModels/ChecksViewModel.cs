namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The Checks window: what <c>Test-LazyVM</c> found, one row per check, with
/// what to do about each. Of the host, or of one VM. Changes nothing.
/// </summary>
public sealed class ChecksViewModel : ViewModelBase
{
    private readonly CommandRunner runner;
    private readonly bool hostOnly;
    private readonly RelayCommand runCommand;
    private readonly RelayCommand cancelCommand;
    private CancellationTokenSource? running;
    private IReadOnlyList<CheckRowViewModel> checks = [];
    private string status = string.Empty;

    /// <param name="vmName">The VM to check; empty for the host.</param>
    /// <param name="hostOnly">Check the host alone. Without it and without a VM, the only VM is checked too, or a note says there are none yet.</param>
    public ChecksViewModel(CommandRunner runner, string? vmName, bool hostOnly)
    {
        this.runner = runner;
        this.hostOnly = hostOnly;
        VMName = vmName;
        runCommand = new RelayCommand(() => _ = RunAsync(), () => !IsRunning);
        cancelCommand = new RelayCommand(() => running?.Cancel(), () => IsRunning);
    }

    /// <summary>The VM checked; empty for the host.</summary>
    public string? VMName { get; }

    public string Title => VMName is null ? "Host checks - LazyVM" : $"{VMName} checks - LazyVM";

    public string Heading => VMName is null ? "Checks of this host" : $"Checks of {VMName}";

    public IReadOnlyList<CheckRowViewModel> Checks
    {
        get => checks;
        private set => SetProperty(ref checks, value);
    }

    /// <summary>What the checks found, such as "8 checks: 1 failed, 2 warnings", or why they did not run.</summary>
    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public bool IsRunning => running is not null;

    public bool HasFailures => Checks.Any(row => row.Status == VMCheck.Failed);

    /// <summary>True when the last run failed as a whole, rather than any one check failing.</summary>
    public bool CouldNotRun { get; private set; }

    /// <summary>Runs the checks again.</summary>
    public RelayCommand RunCommand => runCommand;

    public RelayCommand CancelCommand => cancelCommand;

    public async Task RunAsync()
    {
        if (running is not null)
        {
            return;
        }
        using var cancel = new CancellationTokenSource();
        SetRunning(cancel);
        Status = "Checking";
        CouldNotRun = false;
        try
        {
            var results = await runner.GetChecksAsync(VMName, hostOnly, cancel.Token);
            Checks = results.Select(result => new CheckRowViewModel(result)).ToList();
            Status = Summary(Checks);
        }
        catch (OperationCanceledException)
        {
            Status = "Checks cancelled";
        }
        catch (Exception exception)
        {
            CouldNotRun = true;
            Checks = [];
            Status = "Checks could not run: " + exception.Message;
        }
        finally
        {
            SetRunning(null);
            OnPropertyChanged(nameof(HasFailures));
            OnPropertyChanged(nameof(CouldNotRun));
        }
    }

    private static string Summary(IReadOnlyList<CheckRowViewModel> rows)
    {
        var count = rows.Count == 1 ? "1 check" : $"{rows.Count} checks";
        var failed = rows.Count(row => row.Status == VMCheck.Failed);
        var warned = rows.Count(row => row.Status == VMCheck.Warning);
        var found = new List<string>();
        if (failed > 0)
        {
            found.Add($"{failed} failed");
        }
        if (warned > 0)
        {
            found.Add(warned == 1 ? "1 warning" : $"{warned} warnings");
        }
        return found.Count == 0 ? $"{count}: no problems found" : $"{count}: {string.Join(", ", found)}";
    }

    private void SetRunning(CancellationTokenSource? value)
    {
        running = value;
        OnPropertyChanged(nameof(IsRunning));
        runCommand.RaiseCanExecuteChanged();
        cancelCommand.RaiseCanExecuteChanged();
    }
}

/// <summary>One check: its status in words, what was checked and found, and the fix.</summary>
public sealed class CheckRowViewModel(VMCheck check)
{
    /// <summary>OK, INFO, WARN or FAIL, as the module gives it.</summary>
    public string Status => check.Status;

    /// <summary>The status in words, as the window shows it and Narrator reads it.</summary>
    public string StatusText => check.Status switch
    {
        VMCheck.OK => "OK",
        VMCheck.Info => "Note",
        VMCheck.Warning => "Warning",
        VMCheck.Failed => "Failed",
        _ => check.Status,
    };

    /// <summary>A shape for the status, so it is never told by color alone.</summary>
    public string Symbol => check.Status switch
    {
        VMCheck.OK => "✓",
        VMCheck.Warning => "▲",
        VMCheck.Failed => "✖",
        _ => "ℹ",
    };

    public string Area => check.Area;

    public string Check => check.Check;

    public string Detail => check.Detail;

    public string Fix => check.Fix;

    public bool HasFix => check.Fix.Length > 0;

    public bool NeedsAttention => check.Status is VMCheck.Warning or VMCheck.Failed;

    /// <summary>The row as a screen reader reads it: status, check, what was found, then the fix.</summary>
    public string AutomationName =>
        $"{StatusText}, {Check}: {Detail}" + (HasFix ? $". Fix: {Fix}" : string.Empty);
}

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The Checks window: what <c>Test-LazyVM</c> found, one row per check, with
/// what to do about each. Of the host, or of one VM. Changes nothing.
/// </summary>
public sealed class ChecksViewModel : ViewModelBase
{
    private readonly PowerShellCommandRunner _Runner;
    private readonly bool _HostOnly;
    private readonly RelayCommand _RunCommand;
    private readonly RelayCommand _CancelCommand;
    private CancellationTokenSource? _Running;
    private IReadOnlyList<CheckRowViewModel> _Checks = [];
    private string _Status = string.Empty;

    /// <param name="vmName">The VM to check; empty for the host.</param>
    /// <param name="hostOnly">Check the host alone. Without it and without a VM, the only VM is checked too, or a note says there are none yet.</param>
    public ChecksViewModel(PowerShellCommandRunner runner, string? vmName, bool hostOnly)
    {
        _Runner = runner;
        _HostOnly = hostOnly;
        VMName = vmName;
        _RunCommand = new RelayCommand(() => _ = RunAsync(), () => !IsRunning);
        _CancelCommand = new RelayCommand(() => _Running?.Cancel(), () => IsRunning);
    }

    /// <summary>The VM checked; empty for the host.</summary>
    public string? VMName
    {
        get;
    }

    public string Title => VMName is null ? "Host checks - LazyVM" : $"{VMName} checks - LazyVM";

    public string Heading => VMName is null ? "Checks of this host" : $"Checks of {VMName}";

    public IReadOnlyList<CheckRowViewModel> Checks
    {
        get => _Checks;
        private set => SetProperty(ref _Checks, value);
    }

    /// <summary>What the checks found, such as "8 checks: 1 failed, 2 warnings", or why they did not run.</summary>
    public string Status
    {
        get => _Status;
        private set => SetProperty(ref _Status, value);
    }

    public bool IsRunning => _Running is not null;

    public bool HasFailures => Checks.Any(row => row.Status == VMCheck.FAILED);

    /// <summary>True when the last run failed as a whole, rather than any one check failing.</summary>
    public bool CouldNotRun
    {
        get; private set;
    }

    /// <summary>Runs the checks again.</summary>
    public RelayCommand RunCommand => _RunCommand;

    public RelayCommand CancelCommand => _CancelCommand;

    public async Task RunAsync()
    {
        if (_Running is not null)
        {
            return;
        }
        using var cancel = new CancellationTokenSource();
        SetRunning(cancel);
        Status = "Checking";
        CouldNotRun = false;
        try
        {
            var results = await WorkAsync("Running the checks", () => _Runner.GetLazyVMChecksAsync(VMName, _HostOnly, cancel.Token));
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
        var failed = rows.Count(row => row.Status == VMCheck.FAILED);
        var warned = rows.Count(row => row.Status == VMCheck.WARNING);
        var found = new[]
        {
            failed > 0 ? $"{failed} failed" : null,
            warned switch { 0 => null, 1 => "1 warning", _ => $"{warned} warnings" },
        }.OfType<string>().ToList();
        return found.Count == 0 ? $"{count}: no problems found" : $"{count}: {string.Join(", ", found)}";
    }

    private void SetRunning(CancellationTokenSource? value)
    {
        _Running = value;
        OnPropertyChanged(nameof(IsRunning));
        _RunCommand.RaiseCanExecuteChanged();
        _CancelCommand.RaiseCanExecuteChanged();
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
        VMCheck.INFO => "Note",
        VMCheck.WARNING => "Warning",
        VMCheck.FAILED => "Failed",
        _ => check.Status,
    };

    /// <summary>A shape for the status, so it is never told by color alone.</summary>
    public string Symbol => check.Status switch
    {
        VMCheck.OK => "✓",
        VMCheck.WARNING => "▲",
        VMCheck.FAILED => "✖",
        _ => "ℹ",
    };

    public string Area => check.Area;

    public string Check => check.Check;

    public string Detail => check.Detail;

    public string Fix => check.Fix;

    public bool HasFix => check.Fix.Length > 0;

    public bool NeedsAttention => check.Status is VMCheck.WARNING or VMCheck.FAILED;

    /// <summary>The row as a screen reader reads it: status, check, what was found, then the fix.</summary>
    public string AutomationName =>
        $"{StatusText}, {Check}: {Detail}" + (HasFix ? $". Fix: {Fix}" : string.Empty);
}

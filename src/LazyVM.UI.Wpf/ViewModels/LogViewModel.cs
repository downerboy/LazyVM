using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The Log window: a VM's log, one entry per row, oldest first, read as
/// level, time and message, with a way to jump between warnings and errors.
/// </summary>
public sealed class LogViewModel : ViewModelBase
{
    /// <summary>How many of the newest entries are read: a log grows for as long as the VM lives.</summary>
    public const int TAIL = 1000;

    private readonly LazyVMLogRunner _Runner;
    private readonly Guid? _VMId;
    private readonly RelayCommand _ReloadCommand;
    private readonly RelayCommand _NextProblemCommand;
    private readonly RelayCommand _PreviousProblemCommand;
    private IReadOnlyList<LogEntryRowViewModel> _Entries = [];
    private LogEntryRowViewModel? _SelectedEntry;
    private string _Status = string.Empty;
    private bool _IsLoading;

    /// <param name="vmId">The VM's Hyper-V Id; empty for a VM not built yet.</param>
    public LogViewModel(LazyVMLogRunner runner, Guid? vmId, string vmName)
    {
        _Runner = runner;
        _VMId = vmId;
        VMName = vmName;
        _ReloadCommand = new RelayCommand(() => _ = LoadAsync(), () => !IsLoading);
        _NextProblemCommand = new RelayCommand(() => JumpToProblem(1), () => Entries.Count > 0);
        _PreviousProblemCommand = new RelayCommand(() => JumpToProblem(-1), () => Entries.Count > 0);
    }

    /// <summary>Raised when an entry is selected by a jump, so the view can move keyboard focus to it and Narrator reads it.</summary>
    public event Action<LogEntryRowViewModel>? JumpedTo;

    public string VMName
    {
        get;
    }

    public string Title => $"{VMName} log - LazyVM";

    public string Heading => $"Log of {VMName}";

    public IReadOnlyList<LogEntryRowViewModel> Entries
    {
        get => _Entries;
        private set
        {
            if (SetProperty(ref _Entries, value))
            {
                _NextProblemCommand.RaiseCanExecuteChanged();
                _PreviousProblemCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public LogEntryRowViewModel? SelectedEntry
    {
        get => _SelectedEntry;
        set => SetProperty(ref _SelectedEntry, value);
    }

    /// <summary>How many entries, warnings and errors were read, or why the log could not be.</summary>
    public string Status
    {
        get => _Status;
        private set => SetProperty(ref _Status, value);
    }

    public bool IsLoading
    {
        get => _IsLoading;
        private set
        {
            if (SetProperty(ref _IsLoading, value))
            {
                _ReloadCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>Reads the log again, such as while a build is writing to it.</summary>
    public RelayCommand ReloadCommand => _ReloadCommand;

    /// <summary>Selects the next warning or error after the selected entry (F8).</summary>
    public RelayCommand NextProblemCommand => _NextProblemCommand;

    /// <summary>Selects the warning or error before the selected entry (Shift+F8).</summary>
    public RelayCommand PreviousProblemCommand => _PreviousProblemCommand;

    /// <summary>Reads the newest entries and selects the newest one.</summary>
    public async Task LoadAsync()
    {
        if (IsLoading)
        {
            return;
        }
        IsLoading = true;
        Status = "Reading the log";
        try
        {
            var read = await WorkAsync("Reading the log", () => _Runner.GetLazyVMLogAsync(_VMId, VMName, TAIL, CancellationToken.None));
            Entries = read.Select(entry => new LogEntryRowViewModel(entry)).ToList();
            Status = Summary(Entries);
            SelectedEntry = Entries.Count > 0 ? Entries[^1] : null;
            if (SelectedEntry is { } newest)
            {
                JumpedTo?.Invoke(newest);
            }
        }
        catch (Exception exception)
        {
            // The view shows any failure the same way; the entries already read are kept.
            Status = "The log could not be read: " + exception.Message;
        }
        finally
        {
            IsLoading = false;
        }
    }

    private void JumpToProblem(int direction)
    {
        var start = SelectedEntry is null
            ? (direction > 0 ? 0 : Entries.Count - 1)
            : IndexOf(SelectedEntry) + direction;
        // Forward from start, or back from it; a start outside the list finds nothing.
        var next = direction > 0
            ? Entries.Skip(start).FirstOrDefault(entry => entry.IsProblem)
            : Entries.Take(start + 1).LastOrDefault(entry => entry.IsProblem);
        if (next is not null)
        {
            SelectedEntry = next;
            JumpedTo?.Invoke(next);
            return;
        }
        Status = direction > 0 ? "No warnings or errors after this entry" : "No warnings or errors before this entry";
    }

    private int IndexOf(LogEntryRowViewModel entry)
    {
        return Entries.Select((row, index) => ReferenceEquals(row, entry) ? index : -1).FirstOrDefault(index => index >= 0, -1);
    }

    private static string Summary(IReadOnlyList<LogEntryRowViewModel> rows)
    {
        if (rows.Count == 0)
        {
            return "No log entries yet";
        }
        var count = rows.Count switch
        {
            1 => "1 entry",
            TAIL => $"The last {TAIL} entries",
            _ => $"{rows.Count} entries",
        };
        var errors = rows.Count(row => row.Level == VMLogEntry.ERROR);
        var warnings = rows.Count(row => row.Level == VMLogEntry.WARNING);
        var found = new[]
        {
            errors switch { 0 => null, 1 => "1 error", _ => $"{errors} errors" },
            warnings switch { 0 => null, 1 => "1 warning", _ => $"{warnings} warnings" },
        }.OfType<string>().ToList();
        return found.Count == 0 ? $"{count}: no warnings or errors" : $"{count}: {string.Join(", ", found)}";
    }
}

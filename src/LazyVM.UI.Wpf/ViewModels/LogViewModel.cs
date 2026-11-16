using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The Log window: a VM's log, one entry per row, oldest first, read as
/// level, time and message, with a way to jump between warnings and errors.
/// </summary>
public sealed class LogViewModel : ViewModelBase
{
    /// <summary>How many of the newest entries are read: a log grows for as long as the VM lives.</summary>
    public const int Tail = 1000;

    private readonly CommandRunner runner;
    private readonly RelayCommand reloadCommand;
    private readonly RelayCommand nextProblemCommand;
    private readonly RelayCommand previousProblemCommand;
    private IReadOnlyList<LogEntryRowViewModel> entries = [];
    private LogEntryRowViewModel? selectedEntry;
    private string status = string.Empty;
    private bool isLoading;

    public LogViewModel(CommandRunner runner, string vmName)
    {
        this.runner = runner;
        VMName = vmName;
        reloadCommand = new RelayCommand(() => _ = LoadAsync(), () => !IsLoading);
        nextProblemCommand = new RelayCommand(() => JumpToProblem(1), () => Entries.Count > 0);
        previousProblemCommand = new RelayCommand(() => JumpToProblem(-1), () => Entries.Count > 0);
    }

    /// <summary>Raised when an entry is selected by a jump, so the view can move keyboard focus to it and Narrator reads it.</summary>
    public event Action<LogEntryRowViewModel>? JumpedTo;

    public string VMName { get; }

    public string Title => $"{VMName} log - LazyVM";

    public string Heading => $"Log of {VMName}";

    public IReadOnlyList<LogEntryRowViewModel> Entries
    {
        get => entries;
        private set
        {
            if (SetProperty(ref entries, value))
            {
                nextProblemCommand.RaiseCanExecuteChanged();
                previousProblemCommand.RaiseCanExecuteChanged();
            }
        }
    }

    public LogEntryRowViewModel? SelectedEntry
    {
        get => selectedEntry;
        set => SetProperty(ref selectedEntry, value);
    }

    /// <summary>How many entries, warnings and errors were read, or why the log could not be.</summary>
    public string Status
    {
        get => status;
        private set => SetProperty(ref status, value);
    }

    public bool IsLoading
    {
        get => isLoading;
        private set
        {
            if (SetProperty(ref isLoading, value))
            {
                reloadCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>Reads the log again, such as while a build is writing to it.</summary>
    public RelayCommand ReloadCommand => reloadCommand;

    /// <summary>Selects the next warning or error after the selected entry (F8).</summary>
    public RelayCommand NextProblemCommand => nextProblemCommand;

    /// <summary>Selects the warning or error before the selected entry (Shift+F8).</summary>
    public RelayCommand PreviousProblemCommand => previousProblemCommand;

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
            var read = await runner.GetLogAsync(VMName, Tail, CancellationToken.None);
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
        for (var index = start; index >= 0 && index < Entries.Count; index += direction)
        {
            if (Entries[index].IsProblem)
            {
                SelectedEntry = Entries[index];
                JumpedTo?.Invoke(Entries[index]);
                return;
            }
        }
        Status = direction > 0 ? "No warnings or errors after this entry" : "No warnings or errors before this entry";
    }

    private int IndexOf(LogEntryRowViewModel entry)
    {
        for (var index = 0; index < Entries.Count; index++)
        {
            if (ReferenceEquals(Entries[index], entry))
            {
                return index;
            }
        }
        return -1;
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
            Tail => $"The last {Tail} entries",
            _ => $"{rows.Count} entries",
        };
        var errors = rows.Count(row => row.Level == VMLogEntry.Error);
        var warnings = rows.Count(row => row.Level == VMLogEntry.Warning);
        var found = new List<string>();
        if (errors > 0)
        {
            found.Add(errors == 1 ? "1 error" : $"{errors} errors");
        }
        if (warnings > 0)
        {
            found.Add(warnings == 1 ? "1 warning" : $"{warnings} warnings");
        }
        return found.Count == 0 ? $"{count}: no warnings or errors" : $"{count}: {string.Join(", ", found)}";
    }
}

/// <summary>One entry of the log.</summary>
public sealed class LogEntryRowViewModel(VMLogEntry entry)
{
    /// <summary>Info, OK, Warning, Error or Phase.</summary>
    public string Level => entry.Level;

    /// <summary>The day and time to the second, such as "12 November 2026 02:10:05".</summary>
    public string TimeText => entry.Time is { } time
        ? time.ToString("d MMMM yyyy ", CultureInfo.CurrentCulture) + time.ToString("T", CultureInfo.CurrentCulture)
        : DashboardText.NotKnown;

    public string Message => entry.Message;

    public bool IsProblem => entry.Level is VMLogEntry.Warning or VMLogEntry.Error;

    /// <summary>The entry as a screen reader reads it: level, time, then message.</summary>
    public string AutomationName => $"{Level}, {TimeText}, {Message}";
}

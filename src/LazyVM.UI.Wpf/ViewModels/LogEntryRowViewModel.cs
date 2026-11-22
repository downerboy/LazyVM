using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One entry of the log.</summary>
public sealed class LogEntryRowViewModel(VMLogEntry entry)
{
    /// <summary>Info, OK, Warning, Error or Phase.</summary>
    public string Level => entry.Level;

    /// <summary>The day and time to the second, such as "12 November 2026 02:10:05".</summary>
    public string TimeText => entry.Time is { } time
        ? time.ToString("d MMMM yyyy ", CultureInfo.CurrentCulture) + time.ToString("T", CultureInfo.CurrentCulture)
        : DashboardText.NOT_KNOWN;

    public string Message => entry.Message;

    public bool IsProblem => entry.Level is VMLogEntry.WARNING or VMLogEntry.ERROR;

    /// <summary>The entry as a screen reader reads it: level, time, then message.</summary>
    public string AutomationName => $"{Level}, {TimeText}, {Message}";
}

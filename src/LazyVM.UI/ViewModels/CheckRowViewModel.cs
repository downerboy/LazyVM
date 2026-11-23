namespace LazyVM.UI.ViewModels;

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

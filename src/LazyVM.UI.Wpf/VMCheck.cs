namespace LazyVM.UI.Wpf;

/// <summary>
/// One check <c>Test-LazyVM</c> made, as plain values: what was checked,
/// what was found, and what to do about it.
/// </summary>
/// <param name="Area">Host, VM, Guest or Schedule.</param>
/// <param name="Check">What was checked, such as "LazyVM folder".</param>
/// <param name="Status">OK, INFO, WARN or FAIL.</param>
/// <param name="Detail">What was found.</param>
/// <param name="Fix">What to do about it, ending with the command to run; empty when there is no known fix.</param>
public sealed record VMCheck(string Area, string Check, string Status, string Detail, string Fix)
{
    public const string OK = "OK";
    public const string Info = "INFO";
    public const string Warning = "WARN";
    public const string Failed = "FAIL";
}

/// <summary>One entry of a VM's log, as <c>Get-LazyVMLog</c> reads it.</summary>
/// <param name="Time">When it was written; empty when it could not be read.</param>
/// <param name="Level">Info, OK, Warning, Error or Phase.</param>
/// <param name="Message">The message; it may run over several lines.</param>
public sealed record VMLogEntry(DateTime? Time, string Level, string Message)
{
    public const string Warning = "Warning";
    public const string Error = "Error";
}

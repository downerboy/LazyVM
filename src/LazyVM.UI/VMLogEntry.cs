namespace LazyVM.UI;

/// <summary>One entry of a VM's log, as <c>Get-LazyVMLog</c> reads it.</summary>
/// <param name="Time">When it was written; empty when it could not be read.</param>
/// <param name="Level">Info, OK, Warning, Error or Phase.</param>
/// <param name="Message">The message; it may run over several lines.</param>
public sealed record VMLogEntry(DateTime? Time, string Level, string Message)
{
    public const string WARNING = "Warning";
    public const string ERROR = "Error";
}

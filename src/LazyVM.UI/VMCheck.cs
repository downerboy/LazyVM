namespace LazyVM.UI;

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
    public const string INFO = "INFO";
    public const string WARNING = "WARN";
    public const string FAILED = "FAIL";
}
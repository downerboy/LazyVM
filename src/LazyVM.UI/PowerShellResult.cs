using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>
/// What one command wrote, not yet judged: its output, its errors and the
/// text of its warnings. <see cref="PowerShellCommandRunner"/> decides
/// whether the errors are a failure.
/// </summary>
public sealed record PowerShellResult(IReadOnlyList<PSObject> Output, IReadOnlyList<ErrorRecord> Errors, IReadOnlyList<string> Warnings);

namespace LazyVM.UI;

/// <summary>What <c>Export-LazyVMRecoveryKey</c> did: the file it wrote, and the warnings it gave, such as for a file in OneDrive.</summary>
public sealed record RecoveryKeyExport(string Path, IReadOnlyList<string> Warnings);

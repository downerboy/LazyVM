namespace LazyVM.UI;

/// <summary>
/// One restore point <c>Get-LazyVMRestorePoint</c> lists: a tooling version
/// with its checkpoint. <see cref="Stamp"/> is what <c>Restore-LazyVMTooling
/// -RestorePoint</c> takes, such as 20261008-193000. Without its tooling
/// list, a point cannot be restored.
/// </summary>
public sealed record VMRestorePoint(string Stamp, DateTime? Taken, bool HasToolingList);

namespace LazyVM.UI;

/// <summary>
/// One BitLocker recovery key <c>Get-LazyVMRecoveryKey</c> lists, without
/// its password: the disk, its GPT disk GUID, the key ID BitLocker's
/// recovery screen shows (empty until the guest has reported it), when it
/// was recorded, and whether the last export held it.
/// </summary>
public sealed record VMRecoveryKey(string Disk, string DiskGuid, string KeyId, DateTime? Recorded, bool Exported);

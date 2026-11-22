namespace LazyVM.UI;

/// <summary>
/// A virtual hard disk attached to a VM. 
/// Sizes are in bytes.
/// </summary>
public sealed record VMDisk(string DiskName,
                            string DiskPath,
                            long UsedDiskSpace,
                            long MaximumDiskSpace);

namespace LazyVM.UI.Wpf;

/// <summary>
/// What <c>Get-LazyVMRemovalPlan</c> says deleting a VM would delete and
/// keep, as plain values. Sizes are in bytes.
/// </summary>
public sealed record RemovalPlan
{
    public required string Name
    {
        get; init;
    }

    /// <summary>The Hyper-V VM's state, such as Running or Off; empty when there is no Hyper-V VM to remove.</summary>
    public string? HyperVState
    {
        get; init;
    }

    public int CheckpointCount
    {
        get; init;
    }

    /// <summary>
    /// The scheduled tasks that go, such as
    /// the VM's maintenance task.
    /// </summary>
    public IReadOnlyList<string> ScheduledTasks { get; init; } = [];

    public IReadOnlyList<RemovalItem> Items { get; init; } = [];

    /// <summary>
    /// The space every item takes together.
    /// </summary>
    public long TotalSize
    {
        get; init;
    }

    public IReadOnlyList<KeptItem> Kept { get; init; } = [];

    /// <summary>The disks holding your own work that go too: the Dev Drive and the User disk.</summary>
    public IReadOnlyList<WorkDisk> WorkDisks { get; init; } = [];

    /// <summary>True when nothing of the VM is left to delete.</summary>
    public bool IsEmpty => HyperVState is null && ScheduledTasks.Count == 0 && Items.Count == 0;
}

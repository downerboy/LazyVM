using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the restore runner reads a VM's restore points.</summary>
public sealed class LazyVMRestoreRunnerTests
{
    [Fact]
    public void ToRestorePoint_ReadsEveryField()
    {
        var point = LazyVMRestoreRunner.LazyVMToRestorePoint(Entry(
            ("Name", "DevBox"),
            ("RestorePoint", "20261008-193000"),
            ("Taken", new DateTime(2026, 10, 8, 19, 30, 0)),
            ("Checkpoint", "LazyVM tooling 20261008-193000"),
            ("HasToolingList", false)));

        Assert.Equal(new VMRestorePoint("20261008-193000", new DateTime(2026, 10, 8, 19, 30, 0), HasToolingList: false), point);
    }
}

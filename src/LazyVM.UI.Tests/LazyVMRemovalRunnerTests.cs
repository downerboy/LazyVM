using System.Management.Automation;

using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the removal runner reads what deleting a VM removes, and closes the VM's session once it is deleted.</summary>
public sealed class LazyVMRemovalRunnerTests
{
    private static readonly Guid _DEV_BOX = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");

    [Fact]
    public async Task RemoveLazyVMAsync_RunsInTheVMsSession_ThenClosesIt()
    {
        using var sessions = new ScriptedSessions();
        var before = sessions.ForVM(_DEV_BOX);

        await new LazyVMRemovalRunner(sessions).RemoveLazyVMAsync(_DEV_BOX, "DevBox");

        Assert.Same(before, sessions.Call.Session);
        Assert.Equal("Remove-LazyVM", sessions.Call.Command);
        Assert.NotSame(before, sessions.ForVM(_DEV_BOX));
    }

    [Fact]
    public async Task RemoveLazyVMAsync_ThatRemovedOnlyPart_StillClosesTheVMsSession()
    {
        // Only part removed may still be the Hyper-V VM gone, with its Id.
        using var sessions = new ScriptedSessions { Fails = new InvalidOperationException("The folder is in use.") };
        var before = sessions.ForVM(_DEV_BOX);

        await Assert.ThrowsAsync<InvalidOperationException>(() => new LazyVMRemovalRunner(sessions).RemoveLazyVMAsync(_DEV_BOX, "DevBox"));

        Assert.NotSame(before, sessions.ForVM(_DEV_BOX));
    }

    [Fact]
    public void ToRemovalPlan_ReadsEveryField()
    {
        var plan = LazyVMRemovalRunner.LazyVMRemovalPlan(Entry(
            ("Name", "DevBox"),
            ("HyperVState", "Running"),
            ("CheckpointCount", 2),
            ("Tasks", new object[] { @"LazyVM\DevBox maintenance" }),
            ("Items", new object[]
            {
                Entry(("Kind", "Folder"), ("Path", @"C:\LazyVM\DevBox"), ("Size", 1073741824.0)),
                Entry(("Kind", "File"), ("Path", @"E:\Disks\DevBox\SQL.vhdx"), ("Size", 2048.0)),
            }),
            ("Total", 1073743872.0),
            ("Kept", new object[] { Entry(("Path", @"C:\LazyVM\Shared"), ("Reason", "Every VM uses it.")) }),
            ("WorkDisks", new object[] { Entry(("Name", "The Dev Drive"), ("Path", @"C:\LazyVM\DevBox\Dev.vhdx"), ("Size", 512.0), ("Advice", "Push first.")) })));

        Assert.Equal("DevBox", plan.Name);
        Assert.Equal("Running", plan.HyperVState);
        Assert.Equal(2, plan.CheckpointCount);
        Assert.Equal([@"LazyVM\DevBox maintenance"], plan.ScheduledTasks);
        Assert.Equal(
            [new RemovalItem("Folder", @"C:\LazyVM\DevBox", 1073741824), new RemovalItem("File", @"E:\Disks\DevBox\SQL.vhdx", 2048)],
            plan.Items);
        Assert.Equal(1073743872, plan.TotalSize);
        Assert.Equal([new KeptItem(@"C:\LazyVM\Shared", "Every VM uses it.")], plan.Kept);
        Assert.Equal([new WorkDisk("The Dev Drive", @"C:\LazyVM\DevBox\Dev.vhdx", 512, "Push first.")], plan.WorkDisks);
    }

    [Fact]
    public void ToRemovalPlan_WithNothingLeft_IsEmpty()
    {
        var plan = LazyVMRemovalRunner.LazyVMRemovalPlan(Entry(
            ("Name", "DevBox"),
            ("HyperVState", null),
            ("CheckpointCount", 0),
            ("Tasks", Array.Empty<object>()),
            ("Items", Array.Empty<object>()),
            ("Total", 0.0),
            ("Kept", Array.Empty<object>()),
            ("WorkDisks", Array.Empty<object>())));

        Assert.True(plan.IsEmpty);
        Assert.Null(plan.HyperVState);
        Assert.Empty(plan.WorkDisks);
    }
}

using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class RemovalViewModelTests : IDisposable
{
    private const long _MB = 1024L * 1024;
    private const long _GB = 1024 * _MB;

    private readonly CultureScope _Culture = new("en-GB");

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static RemovalPlan Plan()
    {
        return new()
        {
            Name = "DevBox",
            HyperVState = "Running",
            CheckpointCount = 2,
            Tasks = [@"LazyVM\DevBox maintenance"],
            Items =
            [
                new("Folder", @"C:\LazyVM\DevBox", 90 * _GB),
                new(RemovalItem.FILE, @"E:\Disks\DevBox\SQL.vhdx", 10 * _GB),
            ],
            Total = 100 * _GB,
            Kept = [new(@"C:\LazyVM\Shared\Win11.iso", "Every VM uses it.")],
            WorkDisks =
            [
                new("The Dev Drive", @"C:\LazyVM\DevBox\Disks\Dev.vhdx", 40 * _GB, "It holds this VM's source code. Push or copy anything not yet in source control first."),
                new("The User disk", @"C:\LazyVM\DevBox\Disks\User.vhdx", 5 * _GB, "It holds this VM's Documents. Copy anything you need first."),
            ],
        };
    }

    [Fact]
    public void Lines_PutTheWorkDiskWarningsFirst_ThenWhatGoes_ThenWhatIsKept()
    {
        var removal = new RemovalViewModel(Plan());

        Assert.Equal(
        [
            @"Warning: The Dev Drive goes too, 40 GB, C:\LazyVM\DevBox\Disks\Dev.vhdx. It holds this VM's source code. Push or copy anything not yet in source control first.",
            @"Warning: The User disk goes too, 5 GB, C:\LazyVM\DevBox\Disks\User.vhdx. It holds this VM's Documents. Copy anything you need first.",
            "The Hyper-V VM DevBox, Running, with 2 checkpoints. It is turned off first.",
            @"Scheduled task LazyVM\DevBox maintenance",
            @"Folder C:\LazyVM\DevBox, 90 GB",
            @"File E:\Disks\DevBox\SQL.vhdx, 10 GB",
            "100 GB in all.",
            @"Kept: C:\LazyVM\Shared\Win11.iso. Every VM uses it.",
        ], removal.Lines.Select(line => line.Text));
        Assert.Equal([true, true, false, false, false, false, false, false], removal.Lines.Select(line => line.IsWarning));
    }

    [Fact]
    public void AVMThatIsOff_WithOneCheckpoint_IsNotTurnedOff()
    {
        var removal = new RemovalViewModel(Plan() with { HyperVState = "Off", CheckpointCount = 1 });

        Assert.Contains("The Hyper-V VM DevBox, Off, with 1 checkpoint.", removal.Lines.Select(line => line.Text));
    }

    [Fact]
    public void AVMWithNoCheckpoints_SaysNothingOfThem()
    {
        var removal = new RemovalViewModel(Plan() with { HyperVState = "Off", CheckpointCount = 0 });

        Assert.Contains("The Hyper-V VM DevBox, Off.", removal.Lines.Select(line => line.Text));
    }

    [Theory]
    [InlineData(0, "less than 1 MB")]
    [InlineData(300 * 1024, "less than 1 MB")]
    [InlineData(12 * _MB, "12 MB")]
    [InlineData(1536 * _MB, "1.5 GB")]
    public void SmallFiles_AreShownInMB(long size, string said)
    {
        var removal = new RemovalViewModel(new RemovalPlan
        {
            Name = "DevBox",
            Items = [new(RemovalItem.FILE, @"C:\Logs\DevBox.log", size)],
            Total = size,
        });

        Assert.Contains($@"File C:\Logs\DevBox.log, {said}", removal.Lines.Select(line => line.Text));
    }

    [Fact]
    public void APlanWithNothingLeft_SaysSo()
    {
        var removal = new RemovalViewModel(new RemovalPlan { Name = "DevBox" });

        Assert.Equal(["Nothing of DevBox is left to delete."], removal.Lines.Select(line => line.Text));
    }

    [Fact]
    public void TheQuestion_AndTheTitle_NameTheVM()
    {
        var removal = new RemovalViewModel(Plan());

        Assert.Equal("Do you really want to delete this VM?", removal.Question);
        Assert.Equal("Delete DevBox - LazyVM", removal.Title);
        Assert.Equal("DevBox", removal.Name);
        Assert.Equal("Deleting DevBox cannot be undone. This is what goes, and what is kept:", removal.Heading);
    }

    [Fact]
    public void Left_NamesWhatIsStillThere()
    {
        Assert.Equal(
            @"Still there: the Hyper-V VM DevBox, scheduled task LazyVM\DevBox maintenance, C:\LazyVM\DevBox, E:\Disks\DevBox\SQL.vhdx.",
            RemovalViewModel.Left(Plan()));
        Assert.Equal(string.Empty, RemovalViewModel.Left(new RemovalPlan { Name = "DevBox" }));
    }
}

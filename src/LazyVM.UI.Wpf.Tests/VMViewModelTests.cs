using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class VMViewModelTests : IDisposable
{
    private const long GB = 1024L * 1024 * 1024;

    private readonly CultureScope culture = new("en-GB");
    private readonly FakeCommandRunner runner = new();
    private readonly FakeToolWindows tools;

    public VMViewModelTests()
    {
        tools = new FakeToolWindows(runner);
    }

    public void Dispose() => culture.Dispose();

    private VMViewModel Open(VMDashboard entry) => new(entry, tools);

    [Fact]
    public void Checks_OpensTheVMsChecks()
    {
        runner.ReturnsChecks(Sample.Check());
        var vm = Open(Sample.VM("DevEnv"));

        vm.ChecksCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<ChecksViewModel>(Assert.Single(tools.Shown)).VMName);
        Assert.Equal([("DevEnv", false)], runner.CheckCalls);
    }

    [Fact]
    public void Log_OpensTheVMsLog()
    {
        runner.ReturnsLog();
        var vm = Open(Sample.VM("DevEnv"));

        vm.LogCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<LogViewModel>(Assert.Single(tools.Shown)).VMName);
    }

    private static string? Detail(VMViewModel vm, string label) =>
        vm.Details.SingleOrDefault(detail => detail.Label == label)?.Value;

    [Fact]
    public void Title_NamesTheVM()
    {
        var vm = Open(Sample.VM("DevEnv"));

        Assert.Equal("DevEnv", vm.Name);
        Assert.Equal("DevEnv - LazyVM", vm.Title);
    }

    [Fact]
    public void Memory_IsShownInGB()
    {
        var vm = Open(Sample.VM() with { MemoryAssigned = 8 * GB });

        Assert.Equal("8 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNone()
    {
        var vm = Open(Sample.VM(state: "Off") with { MemoryAssigned = 0 });

        Assert.Equal("None", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Disks_ShowTheTotalAndEachDisk()
    {
        var vm = Open(Sample.VM() with
        {
            DiskSpaceUsed = 214 * GB + GB / 2,
            Disks =
            [
                new VMDisk("DevBox.vhdx", @"D:\VMs\DevBox\DevBox.vhdx", 200 * GB, 512 * GB),
                new VMDisk("Data.vhdx", @"D:\VMs\DevBox\Data.vhdx", 14 * GB + GB / 2, 64 * GB),
            ],
        });

        Assert.Equal("214.5 GB on 2 disks", Detail(vm, "Disk space used"));
        Assert.Equal(@"200 GB used of 512 GB, D:\VMs\DevBox\DevBox.vhdx", Detail(vm, "Disk DevBox.vhdx"));
        Assert.Equal(@"14.5 GB used of 64 GB, D:\VMs\DevBox\Data.vhdx", Detail(vm, "Disk Data.vhdx"));
    }

    [Fact]
    public void ADiskWhoseCheckpointsTakeMoreThanItsSize_SaysWhy()
    {
        // Used counts the disk's checkpoint files too, so it can be more than the disk's size.
        var vm = Open(Sample.VM() with
        {
            DiskSpaceUsed = 148 * GB,
            Disks = [new VMDisk("DevBox-OS.vhdx", @"D:\VMs\DevBox\DevBox-OS.vhdx", 148 * GB, 120 * GB)],
        });

        Assert.Equal(@"148 GB used with its checkpoints, disk size 120 GB, D:\VMs\DevBox\DevBox-OS.vhdx", Detail(vm, "Disk DevBox-OS.vhdx"));
    }

    [Fact]
    public void LastMaintenance_GivesResultDayAndTime()
    {
        var vm = Open(Sample.VM());

        Assert.Equal("Succeeded, 12 November 2026 02:10", Detail(vm, "Last maintenance"));
    }

    [Fact]
    public void Maintenance_GivesTimeAndTask()
    {
        var vm = Open(Sample.VM() with { MaintenanceTime = "02:00" });

        Assert.Equal("Daily at 02:00, task registered", Detail(vm, "Maintenance"));
    }

    [Fact]
    public void SecurityScan_GivesDayAndOpenFindings()
    {
        var vm = Open(Sample.VM() with { LastSecurityScan = new DateTime(2026, 11, 13, 3, 0, 0), OpenFindings = 3 });

        Assert.Equal("13 November 2026 03:00, 3 open findings", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void SecurityScan_BeforeTheFirstScan()
    {
        var vm = Open(Sample.VM() with { LastSecurityScan = null, OpenFindings = null });

        Assert.Equal("Not scanned yet", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void GreenTemplate_GivesNameAndWhenItChanged()
    {
        var vm = Open(Sample.VM() with { GreenTemplate = "DevBox-latest", GreenTemplateUpdated = new DateTime(2026, 11, 13, 3, 5, 0) });

        Assert.Equal("DevBox-latest, updated 13 November 2026 03:05", Detail(vm, "Green template"));
    }

    [Fact]
    public void MissingValues_ReadAsNotKnown()
    {
        var vm = Open(new VMDashboard { Name = "DevBox", State = "Unknown" });

        Assert.Equal("Not known", Detail(vm, "Created"));
        Assert.Equal("Not known", Detail(vm, "Memory in use"));
        Assert.Equal("Not known", Detail(vm, "Disk space used"));
    }

    [Fact]
    public void AVMNotBuiltYet_SaysSoInsteadOfNotKnown()
    {
        var vm = Open(new VMDashboard { Name = "TestBox", State = "Not built" });

        Assert.Equal("Not built yet", Detail(vm, "Created"));
        Assert.Equal("Not built yet", Detail(vm, "Memory in use"));
        Assert.Equal("Not built yet", Detail(vm, "Disk space used"));
    }

    [Fact]
    public void WhatCouldNotBeRead_IsListed()
    {
        var vm = Open(Sample.VM() with { Problems = ["Hyper-V: access denied", "Disks: access denied"] });

        Assert.Equal(
            ["Hyper-V: access denied", "Disks: access denied"],
            vm.Details.Where(detail => detail.Label == "Could not read").Select(detail => detail.Value));
    }

    [Fact]
    public void EachDetail_ReadsAsLabelAndValue()
    {
        var vm = Open(Sample.VM());

        Assert.Equal("State: Running", vm.Details.Single(detail => detail.Label == "State").AutomationName);
    }

    [Fact]
    public void Update_ReplacesTheDetails()
    {
        var vm = Open(Sample.VM(state: "Running"));
        var changed = new List<string?>();
        vm.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.Update(Sample.VM(state: "Off"));

        Assert.Equal("Off", vm.State);
        Assert.Equal("Off", Detail(vm, "State"));
        Assert.Contains(changed, name => string.IsNullOrEmpty(name));
    }

    [Fact]
    public void BuildProgress_IsOfferedOnlyWhileABuildRuns()
    {
        var idle = Open(Sample.VM());
        var building = Open(Sample.VM() with { Run = new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 } });
        var maintaining = Open(Sample.VM() with { Run = new VMRun { Command = "Maintenance", Status = VMRun.Running, ProcessId = 9 } });

        Assert.False(idle.BuildProgressCommand.CanExecute(null));
        Assert.True(building.BuildProgressCommand.CanExecute(null));
        Assert.False(maintaining.BuildProgressCommand.CanExecute(null));
        Assert.True(maintaining.IsBusy);
        Assert.False(idle.IsBusy);
    }

    [Fact]
    public void BuildProgress_OpensTheProgressOfTheRunningBuild()
    {
        runner.ReturnsRun(new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 }, "DevEnv");
        var vm = Open(Sample.VM("DevEnv") with { Run = new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 } });

        vm.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(tools.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        progress.StopFollowing();
    }

    [Theory]
    [InlineData(null, null, false, "Nothing")]
    [InlineData("Build", 7, false, "Build, in phase 7 (Windows)")]
    [InlineData("Build", 7, true, "Build, stopping")]
    [InlineData("Maintenance", null, false, "Maintenance")]
    public void RunningNow_SaysWhatIsRunning(string? command, int? phase, bool stopping, string expected)
    {
        var run = command is null ? null : new VMRun
        {
            Command = command, Status = VMRun.Running, ProcessId = 9, Phase = phase, PhaseName = phase is null ? null : "Windows", StopRequested = stopping,
        };

        var vm = Open(Sample.VM() with { Run = run });

        Assert.Equal(expected, Detail(vm, "Running now"));
    }
}

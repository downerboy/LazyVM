using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class VMViewModelTests : IDisposable
{
    private const long GB = 1024L * 1024 * 1024;

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeBuildLauncher _Launcher = new();
    private readonly FakeToolWindows _Tools;

    public VMViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner, _Launcher);
    }

    public void Dispose() => _Culture.Dispose();

    private VMViewModel Open(VMDashboard entry) => new(entry, _Tools);

    [Fact]
    public void Checks_OpensTheVMsChecks()
    {
        _Runner.ReturnsChecks(Sample.Check());
        var vm = Open(Sample.VM("DevEnv"));

        vm.ChecksCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Shown)).VMName);
        Assert.Equal([("DevEnv", false)], _Runner.CheckCalls);
    }

    [Fact]
    public void Log_OpensTheVMsLog()
    {
        _Runner.ReturnsLog();
        var vm = Open(Sample.VM("DevEnv"));

        vm.LogCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<LogViewModel>(Assert.Single(_Tools.Shown)).VMName);
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
    public void Memory_IsShownOfTheMostTheVMCanUse()
    {
        var vm = Open(Sample.VM() with { MemoryAssigned = 6 * GB, MemoryMaximum = 16 * GB });

        Assert.Equal("6 GB of 16 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNoneOfTheMost()
    {
        var vm = Open(Sample.VM(state: "Off") with { MemoryAssigned = 0, MemoryMaximum = 16 * GB });

        Assert.Equal("None of 16 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void ConfigTemplate_IsNamed()
    {
        var vm = Open(Sample.VM() with { CreatedFromTemplate = "PlainWindows" });

        Assert.Equal("PlainWindows", Detail(vm, "Created from config template"));
    }

    [Fact]
    public void ConfigTemplate_NotRecorded_SaysSo()
    {
        var vm = Open(Sample.VM() with { CreatedFromTemplate = null });

        Assert.Equal("None recorded", Detail(vm, "Created from config template"));
    }

    [Fact]
    public void Memory_NotKnown_DoesNotShowTheMostOnItsOwn()
    {
        var vm = Open(Sample.VM() with { MemoryAssigned = null, MemoryMaximum = 16 * GB });

        Assert.DoesNotContain("16 GB", Detail(vm, "Memory in use"));
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
        _Runner.ReturnsRun(new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 }, "DevEnv");
        var vm = Open(Sample.VM("DevEnv") with { Run = new VMRun { Command = VMRun.Build, Status = VMRun.Running, ProcessId = 9, Phase = 7 } });

        vm.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        progress.StopFollowing();
    }

    private static VMRun LastBuild(string status, int phase) => new()
    {
        Command = VMRun.Build, Status = status, ProcessId = 9, Phase = phase, UnfinishedPhase = status == VMRun.Completed ? null : phase,
    };

    private static VMRun RunningNow(string command) => new() { Command = command, Status = VMRun.Running, ProcessId = 9, Phase = 7 };

    private async Task<VMViewModel> Loaded(VMDashboard entry)
    {
        var vm = Open(entry);
        await vm.LoadAsync();
        return vm;
    }

    [Fact]
    public async Task Load_ListsThePhasesByNumberAndGoal_AndChoosesTheFirst()
    {
        var vm = await Loaded(Sample.VM());

        Assert.Equal([0, 1, 7, 8], vm.Phases.Select(phase => phase.Number));
        Assert.Equal("Phase 7: Install Windows and the tools", vm.Phases[2].Text);
        Assert.Equal(0, vm.SelectedPhase?.Number);
        Assert.False(vm.HasRunNote);
        Assert.True(vm.BuildFromPhaseCommand.CanExecute(null));
    }

    [Theory]
    [InlineData(VMRun.Failed, "failed")]
    [InlineData(VMRun.Stopped, "stopped")]
    [InlineData(VMRun.EndedUnexpectedly, "ended unexpectedly")]
    public async Task AfterABuildThatDidNotFinish_ItsPhaseIsChosen_AndTheNoteSaysWhy(string status, string said)
    {
        var vm = await Loaded(Sample.VM() with { LastBuild = LastBuild(status, 7) });

        Assert.Equal(7, vm.SelectedPhase?.Number);
        Assert.Equal($"The last build {said} in phase 7, so phase 7 is chosen. Let any install still running inside the VM finish first.", vm.RunNote);
    }

    [Fact]
    public async Task AfterABuildThatCompleted_TheFirstPhaseIsChosen()
    {
        var vm = await Loaded(Sample.VM() with { LastBuild = LastBuild(VMRun.Completed, 8) });

        Assert.Equal(0, vm.SelectedPhase?.Number);
    }

    [Fact]
    public async Task Load_WhenThePhasesCannotBeRead_SaysWhy_AndOffersNoBuild()
    {
        _Runner.PhasesFail = new InvalidOperationException("The LazyVM module could not be loaded.");

        var vm = await Loaded(Sample.VM());

        Assert.Equal("The build phases could not be read, so a build cannot start here: The LazyVM module could not be loaded.", vm.Status);
        Assert.False(vm.BuildFromPhaseCommand.CanExecute(null));
    }

    [Fact]
    public async Task BuildFromPhase_StartsTheBuildFromTheChosenPhase_AndShowsItsProgress()
    {
        var vm = await Loaded(Sample.VM("DevEnv"));
        vm.SelectedPhase = vm.Phases.Single(phase => phase.Number == 7);
        _Runner.ReturnsRun(null, "DevEnv");

        await vm.BuildFromPhaseAsync();

        Assert.Equal(new BuildRequest("DevEnv", null, null, 7), Assert.Single(_Launcher.Started).Request);
        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        Assert.Equal("The build of DevEnv has started from phase 7. Its progress is in its own window.", vm.Status);
        progress.StopFollowing();
    }

    [Fact]
    public async Task BuildFromPhase_WhenItCannotStart_SaysWhy()
    {
        _Launcher.Fails = new InvalidOperationException("PowerShell 7.6 or later was not found.");
        var vm = await Loaded(Sample.VM());

        await vm.BuildFromPhaseAsync();

        Assert.Equal("The build could not start: PowerShell 7.6 or later was not found.", vm.Status);
        Assert.True(vm.BuildFromPhaseCommand.CanExecute(null));
    }

    [Fact]
    public async Task RunMaintenance_StartsTheVMsMaintenance_AndSaysSo()
    {
        var vm = await Loaded(Sample.VM("DevEnv"));

        await vm.RunMaintenanceAsync();

        Assert.Equal(["DevEnv"], _Runner.MaintenanceCalls);
        Assert.StartsWith("The maintenance of DevEnv has started, as its nightly run does.", vm.Status);
    }

    [Fact]
    public async Task RunMaintenance_WhenTheModuleStartsNothing_SaysWhy()
    {
        _Runner.MaintenanceFails = new InvalidOperationException("The maintenance of DevBox is running already, so it was not started again.");
        var vm = await Loaded(Sample.VM());

        await vm.RunMaintenanceAsync();

        Assert.Equal("Maintenance did not start: The maintenance of DevBox is running already, so it was not started again.", vm.Status);
    }

    [Theory]
    [InlineData(VMRun.Build, "A build of DevBox is running now.")]
    [InlineData("Maintenance", "Maintenance of DevBox is running now.")]
    [InlineData("Rebuild", "A rebuild of DevBox is running now.")]
    public async Task WhileARunIsGoing_NeitherCanStart_AndTheNoteSaysWhy(string command, string said)
    {
        var vm = await Loaded(Sample.VM() with { Run = RunningNow(command) });

        Assert.False(vm.BuildFromPhaseCommand.CanExecute(null));
        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        Assert.StartsWith(said, vm.RunNote);
        Assert.True(vm.ChecksCommand.CanExecute(null));
        Assert.True(vm.LogCommand.CanExecute(null));

        await vm.RunMaintenanceAsync();
        await vm.BuildFromPhaseAsync();
        Assert.Empty(_Runner.MaintenanceCalls);
        Assert.Empty(_Launcher.Started);
    }

    [Fact]
    public async Task WhenARunStartsOrEnds_TheButtonsFollow()
    {
        var vm = await Loaded(Sample.VM());
        var raised = 0;
        vm.MaintenanceCommand.CanExecuteChanged += (_, _) => raised++;

        vm.Update(Sample.VM() with { Run = RunningNow("Maintenance") });

        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        Assert.True(raised > 0);

        vm.Update(Sample.VM());

        Assert.True(vm.MaintenanceCommand.CanExecute(null));
    }

    [Fact]
    public async Task WithoutAMaintenanceTask_MaintenanceCannotStart_AndTheNoteSaysHowToScheduleIt()
    {
        var vm = await Loaded(Sample.VM() with { MaintenanceTask = "Not registered" });

        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        Assert.True(vm.BuildFromPhaseCommand.CanExecute(null));
        Assert.Equal("Maintenance of DevBox is not scheduled, so it cannot run now. In PowerShell, run Register-LazyVMMaintenance -Name DevBox", vm.RunNote);
    }

    [Fact]
    public async Task Update_AfterABuildFails_ChoosesThePhaseItFailedIn()
    {
        var vm = await Loaded(Sample.VM());

        vm.Update(Sample.VM() with { LastBuild = LastBuild(VMRun.Failed, 8) });

        Assert.Equal(8, vm.SelectedPhase?.Number);
    }

    [Fact]
    public async Task Update_KeepsAPhaseChosenByHand_WhenTheLastBuildIsTheSame()
    {
        var vm = await Loaded(Sample.VM() with { LastBuild = LastBuild(VMRun.Failed, 7) });
        vm.SelectedPhase = vm.Phases[1];

        vm.Update(Sample.VM() with { LastBuild = LastBuild(VMRun.Failed, 7) });

        Assert.Equal(1, vm.SelectedPhase?.Number);
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

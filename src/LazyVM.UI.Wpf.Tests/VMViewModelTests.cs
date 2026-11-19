using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class VMViewModelTests : IDisposable
{
    private const long _GB = 1024L * 1024 * 1024;

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeBuildLauncher _Launcher = new();
    private readonly FakeToolWindows _Tools;

    public VMViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner, _Launcher);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private VMViewModel Open(VMDashboard entry)
    {
        return new(entry, _Tools);
    }

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

    private static string? Detail(VMViewModel vm, string label)
    {
        return vm.Details.SingleOrDefault(detail => detail.Label == label)?.Value;
    }

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
        var vm = Open(Sample.VM() with
        {
            MemoryAssigned = 8 * _GB
        });

        Assert.Equal("8 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNone()
    {
        var vm = Open(Sample.VM(state: "Off") with
        {
            MemoryAssigned = 0
        });

        Assert.Equal("None", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_IsShownOfTheMostTheVMCanUse()
    {
        var vm = Open(Sample.VM() with
        {
            MemoryAssigned = 6 * _GB,
            MemoryMaximum = 16 * _GB
        });

        Assert.Equal("6 GB of 16 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNoneOfTheMost()
    {
        var vm = Open(Sample.VM(state: "Off") with
        {
            MemoryAssigned = 0,
            MemoryMaximum = 16 * _GB
        });

        Assert.Equal("None of 16 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void ConfigTemplate_IsNamed()
    {
        var vm = Open(Sample.VM() with
        {
            CreatedFromTemplate = "PlainWindows"
        });

        Assert.Equal("PlainWindows", Detail(vm, "Created from config template"));
    }

    [Theory]
    [InlineData(3, 1, true, "3 stored, 1 not exported yet, last exported 15 November 2026 10:05")]
    [InlineData(2, 0, true, "2 stored, all exported, last exported 15 November 2026 10:05")]
    [InlineData(2, 2, false, "2 stored, 2 not exported yet, never exported")]
    [InlineData(0, 0, false, "None stored yet")]
    public void RecoveryKeys_SayHowManyAreStored_AndNotExported(int stored, int unexported, bool everExported, string said)
    {
        var vm = Open(Sample.VM() with
        {
            RecoveryKeys = stored,
            UnexportedRecoveryKeys = unexported,
            RecoveryKeysExported = everExported ? new DateTime(2026, 11, 15, 10, 5, 0) : null,
        });

        Assert.Equal(said, Detail(vm, "Recovery keys"));
    }

    [Fact]
    public void RecoveryKeys_NotKnown_SayNotKnown()
    {
        Assert.Equal("Not known", Detail(Open(Sample.VM()), "Recovery keys"));
    }

    [Theory]
    [InlineData(1, "1 BitLocker recovery password of DevBox is not exported yet. Keep a copy offline, such as on a USB drive: choose Recovery keys.")]
    [InlineData(3, "3 BitLocker recovery passwords of DevBox are not exported yet. Keep a copy offline, such as on a USB drive: choose Recovery keys.")]
    public void KeysNotExported_ShowANotice_SayingHowMany(int unexported, string said)
    {
        var vm = Open(Sample.VM() with
        {
            RecoveryKeys = 3,
            UnexportedRecoveryKeys = unexported
        });

        Assert.Equal(said, vm.RecoveryKeyNotice);
        Assert.True(vm.HasRecoveryKeyNotice);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(null)]
    public void EveryKeyExported_OrNotKnown_ShowsNoNotice(int? unexported)
    {
        var vm = Open(Sample.VM() with
        {
            RecoveryKeys = 2,
            UnexportedRecoveryKeys = unexported
        });

        Assert.False(vm.HasRecoveryKeyNotice);
        Assert.Equal(string.Empty, vm.RecoveryKeyNotice);
    }

    [Fact]
    public void ARefresh_AfterAnExport_TakesTheNoticeAway()
    {
        var vm = Open(Sample.VM() with
        {
            RecoveryKeys = 2,
            UnexportedRecoveryKeys = 2
        });
        var changed = new List<string?>();
        vm.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.Update(Sample.VM() with
        {
            RecoveryKeys = 2,
            UnexportedRecoveryKeys = 0
        });

        Assert.False(vm.HasRecoveryKeyNotice);
        Assert.Contains(string.Empty, changed);
    }

    [Fact]
    public void RecoveryKeys_OpensTheVMsRecoveryKeysWindow_AndReadsTheKeys()
    {
        _Runner.ReturnsRecoveryKeys();
        var vm = Open(Sample.VM());

        vm.RecoveryKeysCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<RecoveryKeysViewModel>(Assert.Single(_Tools.Shown)).Name);
        Assert.Equal(["DevBox"], _Runner.RecoveryKeyCalls);
    }

    [Fact]
    public void SecurityFindings_OpensTheVMsSecurityFindingsWindow_AndReadsThem()
    {
        _Runner.ReturnsSecurityFindings();
        _Runner.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM());

        vm.SecurityFindingsCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<SecurityFindingsViewModel>(Assert.Single(_Tools.Shown)).Name);
        Assert.Equal(["DevBox"], _Runner.SecurityFindingCalls);
        Assert.Equal(["DevBox"], _Runner.SecurityApprovalCalls);
    }

    [Fact]
    public void SecurityFindings_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runner.ReturnsSecurityFindings();
        _Runner.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM());

        vm.SecurityFindingsCommand.Execute(null);
        vm.SecurityFindingsCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Shown), Assert.Single(_Tools.BroughtToFront));
        Assert.Single(_Runner.SecurityFindingCalls);
    }

    [Fact]
    public void Update_WithANewerScan_ReadsTheOpenSecurityFindingsWindowAgain()
    {
        _Runner.ReturnsSecurityFindings();
        _Runner.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM() with
        {
            LastSecurityScan = null
        });
        vm.SecurityFindingsCommand.Execute(null);
        _Runner.ReturnsSecurityFindings();
        _Runner.ReturnsSecurityApprovals();

        vm.Update(Sample.VM() with
        {
            LastSecurityScan = new DateTime(2026, 11, 18, 2, 30, 0)
        });

        Assert.Equal(2, _Runner.SecurityFindingCalls.Count);
    }

    [Fact]
    public void Password_OpensTheVMsPasswordWindow_ReadingOnlyTheUserName()
    {
        var vm = Open(Sample.VM());

        vm.PasswordCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<PasswordViewModel>(Assert.Single(_Tools.Shown)).Name);
        Assert.Equal(["DevBox"], _Runner.UserNameCalls);
        Assert.Empty(_Runner.PasswordCalls);
    }

    [Fact]
    public void Password_Twice_BringsTheOpenWindowToTheFront()
    {
        var vm = Open(Sample.VM());

        vm.PasswordCommand.Execute(null);
        vm.PasswordCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Shown), Assert.Single(_Tools.BroughtToFront));
    }

    [Fact]
    public void RecoveryKeys_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runner.ReturnsRecoveryKeys();
        var vm = Open(Sample.VM());

        vm.RecoveryKeysCommand.Execute(null);
        vm.RecoveryKeysCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Shown), Assert.Single(_Tools.BroughtToFront));
        Assert.Single(_Runner.RecoveryKeyCalls);
    }

    [Fact]
    public void ConfigTemplate_NotRecorded_SaysSo()
    {
        var vm = Open(Sample.VM() with
        {
            CreatedFromTemplate = null
        });

        Assert.Equal("None recorded", Detail(vm, "Created from config template"));
    }

    [Fact]
    public void Memory_NotKnown_DoesNotShowTheMostOnItsOwn()
    {
        var vm = Open(Sample.VM() with
        {
            MemoryAssigned = null,
            MemoryMaximum = 16 * _GB
        });

        Assert.DoesNotContain("16 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Disks_ShowTheTotalAndEachDisk()
    {
        var vm = Open(Sample.VM() with
        {
            DiskSpaceUsed = (214 * _GB) + (_GB / 2),
            Disks =
            [
                new VMDisk("DevBox.vhdx", @"D:\VMs\DevBox\DevBox.vhdx", 200 * _GB, 512 * _GB),
                new VMDisk("Data.vhdx", @"D:\VMs\DevBox\Data.vhdx", (14 * _GB) + (_GB / 2), 64 * _GB),
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
            DiskSpaceUsed = 148 * _GB,
            Disks = [new VMDisk("DevBox-OS.vhdx", @"D:\VMs\DevBox\DevBox-OS.vhdx", 148 * _GB, 120 * _GB)],
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
        var vm = Open(Sample.VM() with
        {
            MaintenanceTime = "02:00"
        });

        Assert.Equal("Daily at 02:00, task registered", Detail(vm, "Maintenance"));
    }

    [Fact]
    public void SecurityScan_GivesDayAndOpenFindings()
    {
        var vm = Open(Sample.VM() with
        {
            LastSecurityScan = new DateTime(2026, 11, 13, 3, 0, 0),
            OpenFindings = 3
        });

        Assert.Equal("13 November 2026 03:00, 3 open findings", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void SecurityScan_BeforeTheFirstScan()
    {
        var vm = Open(Sample.VM() with
        {
            LastSecurityScan = null,
            OpenFindings = null
        });

        Assert.Equal("Not scanned yet", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void GreenTemplate_GivesNameAndWhenItChanged()
    {
        var vm = Open(Sample.VM() with
        {
            GreenTemplate = "DevBox-latest",
            GreenTemplateUpdated = new DateTime(2026, 11, 13, 3, 5, 0)
        });

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
        var vm = Open(Sample.VM() with
        {
            Problems = ["Hyper-V: access denied", "Disks: access denied"]
        });

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
        var building = Open(Sample.VM() with
        {
            Run = new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 }
        });
        var maintaining = Open(Sample.VM() with
        {
            Run = new VMRun { Command = "Maintenance", Status = VMRun.RUNNING, ProcessId = 9 }
        });

        Assert.False(idle.BuildProgressCommand.CanExecute(null));
        Assert.True(building.BuildProgressCommand.CanExecute(null));
        Assert.False(maintaining.BuildProgressCommand.CanExecute(null));
        Assert.True(maintaining.IsBusy);
        Assert.False(idle.IsBusy);
    }

    [Fact]
    public void BuildProgress_OpensTheProgressOfTheRunningBuild()
    {
        _Runner.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 }, "DevEnv");
        var vm = Open(Sample.VM("DevEnv") with
        {
            Run = new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 }
        });

        vm.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        progress.StopFollowing();
    }

    private static VMRun LastBuild(string status, int phase)
    {
        return new()
        {
            Command = VMRun.BUILD,
            Status = status,
            ProcessId = 9,
            Phase = phase,
            UnfinishedPhase = status == VMRun.COMPLETED ? null : phase,
        };
    }

    private static VMRun RunningNow(string command)
    {
        return new()
        {
            Command = command,
            Status = VMRun.RUNNING,
            ProcessId = 9,
            Phase = 7
        };
    }

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
    [InlineData(VMRun.FAILED, "failed")]
    [InlineData(VMRun.STOPPED, "stopped")]
    [InlineData(VMRun.ENDED_UNEXPECTEDLY, "ended unexpectedly")]
    public async Task AfterABuildThatDidNotFinish_ItsPhaseIsChosen_AndTheNoteSaysWhy(string status, string said)
    {
        var vm = await Loaded(Sample.VM() with
        {
            LastBuild = LastBuild(status, 7)
        });

        Assert.Equal(7, vm.SelectedPhase?.Number);
        Assert.Equal($"The last build {said} in phase 7, so phase 7 is chosen. Let any install still running inside the VM finish first.", vm.RunNote);
    }

    [Fact]
    public async Task AfterABuildThatCompleted_TheFirstPhaseIsChosen()
    {
        var vm = await Loaded(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.COMPLETED, 8)
        });

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
    [InlineData(VMRun.BUILD, "A build of DevBox is running now.")]
    [InlineData("Maintenance", "Maintenance of DevBox is running now.")]
    [InlineData("Rebuild", "A rebuild of DevBox is running now.")]
    public async Task WhileARunIsGoing_NeitherCanStart_AndTheNoteSaysWhy(string command, string said)
    {
        var vm = await Loaded(Sample.VM() with
        {
            Run = RunningNow(command)
        });

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

        vm.Update(Sample.VM() with
        {
            Run = RunningNow("Maintenance")
        });

        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        Assert.True(raised > 0);

        vm.Update(Sample.VM());

        Assert.True(vm.MaintenanceCommand.CanExecute(null));
    }

    [Fact]
    public async Task WithoutAMaintenanceTask_MaintenanceCannotStart_AndTheNoteSaysHowToScheduleIt()
    {
        var vm = await Loaded(Sample.VM() with
        {
            MaintenanceTask = "Not registered"
        });

        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        Assert.True(vm.BuildFromPhaseCommand.CanExecute(null));
        Assert.Equal("Maintenance of DevBox is not scheduled, so it cannot run now. In PowerShell, run Register-LazyVMMaintenance -Name DevBox", vm.RunNote);
    }

    [Fact]
    public async Task Update_AfterABuildFails_ChoosesThePhaseItFailedIn()
    {
        var vm = await Loaded(Sample.VM());

        vm.Update(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.FAILED, 8)
        });

        Assert.Equal(8, vm.SelectedPhase?.Number);
    }

    [Fact]
    public async Task Update_KeepsAPhaseChosenByHand_WhenTheLastBuildIsTheSame()
    {
        var vm = await Loaded(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.FAILED, 7)
        });
        vm.SelectedPhase = vm.Phases[1];

        vm.Update(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.FAILED, 7)
        });

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
            Command = command,
            Status = VMRun.RUNNING,
            ProcessId = 9,
            Phase = phase,
            PhaseName = phase is null ? null : "Windows",
            StopRequested = stopping,
        };

        var vm = Open(Sample.VM() with
        {
            Run = run
        });

        Assert.Equal(expected, Detail(vm, "Running now"));
    }

    private static RemovalPlan PlanOf(string name = "DevBox")
    {
        return new()
        {
            Name = name,
            HyperVState = "Off",
            Items = [new("Folder", $@"C:\LazyVM\{name}", 50 * _GB)],
            Total = 50 * _GB,
        };
    }

    [Fact]
    public async Task Delete_ShowsWhatGoes_AndOnYes_RemovesTheVM()
    {
        _Runner.ReturnsRemovalPlan(PlanOf());
        _Tools.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Removed += (_, _) => removed++;
        var listChanged = 0;
        _Tools.VMRemoved += (_, _) => listChanged++;

        await vm.DeleteAsync();

        var asked = Assert.Single(_Tools.RemovalsAsked);
        Assert.Equal("DevBox", asked.Name);
        Assert.Contains(@"Folder C:\LazyVM\DevBox, 50 GB", asked.Lines.Select(line => line.Text));
        Assert.Equal(["DevBox"], _Runner.RemovalPlanCalls);
        Assert.Equal(["DevBox"], _Runner.RemoveCalls);
        Assert.Equal(1, removed);
        Assert.Equal(1, listChanged);
        Assert.Equal("DevBox has been deleted.", vm.Status);
        Assert.False(vm.IsDeleting);
    }

    [Fact]
    public async Task Delete_OnNo_DeletesNothing()
    {
        _Runner.ReturnsRemovalPlan(PlanOf());
        _Tools.ConfirmsRemoval = false;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Removed += (_, _) => removed++;

        await vm.DeleteAsync();

        Assert.Single(_Tools.RemovalsAsked);
        Assert.Empty(_Runner.RemoveCalls);
        Assert.Equal(0, removed);
        Assert.Equal("DevBox was not deleted.", vm.Status);
        Assert.True(vm.DeleteCommand.CanExecute(null));
    }

    [Fact]
    public async Task Delete_WhenWhatGoesCannotBeRead_AsksNothing_AndSaysWhy()
    {
        _Runner.RemovalPlanThrows(new InvalidOperationException("Cannot tell what VM 'Other' uses, so nothing has been removed."));
        var vm = await Loaded(Sample.VM());

        await vm.DeleteAsync();

        Assert.Empty(_Tools.RemovalsAsked);
        Assert.Empty(_Runner.RemoveCalls);
        Assert.Equal("DevBox cannot be deleted now: Cannot tell what VM 'Other' uses, so nothing has been removed.", vm.Status);
    }

    [Fact]
    public async Task Delete_ThatOnlyPartlyRemoved_SaysWhatIsLeft_AndKeepsTheWindow()
    {
        _Runner.ReturnsRemovalPlan(PlanOf());
        _Runner.ReturnsRemovalPlan(new RemovalPlan { Name = "DevBox", Items = [new(RemovalItem.FILE, @"E:\Disks\DevBox\SQL.vhdx", _GB)] });
        _Runner.RemoveFails = new InvalidOperationException(@"'DevBox' was only partly removed. The log lists what is left: C:\LazyVM\DevBox\Logs\DevBox.log");
        _Tools.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Removed += (_, _) => removed++;
        var listChanged = 0;
        _Tools.VMRemoved += (_, _) => listChanged++;

        await vm.DeleteAsync();

        Assert.Equal(0, removed);
        Assert.Equal(1, listChanged);
        Assert.Equal(
            @"Deleting DevBox did not finish: 'DevBox' was only partly removed. The log lists what is left: C:\LazyVM\DevBox\Logs\DevBox.log Still there: E:\Disks\DevBox\SQL.vhdx.",
            vm.Status);
        Assert.True(vm.DeleteCommand.CanExecute(null));
    }

    [Fact]
    public async Task Delete_ThatFailed_WhenWhatIsLeftCannotBeRead_GivesTheModulesReason()
    {
        _Runner.ReturnsRemovalPlan(PlanOf());
        _Runner.RemovalPlanThrows(new InvalidOperationException("There is no VM named DevBox."));
        _Runner.RemoveFails = new InvalidOperationException("'DevBox' was only partly removed.");
        _Tools.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());

        await vm.DeleteAsync();

        Assert.Equal("Deleting DevBox did not finish: 'DevBox' was only partly removed.", vm.Status);
    }

    [Fact]
    public async Task WhileDeleting_NothingElseCanStart()
    {
        _Runner.ReturnsRemovalPlan(PlanOf());
        _Runner.RemoveGate = new TaskCompletionSource();
        _Tools.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());

        var deleting = vm.DeleteAsync();

        Assert.True(vm.IsDeleting);
        Assert.Equal("Deleting DevBox", vm.Status);
        Assert.False(vm.DeleteCommand.CanExecute(null));
        Assert.False(vm.BuildFromPhaseCommand.CanExecute(null));
        Assert.False(vm.MaintenanceCommand.CanExecute(null));
        await vm.BuildFromPhaseAsync();
        await vm.RunMaintenanceAsync();
        Assert.Empty(_Launcher.Started);
        Assert.Empty(_Runner.MaintenanceCalls);

        _Runner.RemoveGate.SetResult();
        await deleting;
        Assert.Equal(["DevBox"], _Runner.RemoveCalls);
    }

    [Theory]
    [InlineData(VMRun.BUILD, "A build of DevBox is running now, so DevBox cannot be deleted until it has ended.")]
    [InlineData("Remove", "A delete of DevBox is running now, so DevBox cannot be deleted until it has ended.")]
    [InlineData("Restore", "A restore of the tooling of DevBox is running now, so DevBox cannot be deleted until it has ended.")]
    public async Task WhileARunIsGoing_DeleteIsDisabled_AndItsNoteSaysWhy(string command, string said)
    {
        var vm = await Loaded(Sample.VM() with
        {
            Run = RunningNow(command)
        });

        Assert.False(vm.DeleteCommand.CanExecute(null));
        Assert.Equal(said, vm.DeleteNote);
        Assert.True(vm.HasDeleteNote);

        await vm.DeleteAsync();
        Assert.Empty(_Runner.RemovalPlanCalls);
    }

    [Fact]
    public async Task WhenNothingIsRunning_DeleteCanStart_WithNoNote()
    {
        var vm = await Loaded(Sample.VM());

        Assert.True(vm.DeleteCommand.CanExecute(null));
        Assert.False(vm.HasDeleteNote);
    }

    [Fact]
    public async Task ARunThatStartsLater_DisablesDelete()
    {
        var vm = await Loaded(Sample.VM());
        var changed = 0;
        vm.DeleteCommand.CanExecuteChanged += (_, _) => changed++;

        vm.Update(Sample.VM() with
        {
            Run = RunningNow("Maintenance")
        });

        Assert.False(vm.DeleteCommand.CanExecute(null));
        Assert.True(changed > 0);
    }

    [Fact]
    public async Task RestorePoints_OpensTheVMsRestoreWindow_AndReadsThePoints()
    {
        _Runner.ReturnsRestorePoints();
        var vm = await Loaded(Sample.VM());

        vm.RestorePointsCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<RestoreViewModel>(Assert.Single(_Tools.Shown)).Name);
        Assert.Equal(["DevBox"], _Runner.RestorePointCalls);
    }

    [Fact]
    public async Task RestorePoints_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runner.ReturnsRestorePoints();
        var vm = await Loaded(Sample.VM());

        vm.RestorePointsCommand.Execute(null);
        vm.RestorePointsCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Shown), Assert.Single(_Tools.BroughtToFront));
    }

    [Fact]
    public async Task ARefresh_ReachesTheOpenRestoreWindow()
    {
        _Runner.ReturnsRestorePoints(new VMRestorePoint("20261008-193000", new DateTime(2026, 10, 8), true));
        var vm = await Loaded(Sample.VM());
        vm.RestorePointsCommand.Execute(null);
        var restore = Assert.IsType<RestoreViewModel>(Assert.Single(_Tools.Shown));
        await Task.Yield();

        vm.Update(Sample.VM() with
        {
            Run = RunningNow(VMRun.BUILD)
        });

        Assert.False(restore.RestoreCommand.CanExecute(null));
    }

    [Theory]
    [InlineData("Remove", "A delete of DevBox is running now.")]
    [InlineData("Restore", "A restore of the tooling of DevBox is running now.")]
    public async Task TheRunNote_NamesADeleteOrARestore(string command, string said)
    {
        var vm = await Loaded(Sample.VM() with
        {
            Run = RunningNow(command)
        });

        Assert.StartsWith(said, vm.RunNote);
    }
}

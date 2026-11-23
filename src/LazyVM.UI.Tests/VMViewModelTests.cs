using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

public sealed class VMViewModelTests : IDisposable
{
    private const long _GB = 1024L * 1024 * 1024;
    private static readonly Guid _DEV_BOX_ID = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeRunners _Runners = new();
    private readonly FakeBuildLauncher _Launcher = new();
    private readonly FakeToolWindows _Tools;

    public VMViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runners, _Launcher);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private VMViewModel Open(LazyVMDashboard entry)
    {
        return new(entry, _Tools, _Tools.Dialogs, _Runners.Build, _Runners.Removal, _Tools.Changes);
    }

    [Fact]
    public void Checks_OpensTheVMsChecks()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());
        var vm = Open(Sample.VM("DevEnv"));

        vm.ChecksCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<ChecksViewModel>(Assert.Single(_Tools.Windows.Shown)).VMName);
        Assert.Equal([("DevEnv", false)], _Runners.Checks.CheckCalls);
    }

    [Fact]
    public void Log_OpensTheVMsLog()
    {
        _Runners.Log.ReturnsLog();
        var vm = Open(Sample.VM("DevEnv"));

        vm.LogCommand.Execute(null);

        Assert.Equal("DevEnv", Assert.IsType<LogViewModel>(Assert.Single(_Tools.Windows.Shown)).VMName);
    }

    [Fact]
    public void ChecksAndLog_RunInTheVMsOwnSession()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());
        _Runners.Log.ReturnsLog();
        var vm = Open(Sample.VM() with { Id = _DEV_BOX_ID });

        vm.ChecksCommand.Execute(null);
        vm.LogCommand.Execute(null);

        Assert.Equal([_DEV_BOX_ID], _Runners.Checks.CheckIds);
        Assert.Equal([_DEV_BOX_ID], _Runners.Log.LogIds);
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
        _Runners.RecoveryKeys.ReturnsRecoveryKeys();
        var vm = Open(Sample.VM());

        vm.RecoveryKeysCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<RecoveryKeysViewModel>(Assert.Single(_Tools.Windows.Shown)).Name);
        Assert.Equal(["DevBox"], _Runners.RecoveryKeys.RecoveryKeyCalls);
    }

    [Fact]
    public void SecurityFindings_OpensTheVMsSecurityFindingsWindow_AndReadsThem()
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings();
        _Runners.SecurityFindings.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM());

        vm.SecurityFindingsCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<SecurityFindingsViewModel>(Assert.Single(_Tools.Windows.Shown)).Name);
        Assert.Equal(["DevBox"], _Runners.SecurityFindings.SecurityFindingCalls);
        Assert.Equal(["DevBox"], _Runners.SecurityFindings.SecurityApprovalCalls);
    }

    [Fact]
    public void SecurityFindings_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings();
        _Runners.SecurityFindings.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM());

        vm.SecurityFindingsCommand.Execute(null);
        vm.SecurityFindingsCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Windows.Shown), Assert.Single(_Tools.Windows.BroughtToFront));
        Assert.Single(_Runners.SecurityFindings.SecurityFindingCalls);
    }

    [Fact]
    public void Update_WithANewerScan_ReadsTheOpenSecurityFindingsWindowAgain()
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings();
        _Runners.SecurityFindings.ReturnsSecurityApprovals();
        var vm = Open(Sample.VM() with
        {
            LastSecurityScan = null
        });
        vm.SecurityFindingsCommand.Execute(null);
        _Runners.SecurityFindings.ReturnsSecurityFindings();
        _Runners.SecurityFindings.ReturnsSecurityApprovals();

        vm.Update(Sample.VM() with
        {
            LastSecurityScan = new DateTime(2026, 11, 18, 2, 30, 0)
        });

        Assert.Equal(2, _Runners.SecurityFindings.SecurityFindingCalls.Count);
    }

    [Fact]
    public void Password_OpensTheVMsPasswordWindow_ReadingOnlyTheUserName()
    {
        var vm = Open(Sample.VM());

        vm.PasswordCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<PasswordViewModel>(Assert.Single(_Tools.Windows.Shown)).Name);
        Assert.Equal(["DevBox"], _Runners.Credentials.UserNameCalls);
        Assert.Empty(_Runners.Credentials.PasswordCalls);
    }

    [Fact]
    public void Password_Twice_BringsTheOpenWindowToTheFront()
    {
        var vm = Open(Sample.VM());

        vm.PasswordCommand.Execute(null);
        vm.PasswordCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Windows.Shown), Assert.Single(_Tools.Windows.BroughtToFront));
    }

    [Fact]
    public void RecoveryKeys_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.RecoveryKeys.ReturnsRecoveryKeys();
        var vm = Open(Sample.VM());

        vm.RecoveryKeysCommand.Execute(null);
        vm.RecoveryKeysCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Windows.Shown), Assert.Single(_Tools.Windows.BroughtToFront));
        Assert.Single(_Runners.RecoveryKeys.RecoveryKeyCalls);
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
        _Runners.Dashboard.ReturnsRun(new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 }, "DevEnv");
        var vm = Open(Sample.VM("DevEnv") with
        {
            Run = new VMRun { Command = VMRun.BUILD, Status = VMRun.RUNNING, ProcessId = 9, Phase = 7 }
        });

        vm.BuildProgressCommand.Execute(null);

        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Windows.Shown));
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

    private async Task<VMViewModel> Loaded(LazyVMDashboard entry)
    {
        var vm = Open(entry);
        await vm.LoadAsync();
        return vm;
    }

    [Fact]
    public async Task Load_ListsThePhasesByNumberAndGoal_AndChoosesTheFirst()
    {
        var vm = await Loaded(Sample.VM());

        Assert.Equal([0, 1, 7, 8], vm.BuildFromPhase.Phases.Select(phase => phase.Number));
        Assert.Equal("Phase 7: Install Windows and the tools", vm.BuildFromPhase.Phases[2].Text);
        Assert.Equal(0, vm.BuildFromPhase.SelectedPhase?.Number);
        Assert.False(vm.HasRunNote);
        Assert.True(vm.BuildFromPhase.BuildCommand.CanExecute(null));
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

        Assert.Equal(7, vm.BuildFromPhase.SelectedPhase?.Number);
        Assert.Equal($"The last build {said} in phase 7, so phase 7 is chosen. Let any install still running inside the VM finish first.", vm.RunNote);
    }

    [Theory]
    [InlineData(0, "Runs every phase again")]
    [InlineData(1, "Skips the phases before phase 1, then runs phase 1 and those after it again")]
    [InlineData(7, "Skips the phases before phase 7, then runs phase 7 and those after it again")]
    [InlineData(8, "Skips the phases before phase 8, then runs only phase 8 again")]
    public async Task PhaseHelp_SaysWhatBuildingFromTheChosenPhaseSkipsAndKeeps(int number, string runs)
    {
        var vm = await Loaded(Sample.VM());

        vm.BuildFromPhase.SelectedPhase = vm.BuildFromPhase.Phases.Single(phase => phase.Number == number);

        Assert.Equal(runs + ", skipping work already done: the VM, its disks and what is installed are kept. Use it after fixing what stopped a build, from the phase it stopped in.", vm.BuildFromPhase.PhaseHelp);
        Assert.True(vm.BuildFromPhase.HasPhaseHelp);
    }

    [Fact]
    public async Task PhaseHelp_FollowsTheChosenPhase()
    {
        var vm = await Loaded(Sample.VM());
        var changed = new List<string?>();
        vm.BuildFromPhase.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.BuildFromPhase.SelectedPhase = vm.BuildFromPhase.Phases.Single(phase => phase.Number == 7);

        Assert.Contains(nameof(BuildFromPhaseViewModel.PhaseHelp), changed);
        Assert.Contains(nameof(BuildFromPhaseViewModel.HasPhaseHelp), changed);
        Assert.Contains(nameof(BuildFromPhaseViewModel.BuildHelp), changed);
    }

    [Fact]
    public async Task BuildFromPhaseHelp_SaysWhatTheChosenPhaseDoes_ThenHowTheBuildRuns()
    {
        var vm = await Loaded(Sample.VM());

        vm.BuildFromPhase.SelectedPhase = vm.BuildFromPhase.Phases.Single(phase => phase.Number == 7);

        Assert.Equal(vm.BuildFromPhase.PhaseHelp + " Starts the build in its own process, and shows its progress. Closing the app does not stop it.", vm.BuildFromPhase.BuildHelp);
        Assert.StartsWith("Skips the phases before phase 7", vm.BuildFromPhase.BuildHelp);
    }

    [Fact]
    public async Task BuildFromPhaseHelp_WithNoPhaseChosen_SaysOnlyHowTheBuildRuns()
    {
        _Runners.Build.PhasesFail = new InvalidOperationException("The LazyVM module could not be loaded.");

        var vm = await Loaded(Sample.VM());

        Assert.Equal("Starts the build in its own process, and shows its progress. Closing the app does not stop it.", vm.BuildFromPhase.BuildHelp);
    }

    [Fact]
    public async Task PhaseHelp_WhenThePhasesCannotBeRead_IsEmpty()
    {
        _Runners.Build.PhasesFail = new InvalidOperationException("The LazyVM module could not be loaded.");

        var vm = await Loaded(Sample.VM());

        Assert.Equal(string.Empty, vm.BuildFromPhase.PhaseHelp);
        Assert.False(vm.BuildFromPhase.HasPhaseHelp);
    }

    [Fact]
    public void DeleteHelp_SaysTheWorkDisksGoToo_ThatItCannotBeUndone_AndThatTheTemplateIsKept()
    {
        var vm = Open(Sample.VM("DevEnv") with
        {
            GreenTemplate = "DevEnv-latest"
        });

        Assert.Equal(
            "Deletes DevEnv and everything LazyVM made for it: its disks, tasks and folder. "
            + @"That includes the Dev Drive, with any code not yet pushed, and the User disk, with Documents, Desktop, Downloads, .ssh and source\repos, so push or copy your work first. "
            + "It cannot be undone. Its template, DevEnv-latest, is kept, to build a matching VM from later. "
            + "A list of what goes comes first, and you are asked before anything is deleted.",
            vm.Deletion.Help);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    public void DeleteHelp_ForAVMWithNoTemplate_NamesNone(string? template)
    {
        var vm = Open(Sample.VM("DevEnv") with
        {
            GreenTemplate = template
        });

        Assert.Equal(
            "Deletes DevEnv and everything LazyVM made for it: its disks, tasks and folder. "
            + @"That includes the Dev Drive, with any code not yet pushed, and the User disk, with Documents, Desktop, Downloads, .ssh and source\repos, so push or copy your work first. "
            + "It cannot be undone. "
            + "A list of what goes comes first, and you are asked before anything is deleted.",
            vm.Deletion.Help);
    }

    [Fact]
    public void MaintenanceHelp_SaysWhatTheRunDoes_IncludingARearmOrRebuildNearTheEndOfTheEvaluation()
    {
        var vm = Open(Sample.VM());

        Assert.Equal("Runs the VM's nightly maintenance now: it records what changed in the VM, backs up its databases, installs updates and scans it for security problems. Near the end of the evaluation it also rearms Windows and restarts the VM, or, with no rearms left, rebuilds it.", vm.Maintenance.Help);
    }

    [Fact]
    public async Task AfterABuildThatCompleted_TheFirstPhaseIsChosen()
    {
        var vm = await Loaded(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.COMPLETED, 8)
        });

        Assert.Equal(0, vm.BuildFromPhase.SelectedPhase?.Number);
    }

    [Fact]
    public async Task Load_WhenThePhasesCannotBeRead_SaysWhy_AndOffersNoBuild()
    {
        _Runners.Build.PhasesFail = new InvalidOperationException("The LazyVM module could not be loaded.");

        var vm = await Loaded(Sample.VM());

        Assert.Equal("The build phases could not be read, so a build cannot start here: The LazyVM module could not be loaded.", vm.Status);
        Assert.False(vm.BuildFromPhase.BuildCommand.CanExecute(null));
    }

    [Fact]
    public async Task BuildFromPhase_StartsTheBuildFromTheChosenPhase_AndShowsItsProgress()
    {
        var vm = await Loaded(Sample.VM("DevEnv"));
        vm.BuildFromPhase.SelectedPhase = vm.BuildFromPhase.Phases.Single(phase => phase.Number == 7);
        _Runners.Dashboard.ReturnsRun(null, "DevEnv");

        await vm.BuildFromPhase.BuildAsync();

        Assert.Equal(new BuildRequest("DevEnv", null, null, 7), Assert.Single(_Launcher.Started).Request);
        var progress = Assert.IsType<BuildProgressViewModel>(Assert.Single(_Tools.Windows.Shown));
        Assert.Equal("DevEnv", progress.VMName);
        Assert.Equal("The build of DevEnv has started from phase 7. Its progress is in its own window.", vm.Status);
        progress.StopFollowing();
    }

    [Fact]
    public async Task BuildFromPhase_WhenItCannotStart_SaysWhy()
    {
        _Launcher.Fails = new InvalidOperationException("PowerShell 7.6 or later was not found.");
        var vm = await Loaded(Sample.VM());

        await vm.BuildFromPhase.BuildAsync();

        Assert.Equal("The build could not start: PowerShell 7.6 or later was not found.", vm.Status);
        Assert.True(vm.BuildFromPhase.BuildCommand.CanExecute(null));
    }

    [Fact]
    public async Task Load_AndRunMaintenance_AreWorkingWhileThePhasesAreReadAndTheMaintenanceStarts()
    {
        var vm = Open(Sample.VM("DevEnv"));
        var watcher = new WorkWatcher(vm);

        await vm.LoadAsync();
        await vm.Maintenance.RunAsync();

        Assert.Equal(["Reading the build phases", null, "Starting the maintenance", null], watcher.Seen);
    }

    [Fact]
    public async Task Delete_IsWorkingWhileWhatGoesIsReadAndTheVMIsDeleted()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());
        var watcher = new WorkWatcher(vm);

        await vm.Deletion.DeleteAsync();

        Assert.Equal(["Reading what deleting the VM removes", null, "Deleting DevBox", null], watcher.Seen);
    }

    [Fact]
    public async Task RunMaintenance_StartsTheVMsMaintenance_AndSaysSo()
    {
        var vm = await Loaded(Sample.VM("DevEnv"));

        await vm.Maintenance.RunAsync();

        Assert.Equal(["DevEnv"], _Runners.Build.MaintenanceCalls);
        Assert.StartsWith("The maintenance of DevEnv has started, as its nightly run does.", vm.Status);
    }

    [Fact]
    public async Task RunMaintenance_WhenTheModuleStartsNothing_SaysWhy()
    {
        _Runners.Build.MaintenanceFails = new InvalidOperationException("The maintenance of DevBox is running already, so it was not started again.");
        var vm = await Loaded(Sample.VM());

        await vm.Maintenance.RunAsync();

        Assert.Equal("Maintenance did not start: The maintenance of DevBox is running already, so it was not started again.", vm.Status);
    }

    [Fact]
    public async Task RunMaintenance_TellsTheListItStarted_ButNotWhenItDidNot()
    {
        var changed = 0;
        _Tools.Changes.Changed += (_, _) => changed++;
        var vm = await Loaded(Sample.VM());

        await vm.Maintenance.RunAsync();
        Assert.Equal(1, changed);

        _Runners.Build.MaintenanceFails = new InvalidOperationException("A build of DevBox is running, so maintenance was not started.");
        await vm.Maintenance.RunAsync();
        Assert.Equal(1, changed);
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

        Assert.False(vm.BuildFromPhase.BuildCommand.CanExecute(null));
        Assert.False(vm.Maintenance.RunCommand.CanExecute(null));
        Assert.StartsWith(said, vm.RunNote);
        Assert.True(vm.ChecksCommand.CanExecute(null));
        Assert.True(vm.LogCommand.CanExecute(null));

        await vm.Maintenance.RunAsync();
        await vm.BuildFromPhase.BuildAsync();
        Assert.Empty(_Runners.Build.MaintenanceCalls);
        Assert.Empty(_Launcher.Started);
    }

    [Fact]
    public async Task WhenARunStartsOrEnds_TheButtonsFollow()
    {
        var vm = await Loaded(Sample.VM());
        var raised = 0;
        vm.Maintenance.RunCommand.CanExecuteChanged += (_, _) => raised++;

        vm.Update(Sample.VM() with
        {
            Run = RunningNow("Maintenance")
        });

        Assert.False(vm.Maintenance.RunCommand.CanExecute(null));
        Assert.True(raised > 0);

        vm.Update(Sample.VM());

        Assert.True(vm.Maintenance.RunCommand.CanExecute(null));
    }

    [Fact]
    public async Task WithoutAMaintenanceTask_MaintenanceCannotStart_AndTheNoteSaysHowToScheduleIt()
    {
        var vm = await Loaded(Sample.VM() with
        {
            MaintenanceTask = "Not registered"
        });

        Assert.False(vm.Maintenance.RunCommand.CanExecute(null));
        Assert.True(vm.BuildFromPhase.BuildCommand.CanExecute(null));
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

        Assert.Equal(8, vm.BuildFromPhase.SelectedPhase?.Number);
    }

    [Fact]
    public async Task Update_KeepsAPhaseChosenByHand_WhenTheLastBuildIsTheSame()
    {
        var vm = await Loaded(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.FAILED, 7)
        });
        vm.BuildFromPhase.SelectedPhase = vm.BuildFromPhase.Phases[1];

        vm.Update(Sample.VM() with
        {
            LastBuild = LastBuild(VMRun.FAILED, 7)
        });

        Assert.Equal(1, vm.BuildFromPhase.SelectedPhase?.Number);
    }

    private static RemovalPlan PlanOf(string name = "DevBox")
    {
        return new()
        {
            Name = name,
            HyperVState = "Off",
            Items = [new("Folder", $@"C:\LazyVM\{name}", 50 * _GB)],
            TotalSize = 50 * _GB,
        };
    }

    [Fact]
    public async Task Delete_ShowsWhatGoes_AndOnYes_RemovesTheVM()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Deletion.Removed += (_, _) => removed++;
        var listChanged = 0;
        _Tools.Changes.Changed += (_, _) => listChanged++;

        await vm.Deletion.DeleteAsync();

        var asked = Assert.Single(_Tools.Dialogs.RemovalsAsked);
        Assert.Equal("DevBox", asked.Name);
        Assert.Contains(@"Folder C:\LazyVM\DevBox, 50 GB", asked.Lines.Select(line => line.Text));
        Assert.Equal(["DevBox"], _Runners.Removal.RemovalPlanCalls);
        Assert.Equal(["DevBox"], _Runners.Removal.RemoveCalls);
        Assert.Equal(1, removed);
        Assert.Equal(1, listChanged);
        Assert.Equal("DevBox has been deleted.", vm.Status);
        Assert.False(vm.Deletion.IsDeleting);
    }

    [Fact]
    public async Task Delete_OnNo_DeletesNothing()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Tools.Dialogs.ConfirmsRemoval = false;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Deletion.Removed += (_, _) => removed++;

        await vm.Deletion.DeleteAsync();

        Assert.Single(_Tools.Dialogs.RemovalsAsked);
        Assert.Empty(_Runners.Removal.RemoveCalls);
        Assert.Equal(0, removed);
        Assert.Equal("DevBox was not deleted.", vm.Status);
        Assert.True(vm.Deletion.DeleteCommand.CanExecute(null));
    }

    [Fact]
    public async Task Delete_WhenWhatGoesCannotBeRead_AsksNothing_AndSaysWhy()
    {
        _Runners.Removal.RemovalPlanThrows(new InvalidOperationException("Cannot tell what VM 'Other' uses, so nothing has been removed."));
        var vm = await Loaded(Sample.VM());

        await vm.Deletion.DeleteAsync();

        Assert.Empty(_Tools.Dialogs.RemovalsAsked);
        Assert.Empty(_Runners.Removal.RemoveCalls);
        Assert.Equal("DevBox cannot be deleted now: Cannot tell what VM 'Other' uses, so nothing has been removed.", vm.Status);
    }

    [Fact]
    public async Task Delete_ThatOnlyPartlyRemoved_SaysWhatIsLeft_AndKeepsTheWindow()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Runners.Removal.ReturnsRemovalPlan(new RemovalPlan { Name = "DevBox", Items = [new(RemovalItem.FILE, @"E:\Disks\DevBox\SQL.vhdx", _GB)] });
        _Runners.Removal.RemoveFails = new InvalidOperationException(@"'DevBox' was only partly removed. The log lists what is left: C:\LazyVM\DevBox\Logs\DevBox.log");
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());
        var removed = 0;
        vm.Deletion.Removed += (_, _) => removed++;
        var listChanged = 0;
        _Tools.Changes.Changed += (_, _) => listChanged++;

        await vm.Deletion.DeleteAsync();

        Assert.Equal(0, removed);
        Assert.Equal(1, listChanged);
        Assert.Equal(
            @"Deleting DevBox did not finish: 'DevBox' was only partly removed. The log lists what is left: C:\LazyVM\DevBox\Logs\DevBox.log Still there: E:\Disks\DevBox\SQL.vhdx.",
            vm.Status);
        Assert.True(vm.Deletion.DeleteCommand.CanExecute(null));
    }

    [Fact]
    public async Task Delete_RunsInTheVMsSession_AndReadsWhatIsLeftInTheHosts()
    {
        // The delete closes the VM's session, and its Hyper-V Id may be gone:
        // what is left is read without it, so no new session starts for it.
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Runners.Removal.ReturnsRemovalPlan(new RemovalPlan { Name = "DevBox", Items = [new(RemovalItem.FILE, @"E:\Disks\DevBox\SQL.vhdx", _GB)] });
        _Runners.Removal.RemoveFails = new InvalidOperationException("'DevBox' was only partly removed.");
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM() with { Id = _DEV_BOX_ID });

        await vm.Deletion.DeleteAsync();

        Assert.Equal([_DEV_BOX_ID], _Runners.Removal.RemoveIds);
        Assert.Equal([_DEV_BOX_ID, null], _Runners.Removal.RemovalPlanIds);
    }

    [Fact]
    public async Task Delete_ThatFailed_WhenWhatIsLeftCannotBeRead_GivesTheModulesReason()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Runners.Removal.RemovalPlanThrows(new InvalidOperationException("There is no VM named DevBox."));
        _Runners.Removal.RemoveFails = new InvalidOperationException("'DevBox' was only partly removed.");
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());

        await vm.Deletion.DeleteAsync();

        Assert.Equal("Deleting DevBox did not finish: 'DevBox' was only partly removed.", vm.Status);
    }

    [Fact]
    public async Task WhileDeleting_NothingElseCanStart()
    {
        _Runners.Removal.ReturnsRemovalPlan(PlanOf());
        _Runners.Removal.RemoveGate = new TaskCompletionSource();
        _Tools.Dialogs.ConfirmsRemoval = true;
        var vm = await Loaded(Sample.VM());

        var deleting = vm.Deletion.DeleteAsync();

        Assert.True(vm.Deletion.IsDeleting);
        Assert.Equal("Deleting DevBox", vm.Status);
        Assert.False(vm.Deletion.DeleteCommand.CanExecute(null));
        Assert.False(vm.BuildFromPhase.BuildCommand.CanExecute(null));
        Assert.False(vm.Maintenance.RunCommand.CanExecute(null));
        await vm.BuildFromPhase.BuildAsync();
        await vm.Maintenance.RunAsync();
        Assert.Empty(_Launcher.Started);
        Assert.Empty(_Runners.Build.MaintenanceCalls);

        _Runners.Removal.RemoveGate.SetResult();
        await deleting;
        Assert.Equal(["DevBox"], _Runners.Removal.RemoveCalls);
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

        Assert.False(vm.Deletion.DeleteCommand.CanExecute(null));
        Assert.Equal(said, vm.Deletion.Note);
        Assert.True(vm.Deletion.HasNote);

        await vm.Deletion.DeleteAsync();
        Assert.Empty(_Runners.Removal.RemovalPlanCalls);
    }

    [Fact]
    public async Task WhenNothingIsRunning_DeleteCanStart_WithNoNote()
    {
        var vm = await Loaded(Sample.VM());

        Assert.True(vm.Deletion.DeleteCommand.CanExecute(null));
        Assert.False(vm.Deletion.HasNote);
    }

    [Fact]
    public async Task ARunThatStartsLater_DisablesDelete()
    {
        var vm = await Loaded(Sample.VM());
        var changed = 0;
        vm.Deletion.DeleteCommand.CanExecuteChanged += (_, _) => changed++;

        vm.Update(Sample.VM() with
        {
            Run = RunningNow("Maintenance")
        });

        Assert.False(vm.Deletion.DeleteCommand.CanExecute(null));
        Assert.True(changed > 0);
    }

    [Fact]
    public async Task ARunThatStartsLater_ShowsInTheDeleteNote()
    {
        var vm = await Loaded(Sample.VM());
        var changed = new List<string?>();
        vm.Deletion.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.Update(Sample.VM() with
        {
            Run = RunningNow("Maintenance")
        });

        Assert.True(vm.Deletion.HasNote);
        Assert.Contains(changed, name => string.IsNullOrEmpty(name) || name == nameof(VMDeletionViewModel.Note));
    }

    [Fact]
    public void ClosingTheVMWindow_ClosesEveryWindowItOpened()
    {
        _Runners.Checks.ReturnsChecks(Sample.Check());
        _Runners.Log.ReturnsLog();
        _Runners.Restore.ReturnsRestorePoints();
        _Runners.RecoveryKeys.ReturnsRecoveryKeys();
        _Runners.SecurityFindings.ReturnsSecurityFindings();
        _Runners.SecurityFindings.ReturnsSecurityApprovals();
        _Runners.Dashboard.ReturnsRun(RunningNow(VMRun.BUILD));
        _Tools.OpenVM(Sample.VM() with { Run = RunningNow(VMRun.BUILD) });
        var window = Assert.IsType<VMViewModel>(Assert.Single(_Tools.Windows.Shown));
        window.ChecksCommand.Execute(null);
        window.LogCommand.Execute(null);
        window.RestorePointsCommand.Execute(null);
        window.RecoveryKeysCommand.Execute(null);
        window.PasswordCommand.Execute(null);
        window.SecurityFindingsCommand.Execute(null);
        window.BuildProgressCommand.Execute(null);
        var opened = _Tools.Windows.Shown.Skip(1).ToList();
        Assert.Equal(7, opened.Count);

        _Tools.Windows.UserCloses(window);

        Assert.Equal(opened, _Tools.Windows.Closed);
    }

    [Fact]
    public async Task ABuildStartedFromTheVMWindow_HasItsProgressClosedWithIt()
    {
        _Runners.Dashboard.ReturnsRun(null, "DevBox");
        _Tools.OpenVM(Sample.VM());
        var window = Assert.IsType<VMViewModel>(Assert.Single(_Tools.Windows.Shown));
        await window.BuildFromPhase.LoadAsync();

        await window.BuildFromPhase.BuildAsync();
        var progress = Assert.IsType<BuildProgressViewModel>(_Tools.Windows.Shown[1]);
        _Tools.Windows.UserCloses(window);

        Assert.Same(progress, Assert.Single(_Tools.Windows.Closed));
    }

    [Fact]
    public void ClosingAWindowTheVMWindowOpened_LeavesTheVMWindowOpen()
    {
        _Runners.Log.ReturnsLog();
        _Tools.OpenVM(Sample.VM());
        var window = Assert.IsType<VMViewModel>(Assert.Single(_Tools.Windows.Shown));
        window.LogCommand.Execute(null);

        _Tools.Windows.UserCloses(_Tools.Windows.Shown[1]);

        Assert.Same(window, _Tools.Windows.Find<VMViewModel>("vm:DevBox"));
        Assert.Empty(_Tools.Windows.Closed);
    }

    [Fact]
    public async Task RestorePoints_OpensTheVMsRestoreWindow_AndReadsThePoints()
    {
        _Runners.Restore.ReturnsRestorePoints();
        var vm = await Loaded(Sample.VM());

        vm.RestorePointsCommand.Execute(null);

        Assert.Equal("DevBox", Assert.IsType<RestoreViewModel>(Assert.Single(_Tools.Windows.Shown)).Name);
        Assert.Equal(["DevBox"], _Runners.Restore.RestorePointCalls);
    }

    [Fact]
    public async Task RestorePoints_Twice_BringsTheOpenWindowToTheFront()
    {
        _Runners.Restore.ReturnsRestorePoints();
        var vm = await Loaded(Sample.VM());

        vm.RestorePointsCommand.Execute(null);
        vm.RestorePointsCommand.Execute(null);

        Assert.Same(Assert.Single(_Tools.Windows.Shown), Assert.Single(_Tools.Windows.BroughtToFront));
    }

    [Fact]
    public async Task ARefresh_ReachesTheOpenRestoreWindow()
    {
        _Runners.Restore.ReturnsRestorePoints(new VMRestorePoint("20261008-193000", new DateTime(2026, 10, 8), true));
        var vm = await Loaded(Sample.VM());
        vm.RestorePointsCommand.Execute(null);
        var restore = Assert.IsType<RestoreViewModel>(Assert.Single(_Tools.Windows.Shown));
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

using System.Management.Automation;

using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the dashboard runner turns what Get-LazyVMDashboard returns into plain C# values, and where it runs.</summary>
public sealed class LazyVMDashboardRunnerTests
{
    private static readonly Guid _DEV_BOX = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");

    [Fact]
    public async Task GetLazyVMDashboardAsync_RunsInTheHostsSession()
    {
        using var sessions = new ScriptedSessions();

        await new LazyVMDashboardRunner(sessions).GetLazyVMDashboardAsync(CancellationToken.None);

        Assert.Same(sessions.ForHost(), sessions.Call.Session);
        Assert.Equal("Get-LazyVMDashboard", sessions.Call.Command);
    }

    [Fact]
    public async Task GetLazyVMAsync_RunsInTheVMsSession_AndGivesThatVM()
    {
        using var sessions = new ScriptedSessions { Answer = ScriptedSessions.Output(Entry(("Name", "DevBox"), ("Id", _DEV_BOX))) };

        var vm = await new LazyVMDashboardRunner(sessions).GetLazyVMAsync(_DEV_BOX, "DevBox", CancellationToken.None);

        Assert.Same(sessions.ForVM(_DEV_BOX), sessions.Call.Session);
        Assert.Equal("DevBox", sessions.Call.Parameters["Name"]);
        Assert.Equal(_DEV_BOX, vm?.Id);
    }

    [Fact]
    public void ToDashboard_ReadsEveryField()
    {
        var created = new DateTime(2026, 10, 1, 9, 0, 0);
        var disk = Entry(("Name", "DevBox.vhdx"), ("Path", @"D:\VMs\DevBox.vhdx"), ("Used", 10L), ("Maximum", 20L));

        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(
            ("Name", "DevBox"),
            ("State", "Running"),
            ("Created", created),
            ("MemoryAssigned", 8L),
            ("MemoryMaximum", 16L),
            ("Disks", new object[] { disk }),
            ("DiskSpaceUsed", 10L),
            ("MaintenanceTime", "02:00"),
            ("MaintenanceTask", "Registered"),
            ("LastMaintenance", created),
            ("LastMaintenanceResult", "Succeeded"),
            ("LastSecurityScan", created),
            ("OpenFindings", 2),
            ("OriginalConfig", @"D:\VMs\DevBox\Config\VM.Template.json"),
            ("CreatedFromTemplate", "PlainWindows"),
            ("GreenTemplate", "DevBox-latest"),
            ("GreenTemplateUpdated", created),
            ("RecoveryKeys", 3),
            ("UnexportedRecoveryKeys", 1),
            ("RecoveryKeysExported", created),
            ("Settings", "OK"),
            ("Problems", new[] { "Disks: access denied" })));

        Assert.Equal("DevBox", vm.Name);
        Assert.Equal("Running", vm.State);
        Assert.Equal(created, vm.Created);
        Assert.Equal(8L, vm.MemoryAssigned);
        Assert.Equal(16L, vm.MemoryMaximum);
        Assert.Equal(new VMDisk("DevBox.vhdx", @"D:\VMs\DevBox.vhdx", 10, 20), Assert.Single(vm.Disks));
        Assert.Equal(10L, vm.DiskSpaceUsed);
        Assert.Equal("02:00", vm.MaintenanceTime);
        Assert.Equal("Registered", vm.MaintenanceTask);
        Assert.Equal(created, vm.LastMaintenance);
        Assert.Equal("Succeeded", vm.LastMaintenanceResult);
        Assert.Equal(created, vm.LastSecurityScan);
        Assert.Equal(2, vm.OpenFindings);
        Assert.Equal(@"D:\VMs\DevBox\Config\VM.Template.json", vm.OriginalConfig);
        Assert.Equal("PlainWindows", vm.CreatedFromTemplate);
        Assert.Equal("DevBox-latest", vm.GreenTemplate);
        Assert.Equal(created, vm.GreenTemplateUpdated);
        Assert.Equal(3, vm.RecoveryKeys);
        Assert.Equal(1, vm.UnexportedRecoveryKeys);
        Assert.Equal(created, vm.RecoveryKeysExported);
        Assert.Equal("OK", vm.Settings);
        Assert.Equal(["Disks: access denied"], vm.Problems);
    }

    [Fact]
    public void ToDashboard_ReadsTheVMsHyperVId()
    {
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("Id", _DEV_BOX), ("State", "Running")));

        Assert.Equal(_DEV_BOX, vm.Id);
    }

    [Fact]
    public void ToDashboard_OfAVMNotBuiltYet_LeavesTheEmptyFieldsEmpty()
    {
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(
            ("Name", "NewBox"),
            ("State", "Not built"),
            ("Created", null),
            ("MemoryAssigned", null),
            ("MemoryMaximum", null),
            ("Disks", Array.Empty<object>()),
            ("DiskSpaceUsed", null),
            ("OpenFindings", null),
            ("Settings", "OK"),
            ("Problems", Array.Empty<string>())));

        Assert.Equal("Not built", vm.State);
        Assert.Null(vm.Id);
        Assert.Null(vm.Created);
        Assert.Null(vm.MemoryAssigned);
        Assert.Null(vm.MemoryMaximum);
        Assert.Null(vm.CreatedFromTemplate);
        Assert.Empty(vm.Disks);
        Assert.Null(vm.OpenFindings);
        Assert.Empty(vm.Problems);
    }

    [Fact]
    public void ToDashboard_WrappedValues_AreUnwrapped()
    {
        // PowerShell often hands values back wrapped in a PSObject.
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(
            ("Name", PSObject.AsPSObject("DevBox")),
            ("State", PSObject.AsPSObject("Off")),
            ("OpenFindings", PSObject.AsPSObject(1)),
            ("Problems", PSObject.AsPSObject(new object[] { PSObject.AsPSObject("Templates: access denied") }))));

        Assert.Equal("DevBox", vm.Name);
        Assert.Equal("Off", vm.State);
        Assert.Equal(1, vm.OpenFindings);
        Assert.Equal(["Templates: access denied"], vm.Problems);
    }

    [Fact]
    public void ToDashboard_DatesWithAnOffset_AreReadAsLocalTime()
    {
        // LastSecurityScan comes from the scan record as a DateTimeOffset.
        var scanned = new DateTimeOffset(2026, 11, 15, 2, 6, 10, TimeSpan.FromHours(-8));

        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(
            ("Name", "DevBox"),
            ("Created", scanned),
            ("LastMaintenance", scanned),
            ("LastSecurityScan", PSObject.AsPSObject(scanned)),
            ("GreenTemplateUpdated", scanned)));

        Assert.Equal(scanned.LocalDateTime, vm.Created);
        Assert.Equal(scanned.LocalDateTime, vm.LastMaintenance);
        Assert.Equal(scanned.LocalDateTime, vm.LastSecurityScan);
        Assert.Equal(scanned.LocalDateTime, vm.GreenTemplateUpdated);
        Assert.Empty(vm.Problems);
    }

    [Fact]
    public void ToDashboard_AValueThatCannotBeRead_IsLeftEmptyAndNamedInProblems()
    {
        // One odd value must not fail the whole refresh: the rest of the VM still shows.
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(
            ("Name", "DevBox"),
            ("State", "Running"),
            ("LastSecurityScan", "not a date"),
            ("OpenFindings", 2),
            ("Problems", new[] { "Disks: access denied" })));

        Assert.Equal("Running", vm.State);
        Assert.Null(vm.LastSecurityScan);
        Assert.Equal(2, vm.OpenFindings);
        Assert.Equal(["Disks: access denied", "Last security scan: could not be read"], vm.Problems);
    }

    [Fact]
    public void ToDashboard_ReadsTheRunAndTheLastBuild()
    {
        var started = new DateTime(2026, 11, 16, 9, 0, 0);
        var run = Entry(
            ("Command", "Build"), ("Status", "Running"), ("ProcessId", 4242), ("Started", started), ("Ended", null),
            ("Phase", 7), ("PhaseName", "Windows"), ("UnfinishedPhase", null), ("PhasesWithProblems", Array.Empty<object>()),
            ("StopRequested", true));

        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Running"), ("Run", run), ("LastBuild", run)));

        var expected = new VMRun
        {
            Command = "Build",
            Status = "Running",
            ProcessId = 4242,
            Started = started,
            Phase = 7,
            PhaseName = "Windows",
            StopRequested = true,
        };
        Assert.Equal(expected, vm.Run);
        Assert.Equal(expected, vm.LastBuild);
        Assert.True(vm.Run!.IsRunning);
        Assert.True(vm.Run.IsBuild);
        Assert.Empty(vm.Problems);
    }

    [Fact]
    public void ToDashboard_WithNoRunYet_LeavesItEmpty()
    {
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", null)));

        Assert.Null(vm.Run);
        Assert.Null(vm.LastBuild);
    }

    [Fact]
    public void ToDashboard_ARunValueThatCannotBeRead_IsNamedInProblems()
    {
        var vm = LazyVMDashboardRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", Entry(("Status", "Failed"), ("Phase", "seven")))));

        Assert.Equal("Failed", vm.Run!.Status);
        Assert.Null(vm.Run.Phase);
        Assert.Equal(["Run phase: could not be read"], vm.Problems);
    }
}

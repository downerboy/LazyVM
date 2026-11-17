using System.Management.Automation;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>How the runner turns what Get-LazyVMDashboard returns into plain C# values.</summary>
public sealed class CommandRunnerTests
{
    private static PSObject Entry(params (string Name, object? Value)[] properties)
    {
        var entry = new PSObject();
        foreach (var (name, value) in properties)
        {
            entry.Properties.Add(new PSNoteProperty(name, value));
        }
        return entry;
    }

    [Fact]
    public void ToDashboard_ReadsEveryField()
    {
        var created = new DateTime(2026, 10, 1, 9, 0, 0);
        var disk = Entry(("Name", "DevBox.vhdx"), ("Path", @"D:\VMs\DevBox.vhdx"), ("Used", 10L), ("Maximum", 20L));

        var vm = CommandRunner.ToDashboard(Entry(
            ("Name", "DevBox"),
            ("State", "Running"),
            ("Created", created),
            ("MemoryAssigned", 8L),
            ("Disks", new object[] { disk }),
            ("DiskSpaceUsed", 10L),
            ("MaintenanceTime", "02:00"),
            ("MaintenanceTask", "Registered"),
            ("LastMaintenance", created),
            ("LastMaintenanceResult", "Succeeded"),
            ("LastSecurityScan", created),
            ("OpenFindings", 2),
            ("OriginalConfig", @"D:\VMs\DevBox\Config\VM.Template.json"),
            ("GreenTemplate", "DevBox-latest"),
            ("GreenTemplateUpdated", created),
            ("Settings", "OK"),
            ("Problems", new[] { "Disks: access denied" })));

        Assert.Equal("DevBox", vm.Name);
        Assert.Equal("Running", vm.State);
        Assert.Equal(created, vm.Created);
        Assert.Equal(8L, vm.MemoryAssigned);
        Assert.Equal(new VMDisk("DevBox.vhdx", @"D:\VMs\DevBox.vhdx", 10, 20), Assert.Single(vm.Disks));
        Assert.Equal(10L, vm.DiskSpaceUsed);
        Assert.Equal("02:00", vm.MaintenanceTime);
        Assert.Equal("Registered", vm.MaintenanceTask);
        Assert.Equal(created, vm.LastMaintenance);
        Assert.Equal("Succeeded", vm.LastMaintenanceResult);
        Assert.Equal(created, vm.LastSecurityScan);
        Assert.Equal(2, vm.OpenFindings);
        Assert.Equal(@"D:\VMs\DevBox\Config\VM.Template.json", vm.OriginalConfig);
        Assert.Equal("DevBox-latest", vm.GreenTemplate);
        Assert.Equal(created, vm.GreenTemplateUpdated);
        Assert.Equal("OK", vm.Settings);
        Assert.Equal(["Disks: access denied"], vm.Problems);
    }

    [Fact]
    public void ToDashboard_OfAVMNotBuiltYet_LeavesTheEmptyFieldsEmpty()
    {
        var vm = CommandRunner.ToDashboard(Entry(
            ("Name", "NewBox"),
            ("State", "Not built"),
            ("Created", null),
            ("MemoryAssigned", null),
            ("Disks", Array.Empty<object>()),
            ("DiskSpaceUsed", null),
            ("OpenFindings", null),
            ("Settings", "OK"),
            ("Problems", Array.Empty<string>())));

        Assert.Equal("Not built", vm.State);
        Assert.Null(vm.Created);
        Assert.Null(vm.MemoryAssigned);
        Assert.Empty(vm.Disks);
        Assert.Null(vm.OpenFindings);
        Assert.Empty(vm.Problems);
    }

    [Fact]
    public void ToDashboard_WrappedValues_AreUnwrapped()
    {
        // PowerShell often hands values back wrapped in a PSObject.
        var vm = CommandRunner.ToDashboard(Entry(
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

        var vm = CommandRunner.ToDashboard(Entry(
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
        var vm = CommandRunner.ToDashboard(Entry(
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
    public void ThrowIfFailed_IgnoresErrorsTheCommandSilenced_WhenItReturnedVMs()
    {
        // Get-LazyVM asks Hyper-V for each VM with -ErrorAction SilentlyContinue;
        // in a hosted runspace those errors still reach the error stream.
        var errors = new[] { Error("Hyper-V was unable to find a virtual machine with name 'NewBox'.") };

        CommandRunner.ThrowIfFailed([PSObject.AsPSObject("an entry")], errors);
    }

    [Fact]
    public void ThrowIfFailed_WithErrorsAndNothingReturned_Throws()
    {
        var errors = new[] { Error("The LazyVM folder was not found.") };

        var failure = Assert.Throws<InvalidOperationException>(() => CommandRunner.ThrowIfFailed([], errors));

        Assert.Equal("The LazyVM folder was not found.", failure.Message);
    }

    [Fact]
    public void ThrowIfFailed_WithNoVMsAndNoErrors_DoesNotThrow()
    {
        CommandRunner.ThrowIfFailed([], []);
    }

    private static ErrorRecord Error(string message) =>
        new(new InvalidOperationException(message), "Test", ErrorCategory.NotSpecified, null);

    [Fact]
    public void ModuleSearchPath_HoldsOnlyFoldersAdministratorsControl()
    {
        // The app runs elevated: a module autoloaded from a folder the user can
        // write to, such as Documents\PowerShell\Modules, would run as administrator.
        var folders = CommandRunner.ModuleSearchPath.Split(System.IO.Path.PathSeparator);

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        Assert.Equal(System.IO.Path.Combine(programFiles, "LazyVM", "Modules"), folders[0]);
        Assert.Contains(System.IO.Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "Modules"), folders);
        Assert.All(folders, folder => Assert.True(
            folder.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(windows, StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(System.IO.Path.GetDirectoryName(typeof(PSObject).Assembly.Location)!, StringComparison.OrdinalIgnoreCase),
            $"{folder} is not a folder only administrators can change"));
        Assert.DoesNotContain(folders, folder =>
            folder.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void Constructor_DoesNotStartPowerShell()
    {
        // A fake runner, or the window before its first refresh, must not need the module installed.
        using var runner = new CommandRunner();

        Assert.False(runner.IsStarted);
    }

    [Fact]
    public void ToCheck_ReadsEveryField()
    {
        var check = CommandRunner.ToCheck(Entry(
            ("Name", "DevBox"),
            ("Area", "Schedule"),
            ("Check", "Maintenance task"),
            ("Status", "WARN"),
            ("Detail", "not scheduled"),
            ("Fix", "Schedule it with: Register-LazyVMMaintenance -Name DevBox")));

        Assert.Equal(new VMCheck("Schedule", "Maintenance task", "WARN", "not scheduled", "Schedule it with: Register-LazyVMMaintenance -Name DevBox"), check);
    }

    [Fact]
    public void ToCheck_WithoutAFix_HasAnEmptyFix()
    {
        var check = CommandRunner.ToCheck(Entry(("Area", "Host"), ("Check", "LazyVM folder"), ("Status", "OK"), ("Detail", @"C:\Users\me\LazyVM")));

        Assert.Equal(string.Empty, check.Fix);
    }

    [Fact]
    public void ToLogEntry_ReadsEveryField()
    {
        var time = new DateTime(2026, 11, 12, 2, 10, 5);

        var entry = CommandRunner.ToLogEntry(Entry(("Time", time), ("Level", "Error"), ("Message", "Windows Update failed\nwith 0x80070005")));

        Assert.Equal(new VMLogEntry(time, "Error", "Windows Update failed\nwith 0x80070005"), entry);
    }

    [Fact]
    public void ToLogEntry_ATimeThatCannotBeRead_IsLeftEmpty()
    {
        var entry = CommandRunner.ToLogEntry(Entry(("Time", "yesterday"), ("Level", "Info"), ("Message", "Started")));

        Assert.Null(entry.Time);
        Assert.Equal("Started", entry.Message);
    }

    [Fact]
    public void ToDashboard_ReadsTheRunAndTheLastBuild()
    {
        var started = new DateTime(2026, 11, 16, 9, 0, 0);
        var run = Entry(
            ("Command", "Build"), ("Status", "Running"), ("ProcessId", 4242), ("Started", started), ("Ended", null),
            ("Phase", 7), ("PhaseName", "Windows"), ("UnfinishedPhase", null), ("PhasesWithProblems", Array.Empty<object>()),
            ("StopRequested", true));

        var vm = CommandRunner.ToDashboard(Entry(("Name", "DevBox"), ("State", "Running"), ("Run", run), ("LastBuild", run)));

        var expected = new VMRun
        {
            Command = "Build", Status = "Running", ProcessId = 4242, Started = started, Phase = 7, PhaseName = "Windows", StopRequested = true,
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
        var vm = CommandRunner.ToDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", null)));

        Assert.Null(vm.Run);
        Assert.Null(vm.LastBuild);
    }

    [Fact]
    public void ToDashboard_ARunValueThatCannotBeRead_IsNamedInProblems()
    {
        var vm = CommandRunner.ToDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", Entry(("Status", "Failed"), ("Phase", "seven")))));

        Assert.Equal("Failed", vm.Run!.Status);
        Assert.Null(vm.Run.Phase);
        Assert.Equal(["Run phase: could not be read"], vm.Problems);
    }
}

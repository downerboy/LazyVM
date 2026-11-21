using System.Management.Automation;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>How the _Runner turns what Get-LazyVMDashboard returns into plain C# values.</summary>
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
    public void UserNameOf_ACredential_GivesItsUserName_AndDisposesThePassword()
    {
        using var password = new System.Security.SecureString();
        password.AppendChar('x');
        var credential = new PSCredential("devadmin", password);

        Assert.Equal("devadmin", PowerShellCommandRunner.LazyVMUserNameOf([PSObject.AsPSObject(credential)]));
        Assert.Throws<ObjectDisposedException>(() => password.Length);
    }

    [Fact]
    public void PasswordOf_APlainCredential_GivesItsPassword()
    {
        Assert.Equal("Correct-Horse-9", PowerShellCommandRunner.LazyVMPasswordOf([Entry(("UserName", "devadmin"), ("Password", "Correct-Horse-9"))]));
    }

    [Fact]
    public void UserNameOf_Nothing_Throws()
    {
        Assert.Throws<InvalidOperationException>(() => PowerShellCommandRunner.LazyVMUserNameOf([]));
    }

    [Fact]
    public void ToRecoveryKey_ReadsEveryField()
    {
        var recorded = new DateTime(2026, 10, 1, 9, 30, 0);

        var key = PowerShellCommandRunner.LazyVMRecoveryKey(Entry(
            ("Name", "DevBox"),
            ("Disk", "OS disk"),
            ("DiskGuid", "{AAAAAAAA-0000-0000-0000-000000000001}"),
            ("KeyId", "{33333333-0000-0000-0000-000000000000}"),
            ("Recorded", recorded),
            ("Exported", true)));

        Assert.Equal(new VMRecoveryKey("OS disk", "{AAAAAAAA-0000-0000-0000-000000000001}", "{33333333-0000-0000-0000-000000000000}", recorded, true), key);
    }

    [Fact]
    public void ToRecoveryKey_WithNoKeyIDOrDate_LeavesThemEmpty()
    {
        var key = PowerShellCommandRunner.LazyVMRecoveryKey(Entry(("Disk", "User disk"), ("DiskGuid", "{B}"), ("KeyId", ""), ("Recorded", null), ("Exported", false)));

        Assert.Equal(string.Empty, key.KeyId);
        Assert.Null(key.Recorded);
        Assert.False(key.Exported);
    }

    [Fact]
    public void RecoveryPasswordOf_GivesOnlyThatDisksPassword_WhateverTheCaseOfItsGuid()
    {
        var keys = new[]
        {
            Entry(("DiskGuid", "{AAAAAAAA-0000-0000-0000-000000000001}"), ("RecoveryPassword", "111111")),
            Entry(("DiskGuid", "{BBBBBBBB-0000-0000-0000-000000000002}"), ("RecoveryPassword", "222222")),
        };

        Assert.Equal("222222", PowerShellCommandRunner.LazyVMDisRecoveryPasswordOf(keys, "{bbbbbbbb-0000-0000-0000-000000000002}"));
    }

    [Fact]
    public void RecoveryPasswordOf_ADiskWithNoneStored_Throws()
    {
        var keys = new[] { Entry(("DiskGuid", "{A}"), ("RecoveryPassword", "111111")) };

        var thrown = Assert.Throws<InvalidOperationException>(() => PowerShellCommandRunner.LazyVMDisRecoveryPasswordOf(keys, "{B}"));

        Assert.Equal("No recovery password is stored for that disk now. Close this window and open it again to see the keys stored now.", thrown.Message);
    }

    [Fact]
    public void ToDashboard_ReadsEveryField()
    {
        var created = new DateTime(2026, 10, 1, 9, 0, 0);
        var disk = Entry(("Name", "DevBox.vhdx"), ("Path", @"D:\VMs\DevBox.vhdx"), ("Used", 10L), ("Maximum", 20L));

        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(
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
    public void ToDashboard_OfAVMNotBuiltYet_LeavesTheEmptyFieldsEmpty()
    {
        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(
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
        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(
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

        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(
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
        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(
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

        PowerShellCommandRunner.ThrowIfFailed([PSObject.AsPSObject("an entry")], errors);
    }

    [Fact]
    public void ThrowIfFailed_WithErrorsAndNothingReturned_Throws()
    {
        var errors = new[] { Error("The LazyVM folder was not found.") };

        var failure = Assert.Throws<InvalidOperationException>(() => PowerShellCommandRunner.ThrowIfFailed([], errors));

        Assert.Equal("The LazyVM folder was not found.", failure.Message);
    }

    [Fact]
    public void ThrowIfFailed_WithNoVMsAndNoErrors_DoesNotThrow()
    {
        PowerShellCommandRunner.ThrowIfFailed([], []);
    }

    [Fact]
    public void ThrowIfFailed_ForACommandThatFailsOnlyByThrowing_IgnoresTheErrorsItSilenced()
    {
        // Remove-LazyVM returns nothing, and Get-LazyVMRestorePoint nothing
        // for a VM with no restore points; both ask for tasks or checkpoints
        // that may not be there with -ErrorAction SilentlyContinue: only an
        // error they throw is their failure.
        var errors = new[] { Error("No MSFT_ScheduledTask objects found.") };

        PowerShellCommandRunner.ThrowIfFailed([], errors, failsOnlyByThrowing: true);
    }

    [Fact]
    public void ThrowIfCommandWroteError_ARefusedId_ThrowsWithTheModulesReason_AndIgnoresWhatItSilenced()
    {
        // As Approve-LazyVMSecurityFinding refuses an Id: a helper throws, the
        // command catches it and writes it with its own $PSCmdlet, through a
        // simple function as Write-CommandItemError does. An error of a call
        // inside it reaches the error stream first, and must not count.
        using var shell = PowerShell.Create();
        shell.AddScript("""
            function Write-ItemError { param($Cmdlet, $ErrorRecord) $Cmdlet.WriteError($ErrorRecord) }
            function Get-Approvable { param($Id) throw "The finding $Id is not an open finding of the last scan." }
            function global:Approve-LazyVMSecurityFinding {
                [CmdletBinding()]
                param([string]$Id)
                $null = Get-Item -LiteralPath 'Z:\lazyvm-not-there'
                & { try { Get-Approvable -Id $Id } catch { Write-ItemError -Cmdlet $PSCmdlet -ErrorRecord $_ } }
            }
            """).Invoke();
        shell.Commands.Clear();
        shell.Streams.Error.Clear();
        shell.AddCommand("Approve-LazyVMSecurityFinding").AddParameter("Id", "Task:x:1").Invoke();
        Assert.Equal(2, shell.Streams.Error.Count);

        var failure = Assert.Throws<InvalidOperationException>(
            () => PowerShellCommandRunner.ThrowIfCommandWroteError("Approve-LazyVMSecurityFinding", shell.Streams.Error));

        Assert.Equal("The finding Task:x:1 is not an open finding of the last scan.", failure.Message);
    }

    [Fact]
    public void ThrowIfCommandWroteError_OnlyErrorsOfCallsInsideIt_DoesNotThrow()
    {
        // An error of a call inside the module, which it does not treat as a
        // failure, reaches the error stream named for that call, not the command.
        using var shell = PowerShell.Create();
        shell.AddScript("""
            function global:Revoke-LazyVMSecurityFinding {
                [CmdletBinding()]
                param()
                $null = Get-Item -LiteralPath 'Z:\lazyvm-not-there'
            }
            """).Invoke();
        shell.Commands.Clear();
        shell.Streams.Error.Clear();
        shell.AddCommand("Revoke-LazyVMSecurityFinding").Invoke();
        Assert.NotEmpty(shell.Streams.Error);

        PowerShellCommandRunner.ThrowIfCommandWroteError("Revoke-LazyVMSecurityFinding", shell.Streams.Error);
    }

    [Fact]
    public void ToRemovalPlan_ReadsEveryField()
    {
        var plan = PowerShellCommandRunner.LazyVMRemovalPlan(Entry(
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
        Assert.Equal([@"LazyVM\DevBox maintenance"], plan.Tasks);
        Assert.Equal(
            [new RemovalItem("Folder", @"C:\LazyVM\DevBox", 1073741824), new RemovalItem("File", @"E:\Disks\DevBox\SQL.vhdx", 2048)],
            plan.Items);
        Assert.Equal(1073743872, plan.Total);
        Assert.Equal([new KeptItem(@"C:\LazyVM\Shared", "Every VM uses it.")], plan.Kept);
        Assert.Equal([new WorkDisk("The Dev Drive", @"C:\LazyVM\DevBox\Dev.vhdx", 512, "Push first.")], plan.WorkDisks);
    }

    [Fact]
    public void ToSecurityFinding_ReadsEveryField_TheFirstSeenTimeInLocalTime()
    {
        var firstSeen = new DateTimeOffset(2026, 11, 12, 2, 31, 0, TimeSpan.Zero);

        var finding = PowerShellCommandRunner.LazyVMSecurityFinding(Entry(
            ("Name", "DevBox"),
            ("Id", "Defender:Detection:Trojan"),
            ("Severity", "Medium"),
            ("Title", "Defender found Trojan:Win32/Sample"),
            ("WhatWeFound", "Defender quarantined a file."),
            ("Where", new[] { @"C:\Temp\a.exe", @"C:\Temp\b.exe" }),
            ("WhyItMatters", "It can run again."),
            ("HowToFix", "Delete it."),
            ("FirstSeen", firstSeen),
            ("Status", "Still open")));

        Assert.Equal("Defender:Detection:Trojan", finding.Id);
        Assert.Equal("Medium", finding.Severity);
        Assert.Equal("Defender found Trojan:Win32/Sample", finding.Title);
        Assert.Equal("Defender quarantined a file.", finding.WhatWeFound);
        Assert.Equal([@"C:\Temp\a.exe", @"C:\Temp\b.exe"], finding.Where);
        Assert.Equal("It can run again.", finding.WhyItMatters);
        Assert.Equal("Delete it.", finding.HowToFix);
        Assert.Equal(firstSeen.LocalDateTime, finding.FirstSeen);
        Assert.Equal("Still open", finding.Status);
    }

    [Fact]
    public void ToSecurityFinding_WithNoFilesOrFirstSeen_LeavesThemEmpty()
    {
        var finding = PowerShellCommandRunner.LazyVMSecurityFinding(Entry(("Id", "Firewall:Public:Off"), ("Where", Array.Empty<string>()), ("FirstSeen", null)));

        Assert.Empty(finding.Where);
        Assert.Null(finding.FirstSeen);
        Assert.Equal(string.Empty, finding.Status);
    }

    [Fact]
    public void ToSecurityApproval_ReadsEveryField()
    {
        var approvedOn = new DateTimeOffset(2026, 11, 10, 9, 15, 0, TimeSpan.Zero);

        var approval = PowerShellCommandRunner.LazyVMSecurityApproval(Entry(
            ("Name", "DevBox"),
            ("Id", "Rdp:On"),
            ("Severity", "Medium"),
            ("Title", "Remote Desktop is on"),
            ("ApprovedOn", approvedOn),
            ("Reason", "I connect with it.")));

        Assert.Equal(new VMSecurityApproval("Rdp:On", "Medium", "Remote Desktop is on", approvedOn.LocalDateTime, "I connect with it."), approval);
    }

    [Fact]
    public void ToRestorePoint_ReadsEveryField()
    {
        var point = PowerShellCommandRunner.LazyVMToRestorePoint(Entry(
            ("Name", "DevBox"),
            ("RestorePoint", "20261008-193000"),
            ("Taken", new DateTime(2026, 10, 8, 19, 30, 0)),
            ("Checkpoint", "LazyVM tooling 20261008-193000"),
            ("HasToolingList", false)));

        Assert.Equal(new VMRestorePoint("20261008-193000", new DateTime(2026, 10, 8, 19, 30, 0), HasToolingList: false), point);
    }

    [Fact]
    public void ToRemovalPlan_WithNothingLeft_IsEmpty()
    {
        var plan = PowerShellCommandRunner.LazyVMRemovalPlan(Entry(
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

    private static ErrorRecord Error(string message)
    {
        return new(new InvalidOperationException(message), "Test", ErrorCategory.NotSpecified, null);
    }

    [Fact]
    public void ModuleSearchPath_HoldsOnlyFoldersAdministratorsControl()
    {
        // The app runs elevated: a module autoloaded from a folder the user can
        // write to, such as Documents\PowerShell\Modules, would run as administrator.
        var folders = PowerShellCommandRunner.ModuleSearchPath.Split(System.IO.Path.PathSeparator);

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
        // A fake _Runner, or the window before its first refresh, must not need the module installed.
        using var runner = new PowerShellCommandRunner();

        Assert.False(runner.IsStarted);
    }

    [Fact]
    public void ToCheck_ReadsEveryField()
    {
        var check = PowerShellCommandRunner.LazyVMCheck(Entry(
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
        var check = PowerShellCommandRunner.LazyVMCheck(Entry(("Area", "Host"), ("Check", "LazyVM folder"), ("Status", "OK"), ("Detail", @"C:\Users\me\LazyVM")));

        Assert.Equal(string.Empty, check.Fix);
    }

    [Fact]
    public void ToLogEntry_ReadsEveryField()
    {
        var time = new DateTime(2026, 11, 12, 2, 10, 5);

        var entry = PowerShellCommandRunner.LazyVMLogEntry(Entry(("Time", time), ("Level", "Error"), ("Message", "Windows Update failed\nwith 0x80070005")));

        Assert.Equal(new VMLogEntry(time, "Error", "Windows Update failed\nwith 0x80070005"), entry);
    }

    [Fact]
    public void ToLogEntry_ATimeThatCannotBeRead_IsLeftEmpty()
    {
        var entry = PowerShellCommandRunner.LazyVMLogEntry(Entry(("Time", "yesterday"), ("Level", "Info"), ("Message", "Started")));

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

        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Running"), ("Run", run), ("LastBuild", run)));

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
        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", null)));

        Assert.Null(vm.Run);
        Assert.Null(vm.LastBuild);
    }

    [Fact]
    public void ToDashboard_ARunValueThatCannotBeRead_IsNamedInProblems()
    {
        var vm = PowerShellCommandRunner.LazyVMDashboard(Entry(("Name", "DevBox"), ("State", "Off"), ("Run", Entry(("Status", "Failed"), ("Phase", "seven")))));

        Assert.Equal("Failed", vm.Run!.Status);
        Assert.Null(vm.Run.Phase);
        Assert.Equal(["Run phase: could not be read"], vm.Problems);
    }
}

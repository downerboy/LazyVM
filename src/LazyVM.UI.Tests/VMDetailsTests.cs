using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>The details a VM's window lists about it, each as a label and its value.</summary>
public sealed class VMDetailsTests : IDisposable
{
    private const long _GB = 1024L * 1024 * 1024;

    private readonly CultureScope _Culture = new("en-GB");

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static string? Detail(LazyVMDashboard entry, string label)
    {
        return VMDetails.Read(entry).SingleOrDefault(detail => detail.Label == label)?.Value;
    }

    [Fact]
    public void Memory_IsShownInGB()
    {
        var entry = Sample.VM() with
        {
            MemoryAssigned = 8 * _GB
        };

        Assert.Equal("8 GB", Detail(entry, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNone()
    {
        var entry = Sample.VM(state: "Off") with
        {
            MemoryAssigned = 0
        };

        Assert.Equal("None", Detail(entry, "Memory in use"));
    }

    [Fact]
    public void Memory_IsShownOfTheMostTheVMCanUse()
    {
        var entry = Sample.VM() with
        {
            MemoryAssigned = 6 * _GB,
            MemoryMaximum = 16 * _GB
        };

        Assert.Equal("6 GB of 16 GB", Detail(entry, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNoneOfTheMost()
    {
        var entry = Sample.VM(state: "Off") with
        {
            MemoryAssigned = 0,
            MemoryMaximum = 16 * _GB
        };

        Assert.Equal("None of 16 GB", Detail(entry, "Memory in use"));
    }

    [Fact]
    public void Memory_NotKnown_DoesNotShowTheMostOnItsOwn()
    {
        var entry = Sample.VM() with
        {
            MemoryAssigned = null,
            MemoryMaximum = 16 * _GB
        };

        Assert.DoesNotContain("16 GB", Detail(entry, "Memory in use"));
    }

    [Fact]
    public void ConfigTemplate_IsNamed()
    {
        var entry = Sample.VM() with
        {
            CreatedFromTemplate = "PlainWindows"
        };

        Assert.Equal("PlainWindows", Detail(entry, "Created from config template"));
    }

    [Fact]
    public void ConfigTemplate_NotRecorded_SaysSo()
    {
        var entry = Sample.VM() with
        {
            CreatedFromTemplate = null
        };

        Assert.Equal("None recorded", Detail(entry, "Created from config template"));
    }

    [Theory]
    [InlineData(3, 1, true, "3 stored, 1 not exported yet, last exported 15 November 2026 10:05")]
    [InlineData(2, 0, true, "2 stored, all exported, last exported 15 November 2026 10:05")]
    [InlineData(2, 2, false, "2 stored, 2 not exported yet, never exported")]
    [InlineData(0, 0, false, "None stored yet")]
    public void RecoveryKeys_SayHowManyAreStored_AndNotExported(int stored, int unexported, bool everExported, string said)
    {
        var entry = Sample.VM() with
        {
            RecoveryKeys = stored,
            UnexportedRecoveryKeys = unexported,
            RecoveryKeysExported = everExported ? new DateTime(2026, 11, 15, 10, 5, 0) : null,
        };

        Assert.Equal(said, Detail(entry, "Recovery keys"));
    }

    [Fact]
    public void RecoveryKeys_NotKnown_SayNotKnown()
    {
        Assert.Equal("Not known", Detail(Sample.VM(), "Recovery keys"));
    }

    [Fact]
    public void Disks_ShowTheTotalAndEachDisk()
    {
        var entry = Sample.VM() with
        {
            DiskSpaceUsed = (214 * _GB) + (_GB / 2),
            Disks =
            [
                new VMDisk("DevBox.vhdx", @"D:\VMs\DevBox\DevBox.vhdx", 200 * _GB, 512 * _GB),
                new VMDisk("Data.vhdx", @"D:\VMs\DevBox\Data.vhdx", (14 * _GB) + (_GB / 2), 64 * _GB),
            ],
        };

        Assert.Equal("214.5 GB on 2 disks", Detail(entry, "Disk space used"));
        Assert.Equal(@"200 GB used of 512 GB, D:\VMs\DevBox\DevBox.vhdx", Detail(entry, "Disk DevBox.vhdx"));
        Assert.Equal(@"14.5 GB used of 64 GB, D:\VMs\DevBox\Data.vhdx", Detail(entry, "Disk Data.vhdx"));
    }

    [Fact]
    public void ADiskWhoseCheckpointsTakeMoreThanItsSize_SaysWhy()
    {
        // Used counts the disk's checkpoint files too, so it can be more than the disk's size.
        var entry = Sample.VM() with
        {
            DiskSpaceUsed = 148 * _GB,
            Disks = [new VMDisk("DevBox-OS.vhdx", @"D:\VMs\DevBox\DevBox-OS.vhdx", 148 * _GB, 120 * _GB)],
        };

        Assert.Equal(@"148 GB used with its checkpoints, disk size 120 GB, D:\VMs\DevBox\DevBox-OS.vhdx", Detail(entry, "Disk DevBox-OS.vhdx"));
    }

    [Fact]
    public void LastMaintenance_GivesResultDayAndTime()
    {
        Assert.Equal("Succeeded, 12 November 2026 02:10", Detail(Sample.VM(), "Last maintenance"));
    }

    [Fact]
    public void Maintenance_GivesTimeAndTask()
    {
        var entry = Sample.VM() with
        {
            MaintenanceTime = "02:00"
        };

        Assert.Equal("Daily at 02:00, task registered", Detail(entry, "Maintenance"));
    }

    [Fact]
    public void SecurityScan_GivesDayAndOpenFindings()
    {
        var entry = Sample.VM() with
        {
            LastSecurityScan = new DateTime(2026, 11, 13, 3, 0, 0),
            OpenFindings = 3
        };

        Assert.Equal("13 November 2026 03:00, 3 open findings", Detail(entry, "Last security scan"));
    }

    [Fact]
    public void SecurityScan_BeforeTheFirstScan()
    {
        var entry = Sample.VM() with
        {
            LastSecurityScan = null,
            OpenFindings = null
        };

        Assert.Equal("Not scanned yet", Detail(entry, "Last security scan"));
    }

    [Fact]
    public void GreenTemplate_GivesNameAndWhenItChanged()
    {
        var entry = Sample.VM() with
        {
            GreenTemplate = "DevBox-latest",
            GreenTemplateUpdated = new DateTime(2026, 11, 13, 3, 5, 0)
        };

        Assert.Equal("DevBox-latest, updated 13 November 2026 03:05", Detail(entry, "Green template"));
    }

    [Fact]
    public void MissingValues_ReadAsNotKnown()
    {
        var entry = new LazyVMDashboard { Name = "DevBox", State = "Unknown" };

        Assert.Equal("Not known", Detail(entry, "Created"));
        Assert.Equal("Not known", Detail(entry, "Memory in use"));
        Assert.Equal("Not known", Detail(entry, "Disk space used"));
    }

    [Fact]
    public void AVMNotBuiltYet_SaysSoInsteadOfNotKnown()
    {
        var entry = new LazyVMDashboard { Name = "TestBox", State = "Not built" };

        Assert.Equal("Not built yet", Detail(entry, "Created"));
        Assert.Equal("Not built yet", Detail(entry, "Memory in use"));
        Assert.Equal("Not built yet", Detail(entry, "Disk space used"));
    }

    [Fact]
    public void WhatCouldNotBeRead_IsListed()
    {
        var entry = Sample.VM() with
        {
            Problems = ["Hyper-V: access denied", "Disks: access denied"]
        };

        Assert.Equal(
            ["Hyper-V: access denied", "Disks: access denied"],
            VMDetails.Read(entry).Where(detail => detail.Label == "Could not read").Select(detail => detail.Value));
    }

    [Fact]
    public void EachDetail_ReadsAsLabelAndValue()
    {
        Assert.Equal("State: Running", VMDetails.Read(Sample.VM()).Single(detail => detail.Label == "State").AutomationName);
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

        Assert.Equal(expected, Detail(Sample.VM() with { Run = run }, "Running now"));
    }
}

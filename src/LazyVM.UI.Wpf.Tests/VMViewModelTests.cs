using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

public sealed class VMViewModelTests : IDisposable
{
    private const long GB = 1024L * 1024 * 1024;

    private readonly CultureScope culture = new("en-GB");

    public void Dispose() => culture.Dispose();

    private static string? Detail(VMViewModel vm, string label) =>
        vm.Details.SingleOrDefault(detail => detail.Label == label)?.Value;

    [Fact]
    public void Title_NamesTheVM()
    {
        var vm = new VMViewModel(Sample.VM("DevEnv"));

        Assert.Equal("DevEnv", vm.Name);
        Assert.Equal("DevEnv - LazyVM", vm.Title);
    }

    [Fact]
    public void Memory_IsShownInGB()
    {
        var vm = new VMViewModel(Sample.VM() with { MemoryAssigned = 8 * GB });

        Assert.Equal("8 GB", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Memory_OfAVMThatIsOff_IsNone()
    {
        var vm = new VMViewModel(Sample.VM(state: "Off") with { MemoryAssigned = 0 });

        Assert.Equal("None", Detail(vm, "Memory in use"));
    }

    [Fact]
    public void Disks_ShowTheTotalAndEachDisk()
    {
        var vm = new VMViewModel(Sample.VM() with
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
    public void LastMaintenance_GivesResultDayAndTime()
    {
        var vm = new VMViewModel(Sample.VM());

        Assert.Equal("Succeeded, 12 November 2026 02:10", Detail(vm, "Last maintenance"));
    }

    [Fact]
    public void Maintenance_GivesTimeAndTask()
    {
        var vm = new VMViewModel(Sample.VM() with { MaintenanceTime = "02:00" });

        Assert.Equal("Daily at 02:00, task registered", Detail(vm, "Maintenance"));
    }

    [Fact]
    public void SecurityScan_GivesDayAndOpenFindings()
    {
        var vm = new VMViewModel(Sample.VM() with { LastSecurityScan = new DateTime(2026, 11, 13, 3, 0, 0), OpenFindings = 3 });

        Assert.Equal("13 November 2026 03:00, 3 open findings", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void SecurityScan_BeforeTheFirstScan()
    {
        var vm = new VMViewModel(Sample.VM() with { LastSecurityScan = null, OpenFindings = null });

        Assert.Equal("Not scanned yet", Detail(vm, "Last security scan"));
    }

    [Fact]
    public void GreenTemplate_GivesNameAndWhenItChanged()
    {
        var vm = new VMViewModel(Sample.VM() with { GreenTemplate = "DevBox-latest", GreenTemplateUpdated = new DateTime(2026, 11, 13, 3, 5, 0) });

        Assert.Equal("DevBox-latest, updated 13 November 2026 03:05", Detail(vm, "Green template"));
    }

    [Fact]
    public void MissingValues_ReadAsNotKnown()
    {
        var vm = new VMViewModel(new VMDashboard { Name = "DevBox", State = "Unknown" });

        Assert.Equal("Not known", Detail(vm, "Created"));
        Assert.Equal("Not known", Detail(vm, "Memory in use"));
        Assert.Equal("Not known", Detail(vm, "Disk space used"));
    }

    [Fact]
    public void WhatCouldNotBeRead_IsListed()
    {
        var vm = new VMViewModel(Sample.VM() with { Problems = ["Hyper-V: access denied", "Disks: access denied"] });

        Assert.Equal(
            ["Hyper-V: access denied", "Disks: access denied"],
            vm.Details.Where(detail => detail.Label == "Could not read").Select(detail => detail.Value));
    }

    [Fact]
    public void EachDetail_ReadsAsLabelAndValue()
    {
        var vm = new VMViewModel(Sample.VM());

        Assert.Equal("State: Running", vm.Details.Single(detail => detail.Label == "State").AutomationName);
    }

    [Fact]
    public void Update_ReplacesTheDetails()
    {
        var vm = new VMViewModel(Sample.VM(state: "Running"));
        var changed = new List<string?>();
        vm.PropertyChanged += (_, e) => changed.Add(e.PropertyName);

        vm.Update(Sample.VM(state: "Off"));

        Assert.Equal("Off", vm.State);
        Assert.Equal("Off", Detail(vm, "State"));
        Assert.Contains(changed, name => string.IsNullOrEmpty(name));
    }
}

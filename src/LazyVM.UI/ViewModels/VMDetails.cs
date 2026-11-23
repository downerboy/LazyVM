namespace LazyVM.UI.ViewModels;

/// <summary>Every detail the dashboard has about a VM, as its window lists them.</summary>
public static class VMDetails
{
    /// <summary>The details of <paramref name="vm"/>, in the order the window shows them.</summary>
    public static IReadOnlyList<VMDetail> Read(LazyVMDashboard vm)
    {
        // Hyper-V has nothing to say about a VM that is not built yet; say why.
        var missing = vm.State == "Not built" ? "Not built yet" : DashboardText.NOT_KNOWN;
        return
        [
            new("State", vm.State),
            new("Running now", RunningText(vm.Run)),
            new("Created", vm.Created is { } created ? DashboardText.When(created) : missing),
            new("Memory in use", MemoryText(vm, missing)),
            new("Disk space used", vm.DiskSpaceUsed is { } used
                ? $"{DashboardText.Size(used)} on {vm.Disks.Count} {(vm.Disks.Count == 1 ? "disk" : "disks")}"
                : missing),
            // UsedDiskSpace counts the disk's checkpoint files too, so it can be more than the disk's size; say why then.
            .. vm.Disks.Select(disk => new VMDetail(
                "Disk " + disk.DiskName,
                disk.UsedDiskSpace > disk.MaximumDiskSpace
                    ? $"{DashboardText.Size(disk.UsedDiskSpace)} used with its checkpoints, disk size {DashboardText.Size(disk.MaximumDiskSpace)}, {disk.DiskPath}"
                    : $"{DashboardText.Size(disk.UsedDiskSpace)} used of {DashboardText.Size(disk.MaximumDiskSpace)}, {disk.DiskPath}")),
            new("Maintenance", MaintenanceText(vm)),
            new("Last maintenance", DashboardText.LastMaintenance(vm, DashboardText.When)),
            new("Last security scan", vm.LastSecurityScan is { } scanned
                ? $"{DashboardText.When(scanned)}, {DashboardText.InSentence(DashboardText.OpenFindings(vm.OpenFindings))}"
                : "Not scanned yet"),
            // Empty both for a VM made without a template and for one made before LazyVM recorded it (#421).
            new("Created from config template", vm.CreatedFromTemplate ?? "None recorded"),
            new("Configuration first built from", vm.OriginalConfig ?? DashboardText.NOT_KNOWN),
            new("Green template", GreenTemplateText(vm)),
            new("Recovery keys", RecoveryKeysText(vm)),
            new("Settings", vm.Settings),
            .. vm.Problems.Select(problem => new VMDetail("Could not read", problem)),
        ];
    }

    /// <summary>Memory in use against the most the VM can use, for example "6 GB of 16 GB" (#420).</summary>
    private static string MemoryText(LazyVMDashboard vm, string missing)
    {
        var inUse = vm.MemoryAssigned switch
        {
            null => missing,
            0 => "None",
            { } bytes => DashboardText.Size(bytes),
        };
        return vm.MemoryAssigned is not null && vm.MemoryMaximum is { } maximum
            ? $"{inUse} of {DashboardText.Size(maximum)}"
            : inUse;
    }

    /// <summary>Such as "Build, in phase 7 (Windows)", "Build, stopping" or "Nothing".</summary>
    private static string RunningText(VMRun? run)
    {
        if (run is not { IsRunning: true })
        {
            return "Nothing";
        }
        var what = run.Command ?? "A run, just starting";
        return run.StopRequested
            ? $"{what}, stopping"
            : run.Phase is { } phase
            ? $"{what}, in phase {phase}" + (run.PhaseName is { Length: > 0 } name ? $" ({name})" : string.Empty)
            : what;
    }

    private static string MaintenanceText(LazyVMDashboard vm)
    {
        var time = vm.MaintenanceTime is null ? DashboardText.NOT_KNOWN : $"Daily at {vm.MaintenanceTime}";
        var task = vm.MaintenanceTask is null ? "task not known" : "task " + DashboardText.InSentence(vm.MaintenanceTask);
        return $"{time}, {task}";
    }

    /// <summary>Such as "3 stored, 1 not exported yet, last exported 15 November 2026 10:05", or "None stored yet".</summary>
    private static string RecoveryKeysText(LazyVMDashboard vm)
    {
        if (vm.RecoveryKeys is not { } stored || vm.UnexportedRecoveryKeys is not { } unexported)
        {
            return DashboardText.NOT_KNOWN;
        }
        if (stored == 0)
        {
            return "None stored yet";
        }
        var exported = unexported == 0 ? "all exported" : $"{unexported} not exported yet";
        var last = vm.RecoveryKeysExported is { } when ? "last exported " + DashboardText.When(when) : "never exported";
        return $"{stored} stored, {exported}, {last}";
    }

    private static string GreenTemplateText(LazyVMDashboard vm)
    {
        return (vm.GreenTemplate, vm.GreenTemplateUpdated) switch
        {
            (null, _) => "None yet",
            ({ } name, { } updated) => $"{name}, updated {DashboardText.When(updated)}",
            ({ } name, null) => name,
        };
    }
}

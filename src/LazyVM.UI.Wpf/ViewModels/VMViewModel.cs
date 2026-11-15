namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>A VM's own window: every detail the dashboard has about it. Read-only in this step.</summary>
public sealed class VMViewModel : ViewModelBase
{
    private VMDashboard entry;

    public VMViewModel(VMDashboard entry)
    {
        this.entry = entry;
        Details = ReadDetails(entry);
    }

    public string Name => entry.Name;

    public string Title => $"{entry.Name} - LazyVM";

    public string State => entry.State;

    /// <summary>The details, in the order the window shows them.</summary>
    public IReadOnlyList<VMDetail> Details { get; private set; }

    /// <summary>Shows what a newer refresh read for this VM.</summary>
    public void Update(VMDashboard entry)
    {
        this.entry = entry;
        Details = ReadDetails(entry);
        OnPropertyChanged(string.Empty);
    }

    private static List<VMDetail> ReadDetails(VMDashboard vm)
    {
        var details = new List<VMDetail>
        {
            new("State", vm.State),
            new("Created", vm.Created is { } created ? DashboardText.When(created) : DashboardText.NotKnown),
            new("Memory in use", vm.MemoryAssigned switch
            {
                null => DashboardText.NotKnown,
                0 => "None",
                { } bytes => DashboardText.Size(bytes),
            }),
            new("Disk space used", vm.DiskSpaceUsed is { } used
                ? $"{DashboardText.Size(used)} on {vm.Disks.Count} {(vm.Disks.Count == 1 ? "disk" : "disks")}"
                : DashboardText.NotKnown),
        };

        details.AddRange(vm.Disks.Select(disk => new VMDetail(
            "Disk " + disk.Name,
            $"{DashboardText.Size(disk.Used)} used of {DashboardText.Size(disk.Maximum)}, {disk.Path}")));

        details.Add(new("Maintenance", MaintenanceText(vm)));
        details.Add(new("Last maintenance", DashboardText.LastMaintenance(vm, DashboardText.When)));
        details.Add(new("Last security scan", vm.LastSecurityScan is { } scanned
            ? $"{DashboardText.When(scanned)}, {DashboardText.InSentence(DashboardText.OpenFindings(vm.OpenFindings))}"
            : "Not scanned yet"));
        details.Add(new("Configuration first built from", vm.OriginalConfig ?? DashboardText.NotKnown));
        details.Add(new("Green template", GreenTemplateText(vm)));
        details.Add(new("Settings", vm.Settings));
        details.AddRange(vm.Problems.Select(problem => new VMDetail("Could not read", problem)));
        return details;
    }

    private static string MaintenanceText(VMDashboard vm)
    {
        var time = vm.MaintenanceTime is null ? DashboardText.NotKnown : $"Daily at {vm.MaintenanceTime}";
        var task = vm.MaintenanceTask is null ? "task not known" : "task " + DashboardText.InSentence(vm.MaintenanceTask);
        return $"{time}, {task}";
    }

    private static string GreenTemplateText(VMDashboard vm) => (vm.GreenTemplate, vm.GreenTemplateUpdated) switch
    {
        (null, _) => "None yet",
        ({ } name, { } updated) => $"{name}, updated {DashboardText.When(updated)}",
        ({ } name, null) => name,
    };
}

/// <summary>One line of a VM's details, such as "Memory in use: 8 GB".</summary>
public sealed record VMDetail(string Label, string Value)
{
    /// <summary>The line as a screen reader reads it.</summary>
    public string AutomationName => $"{Label}: {Value}";
}

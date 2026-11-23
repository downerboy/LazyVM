using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs <c>Get-LazyVMDashboard</c>, for every VM or one, and reads its entries.</summary>
public class LazyVMDashboardRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>Runs <c>Get-LazyVMDashboard</c>: one entry per VM.</summary>
    public virtual async Task<IReadOnlyList<LazyVMDashboard>> GetLazyVMDashboardAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(Sessions.ForHost(), "Get-LazyVMDashboard", [], cancellationToken).ConfigureAwait(false);
        return output.Select(LazyVMDashboard).ToList();
    }

    /// <summary>
    /// Runs <c>Get-LazyVMDashboard -Name</c> in the VM's session: the one VM,
    /// or nothing when there is no such VM. <paramref name="vmId"/> is empty
    /// for a VM not built yet.
    /// </summary>
    public virtual async Task<LazyVMDashboard?> GetLazyVMAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMDashboard", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Select(LazyVMDashboard).FirstOrDefault(entry => string.Equals(entry.Name, name, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Reads one <c>LazyVM.Dashboard</c> object. A value that cannot be read
    /// is left empty and named in the VM's Problems, so one odd value never
    /// fails the whole refresh.
    /// </summary>
    internal static LazyVMDashboard LazyVMDashboard(PSObject entry)
    {
        var problems = entry.ReadList("Problems").Select(problem => problem.BaseObject.ToString() ?? string.Empty).ToList();
        T? Value<T>(PSObject source, string name, string label)
        {
            return source.Read<T>(name, label, problems);
        }

        DateTime? Date(string name, string label)
        {
            return entry.ReadDate(name, label, problems);
        }

        return new()
        {
            Name = Value<string>(entry, "Name", "Name") ?? string.Empty,
            Id = Value<Guid?>(entry, "Id", "Hyper-V Id"),
            State = Value<string>(entry, "State", "State") ?? "Unknown",
            Created = Date("Created", "Created"),
            MemoryAssigned = Value<long?>(entry, "MemoryAssigned", "Memory in use"),
            MemoryMaximum = Value<long?>(entry, "MemoryMaximum", "Memory maximum"),
            Disks = entry.ReadList("Disks").Select(disk => new VMDisk(
                Value<string>(disk, "Name", "Disk name") ?? string.Empty,
                Value<string>(disk, "Path", "Disk path") ?? string.Empty,
                Value<long?>(disk, "Used", "Disk space used") ?? 0,
                Value<long?>(disk, "Maximum", "Disk size") ?? 0)).ToList(),
            DiskSpaceUsed = Value<long?>(entry, "DiskSpaceUsed", "Disk space used"),
            MaintenanceTime = Value<string>(entry, "MaintenanceTime", "Maintenance time"),
            MaintenanceTask = Value<string>(entry, "MaintenanceTask", "Maintenance task"),
            LastMaintenance = Date("LastMaintenance", "Last maintenance"),
            LastMaintenanceResult = Value<string>(entry, "LastMaintenanceResult", "Last maintenance result"),
            LastSecurityScan = Date("LastSecurityScan", "Last security scan"),
            OpenFindings = Value<int?>(entry, "OpenFindings", "Open findings"),
            OriginalConfig = Value<string>(entry, "OriginalConfig", "Original configuration"),
            CreatedFromTemplate = Value<string>(entry, "CreatedFromTemplate", "Config template"),
            GreenTemplate = Value<string>(entry, "GreenTemplate", "Green template"),
            GreenTemplateUpdated = Date("GreenTemplateUpdated", "Green template updated"),
            RecoveryKeys = Value<int?>(entry, "RecoveryKeys", "Recovery keys"),
            UnexportedRecoveryKeys = Value<int?>(entry, "UnexportedRecoveryKeys", "Recovery keys not exported"),
            RecoveryKeysExported = Date("RecoveryKeysExported", "Recovery keys exported"),
            Settings = Value<string>(entry, "Settings", "Settings") ?? "Not known",
            Run = ReadLazyVMRun(entry, "Run", problems),
            LastBuild = ReadLazyVMRun(entry, "LastBuild", problems),
            Problems = problems,
        };
    }

    /// <summary>Reads one <c>LazyVM.VMRun</c> object. A value that cannot be read is left empty and named in <paramref name="problems"/>.</summary>
    internal static VMRun LazyVMRun(PSObject run, List<string> problems)
    {
        return new()
        {
            Command = run.Read<string>("Command", "Run command", problems),
            Status = run.Read<string>("Status", "Run status", problems),
            ProcessId = run.Read<int?>("ProcessId", "Run process", problems),
            Started = run.ReadDate("Started", "Run started", problems),
            Ended = run.ReadDate("Ended", "Run ended", problems),
            Phase = run.Read<int?>("Phase", "Run phase", problems),
            PhaseName = run.Read<string>("PhaseName", "Run phase name", problems),
            UnfinishedPhase = run.Read<int?>("UnfinishedPhase", "Unfinished phase", problems),
            StopRequested = run.Read<bool?>("StopRequested", "Stop requested", problems) ?? false,
        };
    }

    /// <summary>The run as it came: a [pscustomobject] keeps its properties only on its PSObject, never on what it wraps.</summary>
    private static VMRun? ReadLazyVMRun(PSObject entry, string name, List<string> problems)
    {
        return entry.Properties[name]?.Value switch
        {
            null => null,
            PSObject { BaseObject: null } => null,
            PSObject run => LazyVMRun(run, problems),
            var other => LazyVMRun(PSObject.AsPSObject(other), problems),
        };
    }
}

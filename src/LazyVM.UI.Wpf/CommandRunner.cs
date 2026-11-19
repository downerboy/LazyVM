using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Runs the LazyVM module's commands in PowerShell hosted in the app, and
/// hands back plain values. View models take this class through their
/// constructor; tests replace its virtual members.
/// </summary>
/// <remarks>
/// One runspace, opened on the first call, with the installed module
/// imported by full path from %ProgramFiles%\LazyVM\Modules, never found
/// through PSModulePath, no profile scripts, and a module search path of
/// folders only administrators control. Commands are fixed commands
/// with fixed parameters, never script text. A runspace runs one pipeline at
/// a time, so a second call waits for the first.
/// </remarks>
public class CommandRunner : IDisposable
{
    private readonly SemaphoreSlim _OneAtATime = new(1, 1);
    private Runspace? _Runspace;
    private bool _Disposed;

    /// <summary>The installed module: %ProgramFiles%\LazyVM\Modules\LazyVM, which only administrators can change.</summary>
    internal static string ModulePath
    {
        get;
    } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LazyVM", "Modules", "LazyVM");

    /// <summary>
    /// Where the hosted PowerShell finds the modules it loads: only folders
    /// administrators control. The app runs elevated, so a module the user
    /// could change, such as one in Documents\PowerShell\Modules, must never
    /// load into it. LazyVM's folder comes first, then the Windows modules
    /// (Hyper-V, ScheduledTasks), then the modules shipped with the app.
    /// </summary>
    internal static string ModuleSearchPath
    {
        get;
    } = string.Join(
        System.IO.Path.PathSeparator,
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LazyVM", "Modules"),
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules"),
        System.IO.Path.Combine(System.IO.Path.GetDirectoryName(typeof(PSObject).Assembly.Location)!, "Modules"));

    /// <summary>True once PowerShell has started and the module is imported.</summary>
    internal bool IsStarted => _Runspace is not null;

    /// <summary>Runs <c>Get-LazyVMDashboard</c>: one entry per VM.</summary>
    public virtual async Task<IReadOnlyList<VMDashboard>> GetDashboardAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMDashboard", [], cancellationToken).ConfigureAwait(false);
        return output.Select(ToDashboard).ToList();
    }

    /// <summary>Runs <c>Get-LazyVMDashboard -Name</c>: the one VM, or nothing when there is no such VM.</summary>
    public virtual async Task<VMDashboard?> GetVMAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMDashboard", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Select(ToDashboard).FirstOrDefault(entry => string.Equals(entry.Name, name, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Runs <c>Get-LazyVMBuildPhase</c>: every phase of a build, in order.</summary>
    public virtual async Task<IReadOnlyList<BuildPhase>> GetBuildPhasesAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMBuildPhase", [], cancellationToken).ConfigureAwait(false);
        return output.Select(phase => new BuildPhase(
            Read<int?>(phase, "Number", "Number", []) ?? 0, Text(phase, "Name"), Text(phase, "Goal"))).ToList();
    }

    /// <summary>Runs <c>Get-LazyVMConfigTemplate</c>: the config templates a new VM can be built from.</summary>
    public virtual async Task<IReadOnlyList<ConfigTemplate>> GetConfigTemplatesAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMConfigTemplate", [], cancellationToken).ConfigureAwait(false);
        return output.Select(template => new ConfigTemplate(
            Text(template, "Name"),
            Read<bool?>(template, "BuiltIn", "BuiltIn", []) ?? false,
            Read<bool?>(template, "Automatic", "Automatic", []) ?? false)).ToList();
    }

    /// <summary>
    /// Runs <c>Stop-LazyVMBuild -Name</c>: asks the VM's running build to stop
    /// at its next safe point, and returns the run with StopRequested set.
    /// Throws with the module's reason when nothing was stopped, such as a
    /// run that has not recorded itself yet.
    /// </summary>
    public virtual async Task<VMRun?> StopBuildAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Stop-LazyVMBuild", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Count == 0 ? null : ToRun(output[0], []);
    }

    /// <summary>
    /// Runs <c>Start-LazyVMMaintenance -Name</c>: starts the VM's maintenance
    /// task, so it runs as the nightly run does. Throws with the module's
    /// reason when nothing was started, such as while another run of the VM
    /// is going or when maintenance is not scheduled.
    /// </summary>
    public virtual async Task StartMaintenanceAsync(string name, CancellationToken cancellationToken)
    {
        await InvokeAsync("Start-LazyVMMaintenance", [("Name", name)], cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Runs <c>Get-LazyVMRemovalPlan -Name</c>: what deleting the VM would
    /// delete and keep. Throws with the module's reason when nothing could be
    /// removed, such as when another VM's settings cannot be read.
    /// </summary>
    public virtual async Task<RemovalPlan> GetRemovalPlanAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMRemovalPlan", [("Name", name)], cancellationToken).ConfigureAwait(false);
        return output.Select(ToRemovalPlan).FirstOrDefault()
            ?? throw new InvalidOperationException($"Get-LazyVMRemovalPlan said nothing about {name}.");
    }

    /// <summary>
    /// Runs <c>Remove-LazyVM -Name -Force</c>: deletes the VM, without the
    /// question the app has already asked. Never cancelled: a removal stopped
    /// half way leaves more behind. Throws with the module's reason when it
    /// removed nothing or only part, such as while another run of the VM is
    /// going.
    /// </summary>
    public virtual async Task RemoveVMAsync(string name)
    {
        await InvokeAsync("Remove-LazyVM", [("Name", name), ("Force", true)], CancellationToken.None, failsOnlyByThrowing: true).ConfigureAwait(false);
    }

    /// <summary>Runs <c>Get-LazyVMRestorePoint -Name</c>: the VM's restore points, oldest first. None before the first.</summary>
    public virtual async Task<IReadOnlyList<VMRestorePoint>> GetRestorePointsAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMRestorePoint", [("Name", name)], cancellationToken, failsOnlyByThrowing: true).ConfigureAwait(false);
        return output.Select(ToRestorePoint).ToList();
    }

    /// <summary>
    /// Runs <c>Restore-LazyVMTooling -Name -RestorePoint -Force</c>: returns
    /// the VM to the restore point <paramref name="stamp"/>, without the
    /// question the app has already asked. Never cancelled: a revert stopped
    /// half way leaves the VM between the two. Throws with the module's
    /// reason when it did not, such as while another run of the VM is going.
    /// </summary>
    public virtual async Task RestoreToolingAsync(string name, string stamp)
    {
        await InvokeAsync(
            "Restore-LazyVMTooling", [("Name", name), ("RestorePoint", stamp), ("Force", true)], CancellationToken.None, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
    }

    /// <summary>Reads one <c>LazyVM.RestorePoint</c> object. A time that cannot be read is left empty.</summary>
    internal static VMRestorePoint ToRestorePoint(PSObject point)
    {
        return new(
            Text(point, "RestorePoint"),
            ReadDate(point, "Taken", "Taken", []),
            Read<bool?>(point, "HasToolingList", "HasToolingList", []) ?? false);
    }

    /// <summary>Runs <c>Get-LazyVMRecoveryKey -Name</c>: the VM's recovery keys, without their passwords. None while none is stored.</summary>
    public virtual async Task<IReadOnlyList<VMRecoveryKey>> GetRecoveryKeysAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMRecoveryKey", [("Name", name)], cancellationToken, failsOnlyByThrowing: true).ConfigureAwait(false);
        return output.Select(ToRecoveryKey).ToList();
    }

    /// <summary>
    /// Runs <c>Get-LazyVMCredential -Name -RecoveryPassword</c> and gives
    /// only the password of the disk <paramref name="diskGuid"/>, for the
    /// moment it is shown. The others are not kept.
    /// </summary>
    public virtual async Task<string> GetRecoveryPasswordAsync(string name, string diskGuid, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMCredential", [("Name", name), ("RecoveryPassword", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return RecoveryPasswordOf(output, diskGuid);
    }

    /// <summary>
    /// Runs <c>Export-LazyVMRecoveryKey -Name -Path</c>, with <c>-Force</c>
    /// when <paramref name="force"/>, which the app passes only after asking.
    /// Never cancelled. Gives the file written and the module's warnings.
    /// Throws with the module's reason when nothing was written.
    /// </summary>
    public virtual async Task<RecoveryKeyExport> ExportRecoveryKeysAsync(string name, string path, bool force)
    {
        var parameters = new (string Name, object? Value)[] { ("Name", name), ("Path", path), ("Force", force ? true : null) }
            .Where(parameter => parameter.Value is not null)
            .Select(parameter => (parameter.Name, parameter.Value!))
            .ToList();
        var (output, warnings) = await InvokeWithWarningsAsync("Export-LazyVMRecoveryKey", parameters, CancellationToken.None, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        var written = output.Select(file => Text(file, "FullName")).FirstOrDefault(full => full.Length > 0) ?? path;
        return new RecoveryKeyExport(written, warnings);
    }

    /// <summary>
    /// Runs <c>Get-LazyVMCredential -Name</c> and gives only the user name
    /// LazyVM signs in with. The password stays encrypted and is disposed of
    /// at once. Throws with the module's reason, such as when no credential
    /// is stored, which names Set-LazyVMCredential.
    /// </summary>
    public virtual async Task<string> GetUserNameAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMCredential", [("Name", name)], cancellationToken, failsOnlyByThrowing: true).ConfigureAwait(false);
        return UserNameOf(output);
    }

    /// <summary>Runs <c>Get-LazyVMCredential -Name -AsPlainText</c> and gives only the password, for the moment it is shown or copied.</summary>
    public virtual async Task<string> GetPasswordAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMCredential", [("Name", name), ("AsPlainText", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return PasswordOf(output);
    }

    /// <summary>The user name of the credential in <paramref name="output"/>; its password is disposed of. Throws when there is none.</summary>
    internal static string UserNameOf(IEnumerable<PSObject> output)
    {
        var credential = output.Select(item => item.BaseObject).OfType<PSCredential>().FirstOrDefault()
            ?? throw new InvalidOperationException("Get-LazyVMCredential gave no account.");
        credential.Password.Dispose();
        return credential.UserName;
    }

    /// <summary>The password of the <c>LazyVM.PlainCredential</c> in <paramref name="output"/>. Throws, without it, when there is none.</summary>
    internal static string PasswordOf(IEnumerable<PSObject> output)
    {
        return output.Select(item => Text(item, "Password")).FirstOrDefault(password => password.Length > 0)
            ?? throw new InvalidOperationException("Get-LazyVMCredential gave no password.");
    }

    /// <summary>Reads one <c>LazyVM.RecoveryKey</c> object. A date that cannot be read is left empty.</summary>
    internal static VMRecoveryKey ToRecoveryKey(PSObject key)
    {
        return new(
            Text(key, "Disk"),
            Text(key, "DiskGuid"),
            Text(key, "KeyId"),
            ReadDate(key, "Recorded", "Recorded", []),
            Read<bool?>(key, "Exported", "Exported", []) ?? false);
    }

    /// <summary>The recovery password of the disk <paramref name="diskGuid"/> among <paramref name="keys"/>. Throws when it has none.</summary>
    internal static string RecoveryPasswordOf(IEnumerable<PSObject> keys, string diskGuid)
    {
        return keys
            .Where(key => string.Equals(Text(key, "DiskGuid"), diskGuid, StringComparison.OrdinalIgnoreCase))
            .Select(key => Text(key, "RecoveryPassword"))
            .FirstOrDefault(password => password.Length > 0)
            ?? throw new InvalidOperationException(
                "No recovery password is stored for that disk now. Close this window and open it again to see the keys stored now.");
    }

    /// <summary>
    /// Runs <c>Get-LazyVMSecurityFinding -Name</c>: the last scan's findings,
    /// less the approved ones. None before the first scan, and none when it
    /// found nothing: the module tells those apart only in a warning, so the
    /// window tells them apart by the dashboard's <c>LastSecurityScan</c>.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMSecurityFinding>> GetSecurityFindingsAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMSecurityFinding", [("Name", name)], cancellationToken, failsOnlyByThrowing: true).ConfigureAwait(false);
        return output.Select(ToSecurityFinding).ToList();
    }

    /// <summary>Runs <c>Get-LazyVMSecurityFinding -Name -Approved</c>: the approved findings, with when and why. None while none is approved.</summary>
    public virtual async Task<IReadOnlyList<VMSecurityApproval>> GetSecurityApprovalsAsync(string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMSecurityFinding", [("Name", name), ("Approved", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return output.Select(ToSecurityApproval).ToList();
    }

    /// <summary>
    /// Runs <c>Approve-LazyVMSecurityFinding -Name -Id -Reason -Confirm:$false</c>,
    /// without the question the app has already asked. Throws with the
    /// module's reason when it refused the Id, such as a finding no longer open.
    /// </summary>
    public virtual async Task ApproveSecurityFindingAsync(string name, string id, string reason)
    {
        await InvokeAsync(
            "Approve-LazyVMSecurityFinding", [("Name", name), ("Id", id), ("Reason", reason), ("Confirm", false)], CancellationToken.None,
            failsOnlyByThrowing: true, failsByItsOwnErrors: true)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// Runs <c>Revoke-LazyVMSecurityFinding -Name -Id -Confirm:$false</c>,
    /// without the question the app has already asked. Throws with the
    /// module's reason when it refused the Id, such as one not approved.
    /// </summary>
    public virtual async Task RevokeSecurityFindingAsync(string name, string id)
    {
        await InvokeAsync(
            "Revoke-LazyVMSecurityFinding", [("Name", name), ("Id", id), ("Confirm", false)], CancellationToken.None,
            failsOnlyByThrowing: true, failsByItsOwnErrors: true)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// The first error <paramref name="command"/> itself wrote, such as a
    /// refused Id, thrown with the module's reason. Errors of the calls it
    /// silenced inside the module reach the error stream too, and do not count.
    /// </summary>
    internal static void ThrowIfCommandWroteError(string command, IEnumerable<ErrorRecord> errors)
    {
        var own = errors.FirstOrDefault(error => string.Equals(error.InvocationInfo?.MyCommand?.Name, command, StringComparison.OrdinalIgnoreCase));
        if (own is not null)
        {
            throw new InvalidOperationException(own.ToString());
        }
    }

    /// <summary>Reads one <c>LazyVM.SecurityFinding</c> object. A time that cannot be read is left empty.</summary>
    internal static VMSecurityFinding ToSecurityFinding(PSObject finding)
    {
        return new(
            Text(finding, "Id"),
            Text(finding, "Severity"),
            Text(finding, "Title"),
            Text(finding, "WhatWeFound"),
            ReadList(finding, "Where").Select(file => file.BaseObject.ToString() ?? string.Empty).Where(file => file.Length > 0).ToList(),
            Text(finding, "WhyItMatters"),
            Text(finding, "HowToFix"),
            ReadDate(finding, "FirstSeen", "FirstSeen", []),
            Text(finding, "Status"));
    }

    /// <summary>Reads one <c>LazyVM.SecurityApproval</c> object. A time that cannot be read is left empty.</summary>
    internal static VMSecurityApproval ToSecurityApproval(PSObject approval)
    {
        return new(
            Text(approval, "Id"),
            Text(approval, "Severity"),
            Text(approval, "Title"),
            ReadDate(approval, "ApprovedOn", "ApprovedOn", []),
            Text(approval, "Reason"));
    }

    /// <summary>The folder the module was imported from, which holds the script each build runs with.</summary>
    public virtual async Task<string> GetModuleFolderAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-Module", [("Name", "LazyVM")], cancellationToken).ConfigureAwait(false);
        return output.Select(module => Text(module, "ModuleBase")).FirstOrDefault(folder => folder.Length > 0)
            ?? throw new InvalidOperationException("The LazyVM module is not loaded.");
    }

    /// <summary>
    /// Runs <c>Test-LazyVM</c>: the checks of the VM <paramref name="name"/>,
    /// or with no name, of the host and the only VM, if there is one.
    /// <paramref name="hostOnly"/> checks the host alone.
    /// </summary>
    public virtual async Task<IReadOnlyList<VMCheck>> GetChecksAsync(string? name, bool hostOnly, CancellationToken cancellationToken)
    {
        var parameters = new (string Name, object? Value)[] { ("Name", name), ("HostOnly", hostOnly ? true : null) }
            .Where(parameter => parameter.Value is not null)
            .Select(parameter => (parameter.Name, parameter.Value!))
            .ToList();
        var output = await InvokeAsync("Test-LazyVM", parameters, cancellationToken).ConfigureAwait(false);
        return output.Select(ToCheck).ToList();
    }

    /// <summary>Runs <c>Get-LazyVMLog</c>: the last <paramref name="tail"/> entries of the VM's log, oldest first. None before there is a log.</summary>
    public virtual async Task<IReadOnlyList<VMLogEntry>> GetLogAsync(string name, int tail, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync("Get-LazyVMLog", [("Name", name), ("Tail", tail)], cancellationToken).ConfigureAwait(false);
        return output.Select(ToLogEntry).ToList();
    }

    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }

    protected virtual void Dispose(bool disposing)
    {
        if (_Disposed)
        {
            return;
        }
        if (disposing)
        {
            _Runspace?.Dispose();
            _OneAtATime.Dispose();
        }
        _Disposed = true;
    }

    /// <summary>
    /// Reads one <c>LazyVM.Dashboard</c> object. A value that cannot be read
    /// is left empty and named in the VM's Problems, so one odd value never
    /// fails the whole refresh.
    /// </summary>
    internal static VMDashboard ToDashboard(PSObject entry)
    {
        var problems = ReadList(entry, "Problems").Select(problem => problem.BaseObject.ToString() ?? string.Empty).ToList();
        T? Value<T>(PSObject source, string name, string label)
        {
            return Read<T>(source, name, label, problems);
        }

        DateTime? Date(string name, string label)
        {
            return ReadDate(entry, name, label, problems);
        }

        return new()
        {
            Name = Value<string>(entry, "Name", "Name") ?? string.Empty,
            State = Value<string>(entry, "State", "State") ?? "Unknown",
            Created = Date("Created", "Created"),
            MemoryAssigned = Value<long?>(entry, "MemoryAssigned", "Memory in use"),
            MemoryMaximum = Value<long?>(entry, "MemoryMaximum", "Memory maximum"),
            Disks = ReadList(entry, "Disks").Select(disk => new VMDisk(
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
            Run = ReadRun(entry, "Run", problems),
            LastBuild = ReadRun(entry, "LastBuild", problems),
            Problems = problems,
        };
    }

    /// <summary>Reads one <c>LazyVM.VMRun</c> object. A value that cannot be read is left empty and named in <paramref name="problems"/>.</summary>
    internal static VMRun ToRun(PSObject run, List<string> problems)
    {
        return new()
        {
            Command = Read<string>(run, "Command", "Run command", problems),
            Status = Read<string>(run, "Status", "Run status", problems),
            ProcessId = Read<int?>(run, "ProcessId", "Run process", problems),
            Started = ReadDate(run, "Started", "Run started", problems),
            Ended = ReadDate(run, "Ended", "Run ended", problems),
            Phase = Read<int?>(run, "Phase", "Run phase", problems),
            PhaseName = Read<string>(run, "PhaseName", "Run phase name", problems),
            UnfinishedPhase = Read<int?>(run, "UnfinishedPhase", "Unfinished phase", problems),
            StopRequested = Read<bool?>(run, "StopRequested", "Stop requested", problems) ?? false,
        };
    }

    /// <summary>The run as it came: a [pscustomobject] keeps its properties only on its PSObject, never on what it wraps.</summary>
    private static VMRun? ReadRun(PSObject entry, string name, List<string> problems)
    {
        return entry.Properties[name]?.Value switch
        {
            null => null,
            PSObject { BaseObject: null } => null,
            PSObject run => ToRun(run, problems),
            var other => ToRun(PSObject.AsPSObject(other), problems),
        };
    }

    /// <summary>Reads one <c>LazyVM.RemovalPlan</c> object. A size that cannot be read counts as 0.</summary>
    internal static RemovalPlan ToRemovalPlan(PSObject plan)
    {
        long Size(PSObject source, string name)
        {
            return (long)(Read<double?>(source, name, name, []) ?? 0);
        }

        return new()
        {
            Name = Text(plan, "Name"),
            HyperVState = Text(plan, "HyperVState") is { Length: > 0 } state ? state : null,
            CheckpointCount = Read<int?>(plan, "CheckpointCount", "CheckpointCount", []) ?? 0,
            Tasks = ReadList(plan, "Tasks").Select(task => task.BaseObject.ToString() ?? string.Empty).ToList(),
            Items = ReadList(plan, "Items").Select(item => new RemovalItem(Text(item, "Kind"), Text(item, "Path"), Size(item, "Size"))).ToList(),
            Total = Size(plan, "Total"),
            Kept = ReadList(plan, "Kept").Select(kept => new KeptItem(Text(kept, "Path"), Text(kept, "Reason"))).ToList(),
            WorkDisks = ReadList(plan, "WorkDisks")
                .Select(disk => new WorkDisk(Text(disk, "Name"), Text(disk, "Path"), Size(disk, "Size"), Text(disk, "Advice")))
                .ToList(),
        };
    }

    /// <summary>Reads one <c>LazyVM.Check</c> object.</summary>
    internal static VMCheck ToCheck(PSObject check)
    {
        return new(
        Text(check, "Area"),
        Text(check, "Check"),
        Text(check, "Status"),
        Text(check, "Detail"),
        Text(check, "Fix"));
    }

    /// <summary>Reads one <c>LazyVM.LogEntry</c> object. A time that cannot be read is left empty.</summary>
    internal static VMLogEntry ToLogEntry(PSObject entry)
    {
        return new(
        ReadDate(entry, "Time", "Time", []),
        Text(entry, "Level"),
        Text(entry, "Message"));
    }

    /// <summary>
    /// Runs <paramref name="command"/> with each parameter added by name,
    /// never as script text. <paramref name="failsOnlyByThrowing"/>: a
    /// command that can rightly return nothing while it silences errors of
    /// its own, so only an error it throws is its failure.
    /// <paramref name="failsByItsOwnErrors"/>: a command that returns nothing
    /// and reports a refused item as a non-terminating error of its own, so
    /// that error is its failure too (<see cref="ThrowIfCommandWroteError"/>).
    /// </summary>
    private async Task<IReadOnlyList<PSObject>> InvokeAsync(
        string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken, bool failsOnlyByThrowing = false,
        bool failsByItsOwnErrors = false)
    {
        var (output, _) = await InvokeWithWarningsAsync(command, parameters, cancellationToken, failsOnlyByThrowing, failsByItsOwnErrors).ConfigureAwait(false);
        return output;
    }

    /// <summary>As <see cref="InvokeAsync"/>, and also gives the warnings the command wrote, each as its text.</summary>
    private async Task<(IReadOnlyList<PSObject> Output, IReadOnlyList<string> Warnings)> InvokeWithWarningsAsync(
        string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken, bool failsOnlyByThrowing = false,
        bool failsByItsOwnErrors = false)
    {
        ObjectDisposedException.ThrowIf(_Disposed, this);
        await _OneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Importing the module takes a while; keep it off the caller's thread.
            _Runspace ??= await Task.Run(OpenRunspace, cancellationToken).ConfigureAwait(false);

            using var shell = PowerShell.Create(_Runspace);
            shell.AddCommand(command).AddParameters(parameters.ToDictionary(parameter => parameter.Name, parameter => parameter.Value));
            PSDataCollection<PSObject> output;
            using (cancellationToken.Register(() => _ = shell.StopAsync(null, null)))
            {
                try
                {
                    output = await shell.InvokeAsync().ConfigureAwait(false);
                }
                catch (PipelineStoppedException) when (cancellationToken.IsCancellationRequested)
                {
                    throw new OperationCanceledException(cancellationToken);
                }
            }
            cancellationToken.ThrowIfCancellationRequested();
            ThrowIfFailed(output, shell.Streams.Error, failsOnlyByThrowing);
            if (failsByItsOwnErrors)
            {
                ThrowIfCommandWroteError(command, shell.Streams.Error);
            }
            return ([.. output], shell.Streams.Warning.Select(warning => warning.Message).ToList());
        }
        finally
        {
            _OneAtATime.Release();
        }
    }

    /// <summary>
    /// A terminating error already threw. Non-terminating errors count only
    /// when the command returned nothing: the error stream also holds errors a
    /// command silenced with -ErrorAction SilentlyContinue, and the module
    /// reports each VM's own failures in its Problems. A command that
    /// <paramref name="failsOnlyByThrowing"/> never fails here.
    /// </summary>
    internal static void ThrowIfFailed(IList<PSObject> output, IList<ErrorRecord> errors, bool failsOnlyByThrowing = false)
    {
        if (!failsOnlyByThrowing && output.Count == 0 && errors.Count > 0)
        {
            throw new InvalidOperationException(errors[0].ToString());
        }
    }

    private static Runspace OpenRunspace()
    {
        var state = InitialSessionState.CreateDefault2();
        // The policy pwsh has on Windows by default. A hosted runspace with no
        // powershell.config.json would otherwise be Restricted and refuse to
        // load the module. Group Policy still wins over this.
        state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.RemoteSigned;

        var opened = RunspaceFactory.CreateRunspace(state);
        try
        {
            opened.Open();
            // Opening puts the user's own module folders back in front, so the
            // search path is set after it, and the module imported only then.
            Environment.SetEnvironmentVariable("PSModulePath", ModuleSearchPath);
            using var import = PowerShell.Create(opened);
            import.AddCommand("Import-Module").AddParameter("Name", ModulePath).AddParameter("ErrorAction", "Stop");
            try
            {
                import.Invoke();
            }
            catch (ActionPreferenceStopException stopped)
            {
                // Say why the import failed, not that -ErrorAction Stop stopped it.
                throw new InvalidOperationException(stopped.ErrorRecord.Exception.Message, stopped);
            }
            return opened;
        }
        catch
        {
            opened.Dispose();
            throw;
        }
    }

    private static T? Read<T>(PSObject source, string name, string label, List<string> problems)
    {
        var value = Unwrap(source.Properties[name]?.Value);
        if (value is null)
        {
            return default;
        }
        try
        {
            return LanguagePrimitives.ConvertTo<T>(value);
        }
        catch (PSInvalidCastException)
        {
            problems.Add($"{label}: could not be read");
            return default;
        }
    }

    /// <summary>A date, in local time. The module gives some as DateTimeOffset, such as the security scan time.</summary>
    private static DateTime? ReadDate(PSObject source, string name, string label, List<string> problems)
    {
        return Unwrap(source.Properties[name]?.Value) is DateTimeOffset offset
            ? offset.LocalDateTime
            : Read<DateTime?>(source, name, label, problems);
    }

    private static IEnumerable<PSObject> ReadList(PSObject source, string name)
    {
        var value = Unwrap(source.Properties[name]?.Value);
        if (value is null)
        {
            return [];
        }
        var items = LanguagePrimitives.GetEnumerable(value);
        return items is null ? [PSObject.AsPSObject(value)] : items.Cast<object>().Select(PSObject.AsPSObject);
    }

    /// <summary>A property as text; empty when it is missing or empty.</summary>
    private static string Text(PSObject source, string name)
    {
        return Unwrap(source.Properties[name]?.Value)?.ToString() ?? string.Empty;
    }

    private static object? Unwrap(object? value)
    {
        return value is PSObject wrapped ? wrapped.BaseObject : value;
    }
}

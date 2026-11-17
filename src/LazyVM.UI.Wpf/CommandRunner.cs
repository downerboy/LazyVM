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
    private readonly SemaphoreSlim oneAtATime = new(1, 1);
    private Runspace? runspace;
    private bool disposed;

    /// <summary>The installed module: %ProgramFiles%\LazyVM\Modules\LazyVM, which only administrators can change.</summary>
    internal static string ModulePath { get; } = System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LazyVM", "Modules", "LazyVM");

    /// <summary>
    /// Where the hosted PowerShell finds the modules it loads: only folders
    /// administrators control. The app runs elevated, so a module the user
    /// could change, such as one in Documents\PowerShell\Modules, must never
    /// load into it. LazyVM's folder comes first, then the Windows modules
    /// (Hyper-V, ScheduledTasks), then the modules shipped with the app.
    /// </summary>
    internal static string ModuleSearchPath { get; } = string.Join(
        System.IO.Path.PathSeparator,
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LazyVM", "Modules"),
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules"),
        System.IO.Path.Combine(System.IO.Path.GetDirectoryName(typeof(PSObject).Assembly.Location)!, "Modules"));

    /// <summary>True once PowerShell has started and the module is imported.</summary>
    internal bool IsStarted => runspace is not null;

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
    public virtual async Task StartMaintenanceAsync(string name, CancellationToken cancellationToken) =>
        await InvokeAsync("Start-LazyVMMaintenance", [("Name", name)], cancellationToken).ConfigureAwait(false);

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
        var parameters = new List<(string, object)>();
        if (name is not null)
        {
            parameters.Add(("Name", name));
        }
        if (hostOnly)
        {
            parameters.Add(("HostOnly", true));
        }
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
        if (disposed)
        {
            return;
        }
        if (disposing)
        {
            runspace?.Dispose();
            oneAtATime.Dispose();
        }
        disposed = true;
    }

    /// <summary>
    /// Reads one <c>LazyVM.Dashboard</c> object. A value that cannot be read
    /// is left empty and named in the VM's Problems, so one odd value never
    /// fails the whole refresh.
    /// </summary>
    internal static VMDashboard ToDashboard(PSObject entry)
    {
        var problems = ReadList(entry, "Problems").Select(problem => problem.BaseObject.ToString() ?? string.Empty).ToList();
        T? Value<T>(PSObject source, string name, string label) => Read<T>(source, name, label, problems);
        DateTime? Date(string name, string label) => ReadDate(entry, name, label, problems);

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
            GreenTemplate = Value<string>(entry, "GreenTemplate", "Green template"),
            GreenTemplateUpdated = Date("GreenTemplateUpdated", "Green template updated"),
            Settings = Value<string>(entry, "Settings", "Settings") ?? "Not known",
            Run = ReadRun(entry, "Run", problems),
            LastBuild = ReadRun(entry, "LastBuild", problems),
            Problems = problems,
        };
    }

    /// <summary>Reads one <c>LazyVM.VMRun</c> object. A value that cannot be read is left empty and named in <paramref name="problems"/>.</summary>
    internal static VMRun ToRun(PSObject run, List<string> problems) => new()
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

    /// <summary>The run as it came: a [pscustomobject] keeps its properties only on its PSObject, never on what it wraps.</summary>
    private static VMRun? ReadRun(PSObject entry, string name, List<string> problems) =>
        entry.Properties[name]?.Value switch
        {
            null => null,
            PSObject { BaseObject: null } => null,
            PSObject run => ToRun(run, problems),
            var other => ToRun(PSObject.AsPSObject(other), problems),
        };

    /// <summary>Reads one <c>LazyVM.Check</c> object.</summary>
    internal static VMCheck ToCheck(PSObject check) => new(
        Text(check, "Area"),
        Text(check, "Check"),
        Text(check, "Status"),
        Text(check, "Detail"),
        Text(check, "Fix"));

    /// <summary>Reads one <c>LazyVM.LogEntry</c> object. A time that cannot be read is left empty.</summary>
    internal static VMLogEntry ToLogEntry(PSObject entry) => new(
        ReadDate(entry, "Time", "Time", []),
        Text(entry, "Level"),
        Text(entry, "Message"));

    /// <summary>Runs <paramref name="command"/> with each parameter added by name, never as script text.</summary>
    private async Task<IReadOnlyList<PSObject>> InvokeAsync(
        string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        await oneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Importing the module takes a while; keep it off the caller's thread.
            runspace ??= await Task.Run(OpenRunspace, cancellationToken).ConfigureAwait(false);

            using var shell = PowerShell.Create(runspace);
            shell.AddCommand(command);
            foreach (var (name, value) in parameters)
            {
                shell.AddParameter(name, value);
            }
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
            ThrowIfFailed(output, shell.Streams.Error);
            return [.. output];
        }
        finally
        {
            oneAtATime.Release();
        }
    }

    /// <summary>
    /// A terminating error already threw. Non-terminating errors count only
    /// when the command returned nothing: the error stream also holds errors a
    /// command silenced with -ErrorAction SilentlyContinue, and the module
    /// reports each VM's own failures in its Problems.
    /// </summary>
    internal static void ThrowIfFailed(IList<PSObject> output, IList<ErrorRecord> errors)
    {
        if (output.Count == 0 && errors.Count > 0)
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
    private static DateTime? ReadDate(PSObject source, string name, string label, List<string> problems) =>
        Unwrap(source.Properties[name]?.Value) is DateTimeOffset offset
            ? offset.LocalDateTime
            : Read<DateTime?>(source, name, label, problems);

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
    private static string Text(PSObject source, string name) =>
        Unwrap(source.Properties[name]?.Value)?.ToString() ?? string.Empty;

    private static object? Unwrap(object? value) => value is PSObject wrapped ? wrapped.BaseObject : value;
}

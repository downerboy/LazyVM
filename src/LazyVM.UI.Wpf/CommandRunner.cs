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
        var output = await InvokeAsync("Get-LazyVMDashboard", cancellationToken).ConfigureAwait(false);
        return output.Select(ToDashboard).ToList();
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
            Problems = problems,
        };
    }

    private async Task<IReadOnlyList<PSObject>> InvokeAsync(string command, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        await oneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Importing the module takes a while; keep it off the caller's thread.
            runspace ??= await Task.Run(OpenRunspace, cancellationToken).ConfigureAwait(false);

            using var shell = PowerShell.Create(runspace);
            shell.AddCommand(command);
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

    private static object? Unwrap(object? value) => value is PSObject wrapped ? wrapped.BaseObject : value;
}

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
/// through PSModulePath, and no profile scripts. Commands are fixed commands
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

    /// <summary>Reads one <c>LazyVM.Dashboard</c> object.</summary>
    internal static VMDashboard ToDashboard(PSObject entry) => new()
    {
        Name = Read<string>(entry, "Name") ?? string.Empty,
        State = Read<string>(entry, "State") ?? "Unknown",
        Created = Read<DateTime?>(entry, "Created"),
        MemoryAssigned = Read<long?>(entry, "MemoryAssigned"),
        Disks = ReadList(entry, "Disks").Select(disk => new VMDisk(
            Read<string>(disk, "Name") ?? string.Empty,
            Read<string>(disk, "Path") ?? string.Empty,
            Read<long?>(disk, "Used") ?? 0,
            Read<long?>(disk, "Maximum") ?? 0)).ToList(),
        DiskSpaceUsed = Read<long?>(entry, "DiskSpaceUsed"),
        MaintenanceTime = Read<string>(entry, "MaintenanceTime"),
        MaintenanceTask = Read<string>(entry, "MaintenanceTask"),
        LastMaintenance = Read<DateTime?>(entry, "LastMaintenance"),
        LastMaintenanceResult = Read<string>(entry, "LastMaintenanceResult"),
        LastSecurityScan = Read<DateTime?>(entry, "LastSecurityScan"),
        OpenFindings = Read<int?>(entry, "OpenFindings"),
        OriginalConfig = Read<string>(entry, "OriginalConfig"),
        GreenTemplate = Read<string>(entry, "GreenTemplate"),
        GreenTemplateUpdated = Read<DateTime?>(entry, "GreenTemplateUpdated"),
        Settings = Read<string>(entry, "Settings") ?? "Not known",
        Problems = ReadList(entry, "Problems").Select(problem => problem.BaseObject.ToString() ?? string.Empty).ToList(),
    };

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
            if (shell.Streams.Error.Count > 0)
            {
                throw new InvalidOperationException(shell.Streams.Error[0].ToString());
            }
            return [.. output];
        }
        finally
        {
            oneAtATime.Release();
        }
    }

    private static Runspace OpenRunspace()
    {
        var state = InitialSessionState.CreateDefault2();
        // The policy pwsh has on Windows by default. A hosted runspace with no
        // powershell.config.json would otherwise be Restricted and refuse to
        // load the module. Group Policy still wins over this.
        state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.RemoteSigned;
        state.ThrowOnRunspaceOpenError = true;
        state.ImportPSModule(ModulePath);

        var opened = RunspaceFactory.CreateRunspace(state);
        opened.Open();
        return opened;
    }

    private static T? Read<T>(PSObject source, string name)
    {
        var value = Unwrap(source.Properties[name]?.Value);
        return value is null ? default : LanguagePrimitives.ConvertTo<T>(value);
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

    private static object? Unwrap(object? value) => value is PSObject wrapped ? wrapped.BaseObject : value;
}

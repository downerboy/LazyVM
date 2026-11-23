using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;

namespace LazyVM.UI;

/// <summary>
/// One PowerShell hosted in the app, with the LazyVM module imported. A
/// session runs one command at a time, so a second call waits for the
/// first; <see cref="PowerShellSessionFactory"/> gives each VM its own, so
/// one VM's commands never wait for another's.
/// </summary>
/// <remarks>
/// One runspace, opened on the first call, with the installed module
/// imported by full path from %ProgramFiles%\LazyVM\Modules, never found
/// through PSModulePath, no profile scripts, and a module search path of
/// folders only administrators control. Commands are fixed commands with
/// fixed parameters, never script text.
/// </remarks>
public sealed class PowerShellSession : IDisposable
{
    /// <summary>
    /// One runspace opens at a time, in the whole app: PSModulePath belongs
    /// to the process, and opening a runspace changes it, so a second
    /// session opening while the first imports the module could let the
    /// user's own module folders in.
    /// </summary>
    private static readonly Lock _OneOpenAtATime = new();

    private readonly SemaphoreSlim _OneAtATime = new(1, 1);
    private readonly Lock _State = new();
    private Runspace? _Runspace;
    private bool _Disposed;

    /// <summary>The installed module: %ProgramFiles%\LazyVM\Modules\LazyVM, which only administrators can change.</summary>
    internal static string ModulePath
    {
        get;
    } = Path.Combine(
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
        Path.PathSeparator,
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "LazyVM", "Modules"),
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "Modules"),
        Path.Combine(Path.GetDirectoryName(typeof(PSObject).Assembly.Location)!, "Modules"));

    /// <summary>Tells one session from another, such as the host's from a VM's.</summary>
    public Guid InstanceId { get; } = Guid.NewGuid();

    /// <summary>True once PowerShell has started and the module is imported.</summary>
    internal bool IsStarted
    {
        get
        {
            lock (_State)
            {
                return _Runspace is not null;
            }
        }
    }

    /// <summary>
    /// Runs <paramref name="command"/> with each parameter added by name,
    /// never as script text, and gives what it wrote. Throws
    /// <see cref="OperationCanceledException"/> when cancelled, and
    /// <see cref="ObjectDisposedException"/> once the session is closed.
    /// </summary>
    public async Task<PowerShellResult> InvokeAsync(
        string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        await _OneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            // Importing the module takes a while; keep it off the caller's thread.
            var runspace = CurrentRunspace() ?? Keep(await Task.Run(OpenRunspace, cancellationToken).ConfigureAwait(false));

            using var shell = PowerShell.Create(runspace);
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
            return new PowerShellResult([.. output], [.. shell.Streams.Error], [.. shell.Streams.Warning.Select(warning => warning.Message)]);
        }
        finally
        {
            _OneAtATime.Release();
        }
    }

    /// <summary>
    /// Closes the session. A command running now is stopped as PowerShell
    /// closes; one waiting for it throws <see cref="ObjectDisposedException"/>.
    /// </summary>
    public void Dispose()
    {
        Runspace? closing;
        lock (_State)
        {
            if (_Disposed)
            {
                return;
            }
            _Disposed = true;
            closing = _Runspace;
            _Runspace = null;
        }
        // _OneAtATime is left for the collector, not disposed: a call running
        // now still releases it in its finally, and it has no wait handle.
        closing?.Dispose();
    }

    private void ThrowIfDisposed()
    {
        lock (_State)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
        }
    }

    /// <summary>The open runspace, or null before the first call. Throws once the session is closed.</summary>
    private Runspace? CurrentRunspace()
    {
        lock (_State)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
            return _Runspace;
        }
    }

    /// <summary>Keeps the runspace just opened, unless the session closed while it opened.</summary>
    private Runspace Keep(Runspace opened)
    {
        lock (_State)
        {
            if (!_Disposed)
            {
                _Runspace = opened;
                return opened;
            }
        }
        opened.Dispose();
        throw new ObjectDisposedException(nameof(PowerShellSession));
    }

    private static Runspace OpenRunspace()
    {
        var state = InitialSessionState.CreateDefault2();
        // The policy pwsh has on Windows by default. A hosted runspace with no
        // powershell.config.json would otherwise be Restricted and refuse to
        // load the module. Group Policy still wins over this.
        state.ExecutionPolicy = Microsoft.PowerShell.ExecutionPolicy.RemoteSigned;

        lock (_OneOpenAtATime)
        {
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
    }
}

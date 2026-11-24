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
/// fixed parameters, never script text. Tests replace
/// <see cref="InvokeAsync"/> to answer without the module.
/// </remarks>
public class PowerShellSession : IDisposable
{
    /// <summary>
    /// Keeps commands and opens apart in the whole app (#528): PSModulePath
    /// belongs to the process, and opening a runspace puts the user's own
    /// module folders back in it until the session sets it back, so no
    /// command may run, and autoload a module, while any session opens.
    /// </summary>
    private static readonly ModulePathGate _ModulePath = new();

    private readonly SemaphoreSlim _OneAtATime = new(1, 1);
    private readonly Lock _State = new();
    private Runspace? _Runspace;
    private int _Calls;
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

    /// <summary>True while a command runs in the session, or waits for one that does, so the session must not be closed.</summary>
    internal virtual bool IsBusy => Volatile.Read(ref _Calls) > 0;

    /// <summary>
    /// Runs <paramref name="command"/> with each parameter added by name,
    /// never as script text, and gives what it wrote. Throws
    /// <see cref="OperationCanceledException"/> when cancelled, and
    /// <see cref="ObjectDisposedException"/> once the session is closed.
    /// </summary>
    public virtual async Task<PowerShellResult> InvokeAsync(
        string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        Interlocked.Increment(ref _Calls);
        try
        {
            await _OneAtATime.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            Interlocked.Decrement(ref _Calls);
            throw;
        }
        try
        {
            var runspace = CurrentRunspace() ?? Keep(await OpenAsync(cancellationToken).ConfigureAwait(false));

            using var running = await _ModulePath.RunAsync(cancellationToken).ConfigureAwait(false);
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
            Interlocked.Decrement(ref _Calls);
        }
    }

    /// <summary>
    /// Closes the session. A command running now is stopped as PowerShell
    /// closes; one waiting for it throws <see cref="ObjectDisposedException"/>.
    /// </summary>
    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }

    protected virtual void Dispose(bool disposing)
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
        if (disposing)
        {
            closing?.Dispose();
        }
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

    /// <summary>Opens the runspace while no command runs in any session, off the caller's thread: importing the module takes a while.</summary>
    private static async Task<Runspace> OpenAsync(CancellationToken cancellationToken)
    {
        using var opening = await _ModulePath.OpenAsync(cancellationToken).ConfigureAwait(false);
        return await Task.Run(OpenRunspace, cancellationToken).ConfigureAwait(false);
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
            try
            {
                opened.Open();
            }
            finally
            {
                // Opening puts the user's own module folders back in front, even
                // when it then fails, so the search path is set back before any
                // command may run again, and the module imported only after.
                Environment.SetEnvironmentVariable("PSModulePath", ModuleSearchPath);
            }
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

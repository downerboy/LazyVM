namespace LazyVM.UI;

/// <summary>
/// Gives each command the PowerShell session it runs in: one for commands
/// about the host, and one per VM, made on first use and kept, so the app
/// can work on several VMs at once. Past a limit on VM sessions, the one of
/// the VM idle longest is closed to make room, never one running a command,
/// and opens again when its VM is used. A VM is known by its Hyper-V Id,
/// which, unlike its name, never changes. The app makes one factory when it
/// starts and disposes it, with every session, when it exits.
/// </summary>
public class PowerShellSessionFactory : IDisposable
{
    /// <summary>
    /// How many VM sessions stay open. A session costs about 10 MB and 0.2 s
    /// to open on a PC without Hyper-V, and more on a host that loads Hyper-V
    /// and its modules. Set it from a measurement on a real host (#538).
    /// </summary>
    public const int DEFAULT_MAX_VM_SESSIONS = 8;

    private readonly Lock _Gate = new();
    private readonly Dictionary<Guid, VMSession> _VMs = [];
    private readonly int _MaxVMSessions;
    private PowerShellSession? _Host;
    private long _Clock;
    private bool _Disposed;

    /// <summary>A factory that keeps <see cref="DEFAULT_MAX_VM_SESSIONS"/> VM sessions open.</summary>
    public PowerShellSessionFactory()
        : this(DEFAULT_MAX_VM_SESSIONS)
    {
    }

    /// <summary>A factory that keeps at most <paramref name="maxVMSessions"/> VM sessions open, closing the one idle longest to make room.</summary>
    public PowerShellSessionFactory(int maxVMSessions)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxVMSessions, 1);
        _MaxVMSessions = maxVMSessions;
    }

    /// <summary>The session for commands about the host or every VM, such as the dashboard.</summary>
    public PowerShellSession ForHost()
    {
        lock (_Gate)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
            return _Host ??= CreateSession();
        }
    }

    /// <summary>The session for commands about the VM with the Hyper-V Id <paramref name="id"/>.</summary>
    public PowerShellSession ForVM(Guid id)
    {
        List<PowerShellSession> evicted = [];
        PowerShellSession session;
        lock (_Gate)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
            if (_VMs.TryGetValue(id, out var entry))
            {
                entry.LastUsed = ++_Clock;
            }
            else
            {
                evicted = EvictForNewSession();
                entry = new VMSession(CreateSession(), ++_Clock);
                _VMs.Add(id, entry);
            }
            session = entry.Session;
        }
        // A closed session opens again, quietly, the next time its VM is used.
        evicted.ForEach(closing => closing.Dispose());
        return session;
    }

    /// <summary>Closes the VM's session, such as once the VM is deleted. Nothing happens when it has none.</summary>
    public void Close(Guid id)
    {
        VMSession? closing;
        lock (_Gate)
        {
            _VMs.Remove(id, out closing);
        }
        closing?.Session.Dispose();
    }

    /// <summary>
    /// Takes out the sessions of the VMs idle longest until one more fits
    /// under the limit. A session running a command, or with one waiting, is
    /// never taken, so the limit can be passed while every session is busy.
    /// Call with the gate held; the caller disposes what this gives.
    /// </summary>
    private List<PowerShellSession> EvictForNewSession()
    {
        List<PowerShellSession> evicted = [];
        while (_VMs.Count >= _MaxVMSessions
            && _VMs.Where(pair => !pair.Value.Session.IsBusy)
                .OrderBy(pair => pair.Value.LastUsed)
                .Select(pair => (KeyValuePair<Guid, VMSession>?)pair)
                .FirstOrDefault() is { } idle)
        {
            _VMs.Remove(idle.Key);
            evicted.Add(idle.Value.Session);
        }
        return evicted;
    }

    /// <summary>Closes every session.</summary>
    public void Dispose()
    {
        Dispose(true);
        GC.SuppressFinalize(this);
    }

    protected virtual void Dispose(bool disposing)
    {
        List<PowerShellSession> closing;
        lock (_Gate)
        {
            if (_Disposed)
            {
                return;
            }
            _Disposed = true;
            closing = [.. _VMs.Values.Select(entry => entry.Session), .. new[] { _Host }.OfType<PowerShellSession>()];
            _VMs.Clear();
            _Host = null;
        }
        if (!disposing)
        {
            return;
        }
        foreach (var session in closing)
        {
            session.Dispose();
        }
    }

    /// <summary>A new session, not started. Tests make sessions that answer without the module.</summary>
    protected virtual PowerShellSession CreateSession()
    {
        return new PowerShellSession();
    }

    /// <summary>A VM's session and when it was last asked for, by a counter, so the one idle longest has the lowest.</summary>
    private sealed class VMSession(PowerShellSession session, long lastUsed)
    {
        public PowerShellSession Session { get; } = session;

        public long LastUsed { get; set; } = lastUsed;
    }
}

namespace LazyVM.UI;

/// <summary>
/// Gives each command the PowerShell session it runs in: one for commands
/// about the host, and one per VM, made on first use and kept, so the app
/// can work on several VMs at once. A VM is known by its Hyper-V Id, which,
/// unlike its name, never changes. The app makes one factory when it
/// starts and disposes it, with every session, when it exits.
/// </summary>
public sealed class PowerShellSessionFactory : IDisposable
{
    private readonly Lock _Gate = new();
    private readonly Dictionary<Guid, PowerShellSession> _VMs = [];
    private PowerShellSession? _Host;
    private bool _Disposed;

    /// <summary>The session for commands about the host or every VM, such as the dashboard.</summary>
    public PowerShellSession ForHost()
    {
        lock (_Gate)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
            return _Host ??= new PowerShellSession();
        }
    }

    /// <summary>The session for commands about the VM with the Hyper-V Id <paramref name="id"/>.</summary>
    public PowerShellSession ForVM(Guid id)
    {
        lock (_Gate)
        {
            ObjectDisposedException.ThrowIf(_Disposed, this);
            if (!_VMs.TryGetValue(id, out var session))
            {
                session = new PowerShellSession();
                _VMs.Add(id, session);
            }
            return session;
        }
    }

    /// <summary>Closes the VM's session, such as once the VM is deleted. Nothing happens when it has none.</summary>
    public void Close(Guid id)
    {
        PowerShellSession? closing;
        lock (_Gate)
        {
            _VMs.Remove(id, out closing);
        }
        closing?.Dispose();
    }

    /// <summary>Closes every session.</summary>
    public void Dispose()
    {
        List<PowerShellSession> closing;
        lock (_Gate)
        {
            if (_Disposed)
            {
                return;
            }
            _Disposed = true;
            closing = [.. _VMs.Values, .. new[] { _Host }.OfType<PowerShellSession>()];
            _VMs.Clear();
            _Host = null;
        }
        foreach (var session in closing)
        {
            session.Dispose();
        }
    }
}

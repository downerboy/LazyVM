namespace LazyVM.UI;

/// <summary>
/// The one signal that something the list of VMs shows has changed, so the
/// list is read again: a build ended, a run started, a VM was deleted, a
/// restore or an export of recovery keys ended, or a security finding was
/// approved or revoked. Raised even when the command failed, since it may
/// have changed part of what the list shows.
/// </summary>
public sealed class ListChanges
{
    public event EventHandler? Changed;

    /// <summary>Tells every subscriber that the list is out of date.</summary>
    public void Raise()
    {
        Changed?.Invoke(this, EventArgs.Empty);
    }
}

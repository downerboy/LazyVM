namespace LazyVM.UI;

/// <summary>
/// The clipboard, for a password the user copies (#469). The password is put
/// where it is left out of clipboard history and never synced to other
/// devices, as the module's Set-ClipboardSecret does. Three minutes later it
/// is cleared, but only if the clipboard still holds that password, and
/// <see cref="ClearNow"/> clears it at once when the app closes. One for the
/// whole app, so closing the window that copied it does not stop the clear.
/// How a GUI reaches the clipboard is its own: it derives from this class.
/// </summary>
public abstract class SecretClipboard(TimeProvider clock)
{
    /// <summary>How long a copied password stays on the clipboard.</summary>
    public static readonly TimeSpan KEEP_FOR = TimeSpan.FromMinutes(3);

    private readonly object _Gate = new();
    private string? _Held;
    private ITimer? _Clearing;

    /// <summary>Puts <paramref name="secret"/> on the clipboard, and gives when it will be cleared. Throws, with nothing to clear later, when it could not.</summary>
    public DateTimeOffset Put(string secret)
    {
        Write(secret);
        lock (_Gate)
        {
            _Clearing?.Dispose();
            _Held = secret;
            _Clearing = clock.CreateTimer(_ => OnUIThread(ClearNow), null, KEEP_FOR, Timeout.InfiniteTimeSpan);
        }
        return clock.GetLocalNow() + KEEP_FOR;
    }

    /// <summary>Clears the clipboard now if it still holds the secret put on it, as when the app closes. Never throws.</summary>
    public void ClearNow()
    {
        string? held;
        lock (_Gate)
        {
            held = _Held;
            _Held = null;
            _Clearing?.Dispose();
            _Clearing = null;
        }
        if (held is null)
        {
            return;
        }
        try
        {
            if (Holds(held))
            {
                Erase();
            }
        }
        catch (Exception exception) when (exception is System.Runtime.InteropServices.ExternalException or InvalidOperationException)
        {
            // Another program has the clipboard open; there is nothing more to do, and nothing to say the password in.
        }
    }

    /// <summary>Puts the text on the clipboard, out of clipboard history and sync.</summary>
    protected abstract void Write(string secret);

    /// <summary>True while the clipboard holds <paramref name="secret"/>.</summary>
    protected abstract bool Holds(string secret);

    protected abstract void Erase();

    /// <summary>
    /// Runs <paramref name="action"/> where the clipboard can be used: some
    /// GUIs allow it on their UI thread only, and the timer fires on another.
    /// Queued, not waited for, so a timer that fires while the app is closing
    /// never throws: closing clears the clipboard itself.
    /// </summary>
    protected abstract void OnUIThread(Action action);
}

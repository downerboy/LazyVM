using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The clipboard, for a password the user copies (#469). The password is
/// marked with Windows' ExcludeClipboardContentFromMonitorProcessing format,
/// as the module's Set-ClipboardSecret does, so it is left out of clipboard
/// history and never synced to other devices. Three minutes later it is
/// cleared, but only if the clipboard still holds that password, and
/// <see cref="ClearNow"/> clears it at once when the app closes. One for the
/// whole app, so closing the window that copied it does not stop the clear.
/// </summary>
public class SecretClipboard(TimeProvider clock)
{
    /// <summary>How long a copied password stays on the clipboard.</summary>
    public static readonly TimeSpan KEEP_FOR = TimeSpan.FromMinutes(3);

    private const string _EXCLUDE_FROM_HISTORY = "ExcludeClipboardContentFromMonitorProcessing";

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
    protected virtual void Write(string secret)
    {
        var data = new DataObject();
        data.SetText(secret, TextDataFormat.UnicodeText);
        // Any data in this format does it; a stream goes to the clipboard as it is.
        data.SetData(_EXCLUDE_FROM_HISTORY, new System.IO.MemoryStream(new byte[4]));
        Clipboard.SetDataObject(data, copy: true);
    }

    /// <summary>True while the clipboard holds <paramref name="secret"/>.</summary>
    protected virtual bool Holds(string secret)
    {
        return Clipboard.ContainsText(TextDataFormat.UnicodeText) && Clipboard.GetText(TextDataFormat.UnicodeText) == secret;
    }

    protected virtual void Erase()
    {
        Clipboard.Clear();
    }

    /// <summary>
    /// The clipboard can only be used on the UI thread; the timer fires on
    /// another. Queued, not waited for, so a timer that fires while the app
    /// is closing never throws: closing clears the clipboard itself.
    /// </summary>
    protected virtual void OnUIThread(Action action)
    {
        Application.Current?.Dispatcher.BeginInvoke(action);
    }
}

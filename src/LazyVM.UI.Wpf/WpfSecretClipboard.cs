using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The Windows clipboard. A password is marked with the format
/// ExcludeClipboardContentFromMonitorProcessing, so it is left out of
/// clipboard history and never synced to other devices (#469).
/// </summary>
public sealed class WpfSecretClipboard(TimeProvider clock) : SecretClipboard(clock)
{
    private const string _EXCLUDE_FROM_HISTORY = "ExcludeClipboardContentFromMonitorProcessing";

    protected override void Write(string secret)
    {
        var data = new DataObject();
        data.SetText(secret, TextDataFormat.UnicodeText);
        // Any data in this format does it; a stream goes to the clipboard as it is.
        data.SetData(_EXCLUDE_FROM_HISTORY, new System.IO.MemoryStream(new byte[4]));
        Clipboard.SetDataObject(data, copy: true);
    }

    protected override bool Holds(string secret)
    {
        return Clipboard.ContainsText(TextDataFormat.UnicodeText) && Clipboard.GetText(TextDataFormat.UnicodeText) == secret;
    }

    protected override void Erase()
    {
        Clipboard.Clear();
    }

    /// <summary>The clipboard can only be used on the UI thread; the timer fires on another.</summary>
    protected override void OnUIThread(Action action)
    {
        Application.Current?.Dispatcher.BeginInvoke(action);
    }
}

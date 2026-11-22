using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// One disk's key in the Recovery keys window. Its password is not read
/// until Show, and is in nothing the window or Narrator reads until then.
/// </summary>
public sealed class RecoveryKeyRow : ViewModelBase
{
    private const string _HIDDEN = "Recovery password hidden";

    private readonly Func<RecoveryKeyRow, Task> _Toggle;
    private string? _Password;

    public RecoveryKeyRow(VMRecoveryKey key, Func<RecoveryKeyRow, Task> toggle)
    {
        Key = key;
        _Toggle = toggle;
        ToggleCommand = new RelayCommand(() => _ = ToggleAsync());
    }

    public VMRecoveryKey Key
    {
        get;
    }

    /// <summary>Shows the password, reading it now, or hides it again.</summary>
    public RelayCommand ToggleCommand
    {
        get;
    }

    public bool IsShown => _Password is not null;

    /// <summary>Such as "OS disk, key ID {3333...}, recorded 1 October 2026, exported".</summary>
    public string Text
    {
        get
        {
            var keyId = Key.KeyId.Length > 0 ? Key.KeyId : "not known yet";
            var exported = Key.Exported ? "exported" : "not exported yet";
            return $"{Key.Disk}, key ID {keyId}, {RecordedText}, {exported}";
        }
    }

    /// <summary>"Recovery password hidden", or the password once shown.</summary>
    public string PasswordText => _Password ?? _HIDDEN;

    /// <summary>The row as Narrator reads it: the password only once shown.</summary>
    public string AutomationName => _Password is { } password ? $"{Text}. Recovery password {password}" : $"{Text}. {_HIDDEN}";

    /// <summary>The name of the box that holds the password, or says it is hidden, such as "Recovery password of the OS disk recorded 1 October 2026".</summary>
    public string PasswordName => $"Recovery password of the {Key.Disk} {RecordedText}";

    public string ToggleText => IsShown ? "Hide" : "Show";

    /// <summary>The button's name for Narrator, naming its disk, so two OS disks can be told apart.</summary>
    public string ToggleName => $"{ToggleText} the recovery password of the {Key.Disk} {RecordedText}";

    private string RecordedText => Key.Recorded is { } recorded
        ? "recorded " + recorded.ToString("d MMMM yyyy", CultureInfo.CurrentCulture)
        : "date recorded not known";

    public Task ToggleAsync()
    {
        return _Toggle(this);
    }

    /// <summary>Never the password: a list falls back on this for an item's name.</summary>
    public override string ToString()
    {
        return Text;
    }

    internal void Show(string password)
    {
        _Password = password;
        RaiseShownChanged();
    }

    internal void Hide()
    {
        if (_Password is null)
        {
            return;
        }
        _Password = null;
        RaiseShownChanged();
    }

    private void RaiseShownChanged()
    {
        OnPropertyChanged(nameof(IsShown));
        OnPropertyChanged(nameof(PasswordText));
        OnPropertyChanged(nameof(AutomationName));
        OnPropertyChanged(nameof(ToggleText));
        OnPropertyChanged(nameof(ToggleName));
    }
}

using System.Globalization;

namespace LazyVM.UI.ViewModels;

/// <summary>
/// A VM's Password window: the user name LazyVM signs in to the VM with,
/// and its password, hidden until Show reads it. Copy puts the password on
/// the clipboard without showing it, out of clipboard history, for three
/// minutes. Closing the window forgets the password. The password is never
/// in the status line, an error message or anything Narrator reads before
/// Show.
/// </summary>
public sealed class PasswordViewModel : ViewModelBase
{
    private const string _HIDDEN = "Password hidden";

    private readonly LazyVMCredentialsRunner _Runner;
    private readonly SecretClipboard _Clipboard;
    private readonly LazyVMDashboard _Entry;
    private string _UserName = string.Empty;
    private string? _Password;
    private string _Note = string.Empty;
    private string _Status = string.Empty;
    private bool _IsBusy;

    public PasswordViewModel(LazyVMDashboard entry, LazyVMCredentialsRunner runner, SecretClipboard clipboard)
    {
        _Entry = entry;
        _Runner = runner;
        _Clipboard = clipboard;
        ToggleCommand = new RelayCommand(() => _ = ToggleAsync(), () => CanUse);
        CopyCommand = new RelayCommand(() => _ = CopyAsync(), () => CanUse);
    }

    /// <summary>Shows the password, reading it now, or hides it again.</summary>
    public RelayCommand ToggleCommand
    {
        get;
    }

    /// <summary>Puts the password on the clipboard for three minutes, without showing it.</summary>
    public RelayCommand CopyCommand
    {
        get;
    }

    public string Name => _Entry.Name;

    public string Title => $"Password of {_Entry.Name} - LazyVM";

    /// <summary>The user name LazyVM signs in with; empty until read.</summary>
    public string UserName
    {
        get => _UserName;
        private set
        {
            if (SetProperty(ref _UserName, value))
            {
                OnPropertyChanged(nameof(ToggleName));
                RaiseCommandsChanged();
            }
        }
    }

    public bool IsShown => _Password is not null;

    /// <summary>"Password hidden", or the password once shown.</summary>
    public string PasswordText => _Password ?? _HIDDEN;

    public string ToggleText => IsShown ? "Hide password" : "Show password";

    /// <summary>The button's name for Narrator, such as "Show the password of devadmin on DevBox".</summary>
    public string ToggleName => $"{(IsShown ? "Hide" : "Show")} the password of {UserName} on {Name}";

    /// <summary>Why the password cannot be shown or copied, such as no credential stored; empty when it can.</summary>
    public string Note
    {
        get => _Note;
        private set
        {
            if (SetProperty(ref _Note, value))
            {
                OnPropertyChanged(nameof(HasNote));
            }
        }
    }

    public bool HasNote => Note.Length > 0;

    /// <summary>What Show or Copy did. Never the password.</summary>
    public string Status
    {
        get => _Status;
        private set
        {
            if (SetProperty(ref _Status, value))
            {
                OnPropertyChanged(nameof(HasStatus));
            }
        }
    }

    public bool HasStatus => Status.Length > 0;

    private bool CanUse => UserName.Length > 0 && !_IsBusy;

    /// <summary>Reads the user name only; the password stays unread until Show or Copy.</summary>
    public async Task LoadAsync()
    {
        try
        {
            UserName = await WorkAsync("Reading the user name", () => _Runner.GetLazyVMUserNameAsync(_Entry.Id, Name, CancellationToken.None));
        }
        catch (Exception exception)
        {
            Note = exception.Message;
        }
    }

    /// <summary>Shows the password, reading it now, or hides it.</summary>
    public async Task ToggleAsync()
    {
        if (IsShown)
        {
            Forget();
            Status = "The password is hidden.";
            return;
        }
        if (!CanUse)
        {
            return;
        }
        await WhileBusy(async () =>
        {
            try
            {
                SetPassword(await WorkAsync("Reading the password", () => _Runner.GetLazyVMPasswordAsync(_Entry.Id, Name, CancellationToken.None)));
                Status = "The password is shown. Hide password hides it again; closing this window does too.";
            }
            catch (Exception exception)
            {
                Status = "The password could not be read: " + exception.Message;
            }
        });
    }

    /// <summary>Puts the password on the clipboard, out of clipboard history, and says until when. Never shows it.</summary>
    public async Task CopyAsync()
    {
        if (!CanUse)
        {
            return;
        }
        await WhileBusy(async () =>
        {
            try
            {
                var until = _Clipboard.Put(await WorkAsync("Reading the password", () => _Runner.GetLazyVMPasswordAsync(_Entry.Id, Name, CancellationToken.None)));
                Status = $"The password is on the clipboard until {until.ToString("t", CultureInfo.CurrentCulture)}. "
                    + "It is left out of clipboard history, and cleared then if it is still there.";
            }
            catch (Exception exception)
            {
                Status = "The password was not copied: " + exception.Message;
            }
        });
    }

    /// <summary>Hides and forgets the password, as when the window closes. A copy stays on the clipboard until its three minutes are up.</summary>
    public void Forget()
    {
        SetPassword(null);
    }

    /// <summary>Never the password.</summary>
    public override string ToString()
    {
        return Title;
    }

    private async Task WhileBusy(Func<Task> work)
    {
        _IsBusy = true;
        RaiseCommandsChanged();
        try
        {
            await work();
        }
        finally
        {
            _IsBusy = false;
            RaiseCommandsChanged();
        }
    }

    private void SetPassword(string? password)
    {
        if (_Password == password)
        {
            return;
        }
        _Password = password;
        OnPropertyChanged(nameof(IsShown));
        OnPropertyChanged(nameof(PasswordText));
        OnPropertyChanged(nameof(ToggleText));
        OnPropertyChanged(nameof(ToggleName));
        RaiseCommandsChanged();
    }

    private void RaiseCommandsChanged()
    {
        ToggleCommand.RaiseCanExecuteChanged();
        CopyCommand.RaiseCanExecuteChanged();
    }
}

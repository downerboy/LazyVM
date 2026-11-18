using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// A VM's Recovery keys window: each disk LazyVM encrypted, with the key ID
/// BitLocker's recovery screen shows, when it was recorded and whether it
/// is exported; each password hidden until Show reads it; and exporting the
/// keys to a file the user keeps offline. Closing the window forgets every
/// password it showed.
/// </summary>
public sealed class RecoveryKeysViewModel : ViewModelBase
{
    private readonly ToolWindows _Tools;
    private readonly VMDashboard _Entry;
    private IReadOnlyList<RecoveryKeyRow> _Keys = [];
    private IReadOnlyList<string> _Warnings = [];
    private string _Status = string.Empty;
    private bool _IsLoaded;
    private bool _IsExporting;

    public RecoveryKeysViewModel(VMDashboard entry, ToolWindows tools)
    {
        _Entry = entry;
        _Tools = tools;
        ExportCommand = new RelayCommand(() => _ = ExportAsync(), () => CanExport);
    }

    /// <summary>Asks for a file with a Save dialog, and writes the VM's recovery keys to it.</summary>
    public RelayCommand ExportCommand
    {
        get;
    }

    public string Name => _Entry.Name;

    public string Title => $"Recovery keys of {_Entry.Name} - LazyVM";

    /// <summary>Each disk's key, as the module lists them.</summary>
    public IReadOnlyList<RecoveryKeyRow> Keys
    {
        get => _Keys;
        private set
        {
            if (SetProperty(ref _Keys, value))
            {
                OnPropertyChanged(nameof(Summary));
                RaiseExportChanged();
            }
        }
    }

    /// <summary>Such as "3 recovery keys, 1 not exported yet."; empty until the keys are read.</summary>
    public string Summary
    {
        get
        {
            if (Keys.Count == 0)
            {
                return string.Empty;
            }
            var count = Keys.Count == 1 ? "1 recovery key" : $"{Keys.Count} recovery keys";
            var unexported = Keys.Count(key => !key.Key.Exported);
            return unexported == 0 ? $"{count}, all exported." : $"{count}, {unexported} not exported yet.";
        }
    }

    /// <summary>True from the Save dialog until the export has ended.</summary>
    public bool IsExporting
    {
        get => _IsExporting;
        private set
        {
            if (SetProperty(ref _IsExporting, value))
            {
                RaiseExportChanged();
            }
        }
    }

    /// <summary>Why Export is disabled, as text of its own: a disabled button cannot take focus, so Narrator would never read a reason given only on it.</summary>
    public string ExportNote => _IsLoaded && Keys.Count == 0 && !HasStatus
        ? $"No BitLocker recovery password is stored for {Name} yet, so there is nothing to export. A build turns BitLocker on and stores them."
        : string.Empty;

    public bool HasExportNote => ExportNote.Length > 0;

    /// <summary>The warnings the last export gave, such as for a file in OneDrive, each shown as text of its own.</summary>
    public IReadOnlyList<string> Warnings
    {
        get => _Warnings;
        private set
        {
            if (SetProperty(ref _Warnings, value))
            {
                OnPropertyChanged(nameof(HasWarnings));
            }
        }
    }

    public bool HasWarnings => Warnings.Count > 0;

    /// <summary>What reading the keys, showing a password or an export did. Never a password.</summary>
    public string Status
    {
        get => _Status;
        private set
        {
            if (SetProperty(ref _Status, value))
            {
                OnPropertyChanged(nameof(HasStatus));
                RaiseExportChanged();
            }
        }
    }

    public bool HasStatus => Status.Length > 0;

    private bool CanExport => Keys.Count > 0 && !IsExporting;

    /// <summary>Reads the keys, without their passwords.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var found = await _Tools.GetRecoveryKeysAsync(Name);
            Forget();
            Keys = found.Select(key => new RecoveryKeyRow(key, ToggleAsync)).ToList();
        }
        catch (Exception exception)
        {
            Status = "The recovery keys could not be read: " + exception.Message;
        }
        finally
        {
            _IsLoaded = true;
            RaiseExportChanged();
        }
    }

    /// <summary>
    /// Asks for a file, asks before replacing one that exists (No the
    /// default), then writes the VM's keys to it with Export-LazyVMRecoveryKey,
    /// and reads the keys again.
    /// </summary>
    public async Task ExportAsync()
    {
        if (!CanExport)
        {
            return;
        }
        IsExporting = true;
        try
        {
            var path = _Tools.ChooseExportFile(this, $"{Name}-recovery-keys.txt");
            if (path is null)
            {
                Status = "Nothing was exported.";
                return;
            }
            var replace = _Tools.FileExists(path);
            if (replace && !_Tools.ConfirmReplace(this, ReplaceQuestion(path)))
            {
                Status = "Nothing was exported.";
                return;
            }
            Warnings = [];
            Status = $"Exporting the recovery keys of {Name}";
            string done;
            try
            {
                var export = await _Tools.ExportRecoveryKeysAsync(Name, path, replace);
                Warnings = export.Warnings;
                done = $"The recovery passwords of {Name} were written to {export.Path}. Keep that file offline, such as on a USB drive, somewhere safe.";
            }
            catch (Exception exception)
            {
                done = "The recovery keys were not exported: " + exception.Message;
            }
            await LoadAsync();
            Status = done;
        }
        finally
        {
            IsExporting = false;
        }
    }

    /// <summary>Hides every password shown, as when the window closes.</summary>
    public void Forget()
    {
        foreach (var key in Keys)
        {
            key.Hide();
        }
    }

    private async Task ToggleAsync(RecoveryKeyRow row)
    {
        if (row.IsShown)
        {
            row.Hide();
            Status = $"The recovery password of the {row.Key.Disk} is hidden.";
            return;
        }
        try
        {
            row.Show(await _Tools.GetRecoveryPasswordAsync(Name, row.Key.DiskGuid));
            Status = $"The recovery password of the {row.Key.Disk} is shown. Hide hides it again; closing this window does too.";
        }
        catch (Exception exception)
        {
            Status = $"The recovery password of the {row.Key.Disk} could not be read: {exception.Message}";
        }
    }

    private string ReplaceQuestion(string path)
    {
        return $"{path} already exists. Do you want to replace it? Nothing in it now is kept: it will hold only the recovery passwords of {Name}, "
            + "so those of any other VM in it are removed.";
    }

    private void RaiseExportChanged()
    {
        OnPropertyChanged(nameof(ExportNote));
        OnPropertyChanged(nameof(HasExportNote));
        ExportCommand.RaiseCanExecuteChanged();
    }
}

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

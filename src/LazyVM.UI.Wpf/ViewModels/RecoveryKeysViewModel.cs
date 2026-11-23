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
    private readonly LazyVMRecoveryKeysRunner _Runner;
    private readonly Dialogs _Dialogs;
    private readonly ListChanges _Changes;
    private readonly LazyVMDashboard _Entry;
    private IReadOnlyList<RecoveryKeyRow> _Keys = [];
    private IReadOnlyList<string> _Warnings = [];
    private string _Status = string.Empty;
    private bool _IsLoaded;
    private bool _IsExporting;

    public RecoveryKeysViewModel(LazyVMDashboard entry, LazyVMRecoveryKeysRunner runner, Dialogs dialogs, ListChanges changes)
    {
        _Entry = entry;
        _Runner = runner;
        _Dialogs = dialogs;
        _Changes = changes;
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

    /// <summary>
    /// What exporting writes, why the file must be kept offline, what
    /// replacing a file loses, and when to export again. The window shows it
    /// and gives it to Export as its help text, so Narrator reads the same.
    /// </summary>
    public string ExportHelp => $"Writes the BitLocker recovery passwords of {Name} to a file you choose, as plain text. "
        + "If LazyVM's own copy is lost, as when your Windows profile is deleted, this file is the only way to unlock the disks; anyone who has it can unlock them too. "
        + "Keep it offline, such as on a USB drive kept somewhere safe, not on this computer or in the cloud. "
        + $"Replacing a file, after you are asked, keeps nothing that was in it, so give each VM a file of its own. Export again after a build or rebuild of {Name}, which can add new keys: the VM window says when some are not exported yet.";

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
            var found = await WorkAsync("Reading the recovery keys", () => _Runner.GetLazyVMRecoveryKeysAsync(_Entry.Id, Name, CancellationToken.None));
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
            var path = _Dialogs.ChooseExportFile(this, $"{Name}-recovery-keys.txt");
            if (path is null)
            {
                Status = "Nothing was exported.";
                return;
            }
            var replace = _Dialogs.FileExists(path);
            if (replace && !_Dialogs.ConfirmReplace(this, ReplaceQuestion(path)))
            {
                Status = "Nothing was exported.";
                return;
            }
            Warnings = [];
            Status = $"Exporting the recovery keys of {Name}";
            string done;
            try
            {
                var export = await WorkAsync("Exporting the recovery keys", () => ExportKeysAsync(path, replace));
                Warnings = export.Warnings;
                // The status line is what Narrator announces, so it says there are warnings to read.
                var warned = export.Warnings.Count switch
                {
                    0 => string.Empty,
                    1 => " 1 warning is shown below.",
                    var count => $" {count} warnings are shown below.",
                };
                done = $"The recovery passwords of {Name} were written to {export.Path}. Keep that file offline, such as on a USB drive, somewhere safe.{warned}";
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

    /// <summary>Writes the keys to the file, then tells the list, even when the export failed.</summary>
    private async Task<RecoveryKeyExport> ExportKeysAsync(string path, bool force)
    {
        try
        {
            return await _Runner.ExportLazyVMRecoveryKeysAsync(_Entry.Id, Name, path, force);
        }
        finally
        {
            _Changes.Raise();
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
            row.Show(await WorkAsync("Reading the recovery password", () => _Runner.GetLazyVMRecoveryPasswordAsync(_Entry.Id, Name, row.Key.DiskGuid, CancellationToken.None)));
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

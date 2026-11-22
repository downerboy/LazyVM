namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// A VM's Restore window: its restore points, newest first, each with the
/// date it was taken and whether its tooling list is there, and returning
/// the VM to the one chosen, after asking. Restore is disabled while a run
/// of the VM is going.
/// </summary>
public sealed class RestoreViewModel : ViewModelBase
{
    /// <summary>What a restore puts back and loses, said both in the window and in the question before it.</summary>
    private const string _WHAT_GOES_BACK = "All of its disks go back to then, including the Dev Drive, the SQL data disk and the User disk, "
        + "so code not yet pushed, database changes and files in your personal folders changed since then are lost. A checkpoint of how it is now is taken first, so this restore can be undone.";

    private readonly ToolWindows _Tools;
    private LazyVMDashboard _Entry;
    private IReadOnlyList<RestorePointOption> _Points = [];
    private RestorePointOption? _SelectedPoint;
    private string _Status = string.Empty;
    private bool _IsRestoring;

    public RestoreViewModel(LazyVMDashboard entry, ToolWindows tools)
    {
        _Entry = entry;
        _Tools = tools;
        RestoreCommand = new RelayCommand(() => _ = RestoreAsync(), () => CanRestore);
    }

    /// <summary>Asks, and on Yes returns the VM to <see cref="SelectedPoint"/>.</summary>
    public RelayCommand RestoreCommand
    {
        get;
    }

    public string Name => _Entry.Name;

    public string Title => $"Restore points of {_Entry.Name} - LazyVM";

    /// <summary>True while a build, maintenance or other run of the VM is going: no restore may start.</summary>
    public bool IsBusy => _Entry.Run is { IsRunning: true };

    /// <summary>True from the question until the restore has ended.</summary>
    public bool IsRestoring
    {
        get => _IsRestoring;
        private set
        {
            if (SetProperty(ref _IsRestoring, value))
            {
                RestoreCommand.RaiseCanExecuteChanged();
            }
        }
    }

    /// <summary>The restore points, newest first.</summary>
    public IReadOnlyList<RestorePointOption> Points
    {
        get => _Points;
        private set => SetProperty(ref _Points, value);
    }

    public RestorePointOption? SelectedPoint
    {
        get => _SelectedPoint;
        set
        {
            if (SetProperty(ref _SelectedPoint, value))
            {
                RaiseRestoreChanged();
            }
        }
    }

    /// <summary>
    /// Why Restore is disabled, as text of its own: a disabled button cannot
    /// take focus, so Narrator would never read a reason given only on it.
    /// </summary>
    public string RestoreNote => IsBusy
        ? $"{DashboardText.RunName(_Entry.Run!.Command)} of {Name} is running now, so {Name} cannot be restored until it has ended."
        : SelectedPoint is { Point.HasToolingList: false }
        ? "This restore point cannot be restored: its tooling list is missing."
        : string.Empty;

    public bool HasRestoreNote => RestoreNote.Length > 0;

    /// <summary>What reading the points or a restore did, such as why it did not finish.</summary>
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

    private bool CanRestore => !IsBusy && !IsRestoring && SelectedPoint is { Point.HasToolingList: true };

    /// <summary>Reads the restore points, newest first, and chooses the newest.</summary>
    public async Task LoadAsync()
    {
        try
        {
            var found = await WorkAsync("Reading the restore points", () => _Tools.GetRestorePointsAsync(Name));
            Points = found.OrderByDescending(point => point.Taken).Select(point => new RestorePointOption(point)).ToList();
            SelectedPoint = Points.FirstOrDefault();
            if (Points.Count == 0)
            {
                Status = $"{Name} has no restore points yet. One is taken each time a change to its tooling is recorded.";
            }
        }
        catch (Exception exception)
        {
            Status = "The restore points could not be read: " + exception.Message;
        }
    }

    /// <summary>
    /// Asks what a restore does, and on Yes returns the VM to the chosen
    /// point with Restore-LazyVMTooling -Force. The points are read again
    /// afterwards, however it ended.
    /// </summary>
    public async Task RestoreAsync()
    {
        if (!CanRestore || SelectedPoint is not { } chosen)
        {
            return;
        }
        IsRestoring = true;
        try
        {
            var when = chosen.When;
            if (!_Tools.ConfirmRestore(this, Question(when)))
            {
                Status = $"{Name} was not restored.";
                return;
            }
            Status = $"Restoring {Name} to {when}";
            string done;
            try
            {
                await WorkAsync($"Restoring {Name}", () => _Tools.RestoreToolingAsync(Name, chosen.Point.Stamp));
                done = $"{Name} is back at {when}. A restore point of how it was just before was taken, so this can be undone.";
            }
            catch (Exception exception)
            {
                done = "The restore did not finish: " + exception.Message;
            }
            await LoadAsync();
            Status = done;
        }
        finally
        {
            IsRestoring = false;
        }
    }

    /// <summary>Shows what a newer refresh read for this VM, such as a run that has started.</summary>
    public void Update(LazyVMDashboard entry)
    {
        _Entry = entry;
        OnPropertyChanged(nameof(IsBusy));
        RaiseRestoreChanged();
    }

    /// <summary>
    /// What restoring <see cref="SelectedPoint"/> puts back, what it keeps and
    /// what is lost; empty with no point, or one that cannot be restored. The
    /// window shows it and gives it to Restore as its help text, and the
    /// question before a restore says the same.
    /// </summary>
    public string RestoreHelp => SelectedPoint is { Point.HasToolingList: true } point
        ? $"Returns {Name} to {point.When}, with the tooling list it had then; every other setting stays as it is now. {_WHAT_GOES_BACK} Push your work first."
        : string.Empty;

    public bool HasRestoreHelp => RestoreHelp.Length > 0;

    private string Question(string when)
    {
        return $"Do you really want to restore {Name} to {when}? {_WHAT_GOES_BACK}";
    }

    private void RaiseRestoreChanged()
    {
        OnPropertyChanged(nameof(RestoreNote));
        OnPropertyChanged(nameof(HasRestoreNote));
        OnPropertyChanged(nameof(RestoreHelp));
        OnPropertyChanged(nameof(HasRestoreHelp));
        RestoreCommand.RaiseCanExecuteChanged();
    }
}

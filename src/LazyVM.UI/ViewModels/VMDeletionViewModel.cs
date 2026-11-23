namespace LazyVM.UI.ViewModels;

/// <summary>
/// Deleting a VM, in its window: what the delete takes with it, then a list
/// of what goes and a question, and on Yes, Remove-LazyVM -Force. A delete
/// that did not finish says why, as the module reports it, and what is
/// still there.
/// </summary>
public sealed class VMDeletionViewModel : VMPartViewModel
{
    private readonly LazyVMRemovalRunner _Removals;
    private readonly Dialogs _Dialogs;
    private readonly ListChanges _Changes;

    public VMDeletionViewModel(VMRunGate gate, LazyVMRemovalRunner removals, Dialogs dialogs, ListChanges changes)
        : base(gate)
    {
        _Removals = removals;
        _Dialogs = dialogs;
        _Changes = changes;
        DeleteCommand = new RelayCommand(() => _ = DeleteAsync(), () => Gate.CanStart);
    }

    /// <summary>Raised when the VM has been deleted, so its window closes.</summary>
    public event EventHandler? Removed;

    /// <summary>Shows what deleting the VM deletes, asks, and on Yes deletes it.</summary>
    public RelayCommand DeleteCommand
    {
        get;
    }

    /// <summary>True from reading what a delete would delete until the delete has ended.</summary>
    public bool IsDeleting => Gate.IsDeleting;

    /// <summary>
    /// What deleting the VM takes with it, including the work on its Dev
    /// Drive and User disk, and what is kept. The window shows it and gives
    /// it to Delete as its help text, so Narrator reads the same. The
    /// template is named only when the VM has one.
    /// </summary>
    public string Help => string.Join(" ", new[]
    {
        $"Deletes {Name} and everything LazyVM made for it: its disks, tasks and folder.",
        @"That includes the Dev Drive, with any code not yet pushed, and the User disk, with Documents, Desktop, Downloads, .ssh and source\repos, so push or copy your work first.",
        "It cannot be undone.",
        string.IsNullOrEmpty(Gate.Entry.GreenTemplate) ? string.Empty : $"Its template, {Gate.Entry.GreenTemplate}, is kept, to build a matching VM from later.",
        "A list of what goes comes first, and you are asked before anything is deleted.",
    }.Where(text => text.Length > 0));

    /// <summary>Why Delete is disabled, as text of its own beside it; empty when it is not.</summary>
    public string Note => Gate.IsBusy
        ? $"{Gate.RunningName} of {Name} is running now, so {Name} cannot be deleted until it has ended."
        : string.Empty;

    public bool HasNote => Note.Length > 0;

    /// <summary>
    /// Shows what deleting the VM deletes and asks; on Yes, deletes it with
    /// Remove-LazyVM -Force. A delete that did not finish says why, as the
    /// module reports it, and what is still there.
    /// </summary>
    public async Task DeleteAsync()
    {
        if (!Gate.CanStart)
        {
            return;
        }
        Gate.IsDeleting = true;
        Status = $"Reading what deleting {Name} would delete";
        try
        {
            RemovalPlan plan;
            try
            {
                plan = await WorkAsync("Reading what deleting the VM removes", () => _Removals.GetLazyVMRemovalPlanAsync(Gate.Entry.Id, Name, CancellationToken.None));
            }
            catch (Exception exception)
            {
                Status = $"{Name} cannot be deleted now: {exception.Message}";
                return;
            }
            if (!_Dialogs.ConfirmRemoval(new RemovalViewModel(plan)))
            {
                Status = $"{Name} was not deleted.";
                return;
            }
            Status = $"Deleting {Name}";
            try
            {
                await WorkAsync($"Deleting {Name}", RemoveAsync);
            }
            catch (Exception exception)
            {
                var left = await LeftAsync();
                Status = string.Join(" ", new[] { $"Deleting {Name} did not finish: {exception.Message}", left }.Where(text => text.Length > 0));
                return;
            }
            Status = $"{Name} has been deleted.";
            Removed?.Invoke(this, EventArgs.Empty);
        }
        finally
        {
            Gate.IsDeleting = false;
        }
    }

    protected override void GateChanged()
    {
        DeleteCommand.RaiseCanExecuteChanged();
        base.GateChanged();
    }

    /// <summary>Deletes the VM, then tells the list, even when only part was deleted.</summary>
    private async Task RemoveAsync()
    {
        try
        {
            await _Removals.RemoveLazyVMAsync(Gate.Entry.Id, Name);
        }
        finally
        {
            _Changes.Raise();
        }
    }

    /// <summary>What a delete that did not finish left, read again; empty when that cannot be read, such as once the VM's settings are gone.</summary>
    private async Task<string> LeftAsync()
    {
        try
        {
            // In the host's session: the delete closed the VM's, and its Hyper-V Id may be gone.
            return RemovalViewModel.Left(await WorkAsync("Checking what is left of the VM", () => _Removals.GetLazyVMRemovalPlanAsync(null, Name, CancellationToken.None)));
        }
        catch (Exception)
        {
            return string.Empty;
        }
    }
}

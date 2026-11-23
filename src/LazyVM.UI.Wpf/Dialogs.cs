using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The questions the app asks, and the file it asks for, over the window the
/// user is working in. A view model asks through this class, so it never
/// shows a window itself, and tests answer without one.
/// </summary>
public abstract class Dialogs
{
    /// <summary>
    /// Shows what deleting the VM deletes, and asks "Do you really want to
    /// delete this VM?", over the VM's window. True for Yes.
    /// </summary>
    public abstract bool ConfirmRemoval(RemovalViewModel removal);

    /// <summary>Asks <paramref name="question"/> with Yes and No, No the default, over the restore window. True for Yes.</summary>
    public abstract bool ConfirmRestore(RestoreViewModel restore, string question);

    /// <summary>
    /// Asks for the file to export to with a Save dialog over the recovery
    /// keys window; empty for Cancel. It does not ask about a file that
    /// exists: <see cref="ConfirmReplace"/> does, with No the default.
    /// </summary>
    public abstract string? ChooseExportFile(RecoveryKeysViewModel keys, string suggestedName);

    /// <summary>True when there is a file at <paramref name="path"/>.</summary>
    public abstract bool FileExists(string path);

    /// <summary>Asks <paramref name="question"/> with Yes and No, No the default, over the recovery keys window. True for Yes.</summary>
    public abstract bool ConfirmReplace(RecoveryKeysViewModel keys, string question);

    /// <summary>Asks for the optional reason an approval keeps, over the Security findings window. Null for Cancel.</summary>
    public abstract string? AskApprovalReason(SecurityFindingsViewModel findings, SecurityFindingRow finding);

    /// <summary>Asks <paramref name="question"/> with Yes and No, No the default, over the Security findings window. True for Yes.</summary>
    public abstract bool ConfirmSecurityChange(SecurityFindingsViewModel findings, string title, string question);
}

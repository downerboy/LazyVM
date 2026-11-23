using LazyVM.UI.Wpf.ViewModels;

using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>The app's dialogs, shown as WPF windows over the window of the view model that asks.</summary>
public sealed class WpfDialogs : Dialogs
{
    public override bool ConfirmRemoval(RemovalViewModel removal)
    {
        var owner = Windows.OfType<VMWindow>()
            .FirstOrDefault(window => window.DataContext is VMViewModel vm && string.Equals(vm.Name, removal.Name, StringComparison.OrdinalIgnoreCase));
        var dialog = new RemovalWindow { DataContext = removal, Owner = owner ?? Application.Current.MainWindow };
        return dialog.ShowDialog() == true;
    }

    public override bool ConfirmRestore(RestoreViewModel restore, string question)
    {
        return OwnerOf(restore).Ask($"Restore {restore.Name} - LazyVM", question);
    }

    public override string? ChooseExportFile(RecoveryKeysViewModel keys, string suggestedName)
    {
        return OwnerOf(keys).ChooseTextFileToSave($"Export the recovery keys of {keys.Name}", suggestedName);
    }

    public override bool FileExists(string path)
    {
        return System.IO.File.Exists(path);
    }

    public override bool ConfirmReplace(RecoveryKeysViewModel keys, string question)
    {
        return OwnerOf(keys).Ask($"Export the recovery keys of {keys.Name} - LazyVM", question);
    }

    public override string? AskApprovalReason(SecurityFindingsViewModel findings, SecurityFindingRow finding)
    {
        return OwnerOf(findings).AskReason($"Approve a security finding of {findings.Name} - LazyVM", finding.Finding.Id);
    }

    public override bool ConfirmSecurityChange(SecurityFindingsViewModel findings, string title, string question)
    {
        return OwnerOf(findings).Ask(title, question);
    }

    private static IEnumerable<Window> Windows => Application.Current.Windows.OfType<Window>();

    /// <summary>The window that shows <paramref name="viewModel"/>, to own the dialog over it.</summary>
    private static Window OwnerOf(ViewModelBase viewModel)
    {
        return Windows.WindowOf(viewModel) ?? throw new InvalidOperationException($"No window shows {viewModel.GetType().Name}.");
    }
}

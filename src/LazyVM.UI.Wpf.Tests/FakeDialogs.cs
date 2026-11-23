using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>Answers the questions the app asks with the answers a test sets, and records each one, without showing a dialog.</summary>
internal sealed class FakeDialogs : Dialogs
{
    /// <summary>The answer to "Do you really want to delete this VM?": Yes when true.</summary>
    public bool ConfirmsRemoval
    {
        get; set;
    }

    /// <summary>Every delete dialog shown, with what it listed.</summary>
    public List<RemovalViewModel> RemovalsAsked { get; } = [];

    /// <summary>The answer to the restore question: Yes when true.</summary>
    public bool ConfirmsRestore
    {
        get; set;
    }

    /// <summary>Every restore question asked.</summary>
    public List<string> RestoreQuestions { get; } = [];

    /// <summary>The file the Save dialog gives back; empty for Cancel.</summary>
    public string? ChosenExportFile
    {
        get; set;
    }

    /// <summary>The file name each Save dialog suggested.</summary>
    public List<string> ExportFileSuggestions { get; } = [];

    /// <summary>The files there are already.</summary>
    public HashSet<string> ExistingFiles { get; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The answer to "Do you want to replace it?": Yes when true.</summary>
    public bool ConfirmsReplace
    {
        get; set;
    }

    /// <summary>Every replace question asked.</summary>
    public List<string> ReplaceQuestions { get; } = [];

    /// <summary>The reason typed for an approval; null for Cancel.</summary>
    public string? ApprovalReason { get; set; } = string.Empty;

    /// <summary>The finding each reason box was shown for.</summary>
    public List<SecurityFindingRow> ReasonsAsked { get; } = [];

    /// <summary>The answer to the approve or revoke question: Yes when true.</summary>
    public bool ConfirmsSecurityChange
    {
        get; set;
    }

    /// <summary>Every approve or revoke question asked.</summary>
    public List<string> SecurityQuestions { get; } = [];

    public override bool ConfirmRemoval(RemovalViewModel removal)
    {
        RemovalsAsked.Add(removal);
        return ConfirmsRemoval;
    }

    public override bool ConfirmRestore(RestoreViewModel restore, string question)
    {
        RestoreQuestions.Add(question);
        return ConfirmsRestore;
    }

    public override string? ChooseExportFile(RecoveryKeysViewModel keys, string suggestedName)
    {
        ExportFileSuggestions.Add(suggestedName);
        return ChosenExportFile;
    }

    public override bool FileExists(string path)
    {
        return ExistingFiles.Contains(path);
    }

    public override bool ConfirmReplace(RecoveryKeysViewModel keys, string question)
    {
        ReplaceQuestions.Add(question);
        return ConfirmsReplace;
    }

    public override string? AskApprovalReason(SecurityFindingsViewModel findings, SecurityFindingRow finding)
    {
        ReasonsAsked.Add(finding);
        return ApprovalReason;
    }

    public override bool ConfirmSecurityChange(SecurityFindingsViewModel findings, string title, string question)
    {
        SecurityQuestions.Add(question);
        return ConfirmsSecurityChange;
    }
}

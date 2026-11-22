using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>Records the windows shown, brought to the front and closed, without making windows.</summary>
internal sealed class FakeToolWindows(PowerShellCommandRunner runner, BuildLauncher? launcher = null, FakeSecretClipboard? clipboard = null)
    : ToolWindows(runner, launcher ?? new FakeBuildLauncher(), new FixedClock(DateTimeOffset.UnixEpoch),
        clipboard ?? new FakeSecretClipboard(new ManualClock(DateTimeOffset.UnixEpoch)))
{
    private readonly Dictionary<ViewModelBase, Action> _Closers = [];

    public List<ViewModelBase> Shown { get; } = [];

    public List<ViewModelBase> BroughtToFront { get; } = [];

    public List<ViewModelBase> Closed { get; } = [];

    /// <summary>The answer to "Do you really want to delete this VM?": Yes when true.</summary>
    public bool ConfirmsRemoval
    {
        get; set;
    }

    /// <summary>Every delete dialog shown, with what it listed.</summary>
    public List<RemovalViewModel> RemovalsAsked { get; } = [];

    public override bool ConfirmRemoval(RemovalViewModel removal)
    {
        RemovalsAsked.Add(removal);
        return ConfirmsRemoval;
    }

    /// <summary>The answer to the restore question: Yes when true.</summary>
    public bool ConfirmsRestore
    {
        get; set;
    }

    /// <summary>Every restore question asked.</summary>
    public List<string> RestoreQuestions { get; } = [];

    public override bool ConfirmRestore(RestoreViewModel restore, string question)
    {
        RestoreQuestions.Add(question);
        return ConfirmsRestore;
    }

    /// <summary>The file the Save dialog gives back; empty for Cancel.</summary>
    public string? ChosenExportFile
    {
        get; set;
    }

    /// <summary>The file name each Save dialog suggested.</summary>
    public List<string> ExportFileSuggestions { get; } = [];

    public override string? ChooseExportFile(RecoveryKeysViewModel keys, string suggestedName)
    {
        ExportFileSuggestions.Add(suggestedName);
        return ChosenExportFile;
    }

    /// <summary>The files there are already.</summary>
    public HashSet<string> ExistingFiles { get; } = new(StringComparer.OrdinalIgnoreCase);

    public override bool FileExists(string path)
    {
        return ExistingFiles.Contains(path);
    }

    /// <summary>The answer to "Do you want to replace it?": Yes when true.</summary>
    public bool ConfirmsReplace
    {
        get; set;
    }

    /// <summary>Every replace question asked.</summary>
    public List<string> ReplaceQuestions { get; } = [];

    public override bool ConfirmReplace(RecoveryKeysViewModel keys, string question)
    {
        ReplaceQuestions.Add(question);
        return ConfirmsReplace;
    }

    /// <summary>The reason typed for an approval; null for Cancel.</summary>
    public string? ApprovalReason { get; set; } = string.Empty;

    /// <summary>The finding each reason box was shown for.</summary>
    public List<SecurityFindingRow> ReasonsAsked { get; } = [];

    public override string? AskApprovalReason(SecurityFindingsViewModel findings, SecurityFindingRow finding)
    {
        ReasonsAsked.Add(finding);
        return ApprovalReason;
    }

    /// <summary>The answer to the approve or revoke question: Yes when true.</summary>
    public bool ConfirmsSecurityChange
    {
        get; set;
    }

    /// <summary>Every approve or revoke question asked.</summary>
    public List<string> SecurityQuestions { get; } = [];

    public override bool ConfirmSecurityChange(SecurityFindingsViewModel findings, string title, string question)
    {
        SecurityQuestions.Add(question);
        return ConfirmsSecurityChange;
    }

    public void Close(ViewModelBase window)
    {
        _Closers[window]();
    }

    protected override void CloseWindow(ViewModelBase viewModel)
    {
        Closed.Add(viewModel);
        _Closers[viewModel]();
    }

    protected override void Show(ViewModelBase viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(ViewModelBase viewModel)
    {
        BroughtToFront.Add(viewModel);
    }
}

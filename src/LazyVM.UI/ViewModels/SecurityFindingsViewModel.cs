namespace LazyVM.UI.ViewModels;

/// <summary>
/// A VM's Security findings window: what its last nightly security scan
/// found, the open findings first by severity and the resolved ones last,
/// and the findings approved, each with when and why. It tells "not scanned
/// yet" from "no open findings" by the dashboard's <c>LastSecurityScan</c>,
/// since the module returns nothing in both cases. A finding's text comes
/// from inside the VM, so the window shows it as plain text only. An open
/// finding can be approved, and an approval revoked, each after asking;
/// both lists, and the main list, are read again afterwards.
/// </summary>
public sealed class SecurityFindingsViewModel : ViewModelBase
{
    private const string _APPROVE_HELP = "Approving accepts a finding you expect, such as a service you installed yourself, with your reason. "
        + "The nightly scan stops reporting it until it changes. An approved event, such as a Defender detection, covers that one occurrence only. "
        + "Approve only what you recognize.";
    private const string _REVOKE_HELP = "Revoking undoes an approval. The next nightly scan reports the finding again, as new, if it still finds it.";

    private readonly LazyVMSecurityFindingsRunner _Runner;
    private readonly Dialogs _Dialogs;
    private readonly ListChanges _Changes;
    private LazyVMDashboard _Entry;
    private IReadOnlyList<SecurityFindingRow> _Findings = [];
    private IReadOnlyList<SecurityApprovalRow> _Approvals = [];
    private SecurityFindingRow? _SelectedFinding;
    private SecurityApprovalRow? _SelectedApproval;
    private bool _FindingsRead;
    private bool _ApprovalsRead;
    private bool _IsChanging;
    private string _Status = string.Empty;

    public SecurityFindingsViewModel(LazyVMDashboard entry, LazyVMSecurityFindingsRunner runner, Dialogs dialogs, ListChanges changes)
    {
        _Entry = entry;
        _Runner = runner;
        _Dialogs = dialogs;
        _Changes = changes;
        ReloadCommand = new RelayCommand(() => _ = ReloadAsync());
        ApproveCommand = new RelayCommand(() => _ = ApproveAsync(), () => CanApprove);
        RevokeCommand = new RelayCommand(() => _ = RevokeAsync(), () => CanRevoke);
    }

    /// <summary>Reads the findings and the approvals again (F5).</summary>
    public RelayCommand ReloadCommand
    {
        get;
    }

    /// <summary>Asks for a reason, then asks, and on Yes approves <see cref="SelectedFinding"/>.</summary>
    public RelayCommand ApproveCommand
    {
        get;
    }

    /// <summary>Asks, and on Yes revokes <see cref="SelectedApproval"/>.</summary>
    public RelayCommand RevokeCommand
    {
        get;
    }

    /// <summary>The finding chosen in the list, to approve.</summary>
    public SecurityFindingRow? SelectedFinding
    {
        get => _SelectedFinding;
        set
        {
            if (SetProperty(ref _SelectedFinding, value))
            {
                RaiseActionsChanged();
            }
        }
    }

    /// <summary>The approval chosen in the list, to revoke.</summary>
    public SecurityApprovalRow? SelectedApproval
    {
        get => _SelectedApproval;
        set
        {
            if (SetProperty(ref _SelectedApproval, value))
            {
                RaiseActionsChanged();
            }
        }
    }

    /// <summary>True from the first question until an approval or revoke, and reading the lists again, has ended.</summary>
    public bool IsChanging
    {
        get => _IsChanging;
        private set
        {
            if (SetProperty(ref _IsChanging, value))
            {
                RaiseActionsChanged();
            }
        }
    }

    /// <summary>
    /// Why Approve is disabled for the chosen finding, as text of its own: a
    /// disabled button cannot take focus, so Narrator would never read a
    /// reason given only on it.
    /// </summary>
    public string ApproveNote => SelectedFinding is { IsResolved: true }
        ? "A resolved finding cannot be approved: the last scan no longer found it, so there is nothing to approve."
        : string.Empty;

    public bool HasApproveNote => ApproveNote.Length > 0;

    /// <summary>What approving a finding does. The window shows it and gives it to Approve as its help text, so Narrator reads the same.</summary>
    public string ApproveHelp => _APPROVE_HELP;

    /// <summary>What revoking an approval does. The window shows it and gives it to Revoke as its help text, so Narrator reads the same.</summary>
    public string RevokeHelp => _REVOKE_HELP;

    private bool CanApprove => !IsChanging && SelectedFinding is { IsResolved: false };

    private bool CanRevoke => !IsChanging && SelectedApproval is not null;

    public string Name => _Entry.Name;

    public string Title => $"Security findings of {_Entry.Name} - LazyVM";

    /// <summary>When the last scan ran, or that none has run yet.</summary>
    public string ScanText => _Entry.LastSecurityScan switch
    {
        { } scanned => $"Last scanned {DashboardText.When(scanned)}.",
        null when Findings.Count > 0 => "When the last scan ran is not known.",
        null => $"{Name} has not been scanned yet. The nightly maintenance scans it, as its last step, and lists what it finds here.",
    };

    /// <summary>The findings: open ones first, by severity, then the resolved ones.</summary>
    public IReadOnlyList<SecurityFindingRow> Findings
    {
        get => _Findings;
        private set
        {
            if (SetProperty(ref _Findings, value))
            {
                OnPropertyChanged(nameof(Summary));
                OnPropertyChanged(nameof(ScanText));
            }
        }
    }

    /// <summary>Such as "2 open findings, and 1 resolved since the scan before."; empty before the first scan, and when they could not be read.</summary>
    public string Summary
    {
        get
        {
            if (!_FindingsRead || (_Entry.LastSecurityScan is null && Findings.Count == 0))
            {
                return string.Empty;
            }
            var resolved = Findings.Count(row => row.IsResolved);
            var open = (Findings.Count - resolved) switch
            {
                0 => "No open findings",
                1 => "1 open finding",
                var count => $"{count} open findings",
            };
            return resolved == 0 ? open + "." : $"{open}, and {resolved} resolved since the scan before.";
        }
    }

    /// <summary>The approved findings, as the module lists them.</summary>
    public IReadOnlyList<SecurityApprovalRow> Approvals
    {
        get => _Approvals;
        private set
        {
            if (SetProperty(ref _Approvals, value))
            {
                OnPropertyChanged(nameof(ApprovalsSummary));
            }
        }
    }

    /// <summary>How many findings are approved; empty when they could not be read.</summary>
    public string ApprovalsSummary => !_ApprovalsRead
        ? string.Empty
        : Approvals.Count switch
        {
            0 => "No findings are approved.",
            1 => "1 approved finding. An approved finding is left out of the findings above.",
            var count => $"{count} approved findings. An approved finding is left out of the findings above.",
        };

    /// <summary>What went wrong reading the findings or the approvals; empty when nothing did.</summary>
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

    /// <summary>Reads the findings and the approvals. One that cannot be read says why, and does not keep the other from showing.</summary>
    public async Task LoadAsync()
    {
        Status = string.Join(" ", await ReadAsync());
    }

    /// <summary>
    /// Reads both lists, keeps the chosen finding and approval by their Id
    /// while they are still listed, and gives what could not be read.
    /// </summary>
    private async Task<IReadOnlyList<string>> ReadAsync()
    {
        // Taken first: a list given new items lets go of its selection.
        var findingId = SelectedFinding?.Finding.Id;
        var approvalId = SelectedApproval?.Approval.Id;
        var problems = new List<string>();
        try
        {
            var found = await WorkAsync("Reading the security findings", () => _Runner.GetLazyVMSecurityFindingsAsync(_Entry.Id, Name, CancellationToken.None));
            _FindingsRead = true;
            Findings = found
                .Select(finding => new SecurityFindingRow(finding))
                .OrderBy(row => row.IsResolved)
                .ThenBy(row => row.SeverityRank)
                .ToList();
        }
        catch (Exception exception)
        {
            _FindingsRead = false;
            Findings = [];
            problems.Add("The security findings could not be read: " + exception.Message);
        }
        try
        {
            var approved = await WorkAsync("Reading the approved findings", () => _Runner.GetLazyVMSecurityApprovalsAsync(_Entry.Id, Name, CancellationToken.None));
            _ApprovalsRead = true;
            Approvals = approved.Select(approval => new SecurityApprovalRow(approval)).ToList();
        }
        catch (Exception exception)
        {
            _ApprovalsRead = false;
            Approvals = [];
            problems.Add("The approved findings could not be read: " + exception.Message);
        }
        SelectedFinding = Findings.FirstOrDefault(row => string.Equals(row.Finding.Id, findingId, StringComparison.Ordinal));
        SelectedApproval = Approvals.FirstOrDefault(row => string.Equals(row.Approval.Id, approvalId, StringComparison.Ordinal));
        OnPropertyChanged(nameof(Summary));
        OnPropertyChanged(nameof(ApprovalsSummary));
        return problems;
    }

    /// <summary>
    /// Asks for the optional reason, then asks, naming the finding's Id and
    /// severity, what approving does; on Yes runs
    /// Approve-LazyVMSecurityFinding. Both lists are read again afterwards,
    /// however it ended.
    /// </summary>
    public async Task ApproveAsync()
    {
        if (!CanApprove || SelectedFinding is not { } chosen)
        {
            return;
        }
        var id = chosen.Finding.Id;
        await ChangeAsync(
            () => _Dialogs.AskApprovalReason(this, chosen) is { } reason
                && _Dialogs.ConfirmSecurityChange(this, $"Approve a security finding of {Name} - LazyVM", ApproveQuestion(chosen))
                ? () => ApproveFindingAsync(id, reason.Trim())
                : null,
            $"Approving {id}",
            $"{id} is approved. The nightly scan stops reporting it until it changes.",
            $"{id} was not approved");
    }

    /// <summary>
    /// Asks, naming the approval's Id and severity, what revoking does; on
    /// Yes runs Revoke-LazyVMSecurityFinding. Both lists are read again
    /// afterwards, however it ended.
    /// </summary>
    public async Task RevokeAsync()
    {
        if (!CanRevoke || SelectedApproval is not { } chosen)
        {
            return;
        }
        var id = chosen.Approval.Id;
        await ChangeAsync(
            () => _Dialogs.ConfirmSecurityChange(this, $"Revoke an approval of {Name} - LazyVM", RevokeQuestion(chosen.Approval))
                ? () => RevokeApprovalAsync(id)
                : null,
            $"Revoking the approval of {id}",
            $"The approval of {id} is revoked. The next nightly scan reports it again, as new, if it still finds it.",
            $"The approval of {id} was not revoked");
    }

    /// <summary>
    /// Asks with <paramref name="ask"/>, which gives the change to make, or
    /// null when it was not wanted; makes it, reads both lists again, and
    /// says how it ended, then what could not be read.
    /// </summary>
    private async Task ChangeAsync(Func<Func<Task>?> ask, string doing, string done, string notDone)
    {
        IsChanging = true;
        try
        {
            if (ask() is not { } change)
            {
                Status = notDone + ".";
                return;
            }
            Status = doing;
            string outcome;
            try
            {
                await WorkAsync(doing, change);
                outcome = done;
            }
            catch (Exception exception)
            {
                outcome = $"{notDone}: {exception.Message}";
            }
            var problems = await ReadAsync();
            Status = string.Join(" ", new[] { outcome }.Concat(problems));
        }
        finally
        {
            IsChanging = false;
        }
    }

    private string ApproveQuestion(SecurityFindingRow finding)
    {
        return $"Do you really want to approve the finding {finding.Finding.Id} ({finding.SeverityWords}) of {Name}? "
            + $"Its title, made from names chosen inside the VM, is: {finding.Finding.Title}. "
            + "The nightly scan stops reporting it until it changes. "
            + "An approved event, such as a Defender detection, covers only that one occurrence: another one is reported again.";
    }

    private string RevokeQuestion(VMSecurityApproval approval)
    {
        return $"Do you really want to revoke the approval of the finding {approval.Id} ({SecurityFindingRow.InWords(approval.Severity)}) of {Name}? "
            + $"Its title, made from names chosen inside the VM, is: {approval.Title}. "
            + "The next nightly scan reports it again, as new, if it still finds it.";
    }

    private void RaiseActionsChanged()
    {
        OnPropertyChanged(nameof(ApproveNote));
        OnPropertyChanged(nameof(HasApproveNote));
        ApproveCommand.RaiseCanExecuteChanged();
        RevokeCommand.RaiseCanExecuteChanged();
    }

    /// <summary>Approves the finding, then tells the list, even when the approval was refused.</summary>
    private async Task ApproveFindingAsync(string id, string reason)
    {
        try
        {
            await _Runner.ApproveLazyVMSecurityFindingAsync(_Entry.Id, Name, id, reason);
        }
        finally
        {
            _Changes.Raise();
        }
    }

    /// <summary>Revokes the approval, then tells the list, even when the revoke was refused.</summary>
    private async Task RevokeApprovalAsync(string id)
    {
        try
        {
            await _Runner.RevokeLazyVMSecurityFindingAsync(_Entry.Id, Name, id);
        }
        finally
        {
            _Changes.Raise();
        }
    }

    /// <summary>Reads both again.</summary>
    public Task ReloadAsync()
    {
        return LoadAsync();
    }

    /// <summary>Shows what a newer refresh read for this VM; reads the findings again when a newer scan has run.</summary>
    public Task Update(LazyVMDashboard entry)
    {
        var rescanned = entry.LastSecurityScan != _Entry.LastSecurityScan;
        _Entry = entry;
        OnPropertyChanged(nameof(ScanText));
        OnPropertyChanged(nameof(Summary));
        return rescanned ? LoadAsync() : Task.CompletedTask;
    }
}

using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

public sealed class SecurityFindingsViewModelTests : IDisposable
{
    private static readonly DateTime _Scanned = new(2026, 11, 18, 2, 30, 0);

    private static readonly VMSecurityFinding _Firewall = new(
        "Firewall:Public:Off", "High", "The Public firewall profile is off", "The firewall of the Public profile is turned off.", [],
        "Anything on the network can reach every port the VM listens on.", "Turn the Public firewall profile back on.",
        new DateTime(2026, 11, 12, 2, 31, 0), "New");

    private static readonly VMSecurityFinding _Detection = new(
        "Defender:Detection:Trojan", "Medium", "Defender found Trojan:Win32/Sample", "Defender quarantined a file.",
        [@"C:\Users\devadmin\Downloads\tool.exe", @"C:\Temp\copy.exe"],
        "The file can run again if it is restored.", "Delete the file and scan again.",
        new DateTime(2026, 11, 15, 2, 32, 0), "Still open");

    private static readonly VMSecurityFinding _Smb = new(
        "Smb:V1:On", "Low", "SMB 1 is on", "SMB 1 is turned on.", [], "SMB 1 is old and unsafe.", "Turn SMB 1 off.",
        new DateTime(2026, 11, 1, 2, 30, 0), "Resolved");

    private static readonly VMSecurityFinding _Info = new(
        "Update:Pending", "Info", "An update is waiting for a restart", "One update needs a restart.", [], "It is not in use yet.", "Restart the VM.",
        new DateTime(2026, 11, 17, 2, 30, 0), "Still open");

    private static readonly VMSecurityApproval _Approval = new(
        "Rdp:On", "Medium", "Remote Desktop is on", new DateTime(2026, 11, 10, 9, 15, 0), "I connect to it with Remote Desktop.");

    private readonly CultureScope _Culture = new("en-GB");
    private readonly FakeRunners _Runners = new();
    private readonly FakeToolWindows _Tools;

    public SecurityFindingsViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runners);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static LazyVMDashboard Scanned(DateTime? when = null)
    {
        return Sample.VM() with
        {
            LastSecurityScan = when ?? _Scanned
        };
    }

    [Fact]
    public async Task ApproveHelp_AndRevokeHelp_SayWhatEachDoesToTheNightlyScan()
    {
        var window = await Loaded(Scanned(), [_Firewall], _Approval);

        Assert.Equal(
            "Approving accepts a finding you expect, such as a service you installed yourself, with your reason. "
            + "The nightly scan stops reporting it until it changes. An approved event, such as a Defender detection, covers that one occurrence only. "
            + "Approve only what you recognize.",
            window.ApproveHelp);
        Assert.Equal("Revoking undoes an approval. The next nightly scan reports the finding again, as new, if it still finds it.", window.RevokeHelp);
    }

    [Fact]
    public async Task Load_IsWorkingWhileTheFindingsAndTheApprovalsAreRead()
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings([_Firewall]);
        _Runners.SecurityFindings.ReturnsSecurityApprovals([]);
        var window = new SecurityFindingsViewModel(Sample.VM(), _Runners.SecurityFindings, _Tools.Dialogs, _Tools.Changes);
        var watcher = new WorkWatcher(window);

        await window.LoadAsync();

        Assert.Equal(["Reading the security findings", null, "Reading the approved findings", null], watcher.Seen);
    }

    private async Task<SecurityFindingsViewModel> Loaded(LazyVMDashboard entry, VMSecurityFinding[] findings, params VMSecurityApproval[] approvals)
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings(findings);
        _Runners.SecurityFindings.ReturnsSecurityApprovals(approvals);
        var window = new SecurityFindingsViewModel(entry, _Runners.SecurityFindings, _Tools.Dialogs, _Tools.Changes);
        await window.LoadAsync();
        return window;
    }

    [Fact]
    public async Task Load_ReadsTheFindings_AndTheApprovals_OfThatVM()
    {
        var window = await Loaded(Scanned(), [_Firewall], _Approval);

        Assert.Equal(["DevBox"], _Runners.SecurityFindings.SecurityFindingCalls);
        Assert.Equal(["DevBox"], _Runners.SecurityFindings.SecurityApprovalCalls);
        Assert.Equal("Security findings of DevBox - LazyVM", window.Title);
    }

    [Fact]
    public async Task ScanText_SaysWhenTheLastScanRan()
    {
        var window = await Loaded(Scanned(), [_Firewall]);

        Assert.Equal("Last scanned 18 November 2026 02:30.", window.ScanText);
    }

    [Fact]
    public async Task NotScannedYet_IsToldApart_FromNoOpenFindings()
    {
        var notScanned = await Loaded(Sample.VM() with
        {
            LastSecurityScan = null
        }, []);
        var clean = await Loaded(Scanned(), []);

        Assert.Equal(
            "DevBox has not been scanned yet. The nightly maintenance scans it, as its last step, and lists what it finds here.",
            notScanned.ScanText);
        Assert.Equal(string.Empty, notScanned.Summary);
        Assert.Equal("Last scanned 18 November 2026 02:30.", clean.ScanText);
        Assert.Equal("No open findings.", clean.Summary);
    }

    [Fact]
    public async Task Findings_ListOpenOnes_BySeverity_AndResolvedOnesLast()
    {
        var window = await Loaded(Scanned(), [_Smb, _Info, _Detection, _Firewall]);

        Assert.Equal(["Firewall:Public:Off", "Defender:Detection:Trojan", "Update:Pending", "Smb:V1:On"], window.Findings.Select(row => row.Finding.Id));
        Assert.Equal("3 open findings, and 1 resolved since the scan before.", window.Summary);
    }

    [Theory]
    [InlineData(new[] { "New" }, "1 open finding.")]
    [InlineData(new[] { "New", "Still open" }, "2 open findings.")]
    [InlineData(new[] { "Resolved" }, "No open findings, and 1 resolved since the scan before.")]
    [InlineData(new[] { "New", "Resolved", "Resolved" }, "1 open finding, and 2 resolved since the scan before.")]
    public async Task Summary_CountsOpenAndResolvedFindings(string[] statuses, string said)
    {
        var findings = statuses.Select((status, index) => _Firewall with { Id = $"Finding:{index}", Status = status }).ToArray();

        var window = await Loaded(Scanned(), findings);

        Assert.Equal(said, window.Summary);
    }

    [Fact]
    public async Task EachFinding_ReadsAsSeverityTitleAndStatusFirst_ThenTheRest()
    {
        var window = await Loaded(Scanned(), [_Detection]);
        var row = Assert.Single(window.Findings);

        Assert.Equal("Medium severity, Defender found Trojan:Win32/Sample, still open", row.Heading);
        Assert.Equal(
            "Medium severity, Defender found Trojan:Win32/Sample, still open. First seen 15 November 2026 02:32. "
            + @"What was found: Defender quarantined a file. Where: C:\Users\devadmin\Downloads\tool.exe; C:\Temp\copy.exe. "
            + "Why it matters: The file can run again if it is restored. How to fix it: Delete the file and scan again.",
            row.AutomationName);
    }

    [Fact]
    public async Task EachFinding_ShowsEveryPart_AsTextOfItsOwn()
    {
        var window = await Loaded(Scanned(), [_Detection]);
        var row = Assert.Single(window.Findings);

        Assert.Equal("Medium", row.SeverityText);
        Assert.Equal("Defender found Trojan:Win32/Sample", row.Finding.Title);
        Assert.Equal("Still open", row.StatusText);
        Assert.Equal("First seen 15 November 2026 02:32", row.FirstSeenText);
        Assert.Equal(@"C:\Users\devadmin\Downloads\tool.exe; C:\Temp\copy.exe", row.WhereText);
        Assert.True(row.HasWhere);
    }

    [Fact]
    public async Task AFindingWithNoFiles_HasNoWhere()
    {
        var window = await Loaded(Scanned(), [_Firewall]);
        var row = Assert.Single(window.Findings);

        Assert.False(row.HasWhere);
        Assert.DoesNotContain("Where:", row.AutomationName);
    }

    [Theory]
    [InlineData("High", "High severity")]
    [InlineData("Medium", "Medium severity")]
    [InlineData("Low", "Low severity")]
    [InlineData("Info", "Information only")]
    [InlineData("", "Severity not known")]
    public async Task Severity_IsInWords(string severity, string said)
    {
        var window = await Loaded(Scanned(), [_Firewall with { Severity = severity }]);

        Assert.StartsWith(said + ", ", Assert.Single(window.Findings).Heading);
    }

    [Fact]
    public async Task AResolvedFinding_IsLabeledResolved()
    {
        var window = await Loaded(Scanned(), [_Smb]);
        var row = Assert.Single(window.Findings);

        Assert.True(row.IsResolved);
        Assert.Equal("Low severity, SMB 1 is on, resolved", row.Heading);
    }

    [Fact]
    public async Task AFindingWithNoFirstSeen_SaysItIsNotKnown()
    {
        var window = await Loaded(Scanned(), [_Firewall with { FirstSeen = null }]);

        Assert.Equal("First seen: not known", Assert.Single(window.Findings).FirstSeenText);
    }

    [Fact]
    public async Task Approvals_ListEach_WithWhenAndWhyItWasApproved()
    {
        var window = await Loaded(Scanned(), [], _Approval, _Approval with
        {
            Id = "Other",
            Severity = "Low",
            Title = "Guest account is on",
            Reason = ""
        });

        Assert.Equal(
        [
            "Medium severity, Remote Desktop is on, approved 10 November 2026 09:15. Why: I connect to it with Remote Desktop.",
            "Low severity, Guest account is on, approved 10 November 2026 09:15. No reason was given.",
        ], window.Approvals.Select(row => row.Text));
        Assert.Equal("2 approved findings. An approved finding is left out of the findings above.", window.ApprovalsSummary);
    }

    [Fact]
    public async Task NoApprovals_SaySo()
    {
        var window = await Loaded(Scanned(), [_Firewall]);

        Assert.Empty(window.Approvals);
        Assert.Equal("No findings are approved.", window.ApprovalsSummary);
    }

    [Fact]
    public async Task OneApproval_IsCountedInTheSingular()
    {
        var window = await Loaded(Scanned(), [], _Approval);

        Assert.Equal("1 approved finding. An approved finding is left out of the findings above.", window.ApprovalsSummary);
    }

    [Fact]
    public async Task FindingsThatCannotBeRead_SayWhy_AndStillReadTheApprovals()
    {
        _Runners.SecurityFindings.SecurityFindingsThrow(new InvalidOperationException("Access is denied."));
        _Runners.SecurityFindings.ReturnsSecurityApprovals(_Approval);
        var window = new SecurityFindingsViewModel(Scanned(), _Runners.SecurityFindings, _Tools.Dialogs, _Tools.Changes);

        await window.LoadAsync();

        Assert.Equal("The security findings could not be read: Access is denied.", window.Status);
        Assert.Equal(string.Empty, window.Summary);
        Assert.Single(window.Approvals);
    }

    [Fact]
    public async Task ApprovalsThatCannotBeRead_SayWhy_AndKeepTheFindings()
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings(_Firewall);
        _Runners.SecurityFindings.SecurityApprovalsThrow(new InvalidOperationException("The file is damaged."));
        var window = new SecurityFindingsViewModel(Scanned(), _Runners.SecurityFindings, _Tools.Dialogs, _Tools.Changes);

        await window.LoadAsync();

        Assert.Equal("The approved findings could not be read: The file is damaged.", window.Status);
        Assert.Equal(string.Empty, window.ApprovalsSummary);
        Assert.Single(window.Findings);
    }

    [Fact]
    public async Task ReadAgain_ReadsBothAgain()
    {
        var window = await Loaded(Scanned(), [_Firewall]);
        _Runners.SecurityFindings.ReturnsSecurityFindings(_Firewall, _Detection);
        _Runners.SecurityFindings.ReturnsSecurityApprovals();

        await window.ReloadAsync();

        Assert.Equal(2, window.Findings.Count);
        Assert.Equal(["DevBox", "DevBox"], _Runners.SecurityFindings.SecurityFindingCalls);
    }

    [Fact]
    public async Task Update_WithANewerScan_ReadsTheFindingsAgain()
    {
        var window = await Loaded(Sample.VM() with
        {
            LastSecurityScan = null
        }, []);
        _Runners.SecurityFindings.ReturnsSecurityFindings(_Firewall);
        _Runners.SecurityFindings.ReturnsSecurityApprovals();

        await window.Update(Scanned());

        Assert.Equal("Last scanned 18 November 2026 02:30.", window.ScanText);
        Assert.Single(window.Findings);
        Assert.Equal(2, _Runners.SecurityFindings.SecurityFindingCalls.Count);
    }

    [Fact]
    public async Task Update_WithTheSameScan_DoesNotReadAgain()
    {
        var window = await Loaded(Scanned(), [_Firewall]);

        await window.Update(Scanned());

        Assert.Single(_Runners.SecurityFindings.SecurityFindingCalls);
    }

    [Fact]
    public async Task Text_FromInsideTheVM_IsKeptAsItIs()
    {
        // The title is made from names the VM chose; the window shows it as plain text, never as markup or a link.
        var window = await Loaded(Scanned(), [_Firewall with { Title = "<Bold>Run</Bold> {Binding} https://example.invalid" }]);

        Assert.Equal("<Bold>Run</Bold> {Binding} https://example.invalid", Assert.Single(window.Findings).Finding.Title);
    }

    private async Task<SecurityFindingsViewModel> Chosen(VMSecurityFinding finding)
    {
        var window = await Loaded(Scanned(), [finding], _Approval);
        window.SelectedFinding = window.Findings.Single();
        return window;
    }

    /// <summary>What reading both lists again, after an approval or revoke, returns.</summary>
    private void ReadAgainGives(VMSecurityFinding[] findings, params VMSecurityApproval[] approvals)
    {
        _Runners.SecurityFindings.ReturnsSecurityFindings(findings);
        _Runners.SecurityFindings.ReturnsSecurityApprovals(approvals);
    }

    [Fact]
    public async Task Approve_IsDisabled_UntilAFindingIsChosen()
    {
        var window = await Loaded(Scanned(), [_Firewall]);

        Assert.False(window.ApproveCommand.CanExecute(null));

        window.SelectedFinding = window.Findings.Single();

        Assert.True(window.ApproveCommand.CanExecute(null));
    }

    [Fact]
    public async Task AResolvedFinding_CannotBeApproved_AndANoteSaysWhy()
    {
        var window = await Chosen(_Smb);

        Assert.False(window.ApproveCommand.CanExecute(null));
        Assert.True(window.HasApproveNote);
        Assert.Contains("resolved finding cannot be approved", window.ApproveNote);
    }

    [Fact]
    public async Task AnOpenFinding_HasNoNote()
    {
        var window = await Chosen(_Firewall);

        Assert.False(window.HasApproveNote);
        Assert.Equal(string.Empty, window.ApproveNote);
    }

    [Fact]
    public async Task Approve_AsksForAReason_ThenAsksWithYesAndNo_ThenApprovesWithTheReason()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ApprovalReason = "I turned it off for a test";
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        ReadAgainGives([], _Approval);

        await window.ApproveAsync();

        Assert.Equal(_Firewall.Id, Assert.Single(_Tools.Dialogs.ReasonsAsked).Finding.Id);
        Assert.Single(_Tools.Dialogs.SecurityQuestions);
        Assert.Equal([("DevBox", "Firewall:Public:Off", "I turned it off for a test")], _Runners.SecurityFindings.ApproveCalls);
    }

    [Fact]
    public async Task ApproveQuestion_NamesTheIdAndSeverity_AndSaysWhatApprovingDoes()
    {
        var window = await Chosen(_Detection);
        ReadAgainGives([_Detection]);

        await window.ApproveAsync();

        var question = Assert.Single(_Tools.Dialogs.SecurityQuestions);
        Assert.Contains("Defender:Detection:Trojan", question);
        Assert.Contains("Medium severity", question);
        Assert.Contains("Defender found Trojan:Win32/Sample", question);
        Assert.Contains("DevBox", question);
        Assert.Contains("stops reporting it until it changes", question);
        Assert.Contains("an approved event, such as a Defender detection, covers only that one occurrence", question, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task Approve_AReasonOfOnlySpaces_IsNoReason()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ApprovalReason = "   ";
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        ReadAgainGives([]);

        await window.ApproveAsync();

        Assert.Equal(string.Empty, Assert.Single(_Runners.SecurityFindings.ApproveCalls).Reason);
    }

    [Fact]
    public async Task Approve_CancelledAtTheReason_AsksNothingMore_AndApprovesNothing()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ApprovalReason = null;

        await window.ApproveAsync();

        Assert.Empty(_Tools.Dialogs.SecurityQuestions);
        Assert.Empty(_Runners.SecurityFindings.ApproveCalls);
        Assert.Equal("Firewall:Public:Off was not approved.", window.Status);
    }

    [Fact]
    public async Task Approve_No_ApprovesNothing()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ConfirmsSecurityChange = false;
        var changed = 0;
        _Tools.Changes.Changed += (_, _) => changed++;

        await window.ApproveAsync();

        Assert.Empty(_Runners.SecurityFindings.ApproveCalls);
        Assert.Equal(0, changed);
        Assert.Equal("Firewall:Public:Off was not approved.", window.Status);
    }

    [Fact]
    public async Task Approve_Yes_SaysItIsApproved_AndReadsBothListsAndTheMainListAgain()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        var changed = 0;
        _Tools.Changes.Changed += (_, _) => changed++;
        var approved = new VMSecurityApproval(_Firewall.Id, _Firewall.Severity, _Firewall.Title, _Scanned, string.Empty);
        ReadAgainGives([], _Approval, approved);

        await window.ApproveAsync();

        Assert.Equal(2, _Runners.SecurityFindings.SecurityFindingCalls.Count);
        Assert.Equal(2, _Runners.SecurityFindings.SecurityApprovalCalls.Count);
        Assert.Equal(1, changed);
        Assert.Empty(window.Findings);
        Assert.Equal(2, window.Approvals.Count);
        Assert.Equal("Firewall:Public:Off is approved. The nightly scan stops reporting it until it changes.", window.Status);
    }

    [Fact]
    public async Task Approve_Refused_SaysTheModulesReason_AndStillReadsAgain()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        _Runners.SecurityFindings.ApproveFails = new InvalidOperationException("Firewall:Public:Off is not an open finding of the last scan of DevBox.");
        var changed = 0;
        _Tools.Changes.Changed += (_, _) => changed++;
        ReadAgainGives([_Firewall]);

        await window.ApproveAsync();

        Assert.Equal(1, changed);
        Assert.Equal(2, _Runners.SecurityFindings.SecurityFindingCalls.Count);
        Assert.Equal("Firewall:Public:Off was not approved: Firewall:Public:Off is not an open finding of the last scan of DevBox.", window.Status);
    }

    [Fact]
    public async Task AfterAnAction_AListThatCannotBeRead_IsSaidAfterTheOutcome()
    {
        var window = await Chosen(_Firewall);
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        _Runners.SecurityFindings.SecurityFindingsThrow(new InvalidOperationException("The file is locked."));
        _Runners.SecurityFindings.ReturnsSecurityApprovals(_Approval);

        await window.ApproveAsync();

        Assert.Equal(
            "Firewall:Public:Off is approved. The nightly scan stops reporting it until it changes. The security findings could not be read: The file is locked.",
            window.Status);
    }

    [Fact]
    public async Task WhileApproving_NeitherApproveNorRevokeCanStart()
    {
        var window = await Chosen(_Firewall);
        window.SelectedApproval = window.Approvals.Single();
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        _Runners.SecurityFindings.ApproveGate = new();
        ReadAgainGives([]);

        var approving = window.ApproveAsync();

        Assert.True(window.IsChanging);
        Assert.False(window.ApproveCommand.CanExecute(null));
        Assert.False(window.RevokeCommand.CanExecute(null));
        Assert.Equal("Approving Firewall:Public:Off", window.Status);

        _Runners.SecurityFindings.ApproveGate.SetResult();
        await approving;

        Assert.False(window.IsChanging);
    }

    [Fact]
    public async Task Revoke_IsDisabled_UntilAnApprovalIsChosen()
    {
        var window = await Loaded(Scanned(), [], _Approval);

        Assert.False(window.RevokeCommand.CanExecute(null));

        window.SelectedApproval = window.Approvals.Single();

        Assert.True(window.RevokeCommand.CanExecute(null));
    }

    [Fact]
    public async Task RevokeQuestion_NamesTheIdAndSeverity_AndSaysWhatRevokingDoes()
    {
        var window = await Loaded(Scanned(), [], _Approval);
        window.SelectedApproval = window.Approvals.Single();

        await window.RevokeAsync();

        var question = Assert.Single(_Tools.Dialogs.SecurityQuestions);
        Assert.Contains("Rdp:On", question);
        Assert.Contains("Medium severity", question);
        Assert.Contains("Remote Desktop is on", question);
        Assert.Contains("reports it again", question);
        Assert.Empty(_Runners.SecurityFindings.RevokeCalls);
        Assert.Equal("The approval of Rdp:On was not revoked.", window.Status);
    }

    [Fact]
    public async Task Revoke_Yes_RevokesIt_AndReadsBothListsAndTheMainListAgain()
    {
        var window = await Loaded(Scanned(), [], _Approval);
        window.SelectedApproval = window.Approvals.Single();
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        var changed = 0;
        _Tools.Changes.Changed += (_, _) => changed++;
        ReadAgainGives([]);

        await window.RevokeAsync();

        Assert.Equal([("DevBox", "Rdp:On")], _Runners.SecurityFindings.RevokeCalls);
        Assert.Equal(1, changed);
        Assert.Empty(window.Approvals);
        Assert.Null(window.SelectedApproval);
        Assert.Equal("The approval of Rdp:On is revoked. The next nightly scan reports it again, as new, if it still finds it.", window.Status);
    }

    [Fact]
    public async Task Revoke_Refused_SaysTheModulesReason()
    {
        var window = await Loaded(Scanned(), [], _Approval);
        window.SelectedApproval = window.Approvals.Single();
        _Tools.Dialogs.ConfirmsSecurityChange = true;
        _Runners.SecurityFindings.RevokeFails = new InvalidOperationException("Rdp:On is not approved for DevBox.");
        ReadAgainGives([], _Approval);

        await window.RevokeAsync();

        Assert.Equal("The approval of Rdp:On was not revoked: Rdp:On is not approved for DevBox.", window.Status);
    }

    [Fact]
    public async Task ReadingAgain_KeepsTheChosenFinding_ByItsId_AndForgetsOneThatIsGone()
    {
        var window = await Loaded(Scanned(), [_Firewall, _Detection]);
        window.SelectedFinding = window.Findings.Single(row => row.Finding.Id == _Detection.Id);

        ReadAgainGives([_Firewall, _Detection]);
        await window.ReloadAsync();

        Assert.Equal(_Detection.Id, window.SelectedFinding?.Finding.Id);
        Assert.Contains(window.SelectedFinding, window.Findings);

        ReadAgainGives([_Firewall]);
        await window.ReloadAsync();

        Assert.Null(window.SelectedFinding);
        Assert.False(window.ApproveCommand.CanExecute(null));
    }

    [Fact]
    public async Task ReadingAgain_AFindingNowResolved_DisablesApprove_AndSaysWhy()
    {
        var window = await Chosen(_Firewall);

        ReadAgainGives([_Firewall with { Status = "Resolved" }]);
        await window.ReloadAsync();

        Assert.False(window.ApproveCommand.CanExecute(null));
        Assert.True(window.HasApproveNote);
    }
}

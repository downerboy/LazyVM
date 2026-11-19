using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

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
    private readonly FakeCommandRunner _Runner = new();
    private readonly FakeToolWindows _Tools;

    public SecurityFindingsViewModelTests()
    {
        _Tools = new FakeToolWindows(_Runner);
    }

    public void Dispose()
    {
        _Culture.Dispose();
    }

    private static VMDashboard Scanned(DateTime? when = null)
    {
        return Sample.VM() with { LastSecurityScan = when ?? _Scanned };
    }

    private async Task<SecurityFindingsViewModel> Loaded(VMDashboard entry, VMSecurityFinding[] findings, params VMSecurityApproval[] approvals)
    {
        _Runner.ReturnsSecurityFindings(findings);
        _Runner.ReturnsSecurityApprovals(approvals);
        var window = new SecurityFindingsViewModel(entry, _Tools);
        await window.LoadAsync();
        return window;
    }

    [Fact]
    public async Task Load_ReadsTheFindings_AndTheApprovals_OfThatVM()
    {
        var window = await Loaded(Scanned(), [_Firewall], _Approval);

        Assert.Equal(["DevBox"], _Runner.SecurityFindingCalls);
        Assert.Equal(["DevBox"], _Runner.SecurityApprovalCalls);
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
        var notScanned = await Loaded(Sample.VM() with { LastSecurityScan = null }, []);
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
        var window = await Loaded(Scanned(), [], _Approval, _Approval with { Id = "Other", Severity = "Low", Title = "Guest account is on", Reason = "" });

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
        _Runner.SecurityFindingsThrow(new InvalidOperationException("Access is denied."));
        _Runner.ReturnsSecurityApprovals(_Approval);
        var window = new SecurityFindingsViewModel(Scanned(), _Tools);

        await window.LoadAsync();

        Assert.Equal("The security findings could not be read: Access is denied.", window.Status);
        Assert.Equal(string.Empty, window.Summary);
        Assert.Single(window.Approvals);
    }

    [Fact]
    public async Task ApprovalsThatCannotBeRead_SayWhy_AndKeepTheFindings()
    {
        _Runner.ReturnsSecurityFindings(_Firewall);
        _Runner.SecurityApprovalsThrow(new InvalidOperationException("The file is damaged."));
        var window = new SecurityFindingsViewModel(Scanned(), _Tools);

        await window.LoadAsync();

        Assert.Equal("The approved findings could not be read: The file is damaged.", window.Status);
        Assert.Equal(string.Empty, window.ApprovalsSummary);
        Assert.Single(window.Findings);
    }

    [Fact]
    public async Task ReadAgain_ReadsBothAgain()
    {
        var window = await Loaded(Scanned(), [_Firewall]);
        _Runner.ReturnsSecurityFindings(_Firewall, _Detection);
        _Runner.ReturnsSecurityApprovals();

        await window.ReloadAsync();

        Assert.Equal(2, window.Findings.Count);
        Assert.Equal(["DevBox", "DevBox"], _Runner.SecurityFindingCalls);
    }

    [Fact]
    public async Task Update_WithANewerScan_ReadsTheFindingsAgain()
    {
        var window = await Loaded(Sample.VM() with { LastSecurityScan = null }, []);
        _Runner.ReturnsSecurityFindings(_Firewall);
        _Runner.ReturnsSecurityApprovals();

        await window.Update(Scanned());

        Assert.Equal("Last scanned 18 November 2026 02:30.", window.ScanText);
        Assert.Single(window.Findings);
        Assert.Equal(2, _Runner.SecurityFindingCalls.Count);
    }

    [Fact]
    public async Task Update_WithTheSameScan_DoesNotReadAgain()
    {
        var window = await Loaded(Scanned(), [_Firewall]);

        await window.Update(Scanned());

        Assert.Single(_Runner.SecurityFindingCalls);
    }

    [Fact]
    public async Task Text_FromInsideTheVM_IsKeptAsItIs()
    {
        // The title is made from names the VM chose; the window shows it as plain text, never as markup or a link.
        var window = await Loaded(Scanned(), [_Firewall with { Title = "<Bold>Run</Bold> {Binding} https://example.invalid" }]);

        Assert.Equal("<Bold>Run</Bold> {Binding} https://example.invalid", Assert.Single(window.Findings).Finding.Title);
    }
}

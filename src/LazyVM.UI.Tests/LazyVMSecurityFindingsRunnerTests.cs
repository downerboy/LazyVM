using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the security findings runner reads a VM's findings and approvals.</summary>
public sealed class LazyVMSecurityFindingsRunnerTests
{
    [Fact]
    public void ToSecurityFinding_ReadsEveryField_TheFirstSeenTimeInLocalTime()
    {
        var firstSeen = new DateTimeOffset(2026, 11, 12, 2, 31, 0, TimeSpan.Zero);

        var finding = LazyVMSecurityFindingsRunner.LazyVMSecurityFinding(Entry(
            ("Name", "DevBox"),
            ("Id", "Defender:Detection:Trojan"),
            ("Severity", "Medium"),
            ("Title", "Defender found Trojan:Win32/Sample"),
            ("WhatWeFound", "Defender quarantined a file."),
            ("Where", new[] { @"C:\Temp\a.exe", @"C:\Temp\b.exe" }),
            ("WhyItMatters", "It can run again."),
            ("HowToFix", "Delete it."),
            ("FirstSeen", firstSeen),
            ("Status", "Still open")));

        Assert.Equal("Defender:Detection:Trojan", finding.Id);
        Assert.Equal("Medium", finding.Severity);
        Assert.Equal("Defender found Trojan:Win32/Sample", finding.Title);
        Assert.Equal("Defender quarantined a file.", finding.WhatWeFound);
        Assert.Equal([@"C:\Temp\a.exe", @"C:\Temp\b.exe"], finding.Where);
        Assert.Equal("It can run again.", finding.WhyItMatters);
        Assert.Equal("Delete it.", finding.HowToFix);
        Assert.Equal(firstSeen.LocalDateTime, finding.FirstSeen);
        Assert.Equal("Still open", finding.Status);
    }

    [Fact]
    public void ToSecurityFinding_WithNoFilesOrFirstSeen_LeavesThemEmpty()
    {
        var finding = LazyVMSecurityFindingsRunner.LazyVMSecurityFinding(Entry(("Id", "Firewall:Public:Off"), ("Where", Array.Empty<string>()), ("FirstSeen", null)));

        Assert.Empty(finding.Where);
        Assert.Null(finding.FirstSeen);
        Assert.Equal(string.Empty, finding.Status);
    }

    [Fact]
    public void ToSecurityApproval_ReadsEveryField()
    {
        var approvedOn = new DateTimeOffset(2026, 11, 10, 9, 15, 0, TimeSpan.Zero);

        var approval = LazyVMSecurityFindingsRunner.LazyVMSecurityApproval(Entry(
            ("Name", "DevBox"),
            ("Id", "Rdp:On"),
            ("Severity", "Medium"),
            ("Title", "Remote Desktop is on"),
            ("ApprovedOn", approvedOn),
            ("Reason", "I connect with it.")));

        Assert.Equal(new VMSecurityApproval("Rdp:On", "Medium", "Remote Desktop is on", approvedOn.LocalDateTime, "I connect with it."), approval);
    }
}

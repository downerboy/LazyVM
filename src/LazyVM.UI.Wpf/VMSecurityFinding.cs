namespace LazyVM.UI.Wpf;

/// <summary>
/// One finding of a VM's last nightly security scan, as
/// <c>Get-LazyVMSecurityFinding</c> lists it: its Id, its severity (High,
/// Medium, Low or Info), its title, what was found, the files it is about,
/// why it matters, how to fix it, when it was first seen, and its status
/// compared with the scan before (New, Still open or Resolved). Its text
/// comes from inside the VM, so it is only ever shown as plain text.
/// </summary>
public sealed record VMSecurityFinding(
    string Id,
    string Severity,
    string Title,
    string WhatWeFound,
    IReadOnlyList<string> Where,
    string WhyItMatters,
    string HowToFix,
    DateTime? FirstSeen,
    string Status)
{
    public const string HIGH = "High";
    public const string MEDIUM = "Medium";
    public const string LOW = "Low";
    public const string INFO = "Info";
    public const string RESOLVED = "Resolved";
}

/// <summary>
/// A finding approved with <c>Approve-LazyVMSecurityFinding</c>, as
/// <c>Get-LazyVMSecurityFinding -Approved</c> lists it: its Id, severity and
/// title, when it was approved and why.
/// </summary>
public sealed record VMSecurityApproval(string Id, string Severity, string Title, DateTime? ApprovedOn, string Reason);

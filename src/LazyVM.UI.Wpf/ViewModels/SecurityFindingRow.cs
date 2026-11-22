namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// One finding in the Security findings window. Narrator reads its
/// severity, title and status first, then when it was first seen, what was
/// found, where, why it matters and how to fix it.
/// </summary>
public sealed class SecurityFindingRow(VMSecurityFinding finding)
{
    public VMSecurityFinding Finding { get; } = finding;

    public bool IsResolved => string.Equals(Finding.Status, VMSecurityFinding.RESOLVED, StringComparison.OrdinalIgnoreCase);

    /// <summary>The severity as the badge shows it, such as "High".</summary>
    public string SeverityText => Finding.Severity.Length > 0 ? Finding.Severity : "Not known";

    /// <summary>The severity in words, to start a sentence, such as "High severity" or "Information only".</summary>
    public string SeverityWords => InWords(Finding.Severity);

    /// <summary>A severity in words, for a finding or an approval.</summary>
    internal static string InWords(string severity)
    {
        return severity switch
        {
            VMSecurityFinding.INFO => "Information only",
            "" => "Severity not known",
            var other => other + " severity",
        };
    }

    /// <summary>High first, then Medium, Low, Info, and any other last.</summary>
    internal int SeverityRank => Finding.Severity switch
    {
        VMSecurityFinding.HIGH => 0,
        VMSecurityFinding.MEDIUM => 1,
        VMSecurityFinding.LOW => 2,
        VMSecurityFinding.INFO => 3,
        _ => 4,
    };

    /// <summary>New, Still open or Resolved, as the module says it.</summary>
    public string StatusText => Finding.Status.Length > 0 ? Finding.Status : "Status not known";

    /// <summary>Severity, title and status, such as "High severity, The Public firewall profile is off, new".</summary>
    public string Heading => $"{SeverityWords}, {Finding.Title}, {DashboardText.InSentence(StatusText)}";

    public string FirstSeenText => Finding.FirstSeen is { } seen ? "First seen " + DashboardText.When(seen) : "First seen: not known";

    /// <summary>The files the finding is about, separated by semicolons; empty when it names none.</summary>
    public string WhereText => string.Join("; ", Finding.Where);

    public bool HasWhere => Finding.Where.Count > 0;

    /// <summary>The finding as Narrator reads it: severity, title and status first, then the rest.</summary>
    public string AutomationName => string.Join(
        " ",
        new[]
        {
            $"{Heading}.",
            $"{FirstSeenText}.",
            $"What was found: {Finding.WhatWeFound}",
            HasWhere ? $"Where: {WhereText}." : null,
            $"Why it matters: {Finding.WhyItMatters}",
            $"How to fix it: {Finding.HowToFix}",
        }.OfType<string>());

    /// <summary>A list falls back on this for an item's name.</summary>
    public override string ToString()
    {
        return Heading;
    }
}

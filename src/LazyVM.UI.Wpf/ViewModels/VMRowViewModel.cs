namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One VM's row in the main list: name, state, open findings and last maintenance.</summary>
public sealed class VMRowViewModel(VMDashboard entry) : ViewModelBase
{
    internal VMDashboard Entry { get; private set; } = entry;

    public string Name => Entry.Name;

    public string State => Entry.State;

    /// <summary>True when the last maintenance failed or the VM's settings have a problem.</summary>
    public bool NeedsAttention => AttentionText is not null;

    /// <summary>What needs attention, such as "Needs attention: last maintenance failed"; empty when nothing does.</summary>
    public string? AttentionText
    {
        get
        {
            var reasons = new List<string>();
            if (DashboardText.MaintenanceFailed(Entry))
            {
                reasons.Add("last maintenance failed");
            }
            if (DashboardText.SettingsProblem(Entry))
            {
                reasons.Add("settings problem");
            }
            return reasons.Count == 0 ? null : "Needs attention: " + string.Join(", ", reasons);
        }
    }

    /// <summary>"None", "1 open finding", "3 open findings" or "Not scanned yet".</summary>
    public string OpenFindingsText => Entry.OpenFindings == 0 ? "None" : DashboardText.OpenFindings(Entry.OpenFindings);

    /// <summary>How the last maintenance run ended and on which day, such as "Succeeded, 12 November".</summary>
    public string LastMaintenanceText => DashboardText.LastMaintenance(Entry, DashboardText.Day);

    /// <summary>What could not be read for this VM, such as "Could not read: Disks: access denied"; empty when everything was read.</summary>
    public string? ProblemText => Entry.Problems.Count == 0 ? null : "Could not read: " + string.Join("; ", Entry.Problems);

    /// <summary>The row as one sentence for a screen reader.</summary>
    public string AutomationName
    {
        get
        {
            var parts = new List<string> { Name, State };
            if (AttentionText is { } attention)
            {
                parts.Add(DashboardText.InSentence(attention));
            }
            parts.Add(MaintenanceInSentence());
            parts.Add(DashboardText.InSentence(DashboardText.OpenFindings(Entry.OpenFindings)));
            if (ProblemText is { } problem)
            {
                parts.Add(DashboardText.InSentence(problem));
            }
            return string.Join(", ", parts);
        }
    }

    /// <summary>Shows what a newer refresh read for this VM.</summary>
    public void Update(VMDashboard entry)
    {
        Entry = entry;
        OnPropertyChanged(string.Empty);
    }

    /// <summary>Such as "last maintenance succeeded 12 November".</summary>
    private string MaintenanceInSentence()
    {
        if (Entry.LastMaintenanceResult is not { } result)
        {
            return DashboardText.InSentence(DashboardText.LastMaintenance(Entry, DashboardText.Day)) switch
            {
                "no maintenance task" => "no maintenance task",
                var text => "last maintenance " + text,
            };
        }
        var day = Entry.LastMaintenance is { } ran ? " " + DashboardText.Day(ran) : string.Empty;
        return $"last maintenance {DashboardText.InSentence(result)}{day}";
    }
}

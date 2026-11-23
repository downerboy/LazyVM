namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>One VM's row in the main list: name, state, open findings and last maintenance.</summary>
public sealed class VMRowViewModel(LazyVMDashboard entry) : ViewModelBase
{
    internal LazyVMDashboard Entry { get; private set; } = entry;

    public string Name => Entry.Name;

    /// <summary>The VM's Hyper-V Id; empty for a VM not built yet.</summary>
    public Guid? Id => Entry.Id;

    public string State => Entry.State;

    /// <summary>True while a build of the VM runs.</summary>
    public bool IsBuilding => Entry.IsBuilding;

    /// <summary>True when the last maintenance failed, the VM's settings have a problem, or recovery keys are not exported.</summary>
    public bool NeedsAttention => AttentionText is not null;

    /// <summary>What needs attention, such as "Needs attention: last maintenance failed"; empty when nothing does.</summary>
    public string? AttentionText
    {
        get
        {
            var reasons = new[]
            {
                DashboardText.MaintenanceFailed(Entry) ? "last maintenance failed" : null,
                DashboardText.SettingsProblem(Entry) ? "settings problem" : null,
                Entry.UnexportedRecoveryKeys switch
                {
                    null or <= 0 => null,
                    1 => "1 recovery key not exported",
                    var count => $"{count} recovery keys not exported",
                },
            }.OfType<string>().ToList();
            return reasons.Count == 0 ? null : "Needs attention: " + string.Join(", ", reasons);
        }
    }

    /// <summary>"None", "1 open finding", "3 open findings" or "Not scanned yet".</summary>
    public string OpenFindingsText => Entry.OpenFindings == 0 ? "None" : DashboardText.OpenFindings(Entry.OpenFindings);

    /// <summary>How the last maintenance run ended and on which day, such as "Succeeded, 12 November".</summary>
    public string LastMaintenanceText => DashboardText.LastMaintenance(Entry, DashboardText.Day);

    /// <summary>What could not be read for this VM, such as "Could not read: Disks: access denied"; empty when everything was read.</summary>
    public string? ProblemText => Entry.Problems.Count == 0 ? null : "Could not read: " + string.Join("; ", Entry.Problems);

    /// <summary>The Name cell for a screen reader: the name, and what could not be read.</summary>
    public string NameCellText => ProblemText is { } problem ? $"{Name}, {DashboardText.InSentence(problem)}" : Name;

    /// <summary>The State cell for a screen reader: the state, and what needs attention.</summary>
    public string StateCellText => AttentionText is { } attention ? $"{State}, {DashboardText.InSentence(attention)}" : State;

    /// <summary>The row as one sentence for a screen reader.</summary>
    public string AutomationName
    {
        get
        {
            var parts = new[]
            {
                Name,
                State,
                AttentionText is { } attention ? DashboardText.InSentence(attention) : null,
                MaintenanceInSentence(),
                DashboardText.InSentence(DashboardText.OpenFindings(Entry.OpenFindings)),
                ProblemText is { } problem ? DashboardText.InSentence(problem) : null,
            }.OfType<string>();
            return string.Join(", ", parts);
        }
    }

    /// <summary>Shows what a newer refresh read for this VM.</summary>
    public void Update(LazyVMDashboard entry)
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

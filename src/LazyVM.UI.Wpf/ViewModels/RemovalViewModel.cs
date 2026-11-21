using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>
/// The delete dialog: what deleting a VM deletes, from its removal plan,
/// with the disks holding your own work first, what is kept and why, and
/// the question. The dialog answers it; this only says what to show.
/// </summary>
public sealed class RemovalViewModel(RemovalPlan plan) : ViewModelBase
{
    private const double _BYTES_PER_MB = 1024 * 1024;
    private const long _BYTES_PER_GB = 1024L * 1024 * 1024;

    public string Name => plan.Name;

    public string Title => $"Delete {plan.Name} - LazyVM";

    public string Heading => $"Deleting {plan.Name} cannot be undone. This is what goes, and what is kept:";

    public string Question => "Do you really want to delete this VM?";

    /// <summary>One line each, in the order the dialog lists them.</summary>
    public IReadOnlyList<RemovalLine> Lines { get; } = ReadLines(plan);

    /// <summary>What a plan read after a delete that did not finish still lists, such as "Still there: C:\LazyVM\DevBox."; empty when nothing is.</summary>
    public static string Left(RemovalPlan plan)
    {
        string[] left =
        [
            .. plan.HyperVState is null ? [] : new[] { $"the Hyper-V VM {plan.Name}" },
            .. plan.ScheduledTasks.Select(task => "scheduled task " + task),
            .. plan.Items.Select(item => item.Path),
        ];
        return left.Length == 0 ? string.Empty : $"Still there: {string.Join(", ", left)}.";
    }

    private static List<RemovalLine> ReadLines(RemovalPlan plan)
    {
        return plan.IsEmpty
            ? [new($"Nothing of {plan.Name} is left to delete.")]
            : [
            .. plan.WorkDisks.Select(disk => new RemovalLine(
                $"Warning: {disk.Name} goes too, {Size(disk.Size)}, {disk.Path}. {disk.Advice}", IsWarning: true)),
            .. plan.HyperVState is { } state ? new[] { new RemovalLine(MachineText(plan.Name, state, plan.CheckpointCount)) } : [],
            .. plan.ScheduledTasks.Select(task => new RemovalLine("Scheduled task " + task)),
            .. plan.Items.Select(item => new RemovalLine(
                $"{(item.Kind == RemovalItem.FILE ? "File" : "Folder")} {item.Path}, {Size(item.Size)}")),
            new($"{Size(plan.TotalSize)} in all."),
            .. plan.Kept.Select(kept => new RemovalLine($"Kept: {kept.Path}. {kept.Reason}")),
        ];
    }

    /// <summary>Such as "The Hyper-V VM DevBox, Running, with 2 checkpoints. It is turned off first."</summary>
    private static string MachineText(string name, string state, int checkpoints)
    {
        var withCheckpoints = checkpoints switch
        {
            0 => string.Empty,
            1 => ", with 1 checkpoint",
            _ => $", with {checkpoints} checkpoints",
        };
        var turnedOff = state == "Off" ? string.Empty : " It is turned off first.";
        return $"The Hyper-V VM {name}, {state}{withCheckpoints}.{turnedOff}";
    }

    /// <summary>In GB from 1 GB up, as elsewhere in the app, and in MB below it, so a log is not "0 GB".</summary>
    private static string Size(long bytes)
    {
        return bytes switch
        {
            >= _BYTES_PER_GB => DashboardText.Size(bytes),
            < (long)_BYTES_PER_MB => "less than 1 MB",
            _ => (bytes / _BYTES_PER_MB).ToString("0", CultureInfo.CurrentCulture) + " MB",
        };
    }
}

/// <summary>One line of the delete dialog's list. A warning is about a disk holding your own work.</summary>
public sealed record RemovalLine(string Text, bool IsWarning = false);

using System.Globalization;

namespace LazyVM.UI.ViewModels;

/// <summary>The words the list and the VM window use for the dashboard's values, so both say the same thing.</summary>
internal static class DashboardText
{
    public const string NOT_KNOWN = "Not known";

    private const double _BYTES_PER_GB = 1024d * 1024 * 1024;

    public static string Size(long bytes)
    {
        return (bytes / _BYTES_PER_GB).ToString("0.#", CultureInfo.CurrentCulture) + " GB";
    }

    /// <summary>A day and time without the weekday, 
    /// such as "12 November 2026 02:10".
    /// </summary>
    public static string When(DateTime value)
    {
        return value.ToString("d MMMM yyyy ", CultureInfo.CurrentCulture) + value.ToString("t", CultureInfo.CurrentCulture);
    }

    /// <summary>The run going now, to start a sentence, 
    /// such as "A build" or "Maintenance".
    /// </summary>
    public static string RunName(string? command)
    {
        return command switch
        {
            VMRun.BUILD => "A build",
            "Maintenance" => "Maintenance",
            "Rebuild" => "A rebuild",
            "Remove" => "A delete",
            "Restore" => "A restore of the tooling",
            _ => "A run",
        };
    }

    /// <summary>
    /// A day without the year, such as "12 November".
    /// </summary>
    public static string Day(DateTime value)
    {
        return value.ToString("M", CultureInfo.CurrentCulture);
    }

    /// <summary>
    /// "2 open findings", "1 open finding", 
    /// "No open findings", or "Not scanned yet" 
    /// before the first scan.
    /// </summary>
    public static string OpenFindings(int? count)
    {
        return count switch
        {
            null => "Not scanned yet",
            0 => "No open findings",
            1 => "1 open finding",
            _ => $"{count} open findings",
        };
    }

    public static bool MaintenanceFailed(LazyVMDashboard vm)
    {
        return vm.LastMaintenanceResult?.StartsWith("Failed", StringComparison.Ordinal) == true;
    }

    public static bool SettingsProblem(LazyVMDashboard vm)
    {
        return vm.Settings != LazyVMDashboard.SETTINGS_OK;
    }

    /// <summary>
    /// How the last maintenance run ended and when, such as "Succeeded, 12 November";
    /// <paramref name="when"/> writes the date.
    /// </summary>
    public static string LastMaintenance(LazyVMDashboard lazyVMDashboard, Func<DateTime, string> when)
    {
        return lazyVMDashboard.LastMaintenanceResult is null
            ? lazyVMDashboard.MaintenanceTask == "Registered" ? NOT_KNOWN : "No maintenance task"
            : lazyVMDashboard.LastMaintenance is { } ran ? $"{lazyVMDashboard.LastMaintenanceResult}, {when(ran)}" : lazyVMDashboard.LastMaintenanceResult;
    }

    /// <summary>The first letter in lower case, for a value in the middle of a sentence.</summary>
    public static string InSentence(string text)
    {
        return text.Length == 0 ? text : char.ToLower(text[0], CultureInfo.CurrentCulture) + text[1..];
    }
}

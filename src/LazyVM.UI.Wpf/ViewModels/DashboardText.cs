using System.Globalization;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>The words the list and the VM window use for the dashboard's values, so both say the same thing.</summary>
internal static class DashboardText
{
    public const string NotKnown = "Not known";

    private const double BytesPerGB = 1024d * 1024 * 1024;

    public static string Size(long bytes) =>
        (bytes / BytesPerGB).ToString("0.#", CultureInfo.CurrentCulture) + " GB";

    /// <summary>A day and time without the weekday, such as "12 November 2026 02:10".</summary>
    public static string When(DateTime value) =>
        value.ToString("d MMMM yyyy ", CultureInfo.CurrentCulture) + value.ToString("t", CultureInfo.CurrentCulture);

    /// <summary>A day without the year, such as "12 November".</summary>
    public static string Day(DateTime value) => value.ToString("M", CultureInfo.CurrentCulture);

    /// <summary>"2 open findings", "1 open finding", "No open findings", or "Not scanned yet" before the first scan.</summary>
    public static string OpenFindings(int? count) => count switch
    {
        null => "Not scanned yet",
        0 => "No open findings",
        1 => "1 open finding",
        _ => $"{count} open findings",
    };

    public static bool MaintenanceFailed(VMDashboard vm) =>
        vm.LastMaintenanceResult?.StartsWith("Failed", StringComparison.Ordinal) == true;

    public static bool SettingsProblem(VMDashboard vm) => vm.Settings != VMDashboard.SettingsOK;

    /// <summary>
    /// How the last maintenance run ended and when, such as "Succeeded, 12 November";
    /// <paramref name="when"/> writes the date.
    /// </summary>
    public static string LastMaintenance(VMDashboard vm, Func<DateTime, string> when)
    {
        if (vm.LastMaintenanceResult is null)
        {
            return vm.MaintenanceTask == "Registered" ? NotKnown : "No maintenance task";
        }
        return vm.LastMaintenance is { } ran ? $"{vm.LastMaintenanceResult}, {when(ran)}" : vm.LastMaintenanceResult;
    }

    /// <summary>The first letter in lower case, for a value in the middle of a sentence.</summary>
    public static string InSentence(string text) =>
        text.Length == 0 ? text : char.ToLower(text[0], CultureInfo.CurrentCulture) + text[1..];
}

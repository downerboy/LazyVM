using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

internal static class Sample
{
    public static LazyVMDashboard VM(string name = "DevBox", string state = "Running")
    {
        return new()
        {
            Name = name,
            State = state,
            MaintenanceTask = "Registered",
            LastMaintenance = new DateTime(2026, 11, 12, 2, 10, 0),
            LastMaintenanceResult = "Succeeded",
            OpenFindings = 0,
        };
    }

    public static VMCheck Check(string status = VMCheck.OK, string check = "LazyVM folder", string detail = @"C:\Users\me\LazyVM", string fix = "")
    {
        return new("Host", check, status, detail, fix);
    }

    public static VMLogEntry Log(string level, string message, int minute = 0)
    {
        return new(new DateTime(2026, 11, 12, 2, minute, 5), level, message);
    }
}

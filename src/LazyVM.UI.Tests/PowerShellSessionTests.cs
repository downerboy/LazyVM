using System.Management.Automation;

namespace LazyVM.UI.Tests;

/// <summary>Where a session finds the modules it loads.</summary>
public sealed class PowerShellSessionTests
{
    [Fact]
    public void ModuleSearchPath_HoldsOnlyFoldersAdministratorsControl()
    {
        // The app runs elevated: a module autoloaded from a folder the user can
        // write to, such as Documents\PowerShell\Modules, would run as administrator.
        var folders = PowerShellSession.ModuleSearchPath.Split(System.IO.Path.PathSeparator);

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var windows = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
        Assert.Equal(System.IO.Path.Combine(programFiles, "LazyVM", "Modules"), folders[0]);
        Assert.Contains(System.IO.Path.Combine(windows, "System32", "WindowsPowerShell", "v1.0", "Modules"), folders);
        Assert.All(folders, folder => Assert.True(
            folder.StartsWith(programFiles, StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(windows, StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(System.IO.Path.GetDirectoryName(typeof(PSObject).Assembly.Location)!, StringComparison.OrdinalIgnoreCase),
            $"{folder} is not a folder only administrators can change"));
        Assert.DoesNotContain(folders, folder =>
            folder.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), StringComparison.OrdinalIgnoreCase) ||
            folder.StartsWith(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), StringComparison.OrdinalIgnoreCase));
    }
}

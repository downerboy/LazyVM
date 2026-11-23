namespace LazyVM.UI;

/// <summary>
/// Starts a build in a pwsh process of its own, so it outlives the app. The
/// process runs the script of the module the app has loaded, so the starter
/// first asks where that module is.
/// </summary>
public class BuildStarter(LazyVMBuildRunner builds, BuildLauncher launcher)
{
    /// <summary>
    /// Starts the build and gives it, to follow. Throws with the reason when
    /// it could not start, such as when the module is not loaded or PowerShell
    /// 7.6 is not installed.
    /// </summary>
    public async Task<StartedRun> StartAsync(BuildRequest request, CancellationToken cancellationToken)
    {
        var moduleFolder = await builds.GetModuleFolderAsync(cancellationToken).ConfigureAwait(false);
        return launcher.Start(request, moduleFolder);
    }
}

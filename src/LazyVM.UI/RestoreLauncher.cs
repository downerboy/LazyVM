namespace LazyVM.UI;

/// <summary>
/// Starts each restore in a pwsh process of its own, so closing the app never
/// stops it part way (see <see cref="AppProcessLauncher"/>). The script,
/// Scripts\Start-AppRestore.ps1, runs Restore-LazyVMTooling -Force: the app
/// has already asked.
/// </summary>
public class RestoreLauncher : AppProcessLauncher
{
    internal const string SCRIPT = "Start-AppRestore.ps1";

    /// <summary>Starts returning the VM of <paramref name="request"/> to its restore point with the module in <paramref name="moduleFolder"/>.</summary>
    public virtual StartedRun Start(RestoreRequest request, string moduleFolder)
    {
        return StartProcess(moduleFolder, SCRIPT, ScriptArguments(request));
    }

    /// <summary>The arguments pwsh is started with, one list item each.</summary>
    internal static IReadOnlyList<string> Arguments(RestoreRequest request, string script, string resultPath)
    {
        return Arguments(script, ScriptArguments(request), resultPath);
    }

    private static string[] ScriptArguments(RestoreRequest request)
    {
        return ["-Name", request.Name, "-RestorePoint", request.RestorePoint];
    }
}

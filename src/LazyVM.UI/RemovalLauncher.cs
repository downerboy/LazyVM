namespace LazyVM.UI;

/// <summary>
/// Starts each delete in a pwsh process of its own, so closing the app never
/// stops it part way (see <see cref="AppProcessLauncher"/>). The script,
/// Scripts\Start-AppRemove.ps1, runs Remove-LazyVM -Force: the app has
/// already asked.
/// </summary>
public class RemovalLauncher : AppProcessLauncher
{
    internal const string SCRIPT = "Start-AppRemove.ps1";

    /// <summary>Starts deleting the VM of <paramref name="request"/> with the module in <paramref name="moduleFolder"/>.</summary>
    public virtual StartedRun Start(RemovalRequest request, string moduleFolder)
    {
        return StartProcess(moduleFolder, SCRIPT, ScriptArguments(request));
    }

    /// <summary>The arguments pwsh is started with, one list item each.</summary>
    internal static IReadOnlyList<string> Arguments(RemovalRequest request, string script, string resultPath)
    {
        return Arguments(script, ScriptArguments(request), resultPath);
    }

    private static string[] ScriptArguments(RemovalRequest request)
    {
        return ["-Name", request.Name];
    }
}

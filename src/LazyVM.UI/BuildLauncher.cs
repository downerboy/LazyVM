using System.Globalization;

namespace LazyVM.UI;

/// <summary>
/// Starts each build in a pwsh process of its own, so closing the app never
/// stops it (see <see cref="AppProcessLauncher"/>). View models take this
/// class through their constructor; tests replace <see cref="Start"/>. The
/// script, Scripts\Start-AppBuild.ps1, runs Build-LazyVM.
/// </summary>
public class BuildLauncher : AppProcessLauncher
{
    internal const string SCRIPT = "Start-AppBuild.ps1";

    /// <summary>Starts building <paramref name="request"/> with the module in <paramref name="moduleFolder"/>.</summary>
    public virtual StartedRun Start(BuildRequest request, string moduleFolder)
    {
        return StartProcess(moduleFolder, SCRIPT, ScriptArguments(request));
    }

    /// <summary>The arguments pwsh is started with, one list item each.</summary>
    internal static IReadOnlyList<string> Arguments(BuildRequest request, string script, string resultPath)
    {
        return Arguments(script, ScriptArguments(request), resultPath);
    }

    private static IEnumerable<string> ScriptArguments(BuildRequest request)
    {
        return new[]
        {
            ["-Name", request.Name],
            string.IsNullOrEmpty(request.ConfigTemplate) ? [] : new[] { "-ConfigTemplate", request.ConfigTemplate },
            string.IsNullOrEmpty(request.UserName) ? [] : new[] { "-UserName", request.UserName },
            request.FromPhase is { } phase ? new[] { "-FromPhase", phase.ToString(CultureInfo.InvariantCulture) } : [],
        }.SelectMany(pair => pair);
    }
}

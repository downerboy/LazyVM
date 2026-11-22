using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text.Json;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Starts each build in a pwsh process of its own, so closing the app never
/// stops it. View models take this class through their constructor; tests
/// replace <see cref="Start"/>.
/// </summary>
/// <remarks>
/// pwsh runs the module's own script, Scripts\Start-AppBuild.ps1, with
/// -File and each argument passed as a list item, never as script text. The
/// process inherits the app's elevation and has no window. Its output is not
/// redirected: a pipe the app stops reading, or that breaks when the app
/// closes, could stall or end the build. How it ended comes back through a
/// result file the script writes. The process is never killed: Cancel asks
/// the build to stop with Stop-LazyVMBuild, so its clean-up runs.
/// </remarks>
public class BuildLauncher
{
    /// <summary>The oldest PowerShell the module supports.</summary>
    private static readonly Version _MinimumPowerShell = new(7, 6);

    /// <summary>Microsoft's publisher ID, the end of every Store PowerShell package folder's name.</summary>
    private const string _MICROSOFT_PUBLISHER = "8wekyb3d8bbwe";

    /// <summary>
    /// PowerShell 7.6 or later, from a folder only administrators can change,
    /// never found through PATH: %ProgramFiles%\PowerShell\7 for the MSI
    /// install, or else the newest Store package in %ProgramFiles%\WindowsApps
    /// (Microsoft.PowerShell or Microsoft.PowerShell-LTS, for this
    /// computer's processor). Empty when there is neither.
    /// </summary>
    internal static string? FindPwsh(string programFiles)
    {
        var installed = Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe");
        if (File.Exists(installed))
        {
            return installed;
        }

        var architecture = System.Runtime.InteropServices.RuntimeInformation.OSArchitecture.ToString().ToLowerInvariant();
        IEnumerable<string> folders;
        try
        {
            folders = Directory.EnumerateDirectories(Path.Combine(programFiles, "WindowsApps"), "Microsoft.PowerShell*").ToList();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
        return folders
            .Select(folder => (Folder: folder, Version: StorePackageVersion(Path.GetFileName(folder), architecture)))
            .Where(package => package.Version >= _MinimumPowerShell && File.Exists(Path.Combine(package.Folder, "pwsh.exe")))
            .OrderByDescending(package => package.Version)
            .Select(package => Path.Combine(package.Folder, "pwsh.exe"))
            .FirstOrDefault();
    }

    /// <summary>The version of a Store PowerShell package folder such as Microsoft.PowerShell-LTS_7.6.10.0_x64__8wekyb3d8bbwe; empty for any other folder.</summary>
    private static Version? StorePackageVersion(string folder, string architecture)
    {
        var parts = folder.Split('_');
        return parts.Length != 5
            || parts[0] is not ("Microsoft.PowerShell" or "Microsoft.PowerShell-LTS")
            || !string.Equals(parts[2], architecture, StringComparison.OrdinalIgnoreCase)
            || parts[3].Length != 0
            || parts[4] != _MICROSOFT_PUBLISHER
            ? null
            : Version.TryParse(parts[1], out var version) ? version : null;
    }

    /// <summary>The script, in the folder the module was imported from.</summary>
    internal static string ScriptPath(string moduleFolder)
    {
        return Path.Combine(moduleFolder, "Scripts", "Start-AppBuild.ps1");
    }

    /// <summary>Starts building <paramref name="request"/> with the module in <paramref name="moduleFolder"/>.</summary>
    public virtual StartedBuild Start(BuildRequest request, string moduleFolder)
    {
        var script = ScriptPath(moduleFolder);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var pwsh = FindPwsh(programFiles) ?? throw new InvalidOperationException(
            $"PowerShell 7.6 or later was not found, in {Path.Combine(programFiles, "PowerShell", "7")} or as a Microsoft Store app. Install it, then build again.");
        if (!File.Exists(script))
        {
            throw new InvalidOperationException($"The build script was not found at {script}. Install LazyVM again with Install.ps1.");
        }

        var resultPath = Path.Combine(Path.GetTempPath(), $"LazyVM-build-{Guid.NewGuid():N}.json");
        var start = new ProcessStartInfo(pwsh)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = moduleFolder,
        };
        foreach (var argument in Arguments(request, script, resultPath))
        {
            start.ArgumentList.Add(argument);
        }

        var process = Process.Start(start) ?? throw new InvalidOperationException("PowerShell 7 did not start.");
        return new StartedBuild(process.Id, WaitForEndAsync(process, resultPath));
    }

    /// <summary>The arguments pwsh is started with, one list item each.</summary>
    internal static IReadOnlyList<string> Arguments(BuildRequest request, string script, string resultPath)
    {
        var arguments = new List<string> { "-NoProfile", "-NonInteractive", "-File", script, "-Name", request.Name };
        if (!string.IsNullOrEmpty(request.ConfigTemplate))
        {
            arguments.AddRange(["-ConfigTemplate", request.ConfigTemplate]);
        }
        if (!string.IsNullOrEmpty(request.UserName))
        {
            arguments.AddRange(["-UserName", request.UserName]);
        }
        if (request.FromPhase is { } phase)
        {
            arguments.AddRange(["-FromPhase", phase.ToString(CultureInfo.InvariantCulture)]);
        }
        arguments.AddRange(["-ResultPath", resultPath]);
        return arguments;
    }

    /// <summary>Reads what the script wrote; without it, says the process ended with its exit code.</summary>
    internal static BuildResult ReadResult(string? json, int exitCode)
    {
        if (!string.IsNullOrWhiteSpace(json))
        {
            try
            {
                var result = JsonSerializer.Deserialize<BuildResult>(json);
                if (result is { Outcome.Length: > 0 })
                {
                    return result;
                }
            }
            catch (JsonException)
            {
                // Said below, as for no result at all.
            }
        }
        return new(BuildResult.FAILED, null, $"PowerShell ended with exit code {exitCode} before saying how the build went.");
    }

    private static async Task<BuildResult> WaitForEndAsync(Process process, string resultPath)
    {
        using (process)
        {
            await process.WaitForExitAsync().ConfigureAwait(false);
            string? json = null;
            try
            {
                json = await File.ReadAllTextAsync(resultPath).ConfigureAwait(false);
                File.Delete(resultPath);
            }
            catch (IOException)
            {
                // No result file: the script did not get as far as writing it.
            }
            catch (UnauthorizedAccessException)
            {
                // As above.
            }
            return ReadResult(json, process.ExitCode);
        }
    }
}

using System.Diagnostics;
using System.IO;
using System.Text.Json;

namespace LazyVM.UI;

/// <summary>
/// Starts a build, a delete or a restore in a pwsh process of its own, so
/// closing the app never stops it. Each launcher, such as
/// <see cref="BuildLauncher"/>, names its script and the arguments it takes;
/// tests replace its <c>Start</c>.
/// </summary>
/// <remarks>
/// pwsh runs one of the module's own scripts, from Scripts, with -File and
/// each argument passed as a list item, never as script text. The process
/// inherits the app's elevation and has no window. Its output is not
/// redirected: a pipe the app stops reading, or that breaks when the app
/// closes, could stall or end the run. How it ended comes back through a
/// result file the script writes. The process is never killed: a build is
/// asked to stop with Stop-LazyVMBuild, so its clean-up runs.
/// </remarks>
public abstract class AppProcessLauncher
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

    /// <summary>The script <paramref name="scriptName"/>, in the folder the module was imported from.</summary>
    internal static string ScriptPath(string moduleFolder, string scriptName)
    {
        return Path.Combine(moduleFolder, "Scripts", scriptName);
    }

    /// <summary>The arguments pwsh is started with, one list item each: the script, what it takes, then where it writes its result.</summary>
    internal static IReadOnlyList<string> Arguments(string script, IEnumerable<string> scriptArguments, string resultPath)
    {
        return ["-NoProfile", "-NonInteractive", "-File", script, .. scriptArguments, "-ResultPath", resultPath];
    }

    /// <summary>Reads what the script wrote; without it, says the process ended with its exit code.</summary>
    internal static RunResult ReadResult(string? json, int exitCode)
    {
        if (!string.IsNullOrWhiteSpace(json))
        {
            try
            {
                var result = JsonSerializer.Deserialize<RunResult>(json);
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
        return new(RunResult.FAILED, null, $"PowerShell ended with exit code {exitCode} before saying how it went.");
    }

    /// <summary>
    /// Runs <paramref name="scriptName"/> of the module in <paramref name="moduleFolder"/> with
    /// <paramref name="scriptArguments"/>. Throws with the reason when it could not start, such as when PowerShell 7.6 is not installed.
    /// </summary>
    protected static StartedRun StartProcess(string moduleFolder, string scriptName, IEnumerable<string> scriptArguments)
    {
        var script = ScriptPath(moduleFolder, scriptName);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var pwsh = FindPwsh(programFiles) ?? throw new InvalidOperationException(
            $"PowerShell 7.6 or later was not found, in {Path.Combine(programFiles, "PowerShell", "7")} or as a Microsoft Store app. Install it, then try again.");
        if (!File.Exists(script))
        {
            throw new InvalidOperationException($"The script was not found at {script}. Install LazyVM again with Install.ps1.");
        }

        var resultPath = Path.Combine(Path.GetTempPath(), $"LazyVM-run-{Guid.NewGuid():N}.json");
        var start = new ProcessStartInfo(pwsh)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = moduleFolder,
        };
        foreach (var argument in Arguments(script, scriptArguments, resultPath))
        {
            start.ArgumentList.Add(argument);
        }

        var process = Process.Start(start) ?? throw new InvalidOperationException("PowerShell 7 did not start.");
        return new StartedRun(process.Id, WaitForEndAsync(process, resultPath));
    }

    private static async Task<RunResult> WaitForEndAsync(Process process, string resultPath)
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

using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>
/// What every LazyVM runner shares: the session a command runs in, and
/// the rules for when what a command wrote is its failure. Each runner,
/// such as <see cref="LazyVMLogRunner"/>, runs the module's commands of
/// one area and reads what they return into plain values. View models take
/// runners through their constructor; tests replace their virtual members.
/// </summary>
public abstract class PowerShellCommandRunner
{
    /// <summary>Runs commands in the sessions <paramref name="sessions"/> gives, which the app makes once and disposes when it exits.</summary>
    protected PowerShellCommandRunner(PowerShellSessionFactory sessions)
    {
        ArgumentNullException.ThrowIfNull(sessions);
        Sessions = sessions;
    }

    /// <summary>The sessions commands run in: the host's, and one per VM.</summary>
    protected PowerShellSessionFactory Sessions
    {
        get;
    }

    /// <summary>
    /// The session for a command about the VM with the Hyper-V Id
    /// <paramref name="vmId"/>. A VM with no Id, one not built yet or a new
    /// one until its build creates it, uses the host's.
    /// </summary>
    protected PowerShellSession SessionFor(Guid? vmId)
    {
        return vmId is { } id ? Sessions.ForVM(id) : Sessions.ForHost();
    }

    /// <summary>The folder the module was imported from, which holds the scripts a run in a process of its own starts with. Throws when the module is not loaded.</summary>
    protected async Task<string> ModuleFolderAsync(CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(Sessions.ForHost(), "Get-Module", [("Name", "LazyVM")], cancellationToken).ConfigureAwait(false);
        return output.Select(module => module.PropertyText("ModuleBase")).FirstOrDefault(folder => folder.Length > 0)
            ?? throw new InvalidOperationException("The LazyVM module is not loaded.");
    }

    /// <summary>
    /// Starts a run in a pwsh process of its own, with the module's folder,
    /// and waits for it to end. Never cancelled: a delete or restore stopped
    /// half way leaves more behind. Throws with the script's reason when the
    /// process could not start or did not complete.
    /// </summary>
    protected async Task RunInOwnProcessAsync(Func<string, StartedRun> start)
    {
        var started = start(await ModuleFolderAsync(CancellationToken.None).ConfigureAwait(false));
        var result = await started.Ended.ConfigureAwait(false);
        if (result.Outcome != RunResult.COMPLETED)
        {
            throw new InvalidOperationException(result.Message is { Length: > 0 } message ? message : $"The run ended with the outcome {result.Outcome}.");
        }
    }

    /// <summary>
    /// Runs <paramref name="command"/> in <paramref name="session"/> with each
    /// parameter added by name, never as script text.
    /// <paramref name="failsOnlyByThrowing"/>: a command that can rightly
    /// return nothing while it silences errors of its own, so only an error
    /// it throws is its failure. <paramref name="failsByItsOwnErrors"/>: a
    /// command that returns nothing and reports a refused item as a
    /// non-terminating error of its own, so that error is its failure too
    /// (<see cref="ThrowIfCommandWroteError"/>).
    /// </summary>
    protected async Task<IReadOnlyList<PSObject>> InvokeAsync(
        PowerShellSession session, string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken,
        bool failsOnlyByThrowing = false, bool failsByItsOwnErrors = false)
    {
        var (output, _) = await InvokeWithWarningsAsync(session, command, parameters, cancellationToken, failsOnlyByThrowing, failsByItsOwnErrors)
            .ConfigureAwait(false);
        return output;
    }

    /// <summary>As <see cref="InvokeAsync"/>, and also gives the warnings the command wrote, each as its text.</summary>
    protected async Task<(IReadOnlyList<PSObject> Output, IReadOnlyList<string> Warnings)> InvokeWithWarningsAsync(
        PowerShellSession session, string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken,
        bool failsOnlyByThrowing = false, bool failsByItsOwnErrors = false)
    {
        ArgumentNullException.ThrowIfNull(session);
        var result = await session.InvokeAsync(command, parameters, cancellationToken).ConfigureAwait(false);
        ThrowIfFailed(result.Output, result.Errors, failsOnlyByThrowing);
        if (failsByItsOwnErrors)
        {
            ThrowIfCommandWroteError(command, result.Errors);
        }
        return (result.Output, result.Warnings);
    }

    /// <summary>
    /// The parameters that have a value, such as a switch only when it is
    /// on: <c>("Force", force ? true : null)</c>.
    /// </summary>
    protected static IReadOnlyList<(string Name, object Value)> Present(params (string Name, object? Value)[] parameters)
    {
        return parameters.Where(parameter => parameter.Value is not null).Select(parameter => (parameter.Name, parameter.Value!)).ToList();
    }

    /// <summary>
    /// A terminating error already threw. Non-terminating errors count only
    /// when the command returned nothing: the error stream also holds errors a
    /// command silenced with -ErrorAction SilentlyContinue, and the module
    /// reports each VM's own failures in its Problems. A command that
    /// <paramref name="failsOnlyByThrowing"/> never fails here.
    /// </summary>
    internal static void ThrowIfFailed(IReadOnlyCollection<PSObject> output, IReadOnlyList<ErrorRecord> errors, bool failsOnlyByThrowing = false)
    {
        if (!failsOnlyByThrowing && output.Count == 0 && errors.Count > 0)
        {
            throw new InvalidOperationException(errors[0].ToString());
        }
    }

    /// <summary>
    /// The first error <paramref name="command"/> itself wrote, such as a
    /// refused Id, thrown with the module's reason. Errors of the calls it
    /// silenced inside the module reach the error stream too, and do not count.
    /// </summary>
    internal static void ThrowIfCommandWroteError(string command, IEnumerable<ErrorRecord> errors)
    {
        var own = errors.FirstOrDefault(error => string.Equals(error.InvocationInfo?.MyCommand?.Name, command, StringComparison.OrdinalIgnoreCase));
        if (own is not null)
        {
            throw new InvalidOperationException(own.ToString());
        }
    }
}

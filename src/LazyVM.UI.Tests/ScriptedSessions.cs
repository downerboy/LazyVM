using System.Management.Automation;

namespace LazyVM.UI.Tests;

/// <summary>
/// Sessions that answer each command with <see cref="Answer"/> instead of
/// running it, and keep the session, command and parameters of each call,
/// so a test sees what a runner would run, and where, without the module.
/// </summary>
internal sealed class ScriptedSessions : PowerShellSessionFactory
{
    public PowerShellResult Answer { get; set; } = new([], [], []);

    /// <summary>When set, each command throws this, as one that throws a terminating error.</summary>
    public Exception? Fails
    {
        get; set;
    }

    public List<(PowerShellSession Session, string Command, IReadOnlyDictionary<string, object> Parameters)> Calls { get; } = [];

    /// <summary>The one call made, or the test fails.</summary>
    public (PowerShellSession Session, string Command, IReadOnlyDictionary<string, object> Parameters) Call => Assert.Single(Calls);

    public static PowerShellResult Output(params object[] items)
    {
        return new([.. items.Select(PSObject.AsPSObject)], [], []);
    }

    protected override PowerShellSession CreateSession()
    {
        return new ScriptedSession(this);
    }

    private sealed class ScriptedSession(ScriptedSessions sessions) : PowerShellSession
    {
        public override Task<PowerShellResult> InvokeAsync(
            string command, IReadOnlyList<(string Name, object Value)> parameters, CancellationToken cancellationToken)
        {
            sessions.Calls.Add((this, command, parameters.ToDictionary(parameter => parameter.Name, parameter => parameter.Value)));
            return sessions.Fails is { } failure ? Task.FromException<PowerShellResult>(failure) : Task.FromResult(sessions.Answer);
        }
    }
}

using System.Management.Automation;

namespace LazyVM.UI.Tests;

/// <summary>What every runner shares: the session a command runs in, and when what it wrote is a failure.</summary>
public sealed class PowerShellCommandRunnerTests
{
    private static readonly Guid _DEV_BOX = Guid.Parse("4f2c9a1e-7b3d-4c8e-9a10-2d5e6f7a8b9c");

    private readonly ScriptedSessions _Sessions = new();

    [Fact]
    public void SessionFor_AVMsId_IsThatVMsSession()
    {
        var runner = new ProbeRunner(_Sessions);

        Assert.Same(_Sessions.ForVM(_DEV_BOX), runner.SessionOf(_DEV_BOX));
    }

    [Fact]
    public void SessionFor_NoId_IsTheHostSession()
    {
        // A VM not built yet has no Hyper-V Id, and neither does a new VM
        // until its build creates it: its commands run with the host's.
        var runner = new ProbeRunner(_Sessions);

        Assert.Same(_Sessions.ForHost(), runner.SessionOf(null));
    }

    [Fact]
    public async Task InvokeAsync_NothingReturnedAndAnError_ThrowsTheError()
    {
        _Sessions.Answer = new([], [Error("The LazyVM folder was not found.")], []);
        var runner = new ProbeRunner(_Sessions);

        var failure = await Assert.ThrowsAsync<InvalidOperationException>(() => runner.InvokeAsync("Get-LazyVMDashboard"));

        Assert.Equal("The LazyVM folder was not found.", failure.Message);
    }

    [Fact]
    public async Task InvokeWithWarningsAsync_GivesTheOutputAndTheWarnings()
    {
        _Sessions.Answer = new([PSObject.AsPSObject("written")], [], ["The file is not encrypted."]);
        var runner = new ProbeRunner(_Sessions);

        var (output, warnings) = await runner.InvokeWithWarningsAsync("Export-LazyVMRecoveryKey");

        Assert.Equal("written", Assert.Single(output).BaseObject);
        Assert.Equal(["The file is not encrypted."], warnings);
    }

    [Fact]
    public void ThrowIfFailed_IgnoresErrorsTheCommandSilenced_WhenItReturnedVMs()
    {
        // Get-LazyVM asks Hyper-V for each VM with -ErrorAction SilentlyContinue;
        // in a hosted runspace those errors still reach the error stream.
        var errors = new[] { Error("Hyper-V was unable to find a virtual machine with name 'NewBox'.") };

        PowerShellCommandRunner.ThrowIfFailed([PSObject.AsPSObject("an entry")], errors);
    }

    [Fact]
    public void ThrowIfFailed_WithErrorsAndNothingReturned_Throws()
    {
        var errors = new[] { Error("The LazyVM folder was not found.") };

        var failure = Assert.Throws<InvalidOperationException>(() => PowerShellCommandRunner.ThrowIfFailed([], errors));

        Assert.Equal("The LazyVM folder was not found.", failure.Message);
    }

    [Fact]
    public void ThrowIfFailed_WithNoVMsAndNoErrors_DoesNotThrow()
    {
        PowerShellCommandRunner.ThrowIfFailed([], []);
    }

    [Fact]
    public void ThrowIfFailed_ForACommandThatFailsOnlyByThrowing_IgnoresTheErrorsItSilenced()
    {
        // Remove-LazyVM returns nothing, and Get-LazyVMRestorePoint nothing
        // for a VM with no restore points; both ask for tasks or checkpoints
        // that may not be there with -ErrorAction SilentlyContinue: only an
        // error they throw is their failure.
        var errors = new[] { Error("No MSFT_ScheduledTask objects found.") };

        PowerShellCommandRunner.ThrowIfFailed([], errors, failsOnlyByThrowing: true);
    }

    [Fact]
    public void ThrowIfCommandWroteError_ARefusedId_ThrowsWithTheModulesReason_AndIgnoresWhatItSilenced()
    {
        // As Approve-LazyVMSecurityFinding refuses an Id: a helper throws, the
        // command catches it and writes it with its own $PSCmdlet, through a
        // simple function as Write-CommandItemError does. An error of a call
        // inside it reaches the error stream first, and must not count.
        using var shell = PowerShell.Create();
        shell.AddScript("""
            function Write-ItemError { param($Cmdlet, $ErrorRecord) $Cmdlet.WriteError($ErrorRecord) }
            function Get-Approvable { param($Id) throw "The finding $Id is not an open finding of the last scan." }
            function global:Approve-LazyVMSecurityFinding {
                [CmdletBinding()]
                param([string]$Id)
                $null = Get-Item -LiteralPath 'Z:\lazyvm-not-there'
                & { try { Get-Approvable -Id $Id } catch { Write-ItemError -Cmdlet $PSCmdlet -ErrorRecord $_ } }
            }
            """).Invoke();
        shell.Commands.Clear();
        shell.Streams.Error.Clear();
        shell.AddCommand("Approve-LazyVMSecurityFinding").AddParameter("Id", "Task:x:1").Invoke();
        Assert.Equal(2, shell.Streams.Error.Count);

        var failure = Assert.Throws<InvalidOperationException>(
            () => PowerShellCommandRunner.ThrowIfCommandWroteError("Approve-LazyVMSecurityFinding", shell.Streams.Error));

        Assert.Equal("The finding Task:x:1 is not an open finding of the last scan.", failure.Message);
    }

    [Fact]
    public void ThrowIfCommandWroteError_OnlyErrorsOfCallsInsideIt_DoesNotThrow()
    {
        // An error of a call inside the module, which it does not treat as a
        // failure, reaches the error stream named for that call, not the command.
        using var shell = PowerShell.Create();
        shell.AddScript("""
            function global:Revoke-LazyVMSecurityFinding {
                [CmdletBinding()]
                param()
                $null = Get-Item -LiteralPath 'Z:\lazyvm-not-there'
            }
            """).Invoke();
        shell.Commands.Clear();
        shell.Streams.Error.Clear();
        shell.AddCommand("Revoke-LazyVMSecurityFinding").Invoke();
        Assert.NotEmpty(shell.Streams.Error);

        PowerShellCommandRunner.ThrowIfCommandWroteError("Revoke-LazyVMSecurityFinding", shell.Streams.Error);
    }

    private static ErrorRecord Error(string message)
    {
        return new(new InvalidOperationException(message), "Test", ErrorCategory.NotSpecified, null);
    }

    /// <summary>A runner with no commands of its own, to reach what every runner shares.</summary>
    private sealed class ProbeRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
    {
        public PowerShellSession SessionOf(Guid? vmId)
        {
            return SessionFor(vmId);
        }

        public Task<IReadOnlyList<PSObject>> InvokeAsync(string command)
        {
            return InvokeAsync(Sessions.ForHost(), command, [], CancellationToken.None);
        }

        public Task<(IReadOnlyList<PSObject> Output, IReadOnlyList<string> Warnings)> InvokeWithWarningsAsync(string command)
        {
            return InvokeWithWarningsAsync(Sessions.ForHost(), command, [], CancellationToken.None, failsOnlyByThrowing: true);
        }
    }
}

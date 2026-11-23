using System.Management.Automation;

namespace LazyVM.UI;

/// <summary>Runs <c>Get-LazyVMCredential</c> for the account LazyVM signs in to a VM with, and gives only the part asked for.</summary>
public class LazyVMCredentialsRunner(PowerShellSessionFactory sessions) : PowerShellCommandRunner(sessions)
{
    /// <summary>
    /// Runs <c>Get-LazyVMCredential -Name</c> in the VM's session and gives
    /// only the user name LazyVM signs in with. The password stays encrypted
    /// and is disposed of at once. Throws with the module's reason, such as
    /// when no credential is stored, which names Set-LazyVMCredential.
    /// </summary>
    public virtual async Task<string> GetLazyVMUserNameAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(SessionFor(vmId), "Get-LazyVMCredential", [("Name", name)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return LazyVMUserNameOf(output);
    }

    /// <summary>Runs <c>Get-LazyVMCredential -Name -AsPlainText</c> in the VM's session and gives only the password, for the moment it is shown or copied.</summary>
    public virtual async Task<string> GetLazyVMPasswordAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        var output = await InvokeAsync(
            SessionFor(vmId), "Get-LazyVMCredential", [("Name", name), ("AsPlainText", true)], cancellationToken, failsOnlyByThrowing: true)
            .ConfigureAwait(false);
        return LazyVMPasswordOf(output);
    }

    /// <summary>The user name of the credential in <paramref name="output"/>; its password is disposed of. Throws when there is none.</summary>
    internal static string LazyVMUserNameOf(IEnumerable<PSObject> output)
    {
        var credential = output.Select(item => item.BaseObject).OfType<PSCredential>().FirstOrDefault()
            ?? throw new InvalidOperationException("Get-LazyVMCredential gave no account.");
        credential.Password.Dispose();
        return credential.UserName;
    }

    /// <summary>The password of the <c>LazyVM.PlainCredential</c> in <paramref name="output"/>. Throws, without it, when there is none.</summary>
    internal static string LazyVMPasswordOf(IEnumerable<PSObject> output)
    {
        return output.Select(item => item.PropertyText("Password")).FirstOrDefault(password => password.Length > 0)
            ?? throw new InvalidOperationException("Get-LazyVMCredential gave no password.");
    }
}

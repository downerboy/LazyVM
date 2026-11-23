namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMCredential, answered from memory: the user name, and the password.</summary>
internal sealed class FakeCredentialsRunner() : LazyVMCredentialsRunner(UnusedSessions.Factory)
{
    /// <summary>The user name Get-LazyVMCredential gives; empty for a VM with no credential stored, which fails as the module does.</summary>
    public string? UserName { get; set; } = "devadmin";

    /// <summary>The password Get-LazyVMCredential -AsPlainText gives.</summary>
    public string Password { get; set; } = "Correct-Horse-9";

    /// <summary>Get-LazyVMCredential -AsPlainText fails with this.</summary>
    public Exception? PasswordFails
    {
        get; set;
    }

    public List<string> UserNameCalls { get; } = [];

    public List<string> PasswordCalls { get; } = [];

    /// <summary>The Hyper-V Id each Get-LazyVMCredential -AsPlainText ran for.</summary>
    public List<Guid?> PasswordIds { get; } = [];

    public override Task<string> GetLazyVMUserNameAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        UserNameCalls.Add(name);
        return UserName is { } userName
            ? Task.FromResult(userName)
            : Task.FromException<string>(new InvalidOperationException(
                $"No credential is stored for '{name}' yet. Build-LazyVM creates one, or store one with: Set-LazyVMCredential -Name {name}"));
    }

    public override Task<string> GetLazyVMPasswordAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        PasswordCalls.Add(name);
        PasswordIds.Add(vmId);
        return PasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(Password);
    }
}

namespace LazyVM.UI.Tests;

/// <summary>Get-LazyVMRecoveryKey, one recovery password and Export-LazyVMRecoveryKey, answered from memory.</summary>
internal sealed class FakeRecoveryKeysRunner() : LazyVMRecoveryKeysRunner(UnusedSessions.Factory)
{
    private readonly Answers<VMRecoveryKey> _RecoveryKeys = new();

    public List<string> RecoveryKeyCalls { get; } = [];

    /// <summary>The recovery password Get-LazyVMCredential -RecoveryPassword gives for each disk GUID.</summary>
    public Dictionary<string, string> RecoveryPasswords { get; } = new(StringComparer.OrdinalIgnoreCase);

    public List<(string Name, string DiskGuid)> RecoveryPasswordCalls { get; } = [];

    /// <summary>Get-LazyVMCredential -RecoveryPassword fails with this.</summary>
    public Exception? RecoveryPasswordFails
    {
        get; set;
    }

    public List<(string Name, string Path, bool Force)> ExportCalls { get; } = [];

    /// <summary>Export-LazyVMRecoveryKey fails with this.</summary>
    public Exception? ExportFails
    {
        get; set;
    }

    /// <summary>The warnings Export-LazyVMRecoveryKey writes.</summary>
    public IReadOnlyList<string> ExportWarnings { get; set; } = [];

    /// <summary>The next Get-LazyVMRecoveryKey returns these keys.</summary>
    public void ReturnsRecoveryKeys(params VMRecoveryKey[] keys)
    {
        _RecoveryKeys.Returns(keys);
    }

    public void RecoveryKeysThrow(Exception exception)
    {
        _RecoveryKeys.Throws(exception);
    }

    public override Task<IReadOnlyList<VMRecoveryKey>> GetLazyVMRecoveryKeysAsync(Guid? vmId, string name, CancellationToken cancellationToken)
    {
        RecoveryKeyCalls.Add(name);
        return _RecoveryKeys.Next(cancellationToken);
    }

    public override Task<string> GetLazyVMRecoveryPasswordAsync(Guid? vmId, string name, string diskGuid, CancellationToken cancellationToken)
    {
        RecoveryPasswordCalls.Add((name, diskGuid));
        return RecoveryPasswordFails is { } failure ? Task.FromException<string>(failure) : Task.FromResult(RecoveryPasswords[diskGuid]);
    }

    public override Task<RecoveryKeyExport> ExportLazyVMRecoveryKeysAsync(Guid? vmId, string name, string path, bool force)
    {
        ExportCalls.Add((name, path, force));
        return ExportFails is { } failure
            ? Task.FromException<RecoveryKeyExport>(failure)
            : Task.FromResult(new RecoveryKeyExport(path, ExportWarnings));
    }
}

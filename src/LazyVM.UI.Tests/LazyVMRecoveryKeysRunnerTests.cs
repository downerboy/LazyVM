using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the recovery keys runner reads a VM's keys and one disk's password.</summary>
public sealed class LazyVMRecoveryKeysRunnerTests
{
    [Fact]
    public void ToRecoveryKey_ReadsEveryField()
    {
        var recorded = new DateTime(2026, 10, 1, 9, 30, 0);

        var key = LazyVMRecoveryKeysRunner.LazyVMRecoveryKey(Entry(
            ("Name", "DevBox"),
            ("Disk", "OS disk"),
            ("DiskGuid", "{AAAAAAAA-0000-0000-0000-000000000001}"),
            ("KeyId", "{33333333-0000-0000-0000-000000000000}"),
            ("Recorded", recorded),
            ("Exported", true)));

        Assert.Equal(new VMRecoveryKey("OS disk", "{AAAAAAAA-0000-0000-0000-000000000001}", "{33333333-0000-0000-0000-000000000000}", recorded, true), key);
    }

    [Fact]
    public void ToRecoveryKey_WithNoKeyIDOrDate_LeavesThemEmpty()
    {
        var key = LazyVMRecoveryKeysRunner.LazyVMRecoveryKey(Entry(("Disk", "User disk"), ("DiskGuid", "{B}"), ("KeyId", ""), ("Recorded", null), ("Exported", false)));

        Assert.Equal(string.Empty, key.KeyId);
        Assert.Null(key.Recorded);
        Assert.False(key.Exported);
    }

    [Fact]
    public void RecoveryPasswordOf_GivesOnlyThatDisksPassword_WhateverTheCaseOfItsGuid()
    {
        var keys = new[]
        {
            Entry(("DiskGuid", "{AAAAAAAA-0000-0000-0000-000000000001}"), ("RecoveryPassword", "111111")),
            Entry(("DiskGuid", "{BBBBBBBB-0000-0000-0000-000000000002}"), ("RecoveryPassword", "222222")),
        };

        Assert.Equal("222222", LazyVMRecoveryKeysRunner.LazyVMDiskRecoveryPasswordOf(keys, "{bbbbbbbb-0000-0000-0000-000000000002}"));
    }

    [Fact]
    public void RecoveryPasswordOf_ADiskWithNoneStored_Throws()
    {
        var keys = new[] { Entry(("DiskGuid", "{A}"), ("RecoveryPassword", "111111")) };

        var thrown = Assert.Throws<InvalidOperationException>(() => LazyVMRecoveryKeysRunner.LazyVMDiskRecoveryPasswordOf(keys, "{B}"));

        Assert.Equal("No recovery password is stored for that disk now. Close this window and open it again to see the keys stored now.", thrown.Message);
    }

    [Fact]
    public async Task ExportLazyVMRecoveryKeysAsync_WithoutForce_LeavesForceOut()
    {
        using var sessions = new ScriptedSessions();
        var id = Guid.NewGuid();

        await new LazyVMRecoveryKeysRunner(sessions).ExportLazyVMRecoveryKeysAsync(id, "DevBox", @"C:\Keys\DevBox.txt", force: false);

        Assert.Same(sessions.ForVM(id), sessions.Call.Session);
        Assert.Equal(["Name", "Path"], sessions.Call.Parameters.Keys);
    }
}

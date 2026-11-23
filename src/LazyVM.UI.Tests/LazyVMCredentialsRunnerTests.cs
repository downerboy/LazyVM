using System.Management.Automation;

using static LazyVM.UI.Tests.PSObjects;

namespace LazyVM.UI.Tests;

/// <summary>How the credentials runner gives only the part of a credential asked for.</summary>
public sealed class LazyVMCredentialsRunnerTests
{
    [Fact]
    public void UserNameOf_ACredential_GivesItsUserName_AndDisposesThePassword()
    {
        using var password = new System.Security.SecureString();
        password.AppendChar('x');
        var credential = new PSCredential("devadmin", password);

        Assert.Equal("devadmin", LazyVMCredentialsRunner.LazyVMUserNameOf([PSObject.AsPSObject(credential)]));
        Assert.Throws<ObjectDisposedException>(() => password.Length);
    }

    [Fact]
    public void PasswordOf_APlainCredential_GivesItsPassword()
    {
        Assert.Equal("Correct-Horse-9", LazyVMCredentialsRunner.LazyVMPasswordOf([Entry(("UserName", "devadmin"), ("Password", "Correct-Horse-9"))]));
    }

    [Fact]
    public void UserNameOf_Nothing_Throws()
    {
        Assert.Throws<InvalidOperationException>(() => LazyVMCredentialsRunner.LazyVMUserNameOf([]));
    }
}

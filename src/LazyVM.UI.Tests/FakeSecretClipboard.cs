using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>A clipboard in memory: what Windows' clipboard would hold, and every secret put on it.</summary>
internal sealed class FakeSecretClipboard(TimeProvider clock) : SecretClipboard(clock)
{
    /// <summary>What the clipboard holds now; empty when it is clear.</summary>
    public string? Holding
    {
        get; set;
    }

    public List<string> Written { get; } = [];

    /// <summary>Putting a secret on the clipboard fails with this.</summary>
    public Exception? WriteFails
    {
        get; set;
    }

    protected override void Write(string secret)
    {
        if (WriteFails is { } failure)
        {
            throw failure;
        }
        Written.Add(secret);
        Holding = secret;
    }

    protected override bool Holds(string secret)
    {
        return Holding == secret;
    }

    protected override void Erase()
    {
        Holding = null;
    }

    protected override void OnUIThread(Action action)
    {
        action();
    }
}

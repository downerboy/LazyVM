namespace LazyVM.UI.Tests;

/// <summary>The one signal that something the list of VMs shows has changed, so the list is read again.</summary>
public sealed class ListChangesTests
{
    [Fact]
    public void Raise_TellsEverySubscriber()
    {
        var changes = new ListChanges();
        var first = 0;
        var second = 0;
        changes.Changed += (_, _) => first++;
        changes.Changed += (_, _) => second++;

        changes.Raise();

        Assert.Equal(1, first);
        Assert.Equal(1, second);
    }

    [Fact]
    public void Raise_WithNoSubscriber_DoesNothing()
    {
        new ListChanges().Raise();
    }

    [Fact]
    public void Raise_GivesTheNotifierAsTheSender()
    {
        var changes = new ListChanges();
        object? sender = null;
        changes.Changed += (source, _) => sender = source;

        changes.Raise();

        Assert.Same(changes, sender);
    }
}

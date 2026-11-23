namespace LazyVM.UI.Tests;

/// <summary>A fake command's queue of answers: each call takes the next one.</summary>
internal sealed class Answers<T>
{
    private readonly Queue<Func<CancellationToken, Task<IReadOnlyList<T>>>> _Queue = new();

    public void Returns(T[] values)
    {
        _Queue.Enqueue(_ => Task.FromResult<IReadOnlyList<T>>(values));
    }

    public void Throws(Exception exception)
    {
        _Queue.Enqueue(_ => Task.FromException<IReadOnlyList<T>>(exception));
    }

    public void WaitsForCancel()
    {
        _Queue.Enqueue(async token =>
        {
            await Task.Delay(Timeout.Infinite, token);
            return [];
        });
    }

    public Task<IReadOnlyList<T>> Next(CancellationToken cancellationToken)
    {
        return _Queue.Dequeue()(cancellationToken);
    }
}

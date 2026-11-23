using LazyVM.UI.ViewModels;

namespace LazyVM.UI;

/// <summary>
/// Keeps one window per key: opening one that is open brings it to the front
/// instead. A window is shown for the window that opened it, and closes with
/// it, so the windows form a tree (#531). What a window is, and how it is
/// shown, brought to the front and closed, is the GUI's: it derives from this
/// class, and tests derive a fake that makes no windows.
/// </summary>
public abstract class WindowTracker
{
    private readonly Dictionary<string, ViewModelBase> _Open = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>The windows each window opened, which close with it.</summary>
    private readonly Dictionary<ViewModelBase, List<ViewModelBase>> _Opened = [];

    /// <summary>The view model of the window open for <paramref name="key"/>, left where it is; nothing when no window of that kind is open.</summary>
    public T? Find<T>(string key) where T : ViewModelBase
    {
        return _Open.TryGetValue(key, out var existing) ? existing as T : null;
    }

    /// <summary>
    /// Brings the window open for <paramref name="key"/> to the front and
    /// gives its view model; nothing when no window of that kind is open.
    /// </summary>
    public T? Activate<T>(string key) where T : ViewModelBase
    {
        if (Find<T>(key) is { } open)
        {
            BringToFront(open);
            return open;
        }
        return null;
    }

    /// <summary>
    /// Shows a new window for <paramref name="viewModel"/> under
    /// <paramref name="key"/>, and calls <paramref name="closed"/> when it closes.
    /// It closes with the window of <paramref name="opener"/>, when it has one,
    /// and the windows it opened close with it.
    /// </summary>
    public void Track(string key, ViewModelBase viewModel, Action? closed = null, ViewModelBase? opener = null)
    {
        _Open.Add(key, viewModel);
        if (opener is not null)
        {
            _Opened.TryAdd(opener, []);
            _Opened[opener].Add(viewModel);
        }
        Show(viewModel, () =>
        {
            // Only this window's own entry: a newer window may have taken its key.
            if (_Open.TryGetValue(key, out var current) && current == viewModel)
            {
                _Open.Remove(key);
            }
            if (opener is not null && _Opened.TryGetValue(opener, out var siblings))
            {
                siblings.Remove(viewModel);
            }
            closed?.Invoke();
            // Each of these is closed by the GUI, and so ends up here in turn.
            if (_Opened.Remove(viewModel, out var children))
            {
                foreach (var child in children)
                {
                    CloseWindow(child);
                }
            }
        });
    }

    /// <summary>Closes the window open for <paramref name="key"/> and frees the key, so a new window can take it. Nothing happens when none is open.</summary>
    public void Close(string key)
    {
        if (_Open.Remove(key, out var viewModel))
        {
            CloseWindow(viewModel);
        }
    }

    /// <summary>Closes the window of <paramref name="viewModel"/>.</summary>
    public void Close(ViewModelBase viewModel)
    {
        CloseWindow(viewModel);
    }

    /// <summary>Shows a new window for <paramref name="viewModel"/> and calls <paramref name="closed"/> when it closes.</summary>
    protected abstract void Show(ViewModelBase viewModel, Action closed);

    protected abstract void BringToFront(ViewModelBase viewModel);

    /// <summary>Closes the window of <paramref name="viewModel"/>, which calls the action <see cref="Show"/> was given.</summary>
    protected abstract void CloseWindow(ViewModelBase viewModel);
}

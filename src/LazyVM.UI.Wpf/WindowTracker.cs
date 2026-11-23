using LazyVM.UI.Wpf.ViewModels;

using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Keeps one window per key: opening one that is open brings it to the front
/// instead. The window shown for a view model is the one its type maps to,
/// so a new window is a new entry in <see cref="_WindowOf"/>, not a new
/// method or case elsewhere. Tests replace the members that touch windows.
/// </summary>
public class WindowTracker
{
    private static readonly IReadOnlyDictionary<Type, Func<Window>> _WindowOf = new Dictionary<Type, Func<Window>>
    {
        [typeof(VMViewModel)] = () => new VMWindow(),
        [typeof(ChecksViewModel)] = () => new ChecksWindow(),
        [typeof(LogViewModel)] = () => new LogWindow(),
        [typeof(BuildViewModel)] = () => new BuildWindow(),
        [typeof(BuildProgressViewModel)] = () => new BuildProgressWindow(),
        [typeof(RestoreViewModel)] = () => new RestoreWindow(),
        [typeof(RecoveryKeysViewModel)] = () => new RecoveryKeysWindow(),
        [typeof(PasswordViewModel)] = () => new PasswordWindow(),
        [typeof(SecurityFindingsViewModel)] = () => new SecurityFindingsWindow(),
    };

    private readonly Dictionary<string, ViewModelBase> _Open = new(StringComparer.OrdinalIgnoreCase);

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
    /// </summary>
    public void Track(string key, ViewModelBase viewModel, Action? closed = null)
    {
        _Open.Add(key, viewModel);
        Show(viewModel, () =>
        {
            // Only this window's own entry: a newer window may have taken its key.
            if (_Open.TryGetValue(key, out var current) && current == viewModel)
            {
                _Open.Remove(key);
            }
            closed?.Invoke();
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
    protected virtual void Show(ViewModelBase viewModel, Action closed)
    {
        var window = _WindowOf.TryGetValue(viewModel.GetType(), out var create)
            ? create()
            : throw new ArgumentException($"There is no window for {viewModel.GetType().Name}.", nameof(viewModel));
        window.DataContext = viewModel;
        window.Closed += (_, _) => closed();
        window.Show();
    }

    protected virtual void BringToFront(ViewModelBase viewModel)
    {
        WindowOf(viewModel).BringToFront();
    }

    protected virtual void CloseWindow(ViewModelBase viewModel)
    {
        WindowOf(viewModel).Close();
    }

    private static Window WindowOf(ViewModelBase viewModel)
    {
        return Application.Current.Windows.OfType<Window>().WindowOf(viewModel)
            ?? throw new InvalidOperationException($"No window shows {viewModel.GetType().Name}.");
    }
}

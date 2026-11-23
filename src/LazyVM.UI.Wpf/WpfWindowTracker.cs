using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>
/// The app's windows. The window shown for a view model is the one its type
/// maps to, so a new window is a new entry in <see cref="_WindowOf"/>, not a
/// new method or case elsewhere.
/// </summary>
public sealed class WpfWindowTracker : WindowTracker
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

    protected override void Show(ViewModelBase viewModel, Action closed)
    {
        var window = _WindowOf.TryGetValue(viewModel.GetType(), out var create)
            ? create()
            : throw new ArgumentException($"There is no window for {viewModel.GetType().Name}.", nameof(viewModel));
        window.DataContext = viewModel;
        window.Closed += (_, _) => closed();
        window.Show();
    }

    protected override void BringToFront(ViewModelBase viewModel)
    {
        WindowOf(viewModel).BringToFront();
    }

    protected override void CloseWindow(ViewModelBase viewModel)
    {
        WindowOf(viewModel).Close();
    }

    private static Window WindowOf(ViewModelBase viewModel)
    {
        return Application.Current.Windows.OfType<Window>().WindowOf(viewModel)
            ?? throw new InvalidOperationException($"No window shows {viewModel.GetType().Name}.");
    }
}

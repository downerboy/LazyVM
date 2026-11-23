using LazyVM.UI.ViewModels;

namespace LazyVM.UI.Tests;

/// <summary>Records the windows shown, brought to the front and closed, without making windows.</summary>
internal sealed class FakeWindowTracker : WindowTracker
{
    private readonly Dictionary<ViewModelBase, Action> _Closers = [];

    public List<ViewModelBase> Shown { get; } = [];

    public List<ViewModelBase> BroughtToFront { get; } = [];

    public List<ViewModelBase> Closed { get; } = [];

    /// <summary>The user closes the window of <paramref name="viewModel"/>.</summary>
    public void UserCloses(ViewModelBase viewModel)
    {
        _Closers[viewModel]();
    }

    protected override void Show(ViewModelBase viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(ViewModelBase viewModel)
    {
        BroughtToFront.Add(viewModel);
    }

    protected override void CloseWindow(ViewModelBase viewModel)
    {
        Closed.Add(viewModel);
        _Closers[viewModel]();
    }
}

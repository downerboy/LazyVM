using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>Records the VM windows shown and brought to the front, without making windows.</summary>
internal sealed class FakeVMWindowManager(ToolWindows tools) : VMWindowManager(tools)
{
    private readonly Dictionary<VMViewModel, Action> _Closers = [];

    public List<VMViewModel> Shown { get; } = [];

    public List<VMViewModel> BroughtToFront { get; } = [];

    public List<VMViewModel> Closed { get; } = [];

    public void Close(VMViewModel window)
    {
        _Closers[window]();
    }

    protected override void CloseWindow(VMViewModel viewModel)
    {
        Closed.Add(viewModel);
        _Closers[viewModel]();
    }

    protected override void Show(VMViewModel viewModel, Action closed)
    {
        Shown.Add(viewModel);
        _Closers[viewModel] = closed;
    }

    protected override void BringToFront(VMViewModel viewModel)
    {
        BroughtToFront.Add(viewModel);
    }
}

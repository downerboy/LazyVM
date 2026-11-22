using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>What a view model said it was working on, each time that changed, with empty for not working.</summary>
internal sealed class WorkWatcher
{
    public WorkWatcher(ViewModelBase viewModel)
    {
        viewModel.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName is nameof(ViewModelBase.WorkingText) or nameof(ViewModelBase.IsWorking))
            {
                var now = viewModel.IsWorking ? viewModel.WorkingText : null;
                if (Seen.Count == 0 || Seen[^1] != now)
                {
                    Seen.Add(now);
                }
            }
        };
    }

    public List<string?> Seen { get; } = [];
}

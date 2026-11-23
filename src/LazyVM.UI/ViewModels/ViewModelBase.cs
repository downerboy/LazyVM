using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace LazyVM.UI.ViewModels;

/// <summary>Tells the view when a property changes. The one implementation of <see cref="INotifyPropertyChanged"/>.</summary>
public abstract class ViewModelBase : INotifyPropertyChanged
{
    /// <summary>What each command still running is doing, the latest last.</summary>
    private readonly List<string> _Work = [];

    /// <summary>The view models this one is made of, whose work it shows as its own.</summary>
    private readonly List<ViewModelBase> _Parts = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// True while a command this view model or one of its parts ran has not
    /// answered (#499). The window shows a progress bar then: any command can
    /// take longer than three seconds, the first one starts PowerShell, and
    /// one waits for another, since the app runs one command at a time.
    /// </summary>
    public bool IsWorking => _Work.Count > 0 || _Parts.Any(part => part.IsWorking);

    /// <summary>What it is doing, such as "Reading the log", its own command before a part's; empty when it is not working.</summary>
    public string? WorkingText => _Work.Count > 0
        ? _Work[^1]
        : _Parts.Select(part => part.WorkingText).LastOrDefault(text => text is not null);

    /// <summary>
    /// Shows the work of <paramref name="part"/> as this view model's own, so
    /// a window made of parts still has one progress bar, saying what any
    /// part of it is doing.
    /// </summary>
    protected void Include(ViewModelBase part)
    {
        _Parts.Add(part);
        // A part raises IsWorking and then WorkingText; by the second, both have changed.
        part.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(WorkingText))
            {
                WorkChanged();
            }
        };
    }

    /// <summary>Runs <paramref name="work"/>, working on <paramref name="text"/> until it has answered, failed or been cancelled.</summary>
    protected async Task<T> WorkAsync<T>(string text, Func<Task<T>> work)
    {
        _Work.Add(text);
        WorkChanged();
        try
        {
            return await work();
        }
        finally
        {
            _Work.RemoveAt(_Work.LastIndexOf(text));
            WorkChanged();
        }
    }

    /// <inheritdoc cref="WorkAsync{T}(string, Func{Task{T}})"/>
    protected Task WorkAsync(string text, Func<Task> work)
    {
        return WorkAsync(text, async () =>
        {
            await work();
            return true;
        });
    }

    private void WorkChanged()
    {
        OnPropertyChanged(nameof(IsWorking));
        OnPropertyChanged(nameof(WorkingText));
    }

    /// <summary>Raises <see cref="PropertyChanged"/>; an empty name means every property changed.</summary>
    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }

    protected bool SetProperty<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }
}

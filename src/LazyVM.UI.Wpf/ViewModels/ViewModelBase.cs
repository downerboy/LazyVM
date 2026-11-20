using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>Tells the view when a property changes. The one implementation of <see cref="INotifyPropertyChanged"/>.</summary>
public abstract class ViewModelBase : INotifyPropertyChanged
{
    /// <summary>What each command still running is doing, the latest last.</summary>
    private readonly List<string> _Work = [];

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>
    /// True while a command this view model ran has not answered (#499).
    /// The window shows a progress bar then: any command can take longer than
    /// three seconds, the first one starts PowerShell, and one waits for
    /// another, since the app runs one command at a time.
    /// </summary>
    public bool IsWorking => _Work.Count > 0;

    /// <summary>What it is doing, such as "Reading the log"; empty when it is not working.</summary>
    public string? WorkingText => _Work.Count == 0 ? null : _Work[^1];

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

using System.Windows.Input;

namespace LazyVM.UI.Wpf.ViewModels;

/// <summary>A command that runs an action when it can. The one implementation of <see cref="ICommand"/>.</summary>
public sealed class RelayCommand(Action execute, Func<bool>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter)
    {
        return canExecute?.Invoke() ?? true;
    }

    public void Execute(object? parameter)
    {
        if (CanExecute(parameter))
        {
            execute();
        }
    }

    /// <summary>Tells the view to ask <see cref="CanExecute"/> again.</summary>
    public void RaiseCanExecuteChanged()
    {
        CanExecuteChanged?.Invoke(this, EventArgs.Empty);
    }
}

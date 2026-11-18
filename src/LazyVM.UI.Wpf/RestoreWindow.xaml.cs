using LazyVM.UI.Wpf.ViewModels;
using System.ComponentModel;
using System.Windows;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>A VM's Restore window. Its behavior is in <see cref="RestoreViewModel"/>; this only moves keyboard focus.</summary>
public partial class RestoreWindow : Window
{
    public RestoreWindow()
    {
        InitializeComponent();
        // Once the points are read, focus goes to the newest, the first, so Narrator reads it.
        DataContextChanged += (_, e) =>
        {
            if (e.OldValue is RestoreViewModel old)
            {
                old.PropertyChanged -= FocusOnPoints;
            }
            if (e.NewValue is RestoreViewModel now)
            {
                now.PropertyChanged += FocusOnPoints;
            }
        };
    }

    private void FocusOnPoints(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(RestoreViewModel.Points))
        {
            ListFocus.FocusFirst(List);
        }
    }

    /// <summary>Esc closes the window.</summary>
    private void CloseWindow(object sender, ExecutedRoutedEventArgs e)
    {
        Close();
    }
}

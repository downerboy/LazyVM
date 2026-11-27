using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Ctrl+C on a list copies its selected row as Narrator reads it (#553).
/// Never set it on a list whose rows can hold a secret, such as a recovery
/// password: the ordinary clipboard keeps what it holds in its history.
/// </summary>
public static class RowCopy
{
    public static readonly DependencyProperty IsEnabledProperty = DependencyProperty.RegisterAttached(
        "IsEnabled", typeof(bool), typeof(RowCopy), new PropertyMetadata(false, OnIsEnabledChanged));

    private static readonly CommandBinding _Copy = new(ApplicationCommands.Copy, Copy, CanCopy);

    public static bool GetIsEnabled(DependencyObject element)
    {
        return (bool)element.GetValue(IsEnabledProperty);
    }

    public static void SetIsEnabled(DependencyObject element, bool value)
    {
        element.SetValue(IsEnabledProperty, value);
    }

    /// <summary>The selected row's text as Narrator reads it, or null when no row is selected.</summary>
    internal static string? TextOf(ListBox list)
    {
        return list.SelectedItem is { } item && list.ItemContainerGenerator.ContainerFromItem(item) is UIElement row
            ? AutomationProperties.GetName(row) is { Length: > 0 } name ? name : item.ToString()
            : null;
    }

    /// <summary>Puts <paramref name="text"/> on the clipboard.</summary>
    internal static void Put(string text)
    {
        try
        {
            Clipboard.SetText(text);
        }
        catch (System.Runtime.InteropServices.ExternalException)
        {
            // Another app has the clipboard open; copying again will do.
        }
    }

    private static void OnIsEnabledChanged(DependencyObject element, DependencyPropertyChangedEventArgs e)
    {
        if (element is not ListBox list)
        {
            return;
        }
        if ((bool)e.NewValue)
        {
            list.CommandBindings.Add(_Copy);
        } else
        {
            list.CommandBindings.Remove(_Copy);
        }
    }

    private static void CanCopy(object sender, CanExecuteRoutedEventArgs e)
    {
        e.CanExecute = sender is ListBox { SelectedItem: not null };
    }

    private static void Copy(object sender, ExecutedRoutedEventArgs e)
    {
        if (sender is ListBox list && TextOf(list) is { } text)
        {
            Put(text);
        }
    }
}

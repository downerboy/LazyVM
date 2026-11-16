using System.Windows.Controls;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Moves keyboard focus onto an item of a list, so Narrator reads it.
/// Selecting an item alone moves nothing: focus has to go to its container.
/// </summary>
internal static class ListFocus
{
    public static void FocusFirst(ListBox list)
    {
        if (list.Items.Count > 0)
        {
            Focus(list, list.Items[0]);
        }
    }

    public static void Focus(ListBox list, object item)
    {
        list.SelectedItem = item;
        list.ScrollIntoView(item);
        // The container may not exist until the list has laid out the new items.
        list.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
        {
            list.ScrollIntoView(item);
            if (list.ItemContainerGenerator.ContainerFromItem(item) is ListBoxItem container)
            {
                container.Focus();
            }
        });
    }
}

using LazyVM.UI.Wpf.ViewModels;

using System.Windows;

namespace LazyVM.UI.Wpf;

/// <summary>Behavior the app gives every window, so the classes that open windows do not each carry it.</summary>
internal static class WindowExtensions
{
    extension(IEnumerable<Window> windows)
    {
        /// <summary>The window that shows <paramref name="viewModel"/>; nothing when none does.</summary>
        public Window? WindowOf(ViewModelBase viewModel)
        {
            return windows.FirstOrDefault(window => ReferenceEquals(window.DataContext, viewModel));
        }
    }

    extension(Window window)
    {
        /// <summary>Restores the window when it is minimized, and makes it the active one.</summary>
        public void BringToFront()
        {
            if (window.WindowState == WindowState.Minimized)
            {
                window.WindowState = WindowState.Normal;
            }
            window.Activate();
        }
    }
}

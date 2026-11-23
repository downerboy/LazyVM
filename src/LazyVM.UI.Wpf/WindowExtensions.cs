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

        /// <summary>Asks <paramref name="question"/> with Yes and No, No the default, in a dialog over the window. True for Yes.</summary>
        public bool Ask(string title, string question)
        {
            var dialog = new QuestionWindow { DataContext = new QuestionViewModel(title, question), Owner = window };
            return dialog.ShowDialog() == true;
        }

        /// <summary>Asks for the optional reason for <paramref name="subject"/> in a dialog over the window. Null for Cancel.</summary>
        public string? AskReason(string title, string subject)
        {
            var reason = new ReasonViewModel(title, subject);
            var dialog = new ReasonWindow { DataContext = reason, Owner = window };
            return dialog.ShowDialog() == true ? reason.Reason : null;
        }

        /// <summary>Asks for a text file to save to in a Save dialog over the window; null for Cancel. It does not ask about a file that exists.</summary>
        public string? ChooseTextFileToSave(string title, string suggestedName)
        {
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = title,
                FileName = suggestedName,
                DefaultExt = ".txt",
                Filter = "Text files (*.txt)|*.txt|All files (*.*)|*.*",
                OverwritePrompt = false,
                AddExtension = true,
            };
            return dialog.ShowDialog(window) == true ? dialog.FileName : null;
        }
    }
}

using System.Windows;
using LazyVM.UI.Wpf.ViewModels;
using Microsoft.Win32;

namespace LazyVM.UI.Wpf;

/// <summary>Starts the app: picks the theme, makes the command runner and opens the main window.</summary>
public partial class App : Application
{
    private CommandRunner? runner;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        Resources.MergedDictionaries.Insert(0, new ResourceDictionary
        {
            Source = new Uri($"Themes/{ThemeName()}.xaml", UriKind.Relative),
        });

        runner = new CommandRunner();
        var tools = new ToolWindows(runner, new BuildLauncher(), TimeProvider.System);
        var main = new MainViewModel(runner, new VMWindowManager(tools), tools, TimeProvider.System);
        MainWindow = new MainWindow { DataContext = main };
        MainWindow.Show();
        _ = main.StartAsync();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        runner?.Dispose();
        base.OnExit(e);
    }

    /// <summary>High Contrast when it is on; otherwise the Windows light or dark app setting.</summary>
    private static string ThemeName()
    {
        if (SystemParameters.HighContrast)
        {
            return "HighContrast";
        }
        var light = Registry.GetValue(
            @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1);
        return light is 0 ? "Dark" : "Light";
    }
}

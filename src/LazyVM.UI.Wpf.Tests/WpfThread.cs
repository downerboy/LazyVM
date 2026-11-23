using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>
/// The one thread that owns the WPF application for every test: there can be
/// only one application per process. Tests that need real windows run on it.
/// </summary>
internal static class WpfThread
{
    private static readonly Lazy<Dispatcher> _Thread = new(Start);

    public static Dispatcher Dispatcher => _Thread.Value;

    private static Dispatcher Start()
    {
        var ready = new TaskCompletionSource<Dispatcher>();
        var thread = new Thread(() =>
        {
            var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
            app.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri("pack://application:,,,/LazyVM.UI.Wpf;component/Themes/Light.xaml"),
            });
            app.Resources.MergedDictionaries.Add(new ResourceDictionary
            {
                Source = new Uri("pack://application:,,,/LazyVM.UI.Wpf;component/Themes/Styles.xaml"),
            });
            app.Resources["VisibleWhenTrue"] = new BooleanToVisibilityConverter();
            ready.SetResult(Dispatcher.CurrentDispatcher);
            Dispatcher.Run();
        })
        {
            IsBackground = true,
        };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return ready.Task.GetAwaiter().GetResult();
    }
}

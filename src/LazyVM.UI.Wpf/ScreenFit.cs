using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace LazyVM.UI.Wpf;

/// <summary>Keeps a window wholly inside the work area of its screen (#558). Sizes are in screen pixels.</summary>
public static class ScreenFit
{
    private const uint _MONITOR_DEFAULTTONEAREST = 2;
    private const uint _SWP_NOZORDER = 0x0004;
    private const uint _SWP_NOACTIVATE = 0x0010;

    /// <summary>Set to true on a window, by its style, to have it open inside the work area.</summary>
    public static readonly DependencyProperty OnOpenProperty = DependencyProperty.RegisterAttached(
        "OnOpen", typeof(bool), typeof(ScreenFit), new PropertyMetadata(false, OnOpenChanged));

    /// <summary>Set to true on a window, by its style, to have it open in the middle of the work area (#563).</summary>
    public static readonly DependencyProperty CenteredProperty = DependencyProperty.RegisterAttached(
        "Centered", typeof(bool), typeof(ScreenFit), new PropertyMetadata(false));

    public static bool GetCentered(Window window)
    {
        return (bool)window.GetValue(CenteredProperty);
    }

    public static void SetCentered(Window window, bool value)
    {
        window.SetValue(CenteredProperty, value);
    }

    public static bool GetOnOpen(Window window)
    {
        return (bool)window.GetValue(OnOpenProperty);
    }

    public static void SetOnOpen(Window window, bool value)
    {
        window.SetValue(OnOpenProperty, value);
    }

    /// <summary>Loaded comes after WPF has sized and placed the window, a dialog over its owner included.</summary>
    private static void OnOpenChanged(DependencyObject target, DependencyPropertyChangedEventArgs e)
    {
        if (target is Window window)
        {
            window.Loaded -= Fit;
            if ((bool)e.NewValue)
            {
                window.Loaded += Fit;
            }
        }
    }

    private static void Fit(object sender, RoutedEventArgs e)
    {
        var window = (Window)sender;
        if (window.WindowState == WindowState.Normal)
        {
            Place(window);
        }
        else
        {
            // A maximized window already fills the work area. Its other size is fitted when it is first restored.
            window.StateChanged += FitWhenRestored;
        }
    }

    private static void FitWhenRestored(object? sender, EventArgs e)
    {
        var window = (Window)sender!;
        if (window.WindowState == WindowState.Normal)
        {
            window.StateChanged -= FitWhenRestored;
            Place(window);
        }
    }

    private static void Place(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        var bounds = BoundsOf(handle);
        var area = WorkAreaOf(handle);
        var fitted = GetCentered(window) ? bounds.CenteredIn(area) : bounds.FittedInto(area);
        if (fitted == bounds)
        {
            return;
        }
        if (fitted.Width != bounds.Width || fitted.Height != bounds.Height)
        {
            // A window sized to its content would take its old size back.
            window.SizeToContent = SizeToContent.Manual;
        }
        if (!SetWindowPos(handle, IntPtr.Zero, fitted.X, fitted.Y, fitted.Width, fitted.Height, _SWP_NOZORDER | _SWP_NOACTIVATE))
        {
            throw new Win32Exception();
        }
    }

    extension(Int32Rect window)
    {
        /// <summary>This rectangle in the middle of <paramref name="area"/>, shrunk when it is larger.</summary>
        internal Int32Rect CenteredIn(Int32Rect area)
        {
            var width = Math.Min(window.Width, area.Width);
            var height = Math.Min(window.Height, area.Height);
            return new Int32Rect(area.X + ((area.Width - width) / 2), area.Y + ((area.Height - height) / 2), width, height);
        }

        /// <summary>This rectangle, shrunk when it is larger than <paramref name="area"/>, then moved the least that puts it inside.</summary>
        internal Int32Rect FittedInto(Int32Rect area)
        {
            var width = Math.Min(window.Width, area.Width);
            var height = Math.Min(window.Height, area.Height);
            var x = Math.Clamp(window.X, area.X, area.X + area.Width - width);
            var y = Math.Clamp(window.Y, area.Y, area.Y + area.Height - height);
            return new Int32Rect(x, y, width, height);
        }
    }

    /// <summary>Where the window with this handle is, in screen pixels.</summary>
    internal static Int32Rect BoundsOf(IntPtr handle)
    {
        return GetWindowRect(handle, out var bounds) ? bounds.ToInt32Rect() : throw new Win32Exception();
    }

    /// <summary>The part of the window's screen that the taskbar leaves, in screen pixels.</summary>
    internal static Int32Rect WorkAreaOf(IntPtr handle)
    {
        var monitor = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        return GetMonitorInfo(MonitorFromWindow(handle, _MONITOR_DEFAULTTONEAREST), ref monitor)
            ? monitor.Work.ToInt32Rect()
            : throw new Win32Exception();
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;

        public readonly Int32Rect ToInt32Rect()
        {
            return new Int32Rect(Left, Top, Right - Left, Bottom - Top);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(IntPtr window, out NativeRect bounds);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int width, int height, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr window, uint flags);

    [DllImport("user32.dll", EntryPoint = "GetMonitorInfoW", SetLastError = true)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
}

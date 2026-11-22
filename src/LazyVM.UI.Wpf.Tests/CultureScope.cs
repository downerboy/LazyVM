using LazyVM.UI.Wpf.ViewModels;

namespace LazyVM.UI.Wpf.Tests;

/// <summary>Runs a test with a fixed culture, so dates and numbers read the same on every machine.</summary>
internal sealed class CultureScope : IDisposable
{
    private readonly System.Globalization.CultureInfo _Culture = System.Globalization.CultureInfo.CurrentCulture;
    private readonly System.Globalization.CultureInfo _UiCulture = System.Globalization.CultureInfo.CurrentUICulture;

    public CultureScope(string name)
    {
        var chosen = System.Globalization.CultureInfo.GetCultureInfo(name);
        System.Globalization.CultureInfo.CurrentCulture = chosen;
        System.Globalization.CultureInfo.CurrentUICulture = chosen;
    }

    public void Dispose()
    {
        System.Globalization.CultureInfo.CurrentCulture = _Culture;
        System.Globalization.CultureInfo.CurrentUICulture = _UiCulture;
    }
}

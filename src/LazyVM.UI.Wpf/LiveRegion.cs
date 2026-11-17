using System.ComponentModel;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;

namespace LazyVM.UI.Wpf;

/// <summary>
/// Makes Narrator read a text block out when its text changes, such as the
/// status line after a refresh. Set <c>AutomationProperties.LiveSetting</c> too.
/// </summary>
public static class LiveRegion
{
    public static readonly DependencyProperty AnnounceProperty = DependencyProperty.RegisterAttached(
        "Announce", typeof(bool), typeof(LiveRegion), new PropertyMetadata(false, OnAnnounceChanged));

    private static readonly DependencyPropertyDescriptor _Text =
        DependencyPropertyDescriptor.FromProperty(TextBlock.TextProperty, typeof(TextBlock));

    public static bool GetAnnounce(DependencyObject element) => (bool)element.GetValue(AnnounceProperty);

    public static void SetAnnounce(DependencyObject element, bool value) => element.SetValue(AnnounceProperty, value);

    private static void OnAnnounceChanged(DependencyObject element, DependencyPropertyChangedEventArgs e)
    {
        if (element is not TextBlock block)
        {
            return;
        }
        if ((bool)e.NewValue)
        {
            _Text.AddValueChanged(block, Announce);
        }
        else
        {
            _Text.RemoveValueChanged(block, Announce);
        }
    }

    private static void Announce(object? sender, EventArgs e)
    {
        if (sender is TextBlock block)
        {
            var peer = UIElementAutomationPeer.FromElement(block) ?? UIElementAutomationPeer.CreatePeerForElement(block);
            peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
        }
    }
}

using System.Windows;
using System.Windows.Controls;

namespace CPRemote.Windows;

/// <summary>A name printed on a front panel, struck through by a rule when <paramref name="withRule"/> is set.</summary>
public partial class SectionLabel : UserControl
{
    public SectionLabel(string text, bool withRule)
    {
        InitializeComponent();
        Caption.Text = text;
        Rule.Visibility = withRule ? Visibility.Visible : Visibility.Collapsed;
    }
}

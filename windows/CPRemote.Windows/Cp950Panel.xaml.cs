using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using CPRemote.Core;

namespace CPRemote.Windows;

/// <summary>
/// The CP950 front, after figure 1 of the CP950 and CP950A manual. Live: the
/// fader knob, the fader level on the touch screen (tapped, it switches unit),
/// the speaker icon that mutes, and the macro list. The status LEDs, the booth
/// monitor knob and its grille are drawn only.
/// </summary>
public partial class Cp950Panel : UserControl, IFrontPanel
{
    // The canvas is drawn in units of the panel's height; its width follows the aspect.
    private const double CanvasHeight = 1000;

    // The CP950 front: 890 by 242 units.
    public double Aspect { get; } = 890.0 / 242;

    private const int MacroRows = 8;

    // The grille's dots: 14 rows, and each dot is this fraction of its row's pitch.
    private const int GrilleRows = 14;
    private const double GrilleDotFraction = 0.06;

    private readonly RemoteController _controller;
    private readonly FractionStage _s;
    private readonly FaderKnob _knob;
    private readonly Button _fader = new();
    private readonly Button _mute = new();
    private readonly List<Button> _macroRows = [];
    private readonly TextBlock _macroName;

    public Cp950Panel(RemoteController controller)
    {
        InitializeComponent();
        _controller = controller;
        _s = new FractionStage(Stage, CanvasWidth, CanvasHeight);
        _knob = new FaderKnob(controller, CanvasHeight * 0.413);
        BuildFront();
        _macroName = _s.Label(string.Empty, 0.52, 0.5, 0.06, 0.19, FontWeights.Normal, false,
            this.BrushOf("DimTextBrush"));
        Refresh();
    }

    private double CanvasWidth => CanvasHeight * Aspect;

    public void Refresh()
    {
        bool connected = _controller.IsConnected;
        bool decibels = _controller.LevelInDecibels;
        string level = _controller.LevelTextWithUnit;

        _fader.Content = "FADER " + level;
        _fader.FontSize = CanvasHeight * (decibels ? 0.06 : 0.075);
        AutomationProperties.SetName(_fader, $"Fader {level}");

        bool muted = _controller.Muted;
        _mute.IsEnabled = connected;
        _mute.Content = muted ? PanelText.MuteGlyph : PanelText.VolumeGlyph;
        _mute.Foreground = muted ? this.BrushOf("LampRedBrush") : this.BrushOf("LightTextBrush");
        AutomationProperties.SetName(_mute, muted ? "Unmute" : "Mute");

        // The macros the processor offers, or else the selected macro's name alone.
        IReadOnlyList<RemoteController.Macro>? macros = _controller.Macros;
        int? preset = _controller.MacroPreset;
        for (int index = 0; index < _macroRows.Count; index++)
        {
            Button row = _macroRows[index];
            if (macros is null || index >= macros.Count)
            {
                row.Visibility = Visibility.Collapsed;
                continue;
            }

            RemoteController.Macro macro = macros[index];
            bool selected = macro.Number == preset;
            row.Visibility = Visibility.Visible;
            row.IsEnabled = connected;
            row.Content = (selected ? PanelText.Symbol(0x25B8) + " " : string.Empty) + macro.Name;
            row.FontWeight = selected ? FontWeights.Bold : FontWeights.Normal;
            row.Foreground = selected ? this.BrushOf("WhiteBrush") : this.BrushOf("MacroTextBrush");
            AutomationProperties.SetName(row, $"Macro {macro.Number}: {macro.Name}");
        }

        string? name = _controller.MacroName;
        bool showName = macros is null && name is not null;
        _macroName.Text = name ?? string.Empty;
        _macroName.Visibility = showName ? Visibility.Visible : Visibility.Collapsed;

        _knob.Refresh();
    }

    // ---- Front --------------------------------------------------------------

    private void BuildFront()
    {
        // The dark front, its left rack ear included.
        _s.Box(PanelShape.Rect(this.BrushOf("DarkChassisBrush")), 0.5, 0.5, 1, 1);
        _s.Box(PanelShape.Rect(this.BrushOf("DarkFrontBrush"), CanvasHeight * 0.03), 0.565, 0.5, 0.87, 0.96);

        // The main fader knob, large, at the left.
        _s.Put(_knob, 0.322, 0.483);

        // The touch screen: the fader level, which switches unit when tapped.
        _s.Box(PanelShape.Rect(this.BrushOf("ScreenBrush"), CanvasHeight * 0.03), 0.52, 0.48, 0.209, 0.558);
        _fader.Style = this.StyleOf("PlainButtonStyle");
        _fader.Foreground = this.BrushOf("LightTextBrush");
        _fader.FontWeight = FontWeights.Bold;
        _fader.HorizontalContentAlignment = HorizontalAlignment.Center;
        _fader.VerticalContentAlignment = VerticalAlignment.Center;
        _fader.Width = CanvasWidth * 0.15;
        _fader.Height = CanvasHeight * 0.1 * 1.6;
        _fader.Click += (_, _) => _controller.ToggleLevelUnit();
        _s.Put(_fader, 0.535, 0.36);

        // The macro rows, on the screen below the fader level.
        for (int index = 0; index < MacroRows; index++)
        {
            int row = index;
            Button button = new()
            {
                Style = this.StyleOf("PlainButtonStyle"),
                HorizontalContentAlignment = HorizontalAlignment.Left,
                VerticalContentAlignment = VerticalAlignment.Center,
                FontSize = CanvasHeight * 0.036,
                Width = CanvasWidth * 0.19,
                Height = CanvasHeight * 0.036 * 1.6,
            };
            button.Click += (_, _) => SelectRow(row);
            _macroRows.Add(button);
            _s.Put(button, 0.52, 0.45 + 0.042 * index);
        }

        // The speaker icon: the soft button that mutes.
        _mute.Style = this.StyleOf("PlainButtonStyle");
        _mute.FontFamily = new FontFamily(PanelText.GlyphFont);
        _mute.FontSize = CanvasHeight * 0.07;
        _mute.HorizontalContentAlignment = HorizontalAlignment.Center;
        _mute.VerticalContentAlignment = VerticalAlignment.Center;
        _mute.Width = CanvasHeight * 0.1;
        _mute.Height = CanvasHeight * 0.1;
        _mute.Click += (_, _) => _controller.ToggleMute();
        _s.Put(_mute, 0.44, 0.36);

        // The vertical status LEDs (drawn only), the booth monitor knob and its grille.
        _s.Box(PanelShape.Rect(this.BrushOf("LedBrush"), 1), 0.66, 0.5, 0.005, 0.72);
        _s.Disc(new Ellipse { Fill = this.BrushOf("KnobBrush"), Stretch = Stretch.Fill }, 0.70, 0.48, 0.165);
        BuildGrille(0.85, 0.52, 0.199, 0.579);

        // The Dolby mark, bottom left.
        _s.Label("DOLBY", 0.27, 0.85, 0.1, 0.12, FontWeights.Heavy, false, this.BrushOf("SilverTextBrush"));
    }

    /// <summary>The speaker grille: a field of small dots, drawn as one geometry.</summary>
    private void BuildGrille(double x, double y, double dw, double dh)
    {
        double width = CanvasWidth * dw;
        double height = CanvasHeight * dh;
        double pitch = height / GrilleRows;
        double radius = pitch * GrilleDotFraction;
        int columns = (int)(width / pitch);
        var dots = new GeometryGroup();
        for (int row = 0; row < GrilleRows; row++)
        {
            for (int column = 0; column < columns; column++)
            {
                dots.Children.Add(new EllipseGeometry(
                    new Point(column * pitch + pitch / 2, row * pitch + pitch / 2), radius, radius));
            }
        }

        _s.Box(PanelShape.Rect(this.BrushOf("GrilleBrush")), x, y, dw, dh);
        _s.Box(new System.Windows.Shapes.Path
        {
            Data = dots,
            Fill = this.BrushOf("GrilleDotBrush"),
            Stretch = Stretch.None,
        }, x, y, dw, dh);
    }

    private void SelectRow(int row)
    {
        IReadOnlyList<RemoteController.Macro>? macros = _controller.Macros;
        if (macros is not null && row < macros.Count)
        {
            _controller.SelectMacro(macros[row].Number);
        }
    }
}

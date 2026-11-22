using System.Globalization;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using CPRemote.Core;

namespace CPRemote.Windows;

/// <summary>
/// The CP850 front, drawn after Dolby's product photos of it (no front-panel
/// figure in the manuals). Live: the fader knob, the mute key, the LCD's fader
/// line (tapped, it switches unit), and the eight macro keys. The navigation
/// cross, the power key and the menu lines are drawn only.
/// </summary>
public partial class Cp850Panel : UserControl, IFrontPanel
{
    // The canvas is drawn in units of the panel's height; its width follows the aspect.
    private const double CanvasHeight = 1000;

    // The CP850 front is a 2U, 19-inch panel: 483 by 89 units.
    public double Aspect { get; } = 483.0 / 89;

    private const int MacroKeyCount = 8;
    private const double MacroKeyFirstX = 0.648;
    private const double MacroKeySpacing = 0.0315;

    private readonly RemoteController _controller;
    private readonly FractionStage _s;
    private readonly FaderKnob _knob;
    private readonly Button _mute = new();
    private readonly Button _fader = new();
    private readonly TextBlock _macroLine;
    private readonly List<Button> _macroKeys = [];

    public Cp850Panel(RemoteController controller)
    {
        InitializeComponent();
        _controller = controller;
        _s = new FractionStage(Stage, CanvasWidth, CanvasHeight);
        _knob = new FaderKnob(controller, CanvasHeight * 0.5);
        BuildFront();
        _macroLine = LcdLine(string.Empty, 1);
        Refresh();
    }

    private double CanvasWidth => CanvasHeight * Aspect;

    public void Refresh()
    {
        bool connected = _controller.IsConnected;

        bool muted = _controller.Muted;
        _mute.IsEnabled = connected;
        _mute.Foreground = muted ? this.BrushOf("LampRedBrush") : this.BrushOf("LightTextBrush");
        AutomationProperties.SetName(_mute, muted ? "Unmute" : "Mute");

        string level = _controller.LevelTextWithUnit;
        _fader.Content = "Fader: " + level;
        AutomationProperties.SetName(_fader, $"Fader {level}");
        _macroLine.Text = _controller.MacroName is { } macro ? " " + macro : string.Empty;

        int? preset = _controller.MacroPreset;
        IReadOnlyList<RemoteController.Macro>? macros = _controller.Macros;
        for (int index = 0; index < _macroKeys.Count; index++)
        {
            int number = index + 1;
            Button button = _macroKeys[index];
            bool selected = preset == number;
            string? name = macros?.FirstOrDefault(m => m.Number == number)?.Name;
            button.IsEnabled = connected;
            button.Foreground = selected ? this.BrushOf("BlueBrush") : this.BrushOf("LightTextBrush");
            AutomationProperties.SetName(button,
                $"Macro key {number}{(name is null ? string.Empty : ": " + name)}{(selected ? ", selected" : string.Empty)}");
        }

        _knob.Refresh();
    }

    // ---- Front --------------------------------------------------------------

    private void BuildFront()
    {
        // The rack ears and the black front.
        _s.Box(PanelShape.Rect(this.BrushOf("BlackChassisBrush")), 0.5, 0.5, 1, 1);
        _s.Box(PanelShape.Rect(this.BrushOf("BlackFrontBrush"), CanvasHeight * 0.03), 0.5, 0.5, 0.9, 0.98);

        // The left block: the Dolby mark, the fader knob, the mute key, and the blue light strip.
        _s.Label("DOLBY", 0.17, 0.17, 0.12, 0.12, FontWeights.Heavy, false, this.BrushOf("SilverTextBrush"));
        _s.Put(_knob, 0.165, 0.52);
        _mute.Style = this.StyleOf("DarkKeyStyle");
        _mute.Width = CanvasHeight * 0.13;
        _mute.Height = CanvasHeight * 0.13;
        _mute.Content = PanelText.MuteGlyph;
        _mute.FontFamily = new FontFamily(PanelText.GlyphFont);
        _mute.FontSize = 42;
        _mute.Click += (_, _) => _controller.ToggleMute();
        _s.Put(_mute, 0.262, 0.52);
        _s.Box(PanelShape.Rect(this.BrushOf("BlueBrush"), 1), 0.312, 0.5, 0.004, 0.94);

        // The brushed aluminium inlay and the four-line LCD on it.
        _s.Box(PanelShape.Rect(this.BrushOf("InlayBrush"), CanvasHeight * 0.22), 0.655, 0.49, 0.62, 0.44);
        _s.Box(PanelShape.Rect(this.BrushOf("CalcLcdBrush"), CanvasHeight * 0.02), 0.435, 0.49, 0.175, 0.33);
        _fader.Style = this.StyleOf("PlainButtonStyle");
        _fader.Foreground = this.BrushOf("CalcTextBrush");
        _fader.FontFamily = new FontFamily("Consolas");
        _fader.FontSize = CanvasHeight * 0.074;
        _fader.FontWeight = FontWeights.Medium;
        _fader.HorizontalContentAlignment = HorizontalAlignment.Left;
        _fader.VerticalContentAlignment = VerticalAlignment.Center;
        _fader.Width = CanvasWidth * 0.165;
        _fader.Height = CanvasHeight * 0.074 * 1.6;
        _fader.Click += (_, _) => _controller.ToggleLevelUnit();
        _s.Put(_fader, 0.435, 0.375);
        LcdLine(PanelText.Symbol(0x22A0) + "Macros  " + PanelText.Symbol(0x25A1) + "Network", 2);
        LcdLine(PanelText.Symbol(0x25A1) + "Messages " + PanelText.Symbol(0x25A1) + "Options", 3);

        // The navigation cross (drawn only).
        double navKey = CanvasHeight * 0.11;
        DrawKey(navKey, PanelText.ChevronUpGlyph, 0.565, 0.33);
        DrawKey(navKey, PanelText.ChevronLeftGlyph, 0.54, 0.49);
        DrawKey(navKey, PanelText.Symbol(0x25CF), 0.565, 0.49);
        DrawKey(navKey, PanelText.ChevronRightGlyph, 0.59, 0.49);
        DrawKey(navKey, PanelText.UndoGlyph, 0.54, 0.65);
        DrawKey(navKey, PanelText.ChevronDownGlyph, 0.565, 0.65);

        // The eight macro keys: key n sends sys.macro_preset n, as mapped in the macro editor.
        double macroKey = CanvasHeight * 0.12;
        for (int index = 0; index < MacroKeyCount; index++)
        {
            int number = index + 1;
            Button button = this.KeyOf("DarkKeyStyle", macroKey);
            button.Content = number.ToString(CultureInfo.InvariantCulture);
            button.FontSize = 45;
            button.Click += (_, _) => _controller.SelectMacro(number);
            _macroKeys.Add(button);
            _s.Put(button, MacroKeyFirstX + MacroKeySpacing * index, 0.49);
        }

        // The power key, at the right end (drawn only), and the product name.
        DrawKey(CanvasHeight * 0.12, PanelText.PowerGlyph, 0.93, 0.49);
        _s.Label("Dolby Atmos Cinema Processor CP850", 0.82, 0.86, 0.075, 0.3, FontWeights.Medium, true,
            this.BrushOf("LightTextBrush"));
    }

    /// <summary>A black key that does nothing: its glyph is drawn, not pressed.</summary>
    private void DrawKey(double diameter, string glyph, double x, double y)
    {
        _s.Put(Decoration.Key(diameter, this.BrushOf("DarkKeyBrush"), this.BrushOf("DarkKeyStrokeBrush"),
            diameter * 0.05, glyph, this.BrushOf("LightTextBrush"), diameter * 0.42, PanelText.GlyphFont), x, y);
    }

    /// <summary>One line of the LCD, in its monospaced dark lettering, at <paramref name="row"/>.</summary>
    private TextBlock LcdLine(string text, int row)
    {
        TextBlock block = PanelText.Block(text, CanvasHeight * 0.074, FontWeights.Medium, false,
            this.BrushOf("CalcTextBrush"), TextAlignment.Left, "Consolas");
        var box = new Grid { Width = CanvasWidth * 0.165, Height = CanvasHeight * 0.074 * 1.6, Children = { block } };
        _s.Put(box, 0.435, 0.375 + 0.077 * row);
        return block;
    }
}

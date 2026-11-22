using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using System.Windows.Threading;
using CPRemote.Core;

namespace CPRemote.Windows;

/// <summary>
/// The CP650's live front panel, drawn after figure 2-1 of the CP650 user's
/// manual: every element sits at the position and size it has in that drawing.
/// Live: the eight format buttons, the mute button, the level display, the main
/// fader knob and the front-panel LCD. Drawn only (no command is known for them):
/// the menu buttons, the power button and the P1/P2 lamps.
/// </summary>
public partial class Cp650Panel : UserControl, IFrontPanel
{
    // The panel's outline in figure 2-1, in the figure's own units.
    private const double FigureX = 112;
    private const double FigureY = 642;
    private const double FigureWidth = 956;
    private const double FigureHeight = 280;
    private const double KnobDiameter = 116;
    private const double FormatDiameter = 34;
    private const double MuteDiameter = 30;
    private const double DecorDiameter = 30;

    // The mute button flashes red while the processor is muted, as on the unit.
    private static readonly TimeSpan FlashInterval = TimeSpan.FromMilliseconds(500);

    private readonly RemoteController _controller;
    private readonly FigureStage _stage;
    private readonly FaderKnob _knob;
    private readonly List<Button> _formatButtons = [];
    private readonly Button _mute = new();
    private readonly Button _level = new();
    private readonly TextBlock _levelGhost = new();
    private readonly TextBlock _levelLive = new();
    private readonly TextBlock _lcdFormat = new();
    private readonly TextBlock _lcdName = new();
    private readonly DispatcherTimer _muteFlash = new() { Interval = FlashInterval };
    private bool _muteLit;

    public Cp650Panel(RemoteController controller)
    {
        InitializeComponent();
        _controller = controller;
        _stage = new FigureStage(Stage, FigureX, FigureY);
        _knob = new FaderKnob(controller, KnobDiameter);
        BuildBody();
        BuildDisplays();
        BuildControls();
        _muteFlash.Tick += OnMuteFlash;
        Unloaded += (_, _) => _muteFlash.Stop();
        Refresh();
    }

    public double Aspect { get; } = FigureWidth / FigureHeight;

    public void Refresh()
    {
        bool connected = _controller.IsConnected;

        string? format = _controller.CurrentFormat;
        _lcdFormat.Text = "Format " + (format ?? "--");
        _lcdName.Text = format is not null && RemoteController.FormatNames.TryGetValue(format, out string? name)
            ? name
            : string.Empty;

        for (int index = 0; index < _formatButtons.Count; index++)
        {
            Button button = _formatButtons[index];
            bool selected = _controller.FormatButton == index + 1;
            button.IsEnabled = connected;
            button.Tag = selected ? Brushes.White : null;
            AutomationProperties.SetName(button,
                $"Format button {RemoteController.ButtonSilkscreen[index]}{(selected ? ", selected" : string.Empty)}");
        }

        bool decibels = _controller.LevelInDecibels;
        _levelGhost.Text = decibels ? "-88.8" : "88.8";
        _levelGhost.FontSize = decibels ? 20 : 25;
        _levelLive.Text = _controller.LevelText;
        _levelLive.FontSize = decibels ? 20 : 25;
        AutomationProperties.SetName(_level, $"Fader level {_controller.LevelTextWithUnit}");

        _mute.IsEnabled = connected;
        UpdateMute();
        _knob.Refresh();
    }

    // ---- Body -------------------------------------------------------------

    private void BuildBody()
    {
        _stage.Box(PanelShape.Rect(this.BrushOf("BodyBrush"), 6), 112, 642, 1068, 922);

        // Ventilation louvres on both sides, drawn before the ears that cover their ends.
        for (int slat = 0; slat < 11; slat++)
        {
            double top = 652 + slat * 24.6;
            _stage.Box(PanelShape.Rect(this.BrushOf("LouvreBrush"), 2), 114, top, 262, top + 13);
            _stage.Box(PanelShape.Rect(this.BrushOf("LouvreBrush"), 2), 1030, top, 1066, top + 13);
        }

        // The black rack ears at both ends, each with two white slots.
        _stage.Box(PanelShape.Rect(Brushes.Black), 112, 642, 145, 922);
        _stage.Box(PanelShape.Rect(Brushes.Black), 1035, 642, 1068, 922);
        foreach (double slotX in new double[] { 120, 1043 })
        {
            foreach (double slotY in new double[] { 716, 846 })
            {
                _stage.Box(PanelShape.Rect(Brushes.White, 5.5), slotX, slotY, slotX + 17, slotY + 11);
            }
        }

        // The face between the louvres.
        _stage.Box(PanelShape.Rect(this.BrushOf("FaceBrush")), 262, 645, 1030, 920);

        // The header band in three parts, red as on the unit.
        _stage.Box(PanelShape.Rect(this.BrushOf("RedBandBrush")), 262, 655, 638, 688);
        _stage.Box(PanelShape.Rect(this.BrushOf("RedBandBrush")), 642, 655, 800, 688);
        _stage.Box(PanelShape.Rect(this.BrushOf("RedBandBrush")), 805, 655, 1030, 688);

        // The Dolby mark on the left and the model name on the right.
        _stage.Box(new Border
        {
            BorderBrush = Brushes.White,
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(1.5),
            Child = PanelText.Block("DOLBY", 9, FontWeights.Heavy, false, Brushes.White),
        }, 276, 664, 324, 680);
        _stage.Box(new StackPanel
        {
            Children =
            {
                PanelText.Block("CP650", 13, FontWeights.Heavy, true, this.BrushOf("HeaderTextBrush"),
                    TextAlignment.Right),
                PanelText.Block("Digital Cinema Processor", 10.5, FontWeights.SemiBold, true,
                    this.BrushOf("HeaderTextBrush"), TextAlignment.Right),
            },
        }, 802, 657, 1022, 688);

        // The section dividers on the face.
        _stage.Box(PanelShape.Rect(this.BrushOf("DividerBrush")), 638, 688, 642, 920);
        _stage.Box(PanelShape.Rect(this.BrushOf("DividerBrush")), 800, 688, 805, 920);

        // The setup door, drawn only.
        _stage.Box(new Rectangle
        {
            Fill = this.BrushOf("DoorBrush"),
            Stroke = this.BrushOf("DoorStrokeBrush"),
            StrokeThickness = 1,
            RadiusX = 4,
            RadiusY = 4,
            Stretch = Stretch.Fill,
        }, 272, 815, 628, 916);
    }

    // ---- Displays -----------------------------------------------------------

    private void BuildDisplays()
    {
        // The front-panel LCD: a grey bezel and a green screen with the format number and its name.
        _stage.Box(PanelShape.Rect(this.BrushOf("LcdBezelBrush"), 5), 308, 690, 560, 750);
        var lines = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        foreach (TextBlock line in new[] { _lcdFormat, _lcdName })
        {
            line.FontFamily = new FontFamily("Consolas");
            line.FontSize = 10;
            line.FontWeight = FontWeights.Medium;
            line.Foreground = this.BrushOf("LcdTextBrush");
            line.TextWrapping = TextWrapping.NoWrap;
            line.TextTrimming = TextTrimming.CharacterEllipsis;
            lines.Children.Add(line);
        }

        _stage.Box(new Border
        {
            Background = this.BrushOf("LcdBrush"),
            CornerRadius = new CornerRadius(2),
            Padding = new Thickness(5, 0, 5, 0),
            Child = lines,
        }, 359, 695, 509, 745);

        // The fader level is a button: a tap switches between the fader number and decibels.
        _level.Style = this.StyleOf("PlainButtonStyle");
        _level.Background = this.BrushOf("DisplayBrush");
        _level.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        _level.Click += (_, _) => _controller.ToggleLevelUnit();
        var face = new Grid();
        foreach (TextBlock digits in new[] { _levelGhost, _levelLive })
        {
            digits.FontFamily = new FontFamily("Consolas");
            digits.FontWeight = FontWeights.Bold;
            digits.HorizontalAlignment = HorizontalAlignment.Right;
            digits.VerticalAlignment = VerticalAlignment.Center;
            digits.Margin = new Thickness(0, 0, 6, 0);
            face.Children.Add(digits);
        }

        _levelGhost.Foreground = this.BrushOf("DisplayGhostBrush");
        _levelLive.Foreground = this.BrushOf("DisplayLiveBrush");
        _levelLive.Effect = new DropShadowEffect { Color = Colors.Red, BlurRadius = 3, ShadowDepth = 0, Opacity = 1 };
        _level.Content = face;
        _stage.Box(_level, 683, 696, 768, 746);

        // The projector lamps (drawn only): P1, the power symbol, P2.
        var lamps = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                PanelText.Block("P1", 9, FontWeights.Bold, false, this.BrushOf("PrintBrush")),
                PanelText.Block(PanelText.PowerGlyph, 9, FontWeights.Bold, false, this.BrushOf("PrintBrush"),
                    fontFamily: PanelText.GlyphFont),
                PanelText.Block("P2", 9, FontWeights.Bold, false, this.BrushOf("PrintBrush")),
            },
        };
        _stage.Box(lamps, 692, 751, 752, 765);

        // The knob's recess, then the knob itself.
        _stage.Box(new Ellipse
        {
            Fill = this.BrushOf("CradleBrush"),
            Stroke = this.BrushOf("CradleStrokeBrush"),
            StrokeThickness = 1.5,
            Stretch = Stretch.Fill,
        }, 639, 747, 789, 897);
        _stage.Centre(_knob, 714, 822);

        AddSectionLabel("menu", 368, 496, 432, 767);
        AddSectionLabel("mute", 602, 602, 602, 767);
        AddSectionLabel("format", 840, 997, 918, 750);
    }

    /// <summary>
    /// Adds a section name centred on (x, y). Its rule runs from
    /// <paramref name="lineFrom"/> to <paramref name="lineTo"/>; there is none when they are equal.
    /// </summary>
    private void AddSectionLabel(string text, double lineFrom, double lineTo, double x, double y)
    {
        var label = new SectionLabel(text, lineTo > lineFrom)
        {
            Width = Math.Max(lineTo - lineFrom, 40),
            Height = 12,
        };
        _stage.Centre(label, x, y);
    }

    // ---- Controls -----------------------------------------------------------

    private void BuildControls()
    {
        // The format buttons: two rows of four, numbered 1 to 8 on the panel.
        double[] columns = { 838, 891, 944, 997 };
        for (int index = 0; index < 8; index++)
        {
            int number = index + 1;
            var button = this.KeyOf("KeycapStyle", FormatDiameter);
            button.Content = RemoteController.ButtonSilkscreen[index];
            button.FontSize = KeyUnits.Of(FormatDiameter, 10);
            button.Click += (_, _) => _controller.PressButton(number);
            _formatButtons.Add(button);
            _stage.Centre(button, columns[index % 4], index < 4 ? 724 : 777);
        }

        // The mute button: a speaker with a slash, lit red and flashing while muted.
        _mute.Style = this.StyleOf("KeycapStyle");
        _mute.Width = MuteDiameter;
        _mute.Height = MuteDiameter;
        _mute.Content = PanelText.MuteGlyph;
        _mute.FontFamily = new FontFamily(PanelText.GlyphFont);
        _mute.FontSize = KeyUnits.Of(MuteDiameter, 11);
        _mute.FontWeight = FontWeights.Normal;
        _mute.FontStyle = FontStyles.Normal;
        _mute.Click += (_, _) => _controller.ToggleMute();
        _stage.Centre(_mute, 602, 790);

        // The menu keys and the OK key (drawn only).
        AddDecoration(380, PanelText.EditGlyph, PanelText.GlyphFont, 11);
        AddDecoration(432, PanelText.ListGlyph, PanelText.GlyphFont, 11);
        AddDecoration(484, "OK", "Segoe UI", 10);
    }

    private void AddDecoration(double x, string glyph, string fontFamily, double glyphSize)
    {
        Viewbox key = Decoration.Key(DecorDiameter, this.BrushOf("KeycapBrush"), Brushes.Black, 2.4,
            glyph, this.BrushOf("PrintBrush"), glyphSize, fontFamily);
        _stage.Centre(key, x, 790);
    }

    private void OnMuteFlash(object? sender, EventArgs e)
    {
        _muteLit = !_muteLit;
        ApplyMuteFace();
    }

    private void UpdateMute()
    {
        bool muted = _controller.Muted;
        if (muted && !_muteFlash.IsEnabled)
        {
            _muteLit = true;
            _muteFlash.Start();
        }
        else if (!muted && _muteFlash.IsEnabled)
        {
            _muteFlash.Stop();
            _muteLit = false;
        }

        ApplyMuteFace();
        AutomationProperties.SetName(_mute, $"Mute, {(muted ? "on" : "off")}");
    }

    private void ApplyMuteFace()
    {
        bool lit = _controller.Muted && _muteLit;
        _mute.Tag = lit ? this.BrushOf("LampRedBrush") : null;
        _mute.Foreground = lit ? Brushes.White : this.BrushOf("PrintBrush");
    }
}

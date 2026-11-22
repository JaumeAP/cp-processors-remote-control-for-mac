using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using CPRemote.Core;

namespace CPRemote.Windows;

/// <summary>
/// The CP750 front, drawn after figure 1-1 of the CP750 manual; each element sits
/// where the figure puts it, as a fraction of the panel's width and height.
/// Live: the seven input keys, the mute key, the fader knob and the display (the
/// fader level, which switches unit when tapped, and the input's name). The
/// Valid lamps, the Dolby badge and the USB port are drawn only.
/// </summary>
public partial class Cp750Panel : UserControl, IFrontPanel
{
    // The canvas is drawn in units of the panel's height; its width follows the aspect.
    private const double CanvasHeight = 1000;

    // The CP750 manual's figure, for the aspect (935 by 180 units).
    public double Aspect { get; } = 935.0 / 180;

    private static readonly string[] InputNames =
        { "Digital 1", "Digital 2", "Digital 3", "Digital 4", "Multi-Ch Analog", "NonSync", "Mic" };

    // The engraved names above the input keys; a line break sets the name on two lines, as on the panel.
    private static readonly string[] InputLabels =
        { "Digital\n1", "Digital\n2", "Digital\n3", "Digital\n4", "Multi-Ch\nAnalog", "\nNonSync", "\nMic" };

    private static readonly double[] InputX = { 0.643, 0.685, 0.722, 0.763, 0.802, 0.843, 0.883 };
    private static readonly double[] LampX = { 0.643, 0.684, 0.725, 0.763 };

    private readonly RemoteController _controller;
    private readonly FractionStage _s;
    private readonly FaderKnob _knob;
    private readonly List<Button> _inputKeys = [];
    private readonly Button _mute = new();
    private readonly Button _volume = new();
    private readonly TextBlock _inputName;

    public Cp750Panel(RemoteController controller)
    {
        InitializeComponent();
        _controller = controller;
        _s = new FractionStage(Stage, CanvasWidth, CanvasHeight);
        _knob = new FaderKnob(controller, CanvasHeight * 0.53);
        BuildFront();
        _inputName = _s.Label(string.Empty, 0.28, 0.6, 0.07, 0.12, FontWeights.Normal, false,
            this.BrushOf("MidTextBrush"));
        Refresh();
    }

    private double CanvasWidth => CanvasHeight * Aspect;

    public void Refresh()
    {
        bool connected = _controller.IsConnected;
        int? selected = _controller.FormatButton;
        for (int index = 0; index < _inputKeys.Count; index++)
        {
            Button key = _inputKeys[index];
            bool lit = selected == index + 1;
            key.IsEnabled = connected;
            key.Tag = lit ? Brushes.White : null;
            AutomationProperties.SetName(key, $"Input {InputNames[index]}{(lit ? ", selected" : string.Empty)}");
        }

        bool muted = _controller.Muted;
        _mute.IsEnabled = connected;
        _mute.Tag = muted ? this.BrushOf("LampRedBrush") : null;
        AutomationProperties.SetName(_mute, muted ? "Unmute" : "Mute");

        string level = _controller.LevelTextWithUnit;
        _volume.Content = "Volume " + level;
        AutomationProperties.SetName(_volume, "Volume " + level);
        _inputName.Text = _controller.CurrentInputName;
        _knob.Refresh();
    }

    // ---- Front --------------------------------------------------------------

    private void BuildFront()
    {
        // The rack ears and the grey front.
        _s.Box(PanelShape.Rect(this.BrushOf("ChassisBrush")), 0.5, 0.5, 1, 1);
        _s.Box(PanelShape.Rect(this.BrushOf("Cp750FrontBrush"), CanvasHeight * 0.04), 0.5, 0.5, 0.86, 0.9);

        // The red Dolby badge, top right, with the model name.
        _s.Box(PanelShape.Rect(this.BrushOf("DolbyRedBrush"), CanvasHeight * 0.03), 0.8, 0.09, 0.27, 0.2);
        _s.Label("DOLBY", 0.76, 0.09, 0.11, 0.12, FontWeights.Heavy, false, Brushes.White);
        _s.Label("CP750", 0.85, 0.13, 0.1, 0.12, FontWeights.Heavy, true, Brushes.White);
        _s.Label("Input Select", 0.763, 0.86, 0.06, 0.2, FontWeights.SemiBold, false,
            this.BrushOf("InputLabelBrush"));

        // The seven input-select keys, each with its name above; the selected one lights.
        for (int index = 0; index < InputNames.Length; index++)
        {
            int number = index + 1;
            Button key = this.KeyOf("KeycapStyle", CanvasHeight * 0.133);
            key.Click += (_, _) => _controller.PressButton(number);
            AutomationProperties.SetName(key, $"Input {InputNames[index]}");
            _inputKeys.Add(key);
            _s.Put(key, InputX[index], 0.5);
            _s.Label(InputLabels[index], InputX[index], 0.31, 0.05, 0.038, FontWeights.Bold, false,
                this.BrushOf("InputLabelBrush"));
        }

        // The four Valid lamps under the inputs (drawn only).
        foreach (double lampX in LampX)
        {
            _s.Disc(new Ellipse { Fill = this.BrushOf("LampBrush"), Stretch = Stretch.Fill }, lampX, 0.69, 0.044);
        }

        // The menu keys and the check key (drawn only), the mute key (live) and the USB port.
        _s.Disc(new Ellipse { Fill = this.BrushOf("KeycapBrush"), Stretch = Stretch.Fill }, 0.19, 0.2, 0.122);
        _s.Disc(new Ellipse { Fill = this.BrushOf("KeycapBrush"), Stretch = Stretch.Fill }, 0.19, 0.68, 0.122);
        _mute.Style = this.StyleOf("KeycapStyle");
        _mute.Width = CanvasHeight * 0.122;
        _mute.Height = CanvasHeight * 0.122;
        _mute.Click += (_, _) => _controller.ToggleMute();
        _s.Put(_mute, 0.39, 0.68);
        _s.Box(PanelShape.Rect(this.BrushOf("UsbBrush"), 2), 0.55, 0.69, 0.025, 0.12);

        // The display: the fader level, which switches unit when tapped.
        _s.Disc(new Ellipse { Fill = this.BrushOf("DeepDisplayBrush"), Stretch = Stretch.Fill }, 0.28, 0.53, 0.72);
        _volume.Style = this.StyleOf("PlainButtonStyle");
        _volume.Foreground = this.BrushOf("DimTextBrush");
        _volume.FontWeight = FontWeights.Normal;
        _volume.FontSize = CanvasHeight * 0.1;
        _volume.HorizontalContentAlignment = HorizontalAlignment.Center;
        _volume.VerticalContentAlignment = VerticalAlignment.Center;
        _volume.Width = CanvasWidth * 0.15;
        _volume.Height = CanvasHeight * 0.1 * 1.6;
        _volume.Click += (_, _) => _controller.ToggleLevelUnit();
        _s.Put(_volume, 0.28, 0.5);

        // The main fader knob, to the right of the display.
        _s.Put(_knob, 0.46, 0.44);
    }
}

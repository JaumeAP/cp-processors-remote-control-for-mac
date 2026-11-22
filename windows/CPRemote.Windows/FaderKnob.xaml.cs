using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using CPRemote.Core;

namespace CPRemote.Windows;

/// <summary>
/// The main fader knob: an endless encoder with a finger dimple that turns with
/// it. Dragged, it follows the pointer round its centre. The mouse wheel and the
/// arrow keys step it. Each turn is the same call sequence as the macOS app:
/// BeginKnobTurn, then TurnKnob for each move, then EndKnobTurn.
/// </summary>
public partial class FaderKnob : UserControl
{
    // One notch of a mouse wheel is 120 units of wheel delta.
    private const double WheelDeltaPerNotch = 120;

    // One arrow key or wheel step, as the macOS app's stepKnob: a tenth of a fader unit.
    private const double StepUnits = 0.1;

    private const double DisabledOpacity = 0.4;

    private readonly RemoteController _controller;
    private bool _dragging;
    private double? _angle;

    /// <param name="controller">The model the knob turns.</param>
    /// <param name="diameter">The knob's diameter, in the units of the panel it sits on.</param>
    public FaderKnob(RemoteController controller, double diameter)
    {
        InitializeComponent();
        _controller = controller;
        Width = diameter;
        Height = diameter;
    }

    /// <summary>Shows the knob's rotation, and whether it takes input.</summary>
    public void Refresh()
    {
        bool connected = _controller.IsConnected;
        SpinTransform.Angle = _controller.KnobRotation;
        IsEnabled = connected;
        Opacity = connected ? 1 : DisabledOpacity;
        if (!connected)
        {
            EndDrag();
        }
    }

    protected override void OnMouseLeftButtonDown(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonDown(e);
        Focus();
        CaptureMouse();
        _dragging = true;
        _angle = null;
        Turn(e.GetPosition(this));
        e.Handled = true;
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_dragging)
        {
            Turn(e.GetPosition(this));
        }
    }

    protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e)
    {
        base.OnMouseLeftButtonUp(e);
        EndDrag();
    }

    // A drag can end without a button release (the capture is lost), so the turn ends here too.
    protected override void OnLostMouseCapture(MouseEventArgs e)
    {
        base.OnLostMouseCapture(e);
        EndDrag();
    }

    protected override void OnMouseWheel(MouseWheelEventArgs e)
    {
        base.OnMouseWheel(e);
        if (!IsEnabled || e.Delta == 0)
        {
            return;
        }

        // A notch is one step. A turn already under way (a drag) keeps its own sequence.
        bool alone = !_controller.IsTurningKnob;
        if (alone)
        {
            _controller.BeginKnobTurn();
        }

        _controller.TurnKnob(e.Delta / WheelDeltaPerNotch * StepUnits * RemoteController.DegreesPerUnit);
        if (alone)
        {
            _controller.EndKnobTurn();
        }

        e.Handled = true;
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);
        switch (e.Key)
        {
            case Key.Up:
            case Key.Right:
                _controller.StepKnob(up: true);
                e.Handled = true;
                break;
            case Key.Down:
            case Key.Left:
                _controller.StepKnob(up: false);
                e.Handled = true;
                break;
        }
    }

    /// <summary>
    /// Turns the knob by the pointer's movement round its centre. Near the centre
    /// the angle means nothing, so the anchor is dropped there and set again past
    /// it: crossing the centre never reads as half a turn.
    /// </summary>
    private void Turn(Point position)
    {
        double side = Width;
        double dx = position.X - side / 2;
        double dy = position.Y - side / 2;
        if (dx * dx + dy * dy <= side * side * 0.01)
        {
            _angle = null;
            return;
        }

        double pointer = Math.Atan2(dy, dx) * 180 / Math.PI;
        if (_angle is double last)
        {
            double delta = pointer - last;
            if (delta > 180)
            {
                delta -= 360;
            }

            if (delta < -180)
            {
                delta += 360;
            }

            _controller.TurnKnob(delta);
        }
        else if (!_controller.IsTurningKnob)
        {
            _controller.BeginKnobTurn();
        }

        _angle = pointer;
    }

    private void EndDrag()
    {
        if (!_dragging)
        {
            return;
        }

        _dragging = false;
        _angle = null;
        if (IsMouseCaptured)
        {
            ReleaseMouseCapture();
        }

        _controller.EndKnobTurn();
    }
}

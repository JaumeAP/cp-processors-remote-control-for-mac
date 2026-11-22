namespace CPRemote.Windows;

/// <summary>
/// A front panel of one processor model. It shows the controller's state and
/// sends the user's presses to the controller; it holds no rules of its own.
/// </summary>
public interface IFrontPanel
{
    /// <summary>Width over height of the panel, as the manual draws it.</summary>
    double Aspect { get; }

    /// <summary>Shows the controller's current state. Runs on the UI thread.</summary>
    void Refresh();
}

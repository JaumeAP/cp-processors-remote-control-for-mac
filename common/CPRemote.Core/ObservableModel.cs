using System.ComponentModel;
using System.Runtime.CompilerServices;

namespace CPRemote.Core;

/// <summary>
/// Base for the models the UI binds to. Change notifications go through
/// <c>dispatch</c>, so the UI can marshal them onto its own thread; the
/// default runs them where the change happened.
/// </summary>
public abstract class ObservableModel : INotifyPropertyChanged
{
    private readonly Action<Action> _dispatch;

    protected ObservableModel(Action<Action>? dispatch = null)
    {
        _dispatch = dispatch ?? (action => action());
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Stores <paramref name="value"/> and notifies when it changed.</summary>
    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
        {
            return false;
        }

        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null)
    {
        PropertyChangedEventHandler? handler = PropertyChanged;
        if (handler is null || name is null)
        {
            return;
        }

        _dispatch(() => handler(this, new PropertyChangedEventArgs(name)));
    }
}

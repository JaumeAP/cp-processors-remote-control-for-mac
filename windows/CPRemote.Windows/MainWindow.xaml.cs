using System.ComponentModel;
using System.Windows;
using CPRemote.Core;
using CPRemote.Core.Model;

namespace CPRemote.Windows;

/// <summary>
/// The window: the front panel of the chosen processor, a Level menu and a Setup
/// menu. It shows the state of a <see cref="RemoteController"/> and sends the
/// user's presses to it. Like the macOS app, it connects when it opens, and it
/// opens Setup when no address is saved yet.
/// </summary>
[System.Diagnostics.CodeAnalysis.SuppressMessage(
    "Design", "CA1001:Types that own disposable fields should be disposable",
    Justification = "The controller is disposed when the window closes (see the Closed handler).")]
public partial class MainWindow : Window
{
    private readonly RemoteController _controller;
    private IFrontPanel? _panel;
    private bool _setupOpen;

    public MainWindow()
    {
        InitializeComponent();

        // Settings are read at start and written whenever the address, the model or the level unit changes.
        string settingsPath = SettingsFile.DefaultPath;
        Dictionary<string, string> settings = SettingsFile.Load(settingsPath);
        _controller = new RemoteController(
            settings,
            log: ConnectionLog.Shared,
            announce: text => Dispatch(() => StatusText.Text = text),
            dispatch: Dispatch);
        _controller.SettingsChanged += (_, _) => _ = SettingsFile.Save(settingsPath, settings);
        _controller.PropertyChanged += OnControllerChanged;

        ShowPanel();
        Loaded += OnLoaded;
        Closed += (_, _) => _controller.Dispose();
    }

    /// <summary>Runs an action on the UI thread, where the controller's notifications are raised.</summary>
    private void Dispatch(Action action) => Dispatcher.BeginInvoke(action);

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        UpdatePanelHeight();
        await _controller.ConnectAsync();
    }

    private void OnControllerChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(RemoteController.Model))
        {
            ShowPanel();
        }
        else if (e.PropertyName == nameof(RemoteController.ShowSetup) && _controller.ShowSetup)
        {
            OpenSetup();
        }

        Refresh();
    }

    /// <summary>Shows the front panel of the chosen model, in place of the one shown.</summary>
    private void ShowPanel()
    {
        _panel = _controller.Model switch
        {
            ProcessorModel.Cp750 => new Cp750Panel(_controller),
            ProcessorModel.Cp850 => new Cp850Panel(_controller),
            ProcessorModel.Cp950 or ProcessorModel.Cp950A => new Cp950Panel(_controller),
            _ => new Cp650Panel(_controller),
        };
        PanelHost.Content = _panel;
        UpdatePanelHeight();
        Refresh();
    }

    /// <summary>Keeps the panel in its own proportions as the window's width changes.</summary>
    private void UpdatePanelHeight()
    {
        if (_panel is not null && PanelHost.ActualWidth > 0)
        {
            PanelHost.Height = PanelHost.ActualWidth / _panel.Aspect;
        }
    }

    private void PanelHost_SizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (_panel is not null && e.WidthChanged)
        {
            PanelHost.Height = e.NewSize.Width / _panel.Aspect;
        }
    }

    /// <summary>Opens the Setup dialog, once at a time; the controller's ShowSetup flag is cleared when it closes.</summary>
    private void OpenSetup()
    {
        if (_setupOpen)
        {
            return;
        }

        _setupOpen = true;
        try
        {
            _ = new SetupWindow(_controller) { Owner = this }.ShowDialog();
        }
        finally
        {
            _setupOpen = false;
            _controller.ShowSetup = false;
        }
    }

    /// <summary>Shows the controller's state in the panel and the menus.</summary>
    private void Refresh()
    {
        _panel?.Refresh();
        bool connected = _controller.IsConnected;
        LevelUpItem.IsEnabled = connected;
        LevelDownItem.IsEnabled = connected;
        ReferenceItem.IsEnabled = connected;
        DecibelsItem.IsChecked = _controller.LevelInDecibels;
    }

    private void LevelUp_Click(object sender, RoutedEventArgs e) => _controller.StepKnob(up: true);

    private void LevelDown_Click(object sender, RoutedEventArgs e) => _controller.StepKnob(up: false);

    private void Reference_Click(object sender, RoutedEventArgs e) => _controller.SetReference();

    private void Decibels_Click(object sender, RoutedEventArgs e) => _controller.ToggleLevelUnit();

    private void ProcessorIp_Click(object sender, RoutedEventArgs e) => _controller.ShowSetup = true;

    private async void Reconnect_Click(object sender, RoutedEventArgs e) => await _controller.ReconnectAsync();

    private async void Disconnect_Click(object sender, RoutedEventArgs e) => await _controller.DisconnectAsync();
}

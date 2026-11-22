using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using CPRemote.Core;
using CPRemote.Core.Model;

namespace CPRemote.Windows;

/// <summary>
/// The Setup dialog: the processor model and its IP address, and a Test button
/// that reports whether the processor chosen here answered at that address.
/// Saving stores the address and the model in the controller and reconnects.
/// </summary>
public partial class SetupWindow : Window
{
    private readonly RemoteController _controller;

    public SetupWindow(RemoteController controller)
    {
        InitializeComponent();
        _controller = controller;
        foreach (ProcessorModel model in RemoteController.Choices)
        {
            ModelBox.Items.Add(model.ChoiceName());
        }

        ModelBox.SelectedIndex = Math.Max(0, RemoteController.Choices.ToList().IndexOf(controller.Model));
        AddressBox.Text = controller.Host;
        ModelBox.SelectionChanged += (_, _) => UpdatePort();
        UpdatePort();
    }

    /// <summary>The model picked in the list, saved or not.</summary>
    private ProcessorModel SelectedChoice() => RemoteController.Choices[Math.Max(0, ModelBox.SelectedIndex)];

    private void UpdatePort() =>
        PortText.Text = "Port " + SelectedChoice().DefaultPort().ToString(CultureInfo.InvariantCulture);

    private async void TestButton_Click(object sender, RoutedEventArgs e)
    {
        TestButton.IsEnabled = false;
        TestProgress.Visibility = Visibility.Visible;
        TestResultText.Text = "Testing...";
        string result = await _controller.TestAsync(AddressBox.Text, SelectedChoice());
        TestResultText.Text = result;
        TestProgress.Visibility = Visibility.Collapsed;
        TestButton.IsEnabled = true;
    }

    private void SaveButton_Click(object sender, RoutedEventArgs e)
    {
        _controller.Host = AddressBox.Text.Trim();
        _controller.ChooseModel(SelectedChoice());
        Close();
        _ = _controller.ReconnectAsync();
    }
}

using CPRemote.Core;
using CPRemote.Core.Model;
using Xunit;
using Xunit.Abstractions;

namespace CPRemote.Core.Tests;

public sealed class RemoteControllerTests(ITestOutputHelper output)
{
    [Theory]
    [InlineData(7.0, false, "7.0")]
    [InlineData(10.0, false, "10.0")]
    [InlineData(7.0, true, "0.0")]
    [InlineData(0.0, true, "-90.0")]
    [InlineData(4.0, true, "-10.0")]
    [InlineData(10.0, true, "+10.0")]
    public void LevelText_shows_the_fader_number_or_the_decibels(double fader, bool decibels, string expected)
    {
        Assert.Equal(expected, RemoteController.LevelTextFor(fader, decibels));
    }

    [Theory]
    [InlineData("70", 7.0)]
    [InlineData("1000", 10.0)]
    [InlineData("-5", 0.0)]
    [InlineData("0", 0.0)]
    public void FaderLevel_reads_tenths_and_holds_the_range(string reply, double expected)
    {
        Assert.Equal(expected, RemoteController.FaderLevel(reply));
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("nan")]
    [InlineData("error")]
    public void FaderLevel_is_null_for_a_reply_that_is_not_a_number(string? reply)
    {
        Assert.Null(RemoteController.FaderLevel(reply));
    }

    [Fact]
    public void Decibels_follow_the_manual_scale()
    {
        Assert.Equal(-90, RemoteController.Decibels(0));
        Assert.Equal(-10, RemoteController.Decibels(4));
        Assert.Equal(0, RemoteController.Decibels(7));
        Assert.Equal(10, RemoteController.Decibels(10));
    }

    [Fact]
    public void Model_and_host_are_read_from_the_settings()
    {
        var settings = new Dictionary<string, string>
        {
            ["processorHost"] = "10.0.0.5",
            ["processorModel"] = "CP850",
            ["levelInDecibels"] = "true",
        };

        using var controller = new RemoteController(settings);

        Assert.Equal("10.0.0.5", controller.Host);
        Assert.Equal(ProcessorModel.Cp850, controller.Model);
        Assert.True(controller.LevelInDecibels);
    }

    [Fact]
    public void An_unknown_saved_model_falls_back_to_the_CP650()
    {
        using var controller = new RemoteController(new Dictionary<string, string> { ["processorModel"] = "CP999" });

        Assert.Equal(ProcessorModel.Cp650, controller.Model);
    }

    [Fact]
    public void Choosing_a_model_and_the_level_unit_are_remembered()
    {
        var settings = new Dictionary<string, string>();
        using var controller = new RemoteController(settings);

        controller.ChooseModel(ProcessorModel.Cp950);
        controller.ToggleLevelUnit();

        Assert.Equal("CP950", settings["processorModel"]);
        Assert.Equal("true", settings["levelInDecibels"]);
        Assert.True(controller.LevelInDecibels);
    }

    [Fact]
    public void Controls_stay_off_without_a_link()
    {
        using var controller = new RemoteController(new Dictionary<string, string>());

        controller.SetFader(5);
        controller.ToggleMute();
        controller.PressButton(1);

        Assert.False(controller.IsConnected);
        Assert.Equal(RemoteController.ReferenceLevel, controller.Fader);
        Assert.False(controller.Muted);
    }

    [Fact]
    public async Task Connecting_with_no_address_asks_for_setup()
    {
        using var controller = new RemoteController(new Dictionary<string, string>());

        await controller.ConnectAsync();

        Assert.True(controller.ShowSetup);
    }

    [SkippableFact]
    public async Task Against_the_simulator_the_panel_is_read_and_the_controls_reach_it()
    {
        using var simulator = CpSeriesClientTests.Simulator.Start(output, "CP750");
        var settings = new Dictionary<string, string>
        {
            ["processorHost"] = "127.0.0.1",
            ["processorModel"] = "CP750",
        };
        using var controller = new RemoteController(settings, port: (ushort)simulator.Port, reopenPauseSeconds: 0);

        await controller.ConnectAsync();
        Assert.True(await WaitUntilAsync(() => controller.PanelRead, TimeSpan.FromSeconds(15)), "the panel was not read");
        output.WriteLine($"fader read: {controller.Fader}, muted: {controller.Muted}");

        controller.SetFader(5.0);
        Assert.True(await WaitUntilAsync(() => controller.FaderIsSettled, TimeSpan.FromSeconds(10)), "the fader was not sent");

        // Two poll cycles later the controller must still show the level it sent: a stale reply must not overwrite it.
        await Task.Delay(TimeSpan.FromSeconds(5));
        Assert.Equal(5.0, controller.Fader);

        bool before = controller.Muted;
        controller.ToggleMute();
        Assert.NotEqual(before, controller.Muted);

        await controller.DisconnectAsync();
        Assert.False(controller.IsConnected);
    }

    private static async Task<bool> WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        DateTime deadline = DateTime.UtcNow + timeout;
        while (DateTime.UtcNow < deadline)
        {
            if (condition()) return true;
            await Task.Delay(50);
        }

        return condition();
    }
}

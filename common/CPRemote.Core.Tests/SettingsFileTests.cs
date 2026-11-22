using CPRemote.Core;
using Xunit;

namespace CPRemote.Core.Tests;

public sealed class SettingsFileTests : IDisposable
{
    private readonly string _folder = Path.Combine(Path.GetTempPath(), "cp-remote-settings-tests", Guid.NewGuid().ToString("N"));

    private string SettingsPath => Path.Combine(_folder, "settings.json");

    public void Dispose()
    {
        if (Directory.Exists(_folder))
        {
            Directory.Delete(_folder, recursive: true);
        }
    }

    [Fact]
    public void A_missing_file_gives_empty_settings()
    {
        Assert.Empty(SettingsFile.Load(SettingsPath));
    }

    [Fact]
    public void Saved_settings_are_read_back()
    {
        var settings = new Dictionary<string, string>
        {
            ["processorHost"] = "10.0.0.5",
            ["processorModel"] = "CP950",
            ["levelInDecibels"] = "true",
        };

        Assert.True(SettingsFile.Save(SettingsPath, settings));

        Assert.Equal(settings, SettingsFile.Load(SettingsPath));
    }

    [Fact]
    public void A_corrupt_file_gives_empty_settings_and_the_app_still_starts()
    {
        Directory.CreateDirectory(_folder);
        File.WriteAllText(SettingsPath, "{ not json");

        Assert.Empty(SettingsFile.Load(SettingsPath));
    }

    [Fact]
    public void Saving_replaces_the_previous_file()
    {
        SettingsFile.Save(SettingsPath, new Dictionary<string, string> { ["processorHost"] = "10.0.0.1" });
        SettingsFile.Save(SettingsPath, new Dictionary<string, string> { ["processorHost"] = "10.0.0.2" });

        Assert.Equal("10.0.0.2", SettingsFile.Load(SettingsPath)["processorHost"]);
        Assert.False(File.Exists(SettingsPath + ".tmp"));
    }
}

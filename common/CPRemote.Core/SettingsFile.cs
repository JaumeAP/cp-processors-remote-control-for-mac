using System.Text.Json;

namespace CPRemote.Core;

/// <summary>
/// The app's settings, kept as a JSON object of string values in
/// <c>%LOCALAPPDATA%\CP Remote\settings.json</c>. A missing or unreadable file
/// gives empty settings, so the app always starts.
/// </summary>
public static class SettingsFile
{
    /// <summary>The settings file of the running app.</summary>
    public static string DefaultPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CP Remote", "settings.json");

    /// <summary>Reads the settings at <paramref name="path"/>; empty when there are none or they cannot be read.</summary>
    public static Dictionary<string, string> Load(string path)
    {
        try
        {
            if (!File.Exists(path))
            {
                return [];
            }

            return JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(path)) ?? [];
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }
        catch (JsonException)
        {
            return [];
        }
    }

    /// <summary>
    /// Writes the settings to <paramref name="path"/> through a temporary file, so a
    /// failed write never leaves a half-written file. Returns false when the file cannot be written.
    /// </summary>
    public static bool Save(string path, IReadOnlyDictionary<string, string> settings)
    {
        try
        {
            string? directory = Path.GetDirectoryName(Path.GetFullPath(path));
            if (directory is not null)
            {
                Directory.CreateDirectory(directory);
            }

            string temporary = path + ".tmp";
            File.WriteAllText(temporary, JsonSerializer.Serialize(settings));
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (IOException)
        {
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            return false;
        }
    }
}

namespace CPRemote.Core.Model;

/// <summary>
/// The Dolby cinema processors CP Remote draws a front panel for. The wire
/// names and the TCP ports follow the manuals (61412 for the CP650, 61408 for
/// the others).
/// </summary>
public enum ProcessorModel
{
    Cp650,
    Cp750,
    Cp850,
    Cp950,
    Cp950A,
}

/// <summary>The parameter names one processor model uses on its front panel.</summary>
/// <param name="Fader">The fader parameter.</param>
/// <param name="Mute">The mute parameter.</param>
/// <param name="Inputs">
/// Input selection: the value each front button sends, in button order
/// (CP750 only); null when the model has no input buttons.
/// </param>
/// <param name="FaderMinimum">Lowest value the fader takes on the wire, in tenths (CP950: 1 to 100).</param>
/// <param name="MacroName">The parameter that names the selected macro, shown on the screen (CP850 / CP950 / CP950A).</param>
public sealed record PanelProfile(
    string Fader,
    string Mute,
    IReadOnlyList<string>? Inputs,
    int FaderMinimum,
    string? MacroName = null);

/// <summary>Helpers for <see cref="ProcessorModel"/>.</summary>
public static class ProcessorModels
{
    /// <summary>The model's name on the wire and in the library ("CP650", ..., "CP950A").</summary>
    public static string WireName(this ProcessorModel model) => model switch
    {
        ProcessorModel.Cp650 => "CP650",
        ProcessorModel.Cp750 => "CP750",
        ProcessorModel.Cp850 => "CP850",
        ProcessorModel.Cp950 => "CP950",
        ProcessorModel.Cp950A => "CP950A",
        _ => throw new ArgumentOutOfRangeException(nameof(model)),
    };

    /// <summary>The TCP port of the model's control channel.</summary>
    public static ushort DefaultPort(this ProcessorModel model) =>
        model == ProcessorModel.Cp650 ? (ushort)61412 : (ushort)61408;

    /// <summary>
    /// The name shown for a choice in Setup. The CP950 choice covers the
    /// CP950A (one front, one protocol).
    /// </summary>
    public static string ChoiceName(this ProcessorModel model) =>
        model == ProcessorModel.Cp950 ? "CP950 / CP950A" : model.WireName();

    /// <summary>The parameter names of the model's front panel, as its manual gives them.</summary>
    /// <remarks>
    /// CP650: <c>fader_level</c>, <c>mute</c>, <c>format_button</c>. CP750:
    /// <c>cp750.sys.fader</c>, <c>cp750.sys.mute</c>, <c>cp750.sys.input_mode</c>.
    /// CP850 / CP950 / CP950A: <c>sys.fader</c>, <c>sys.mute</c>, no input
    /// buttons; the macro is <c>sys.macro_preset</c>, named by <c>sys.macro_name</c>.
    /// </remarks>
    public static PanelProfile Panel(this ProcessorModel model) => model switch
    {
        ProcessorModel.Cp650 => new PanelProfile("fader_level", "mute", null, 0),
        ProcessorModel.Cp750 => new PanelProfile(
            "cp750.sys.fader",
            "cp750.sys.mute",
            ["dig_1", "dig_2", "dig_3", "dig_4", "analog", "non_sync", "mic"],
            0),
        _ => new PanelProfile("sys.fader", "sys.mute", null, 1, "sys.macro_name"),
    };

    /// <summary>Parses a wire name such as "CP750"; null for a name the app does not know.</summary>
    public static ProcessorModel? Parse(string? name) => name switch
    {
        "CP650" => ProcessorModel.Cp650,
        "CP750" => ProcessorModel.Cp750,
        "CP850" => ProcessorModel.Cp850,
        "CP950" => ProcessorModel.Cp950,
        "CP950A" => ProcessorModel.Cp950A,
        _ => null,
    };
}

using System.Diagnostics;
using System.Globalization;
using CPRemote.Core.Model;

namespace CPRemote.Core;

/// <summary>
/// The app's live state: one link to the processor at the configured address
/// (<see cref="ProcessorLink"/>, over the cpseries library), the fader level,
/// the selected front-panel button, the mute flag and the macro. A port of the
/// macOS app's RemoteModel; the rules that keep the panel honest (a control
/// changed here is shielded from stale poll replies, the controls stay off
/// until the panel is read on the current link, the CP650 reopen pause) are
/// kept as they are there.
/// </summary>
/// <remarks>
/// State changes happen under one lock, and no network call is made while it
/// is held. A call that awaits the network re-checks that its link is still the
/// current one afterwards, as the macOS app does on the main actor.
/// </remarks>
public sealed class RemoteController : ObservableModel, IDisposable
{
    /// <summary>The fader runs 0.0 to 10.0; the wire carries tenths (<c>70</c> is 7.0).</summary>
    public const double FaderMinimumValue = 0;
    public const double FaderMaximumValue = 10;

    /// <summary>The knob is an endless encoder: three full turns run the fader across its range.</summary>
    public const double DegreesPerUnit = 3 * 360 / (FaderMaximumValue - FaderMinimumValue);

    /// <summary>The Dolby reference level, fader 7.0 (0 dB).</summary>
    public const double ReferenceLevel = 7.0;

    /// <summary>The generic silkscreen on the eight format buttons; fixed, whatever formats are programmed.</summary>
    public static readonly IReadOnlyList<string> ButtonSilkscreen = ["01", "04", "05", "10", "11", "U1", "U2", "NS"];

    /// <summary>Names of the standard Dolby cinema formats; a number not listed has no name shown.</summary>
    public static readonly IReadOnlyDictionary<string, string> FormatNames = new Dictionary<string, string>
    {
        ["01"] = "Mono",
        ["04"] = "Dolby A-Type",
        ["05"] = "Dolby SR",
        ["10"] = "Dolby Digital",
        ["11"] = "External 6-channel",
        ["60"] = "Nonsync",
    };

    /// <summary>The models the Setup menu offers.</summary>
    public static readonly IReadOnlyList<ProcessorModel> Choices =
        [ProcessorModel.Cp650, ProcessorModel.Cp750, ProcessorModel.Cp850, ProcessorModel.Cp950];

    /// <summary>The CP650 takes one connection: seconds to wait after closing a session before the next one opens.</summary>
    public const double Cp650ReopenPauseSeconds = 2.0;

    public const string MacroPresetParam = "sys.macro_preset";
    public const string InputParam = "cp750.sys.input_mode";
    public const string FormatButtonParam = "format_button";

    internal const string HostKey = "processorHost";
    internal const string ModelKey = "processorModel";
    internal const string DecibelsKey = "levelInDecibels";

    // How long a control changed here is shielded from poll replies: a reply read
    // since shortly before the change may predate it on the processor.
    private static readonly long PollHoldOffTicks = (long)(1.5 * Stopwatch.Frequency);
    private static readonly TimeSpan PollInterval = TimeSpan.FromSeconds(2);
    private const int SilentPollLimit = 2;
    private const int MacroMissLimit = 2;
    private const int MacroPausePolls = 5;

    // When this app last closed a CP650 session to each address and port, shared
    // by every controller of the app.
    private static readonly Dictionary<string, long> Cp650Closes = [];
    private static readonly object ClosesLock = new();

    private readonly object _sync = new();
    private readonly SemaphoreSlim _lifecycle = new(1, 1);
    private readonly IDictionary<string, string> _settings;
    private readonly ushort? _port;
    private readonly double _reopenPauseSeconds;
    private readonly ConnectionLog? _log;
    private readonly Action<string>? _announce;

    private string _host = string.Empty;
    private bool _showSetup;
    private ProcessorModel _model;
    private double _fader = ReferenceLevel;
    private int? _formatButton;
    private IReadOnlyList<string>? _programmedFormats;
    private string? _macroName;
    private int? _macroPreset;
    private IReadOnlyList<Macro>? _macros;
    private bool _levelInDecibels;
    private bool _muted;
    private bool _panelRead;
    private double _knobRotation;

    private double? _knobValue;
    private ProcessorLink? _processor;
    private string? _processorHost;
    private bool _linkOpened;
    private CancellationTokenSource? _pollCancel;
    private int? _pendingFader;
    private bool _faderInFlight;
    private readonly Dictionary<string, long> _localChange = [];
    private readonly Dictionary<string, int> _sending = [];
    private bool _formatListDue = true;
    private int _silentPolls;
    private int _linkReopens;
    private bool _announcedConnected;
    private int _macroMisses;
    private int _macroPollsToSkip;
    private int? _macroNameNumber;

    /// <param name="settings">Where the address, the model and the level unit are kept. Read at construction, written as they change.</param>
    /// <param name="port">The TCP port; null: the model's own.</param>
    /// <param name="log">Where the app writes its events; null for none.</param>
    /// <param name="announce">Receives the connection-change announcements (the screen reader's live region).</param>
    /// <param name="dispatch">Runs the change notifications on the UI thread.</param>
    public RemoteController(
        IDictionary<string, string> settings,
        ushort? port = null,
        double reopenPauseSeconds = Cp650ReopenPauseSeconds,
        ConnectionLog? log = null,
        Action<string>? announce = null,
        Action<Action>? dispatch = null)
        : base(dispatch)
    {
        _settings = settings;
        _port = port;
        _reopenPauseSeconds = reopenPauseSeconds;
        _log = log;
        _announce = announce;
        _host = settings.TryGetValue(HostKey, out string? host) ? host : string.Empty;
        _levelInDecibels = settings.TryGetValue(DecibelsKey, out string? decibels) && decibels == "true";
        _model = settings.TryGetValue(ModelKey, out string? model) ? ProcessorModels.Parse(model) ?? ProcessorModel.Cp650 : ProcessorModel.Cp650;
    }

    /// <summary>Raised when a setting that is kept between runs changes: the address, the model or the level unit.</summary>
    public event EventHandler? SettingsChanged;

    /// <summary>The address typed in Setup.</summary>
    public string Host
    {
        get { lock (_sync) return _host; }
        set
        {
            lock (_sync)
            {
                if (!Set(ref _host, value)) return;
                _settings[HostKey] = value;
                SettingsChanged?.Invoke(this, EventArgs.Empty);
            }
        }
    }

    /// <summary>True while the Setup screen is asked for (no address saved yet).</summary>
    public bool ShowSetup
    {
        get { lock (_sync) return _showSetup; }
        set { lock (_sync) Set(ref _showSetup, value); }
    }

    /// <summary>The processor model: its front panel, its wire names and its controls.</summary>
    public ProcessorModel Model
    {
        get { lock (_sync) return _model; }
        private set { lock (_sync) Set(ref _model, value); }
    }

    /// <summary>The fader level, 0.0 to 10.0.</summary>
    public double Fader
    {
        get { lock (_sync) return _fader; }
        private set { lock (_sync) { if (Set(ref _fader, value)) RaiseDerived(); } }
    }

    /// <summary>The selected front-panel button (1 to 8 on the CP650, 1 to 7 inputs on the CP750).</summary>
    public int? FormatButton
    {
        get { lock (_sync) return _formatButton; }
        private set { lock (_sync) { if (Set(ref _formatButton, value)) RaiseDerived(); } }
    }

    /// <summary>The format number programmed on each button; null until the processor reports eight entries.</summary>
    public IReadOnlyList<string>? ProgrammedFormats
    {
        get { lock (_sync) return _programmedFormats; }
        private set { lock (_sync) { if (Set(ref _programmedFormats, value)) RaiseDerived(); } }
    }

    /// <summary>The selected macro's name, read from the processor (CP850 / CP950 / CP950A).</summary>
    public string? MacroName
    {
        get { lock (_sync) return _macroName; }
        private set { lock (_sync) Set(ref _macroName, value); }
    }

    /// <summary>The selected macro's number (CP850 / CP950 / CP950A).</summary>
    public int? MacroPreset
    {
        get { lock (_sync) return _macroPreset; }
        private set { lock (_sync) Set(ref _macroPreset, value); }
    }

    /// <summary>
    /// The macros the processor offers, in its order (CP850 / CP950 / CP950A). Not
    /// read by this build: the list is a multi-line reply, which the cpseries library does not return.
    /// </summary>
    public IReadOnlyList<Macro>? Macros
    {
        get { lock (_sync) return _macros; }
        private set { lock (_sync) Set(ref _macros, value); }
    }

    /// <summary>True: the level is shown in decibels (7.0 is 0 dB) instead of the fader number.</summary>
    public bool LevelInDecibels
    {
        get { lock (_sync) return _levelInDecibels; }
        private set { lock (_sync) { if (Set(ref _levelInDecibels, value)) RaiseDerived(); } }
    }

    /// <summary>The mute state, as the processor last reported it (or as this app set it).</summary>
    public bool Muted
    {
        get { lock (_sync) return _muted; }
        private set { lock (_sync) Set(ref _muted, value); }
    }

    /// <summary>
    /// The fader and the mute have been read on the current link. Until then the
    /// controls stay disabled, so a first touch never starts from a stale level.
    /// </summary>
    public bool PanelRead
    {
        get { lock (_sync) return _panelRead; }
        private set { lock (_sync) { if (Set(ref _panelRead, value)) RaiseDerived(); } }
    }

    /// <summary>The knob's drawn rotation, in degrees, free of the fader's limits.</summary>
    public double KnobRotation
    {
        get { lock (_sync) return _knobRotation; }
        private set { lock (_sync) Set(ref _knobRotation, value); }
    }

    /// <summary>The controls work: a link with the panel read on it.</summary>
    public bool IsConnected
    {
        get { lock (_sync) return IsConnectedLocked; }
    }

    /// <summary>True while a knob turn is under way.</summary>
    public bool IsTurningKnob
    {
        get { lock (_sync) return _knobValue is not null; }
    }

    /// <summary>No fader value waiting to be sent or being sent.</summary>
    public bool FaderIsSettled
    {
        get { lock (_sync) return _pendingFader is null && !_faderInFlight; }
    }

    /// <summary>How many times a hung link was reopened (for tests).</summary>
    public int LinkReopens
    {
        get { lock (_sync) return _linkReopens; }
    }

    /// <summary>The level as shown: the fader number, or decibels with a sign.</summary>
    public string LevelText => LevelTextFor(Fader, LevelInDecibels);

    /// <summary>The level with its unit, for the screens.</summary>
    public string LevelTextWithUnit => LevelInDecibels ? LevelText + " dB" : LevelText;

    /// <summary>The CP750's selected input, by its name on the front.</summary>
    public string CurrentInputName
    {
        get
        {
            int? button = FormatButton;
            if (button is not (>= 1 and <= 7)) return "Input --";
            return new[] { "Digital 1", "Digital 2", "Digital 3", "Digital 4", "Multi-Ch Analog", "NonSync", "Mic" }[button.Value - 1];
        }
    }

    /// <summary>The selected button's programmed format number, or null (CP650 only).</summary>
    public string? CurrentFormat
    {
        get
        {
            int? button = FormatButton;
            IReadOnlyList<string>? formats = ProgrammedFormats;
            if (button is not (>= 1 and <= 8) || formats is null) return null;
            return formats[button.Value - 1];
        }
    }

    /// <summary>One macro of the processor's list.</summary>
    public sealed record Macro(int Number, string Name);

    // MARK equivalents: the public API below mirrors the macOS app's RemoteModel.

    /// <summary>Choose the processor model and remember it. Takes effect at connect.</summary>
    public void ChooseModel(ProcessorModel model)
    {
        lock (_sync)
        {
            Model = model;
            _settings[ModelKey] = model.WireName();
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Drop any link and open a fresh one to <see cref="Host"/>. With no address saved, open Setup.</summary>
    public async Task ConnectAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            await ConnectNowAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    /// <summary>Reopen the current link when it is to the same address and model; otherwise a fresh connect.</summary>
    public async Task ReconnectAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            await ReconnectNowAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    public async Task DisconnectAsync()
    {
        await _lifecycle.WaitAsync().ConfigureAwait(false);
        try
        {
            await DisconnectNowAsync().ConfigureAwait(false);
        }
        finally
        {
            _lifecycle.Release();
        }
    }

    /// <summary>
    /// Checks the processor at <paramref name="address"/>, as <paramref name="chosen"/>
    /// (the model picked in Setup, not yet saved; the saved one when null). When the
    /// main link is to that address and model, asks over it (the CP650 serves one
    /// control client); otherwise opens a short-lived second link.
    /// </summary>
    public async Task<string> TestAsync(string rawAddress, ProcessorModel? chosen = null)
    {
        string address = rawAddress.Trim();
        if (address.Length == 0) return "Type an IP address first.";

        ProcessorModel model = chosen ?? Model;
        string name = model.ChoiceName();
        ProcessorLink? current;
        lock (_sync)
        {
            current = _processor is not null && _processorHost == address && _processor.Model == model ? _processor : null;
        }

        if (current is not null)
        {
            double? existing = FaderLevel(await current.GetAsync(model.Panel().Fader).ConfigureAwait(false));
            return existing is { } known
                ? $"OK: the connected {name} at {address} answered, fader {FaderText(known)}."
                : $"Connected to {address}, but no fader reply.";
        }

        using var link = new ProcessorLink(address, _port, model);
        await PauseAfterCloseAsync(address, link.Port, model).ConfigureAwait(false);
        if (!await link.ConnectAsync().ConfigureAwait(false))
        {
            await link.DisconnectAsync().ConfigureAwait(false);
            return $"No connection to {address} on port {link.Port}.";
        }

        string? reply = await link.GetAsync(model.Panel().Fader).ConfigureAwait(false);
        await link.DisconnectAsync().ConfigureAwait(false);
        NoteClosed(address, link.Port, model);
        double? level = FaderLevel(reply);
        return level is { } value
            ? $"OK: the {name} at {address} answered, fader {FaderText(value)}."
            : $"Connected to {address}:{link.Port}, but no fader reply.";
    }

    /// <summary>
    /// Moves the fader. Only once the panel has been read on the current link: a
    /// change before then would start from the previous level (another unit's, after a switch).
    /// </summary>
    public void SetFader(double value)
    {
        if (!double.IsFinite(value)) return;
        lock (_sync)
        {
            if (!IsConnectedLocked) return;
            double clamped = ClampFader(value);
            int tenths = Math.Max((int)Math.Round(clamped * 10, MidpointRounding.AwayFromZero), Model.Panel().FaderMinimum);
            if (Math.Abs(tenths / 10.0 - Fader) < 1e-9 && _pendingFader is null) return;
            Fader = tenths / 10.0;
            _localChange[Model.Panel().Fader] = Now();
            _pendingFader = tenths;
            RaiseDerived();
        }

        PumpFader();
    }

    public void BeginKnobTurn()
    {
        lock (_sync) { _knobValue = Fader; RaiseDerived(); }
    }

    public void EndKnobTurn()
    {
        lock (_sync) { _knobValue = null; RaiseDerived(); }
    }

    /// <summary>Turns the knob by <paramref name="degrees"/> (clockwise positive) and moves the fader by degrees / <see cref="DegreesPerUnit"/>, held within 0.0 to 10.0.</summary>
    public void TurnKnob(double degrees)
    {
        if (!double.IsFinite(degrees)) return;
        double next;
        lock (_sync)
        {
            if (!IsConnectedLocked) return;
            KnobRotation += degrees;
            next = Math.Clamp((_knobValue ?? Fader) + degrees / DegreesPerUnit, FaderMinimumValue, FaderMaximumValue);
            if (_knobValue is not null) _knobValue = next;
        }

        SetFader(next);
    }

    /// <summary>One 0.1 step of the knob (arrow keys, the Level menu).</summary>
    public void StepKnob(bool up) => TurnKnob((up ? 0.1 : -0.1) * DegreesPerUnit);

    /// <summary>Puts the fader on the reference level (the Level menu).</summary>
    public void SetReference() => SetFader(ReferenceLevel);

    /// <summary>
    /// A front-panel button: the CP650's format buttons (<see cref="FormatButtonParam"/>),
    /// or the CP750's input buttons (<see cref="InputParam"/>).
    /// </summary>
    public void PressButton(int button)
    {
        ProcessorLink? cp;
        ProcessorModel model;
        lock (_sync)
        {
            if (_processor is null || !IsConnectedLocked) return;
            cp = _processor;
            model = Model;
        }

        IReadOnlyList<string>? inputs = model.Panel().Inputs;
        // A key the front does not have selects nothing: CP750 inputs 1 to 7, CP650 formats 1 to 8.
        int keys = inputs?.Count ?? ButtonSilkscreen.Count;
        if (button < 1 || button > keys) return;
        FormatButton = button;
        if (inputs is not null)
        {
            string value = inputs[button - 1];
            Send(InputParam, cp, () => cp.SetAsync(InputParam, value));
        }
        else
        {
            // The panel counts the buttons 1 to 8; the CP650 counts them 0 to 7.
            Send(FormatButtonParam, cp, () => cp.SetAsync(FormatButtonParam, button - 1));
        }
    }

    public void ToggleMute()
    {
        ProcessorLink? cp;
        string param;
        bool value;
        lock (_sync)
        {
            if (_processor is null || !IsConnectedLocked) return;
            cp = _processor;
            Muted = !Muted;
            param = Model.Panel().Mute;
            value = Muted;
        }

        Send(param, cp, () => cp.SetAsync(param, value ? 1 : 0));
    }

    public void ToggleLevelUnit()
    {
        lock (_sync)
        {
            LevelInDecibels = !LevelInDecibels;
            _settings[DecibelsKey] = LevelInDecibels ? "true" : "false";
            SettingsChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>Selects a macro of the processor (CP850 / CP950 / CP950A).</summary>
    public void SelectMacro(int number)
    {
        ProcessorLink? cp;
        string nameParam;
        lock (_sync)
        {
            string? macroParam = Model.Panel().MacroName;
            if (_processor is null || !IsConnectedLocked || macroParam is null) return;
            cp = _processor;
            nameParam = macroParam;
            MacroPreset = number;
            // The new macro's name from the list; unknown, it is blank until the poll reads it.
            MacroName = _macros?.FirstOrDefault(m => m.Number == number)?.Name;
            _macroNameNumber = MacroName is null ? null : number;
            _localChange[nameParam] = Now();
        }

        Send(MacroPresetParam, cp, () => cp.SetAsync(MacroPresetParam, number));
    }

    /// <summary>The next (or previous) macro in the processor's list, wrapping round.</summary>
    public void StepMacro(int delta)
    {
        int number;
        lock (_sync)
        {
            if (_macros is not { Count: > 0 } list) return;
            int index = _macroPreset is int preset
                ? list.ToList().FindIndex(m => m.Number == preset)
                : -1;
            if (index < 0) index = delta > 0 ? -1 : 0;
            number = list[(index + delta + list.Count) % list.Count].Number;
        }

        SelectMacro(number);
    }

    /// <summary>Stops polling and closes the link.</summary>
    public void Dispose()
    {
        ProcessorLink? cp;
        lock (_sync)
        {
            _pollCancel?.Cancel();
            _pollCancel?.Dispose();
            _pollCancel = null;
            cp = _processor;
            _processor = null;
            _processorHost = null;
        }

        cp?.Dispose();
        _lifecycle.Dispose();
    }

    // ---- Values -------------------------------------------------------------

    /// <summary>The fader text with one decimal place.</summary>
    public static string FaderText(double value) => value.ToString("F1", CultureInfo.InvariantCulture);

    /// <summary>
    /// The fader scale of the Dolby processors: 0.0 to 4.0 in steps of 20 dB from
    /// -90 to -10 dB, then 3 1/3 dB per unit up to +10 dB at 10; 7.0 is 0 dB (the
    /// CP650 and CP750 manuals, read from public copies).
    /// </summary>
    public static double Decibels(double fader) => fader < 4 ? -90 + 20 * fader : (fader - 7) * 10 / 3;

    /// <summary>The level as shown: the fader number, or decibels with a sign.</summary>
    public static string LevelTextFor(double fader, bool decibels)
    {
        if (!decibels) return FaderText(fader);
        double value = Math.Round(Decibels(fader) * 10, MidpointRounding.AwayFromZero) / 10;
        return value == 0 ? "0.0" : value.ToString("+0.0;-0.0", CultureInfo.InvariantCulture);
    }

    /// <summary>A fader reply in tenths as a level, held within 0.0 to 10.0; null when it is not a finite number.</summary>
    public static double? FaderLevel(string? reply)
    {
        if (reply is null) return null;
        if (!double.TryParse(reply, NumberStyles.Float, CultureInfo.InvariantCulture, out double tenths) || !double.IsFinite(tenths))
        {
            return null;
        }

        return ClampFader(tenths / 10);
    }

    private static double ClampFader(double value) =>
        Math.Clamp(Math.Round(value * 10, MidpointRounding.AwayFromZero) / 10, FaderMinimumValue, FaderMaximumValue);

    private static long Now() => Stopwatch.GetTimestamp();

    /// <summary>Raises the notifications of the properties computed from the state, which the UI binds to.</summary>
    private void RaiseDerived()
    {
        Raise(nameof(IsConnected));
        Raise(nameof(IsTurningKnob));
        Raise(nameof(FaderIsSettled));
        Raise(nameof(LevelText));
        Raise(nameof(LevelTextWithUnit));
        Raise(nameof(CurrentInputName));
        Raise(nameof(CurrentFormat));
    }

    private bool IsConnectedLocked => _processor is not null && _panelRead;

    // ---- Sending ------------------------------------------------------------

    /// <summary>
    /// Sends one control change, marking the control as changed here and as being
    /// sent until the send is through, so a poll reply from before it does not overwrite it.
    /// </summary>
    private void Send(string param, ProcessorLink cp, Func<Task<bool>> operation)
    {
        lock (_sync)
        {
            _localChange[param] = Now();
            _sending[param] = _sending.GetValueOrDefault(param) + 1;
        }

        _ = Task.Run(async () =>
        {
            bool ok = await operation().ConfigureAwait(false);
            lock (_sync)
            {
                int remaining = _sending.GetValueOrDefault(param) - 1;
                if (remaining <= 0) _sending.Remove(param); else _sending[param] = remaining;
            }

            if (!ok && IsCurrentProcessor(cp))
            {
                Note($"{param} not sent: {await cp.LastErrorAsync().ConfigureAwait(false)}");
            }
        });
    }

    /// <summary>
    /// Sends the latest fader value, one send at a time, so a knob turn sends only
    /// the newest level rather than every step.
    /// </summary>
    private void PumpFader()
    {
        ProcessorLink cp;
        int value;
        string param;
        lock (_sync)
        {
            if (!IsConnectedLocked)
            {
                _pendingFader = null;     // the panel is unread: never send a level from before
                return;
            }

            if (_faderInFlight || _pendingFader is not int pending || _processor is not { } link) return;
            _pendingFader = null;
            _faderInFlight = true;
            RaiseDerived();
            cp = link;
            value = pending;
            param = Model.Panel().Fader;
        }

        _ = Task.Run(async () =>
        {
            if (!await cp.SetAsync(param, value).ConfigureAwait(false) && IsCurrentProcessor(cp))
            {
                Note($"{param} not sent: {await cp.LastErrorAsync().ConfigureAwait(false)}");
            }

            lock (_sync) { _faderInFlight = false; RaiseDerived(); }
            PumpFader();
        });
    }

    // ---- Connection ---------------------------------------------------------

    private string TrimmedHost
    {
        get { lock (_sync) return _host.Trim(); }
    }

    private bool IsCurrentProcessor(ProcessorLink cp)
    {
        lock (_sync) return ReferenceEquals(_processor, cp);
    }

    private async Task ConnectNowAsync()
    {
        await DisconnectNowAsync().ConfigureAwait(false);
        string address = TrimmedHost;
        if (address.Length == 0)
        {
            ShowSetup = true;
            return;
        }

        ProcessorLink cp;
        ProcessorModel model;
        lock (_sync)
        {
            model = Model;
            cp = new ProcessorLink(address, _port, model);
            _processor = cp;
            _processorHost = address;
            _linkOpened = false;
            _localChange.Clear();
            _sending.Clear();
            _formatListDue = true;
            ResetMacroReads();
            _silentPolls = 0;
            // A new processor: nothing shown may be the previous unit's.
            MacroName = null;
            _macroNameNumber = null;
            MacroPreset = null;
            Macros = null;
            Muted = false;
            FormatButton = null;
            ProgrammedFormats = null;
            PanelRead = false;
        }

        Note($"connect to {address}:{cp.Port} as {model.WireName()}");
        AnnounceConnectionChange();

        // A CP650 session this app closed a moment ago may still hold the unit's one connection.
        await PauseAfterCloseAsync(address, cp.Port, model).ConfigureAwait(false);
        if (!IsCurrentProcessor(cp)) return;

        bool opened = await cp.ConnectAsync().ConfigureAwait(false);
        if (!IsCurrentProcessor(cp)) return;
        lock (_sync) _linkOpened = opened;
        if (!opened)
        {
            Note($"no answer from {address} at connect ({await cp.LastErrorAsync().ConfigureAwait(false)}): the poll retries");
        }

        StartPolling(cp);
    }

    private async Task ReconnectNowAsync()
    {
        ProcessorLink? cp;
        lock (_sync)
        {
            cp = _processor;
            if (cp is null || _processorHost != TrimmedHost || cp.Model != Model)
            {
                cp = null;
            }
        }

        if (cp is null)
        {
            await ConnectNowAsync().ConfigureAwait(false);
            return;
        }

        Note("reconnect requested");
        MarkUnread("reconnect requested");
        lock (_sync)
        {
            _formatListDue = true;
            ResetMacroReads();
        }

        bool opened = await cp.ReconnectAsync().ConfigureAwait(false);
        if (!IsCurrentProcessor(cp)) return;
        lock (_sync) _linkOpened = opened;
        if (!opened)
        {
            Note($"reconnect failed: {await cp.LastErrorAsync().ConfigureAwait(false)}");
        }
    }

    private async Task DisconnectNowAsync()
    {
        ProcessorLink? cp;
        string? closedHost;
        lock (_sync)
        {
            _pollCancel?.Cancel();
            _pollCancel?.Dispose();
            _pollCancel = null;
            _pendingFader = null;
            _knobValue = null;
            RaiseDerived();
            cp = _processor;
            if (cp is null) return;
            closedHost = _processorHost;
            _processor = null;
            _processorHost = null;
            ProgrammedFormats = null;
            MacroName = null;
            _macroNameNumber = null;
            MacroPreset = null;
            Macros = null;
            PanelRead = false;
        }

        Note("disconnect requested");
        AnnounceConnectionChange();
        await cp.DisconnectAsync().ConfigureAwait(false);
        if (closedHost is not null) NoteClosed(closedHost, cp.Port, cp.Model);
    }

    /// <summary>Disables the controls until the panel has been read again on the current link, ends a knob turn, and tells the screen reader.</summary>
    private void MarkUnread(string why)
    {
        EndKnobTurn();
        lock (_sync)
        {
            if (!_panelRead) return;
            PanelRead = false;
        }

        Note($"controls disabled: {why}");
        AnnounceConnectionChange();
    }

    private void AnnounceConnectionChange()
    {
        string? text;
        lock (_sync)
        {
            bool connected = IsConnectedLocked;
            if (connected == _announcedConnected) return;
            _announcedConnected = connected;
            text = connected ? "Processor connected" : "Processor not answering; controls disabled";
        }

        _announce?.Invoke(text);
    }

    private void Note(string text) => _log?.Write($"app: {text}");

    private static void NoteClosed(string address, ushort port, ProcessorModel model)
    {
        if (model != ProcessorModel.Cp650) return;
        lock (ClosesLock) Cp650Closes[$"{address}:{port}"] = Now();
    }

    private async Task PauseAfterCloseAsync(string address, ushort port, ProcessorModel model)
    {
        if (model != ProcessorModel.Cp650) return;
        long closed;
        lock (ClosesLock)
        {
            if (!Cp650Closes.TryGetValue($"{address}:{port}", out closed)) return;
        }

        // Wait out what is left of the reopen pause since this app last closed a session to this address.
        double leftSeconds = _reopenPauseSeconds - (double)(Now() - closed) / Stopwatch.Frequency;
        if (leftSeconds > 0)
        {
            await Task.Delay(TimeSpan.FromSeconds(leftSeconds)).ConfigureAwait(false);
        }
    }

    // ---- Polling ------------------------------------------------------------

    private void StartPolling(ProcessorLink cp)
    {
        CancellationTokenSource cancel = new();
        lock (_sync)
        {
            _pollCancel?.Cancel();
            _pollCancel?.Dispose();
            _pollCancel = cancel;
        }

        // Read at once, then every two seconds; Connect does not wait for it, so a link that never answers still shows its state.
        _ = Task.Run(async () =>
        {
            while (!cancel.IsCancellationRequested)
            {
                await PollCycleAsync(cp, cancel.Token).ConfigureAwait(false);
                try
                {
                    await Task.Delay(PollInterval, cancel.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    return;
                }
            }
        });
    }

    private bool IsCurrent(ProcessorLink cp, CancellationToken token) => IsCurrentProcessor(cp) && !token.IsCancellationRequested;

    private async Task PollCycleAsync(ProcessorLink cp, CancellationToken token)
    {
        if (!IsCurrent(cp, token)) return;
        bool needOpen;
        lock (_sync) needOpen = !_linkOpened;
        if (needOpen)
        {
            // A processor that was off, booting or unreachable at connect time is found when it comes up.
            bool ok = await cp.ConnectAsync().ConfigureAwait(false);
            if (!IsCurrent(cp, token)) return;
            Note($"connect {(ok ? "succeeded" : "failed")}");
            if (!ok) return;
            lock (_sync)
            {
                _linkOpened = true;
                _formatListDue = true;
                ResetMacroReads();
            }
        }

        await RefreshAsync(cp, token).ConfigureAwait(false);
    }

    /// <summary>A new or reopened link: the macro number and name are read again, whatever went unanswered on the old one.</summary>
    private void ResetMacroReads()
    {
        _macroMisses = 0;
        _macroPollsToSkip = 0;
    }

    /// <summary>One macro read went unanswered.</summary>
    private void MacroReadMissed()
    {
        _macroMisses++;
        if (_macroMisses < MacroMissLimit) return;
        Note($"macro reads unanswered: paused for {MacroPausePolls} polls");
        _macroMisses = 0;
        _macroPollsToSkip = MacroPausePolls;
    }

    /// <summary>A reply to a read that started at <paramref name="start"/> may update the panel only if no send of that control is under way and the control was not changed here just before the read.</summary>
    private bool MayApply(string param, long start)
    {
        lock (_sync)
        {
            if (_sending.ContainsKey(param)) return false;
            if (_localChange.TryGetValue(param, out long changed) && changed > start - PollHoldOffTicks) return false;
            return true;
        }
    }

    private async Task RefreshAsync(ProcessorLink cp, CancellationToken token)
    {
        ProcessorModel model;
        lock (_sync) model = Model;
        PanelProfile panel = model.Panel();

        long start = Now();
        string? faderReply = await cp.GetAsync(panel.Fader).ConfigureAwait(false);
        if (!IsCurrent(cp, token)) return;
        if (faderReply is null)
        {
            // Unanswered: after a few in a row, reopen a link that is open but hung, and skip the other reads.
            int silent;
            lock (_sync) silent = ++_silentPolls;
            Note($"fader read unanswered ({silent} of {SilentPollLimit}): {await cp.LastErrorAsync().ConfigureAwait(false)}");
            MarkUnread("fader read unanswered");
            if (silent >= SilentPollLimit)
            {
                Note($"reopening the link: {SilentPollLimit} fader reads unanswered");
                lock (_sync)
                {
                    _silentPolls = 0;
                    _formatListDue = true;
                    ResetMacroReads();
                    _linkReopens++;
                }

                await cp.ReconnectAsync().ConfigureAwait(false);
            }

            return;
        }

        lock (_sync) _silentPolls = 0;
        double? faderRead = FaderLevel(faderReply);
        if (faderRead is double level)
        {
            lock (_sync)
            {
                if (MayApply(panel.Fader, start) && _knobValue is null && FaderIsSettledLocked && Fader != level)
                {
                    Fader = level;
                }
            }
        }

        // The selected button: the CP650's format button, or the CP750's input.
        start = Now();
        if (model == ProcessorModel.Cp650)
        {
            string? reply = await cp.GetAsync(FormatButtonParam).ConfigureAwait(false);
            if (reply is not null && IsCurrent(cp, token) && int.TryParse(reply, NumberStyles.Integer, CultureInfo.InvariantCulture, out int wire)
                && wire is >= 0 and <= 7 && MayApply(FormatButtonParam, start))
            {
                lock (_sync)
                {
                    if (FormatButton != wire + 1) FormatButton = wire + 1;
                }
            }
        }
        else if (panel.Inputs is { } inputs)
        {
            string? reply = await cp.GetAsync(InputParam).ConfigureAwait(false);
            int index = reply is null ? -1 : inputs.ToList().IndexOf(reply);
            if (reply is not null && IsCurrent(cp, token) && index >= 0 && MayApply(InputParam, start))
            {
                lock (_sync)
                {
                    if (FormatButton != index + 1) FormatButton = index + 1;
                }
            }
        }

        start = Now();
        string? muteReply = await cp.GetAsync(panel.Mute).ConfigureAwait(false);
        if (!IsCurrent(cp, token)) return;
        if (muteReply is not null && MayApply(panel.Mute, start))
        {
            bool muted = muteReply == "1";
            lock (_sync)
            {
                if (Muted != muted) Muted = muted;
            }
        }

        // The controls come on only once this pass has read the fader and the mute.
        bool becameReady = false;
        lock (_sync)
        {
            if (faderRead is not null && muteReply is not null && !_panelRead)
            {
                PanelRead = true;
                becameReady = true;
            }
        }

        if (becameReady)
        {
            Note("panel read: controls enabled");
            AnnounceConnectionChange();
        }

        await RefreshMacroAsync(cp, panel, token).ConfigureAwait(false);

        // The CP650's programmed formats change only in setup: one attempt per opened link.
        bool formatsDue;
        lock (_sync)
        {
            formatsDue = model == ProcessorModel.Cp650 && _formatListDue;
            if (formatsDue) _formatListDue = false;
        }

        if (!formatsDue || !IsCurrent(cp, token)) return;
        string? list = await cp.GetAsync("format_list").ConfigureAwait(false);
        if (list is null || !IsCurrent(cp, token)) return;
        string[] labels = list.Split(',').Select(s => s.Trim()).ToArray();
        if (labels.Length == 8 && labels.All(s => s.Length > 0))
        {
            ProgrammedFormats = labels;
        }
    }

    private async Task RefreshMacroAsync(ProcessorLink cp, PanelProfile panel, CancellationToken token)
    {
        // The selected macro, for the screen: its number every poll, its name whenever the name shown is not that macro's.
        string? nameParam = panel.MacroName;
        if (nameParam is null) return;
        bool skip;
        lock (_sync)
        {
            if (_macroPollsToSkip > 0) _macroPollsToSkip--;
            skip = _macroPollsToSkip > 0;
        }

        if (skip) return;
        long start = Now();
        string? presetReply = await cp.GetAsync(MacroPresetParam).ConfigureAwait(false);
        if (!IsCurrent(cp, token)) return;
        if (presetReply is null)
        {
            MacroReadMissed();
            return;
        }

        _macroMisses = 0;
        if (!int.TryParse(presetReply.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out int number)
            || !MayApply(MacroPresetParam, start))
        {
            return;
        }

        bool nameKnown;
        lock (_sync) nameKnown = _macroNameNumber == number;
        if (nameKnown)
        {
            lock (_sync) MacroPreset = number;
            return;
        }

        // The number and its name change together: a new key is never shown beside the old macro's name.
        start = Now();
        string? nameReply = await cp.GetAsync(nameParam).ConfigureAwait(false);
        if (!IsCurrent(cp, token)) return;
        lock (_sync)
        {
            if (nameReply is not null)
            {
                if (MayApply(nameParam, start) && MayApply(MacroPresetParam, start))
                {
                    MacroPreset = number;
                    MacroName = nameReply.Trim();
                    _macroNameNumber = number;
                }

                return;
            }
        }

        MacroReadMissed();
        lock (_sync)
        {
            MacroPreset = number;       // the number without a name, not the old name
            MacroName = _macros?.FirstOrDefault(m => m.Number == number)?.Name;
            _macroNameNumber = MacroName is null ? null : number;
        }
    }

    private bool FaderIsSettledLocked => _pendingFader is null && !_faderInFlight;
}

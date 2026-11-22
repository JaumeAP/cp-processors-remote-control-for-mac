using System.Runtime.InteropServices;
using System.Text;
using CPRemote.Core.Native;

namespace CPRemote.Core;

/// <summary>Link status, the values of cpseries_status().</summary>
public enum CpSeriesStatus
{
    Initializing = 0,
    Ok = 1,
    Compromised = 2,
    Missing = 3,
    Fault = 4,
}

/// <summary>The outcome of a SET: queued for <see cref="CpSeriesClient.Run"/>, refused, or the link was down.</summary>
public enum CpSeriesSetResult
{
    LinkDown = 0,
    Queued = 1,
    Rejected = -1,
}

/// <summary>Tuning of a client. Unset fields keep the library defaults.</summary>
public sealed record CpSeriesOptions
{
    /// <summary>Re-open a dropped link inline (library default: false).</summary>
    public bool AutoReconnect { get; init; }

    /// <summary>Extra attempts of a lost or unanswered query (library default: 2).</summary>
    public int GetRetries { get; init; } = 2;

    /// <summary>Seconds without success before the status becomes MISSING (library default: 3.0).</summary>
    public double Watchdog { get; init; } = 3.0;

    /// <summary>Seconds between sends; negative means the model's own gap (library default).</summary>
    public double Gap { get; init; } = -1;

    /// <summary>Seconds before a link is reopened; negative means the model's own value (library default).</summary>
    public double ReopenDelay { get; init; } = -1;
}

/// <summary>
/// A control client for one CP650, CP750, CP850, CP950 or CP950A processor,
/// over the cpseries C library. One command is in flight at a time, so use one
/// instance per thread or serialise the calls, as the library requires.
/// </summary>
public sealed unsafe class CpSeriesClient : IDisposable
{
    // Text the library writes is a short wire value; longer text is truncated
    // by the library's snprintf convention and the truncated prefix is returned.
    private const int TextBufferSize = 4096;

    private nint _handle;

    /// <summary>Creates a client for <paramref name="host"/>. It does not connect.</summary>
    /// <param name="port">The model's port when 0; the model's default is <see cref="DefaultPort"/>.</param>
    /// <exception cref="ArgumentException">The model is not one the library knows.</exception>
    public CpSeriesClient(string host, int port, string model, CpSeriesOptions? options = null)
    {
        ArgumentNullException.ThrowIfNull(host);
        ArgumentNullException.ThrowIfNull(model);

        NativeMethods.Options native;
        NativeMethods.cpseries_options_default(&native);
        if (options is not null)
        {
            native.AutoReconnect = options.AutoReconnect ? 1 : 0;
            native.GetRetries = options.GetRetries;
            native.Watchdog = options.Watchdog;
            native.Gap = options.Gap;
            native.ReopenDelay = options.ReopenDelay;
        }

        _handle = NativeMethods.cpseries_new(host, port, model, &native);
        if (_handle == 0)
        {
            throw new ArgumentException($"The library does not know the model '{model}', or it ran out of memory.", nameof(model));
        }
    }

    /// <summary>The model's documented TCP port (61412 for CP650, 61408 for the others).</summary>
    /// <exception cref="ArgumentException">The model is not one the library knows.</exception>
    public static int DefaultPort(string model)
    {
        ArgumentNullException.ThrowIfNull(model);
        int port = NativeMethods.cpseries_default_port(model);
        return port >= 0 ? port : throw new ArgumentException($"Unknown model '{model}'.", nameof(model));
    }

    /// <summary>Opens the link. Returns false when it could not be opened.</summary>
    public bool Connect() => NativeMethods.cpseries_connect(Handle) == 1;

    /// <summary>Closes the link. The handle stays usable for <see cref="Connect"/>.</summary>
    public void Disconnect() => NativeMethods.cpseries_disconnect(Handle);

    /// <summary>Re-opens the link. Returns false when it could not be re-opened.</summary>
    public bool Reconnect() => NativeMethods.cpseries_reconnect(Handle) == 1;

    /// <summary>Queues an integer SET. Nothing is sent until <see cref="Run"/>.</summary>
    public CpSeriesSetResult SetInt(string param, long value) =>
        ToSetResult(NativeMethods.cpseries_set_int(Handle, param, value));

    /// <summary>Queues a floating-point SET. Nothing is sent until <see cref="Run"/>.</summary>
    public CpSeriesSetResult SetDouble(string param, double value) =>
        ToSetResult(NativeMethods.cpseries_set_double(Handle, param, value));

    /// <summary>Queues a boolean SET (sent as 0 or 1). Nothing is sent until <see cref="Run"/>.</summary>
    public CpSeriesSetResult SetBool(string param, bool value) =>
        ToSetResult(NativeMethods.cpseries_set_bool(Handle, param, value ? 1 : 0));

    /// <summary>Queues a text SET. Nothing is sent until <see cref="Run"/>.</summary>
    public CpSeriesSetResult SetText(string param, string value) =>
        ToSetResult(NativeMethods.cpseries_set_text(Handle, param, value));

    /// <summary>Sends every queued SET, one in flight. Stops when the link is down.</summary>
    public void Run() => NativeMethods.cpseries_run(Handle);

    /// <summary>
    /// Queries <paramref name="param"/> and waits for its answer. Returns null
    /// when there is no value (timeout, an error reply, a lost link).
    /// </summary>
    /// <param name="timeout">How long to wait; null means the library default.</param>
    /// <exception cref="ArgumentException">The parameter cannot be framed on the wire.</exception>
    public string? Get(string param, TimeSpan? timeout = null)
    {
        ArgumentNullException.ThrowIfNull(param);
        double seconds = timeout?.TotalSeconds ?? 0;
        byte[] buffer = new byte[TextBufferSize];
        int length;
        fixed (byte* output = buffer)
        {
            length = NativeMethods.cpseries_get(Handle, param, output, (nuint)buffer.Length, seconds);
        }

        return length switch
        {
            -1 => null,
            -2 => throw new ArgumentException($"The parameter '{param}' cannot be framed on the wire.", nameof(param)),
            _ => Decode(buffer, length),
        };
    }

    /// <summary>
    /// The last value the client recorded for <paramref name="param"/>, without
    /// touching the network. Returns null when there is none.
    /// </summary>
    public string? State(string param)
    {
        ArgumentNullException.ThrowIfNull(param);
        byte[] buffer = new byte[TextBufferSize];
        int length;
        fixed (byte* output = buffer)
        {
            length = NativeMethods.cpseries_state(Handle, param, output, (nuint)buffer.Length);
        }

        return length < 0 ? null : Decode(buffer, length);
    }

    /// <summary>The link status now.</summary>
    public CpSeriesStatus Status => (CpSeriesStatus)NativeMethods.cpseries_status(Handle);

    /// <summary>The number of SETs waiting for <see cref="Run"/>.</summary>
    public int Queued => checked((int)NativeMethods.cpseries_queued(Handle));

    /// <summary>The text of the last error on this client, or an empty string when the last call succeeded.</summary>
    public string LastError
    {
        get
        {
            nint text = NativeMethods.cpseries_last_error(Handle);
            return text == 0 ? string.Empty : Marshal.PtrToStringUTF8(text) ?? string.Empty;
        }
    }

    /// <summary>Closes the link and releases the native handle.</summary>
    public void Dispose()
    {
        if (_handle != 0)
        {
            NativeMethods.cpseries_free(_handle);
            _handle = 0;
        }
    }

    private nint Handle
    {
        get
        {
            ObjectDisposedException.ThrowIf(_handle == 0, this);
            return _handle;
        }
    }

    private static CpSeriesSetResult ToSetResult(int code) => code switch
    {
        1 => CpSeriesSetResult.Queued,
        0 => CpSeriesSetResult.LinkDown,
        _ => CpSeriesSetResult.Rejected,
    };

    private static string Decode(byte[] buffer, int length)
    {
        // The library reports the length the text needs; what was written is
        // capped at the buffer, less the terminating NUL.
        int written = Math.Min(length, buffer.Length - 1);
        return Encoding.UTF8.GetString(buffer, 0, written);
    }
}

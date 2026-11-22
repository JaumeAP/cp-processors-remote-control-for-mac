using System.Runtime.InteropServices;

namespace CPRemote.Core.Native;

/// <summary>
/// P/Invoke declarations for the plain-C API of cpseries (cpseries_c.h, from
/// cpseries-release/Artifacts/windows-x64). The library name is
/// "libcpseries": .NET loads libcpseries.dll on Windows and libcpseries.dylib
/// on macOS, the names the release archives ship.
/// </summary>
internal static unsafe partial class NativeMethods
{
    internal const string LibraryName = "libcpseries";

    [StructLayout(LayoutKind.Sequential)]
    internal struct Options
    {
        public int AutoReconnect;
        public int GetRetries;
        public double Watchdog;
        public double Gap;
        public double ReopenDelay;
    }

    [LibraryImport(LibraryName)]
    internal static partial void cpseries_options_default(Options* options);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_default_port(string model);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial nint cpseries_new(string host, int port, string model, Options* options);

    [LibraryImport(LibraryName)]
    internal static partial void cpseries_free(nint client);

    [LibraryImport(LibraryName)]
    internal static partial int cpseries_connect(nint client);

    [LibraryImport(LibraryName)]
    internal static partial void cpseries_disconnect(nint client);

    [LibraryImport(LibraryName)]
    internal static partial int cpseries_reconnect(nint client);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_set_int(nint client, string param, long value);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_set_double(nint client, string param, double value);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_set_bool(nint client, string param, int value);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_set_text(nint client, string param, string value);

    [LibraryImport(LibraryName)]
    internal static partial void cpseries_run(nint client);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_get(nint client, string param, byte* output, nuint outputSize, double timeout);

    [LibraryImport(LibraryName, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int cpseries_state(nint client, string param, byte* output, nuint outputSize);

    [LibraryImport(LibraryName)]
    internal static partial int cpseries_status(nint client);

    [LibraryImport(LibraryName)]
    internal static partial nuint cpseries_queued(nint client);

    [LibraryImport(LibraryName)]
    internal static partial nint cpseries_last_error(nint client);
}

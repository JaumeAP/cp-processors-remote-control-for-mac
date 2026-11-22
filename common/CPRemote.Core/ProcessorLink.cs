using CPRemote.Core.Model;

namespace CPRemote.Core;

/// <summary>
/// One control link to a processor, through <see cref="CpSeriesClient"/>. The
/// library blocks on the network, so every call runs on the thread pool, one
/// at a time: the client is touched only inside the gate, and the caller is
/// never blocked. The link re-opens itself inside a query or a send when it
/// finds the connection dropped.
/// </summary>
public sealed class ProcessorLink : IDisposable
{
    private readonly CpSeriesClient _client;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private volatile bool _disposed;

    /// <param name="port">Null: the model's own port.</param>
    public ProcessorLink(string host, ushort? port, ProcessorModel model)
    {
        Host = host;
        Model = model;
        Port = port ?? model.DefaultPort();
        _client = new CpSeriesClient(host, Port, model.WireName(), new CpSeriesOptions { AutoReconnect = true });
    }

    public string Host { get; }

    public ushort Port { get; }

    public ProcessorModel Model { get; }

    /// <summary>Open the link. True when it is up.</summary>
    public Task<bool> ConnectAsync() => Perform(false, client => client.Connect());

    /// <summary>Close the link and open it again, keeping queued sends.</summary>
    public Task<bool> ReconnectAsync() => Perform(false, client => client.Reconnect());

    public Task DisconnectAsync() => Perform(0, client => { client.Disconnect(); return 0; });

    /// <summary>The link status now.</summary>
    public Task<CpSeriesStatus> StatusAsync() => Perform(CpSeriesStatus.Missing, client => client.Status);

    /// <summary>
    /// Ask for <paramref name="param"/> and wait for its value; null when there is
    /// none (a timeout, an error reply, a lost link). A null <paramref name="timeout"/>
    /// means the library's own.
    /// </summary>
    public Task<string?> GetAsync(string param, TimeSpan? timeout = null) =>
        Perform<string?>(null, client => client.Get(param, timeout));

    /// <summary>Send an integer SET and wait until it is through. False when it could not be sent.</summary>
    public Task<bool> SetAsync(string param, long value) => Perform(false, client =>
    {
        if (client.SetInt(param, value) != CpSeriesSetResult.Queued) return false;
        client.Run();
        return true;
    });

    /// <summary>Send a text SET and wait until it is through. False when it could not be sent.</summary>
    public Task<bool> SetAsync(string param, string value) => Perform(false, client =>
    {
        if (client.SetText(param, value) != CpSeriesSetResult.Queued) return false;
        client.Run();
        return true;
    });

    /// <summary>The text of the last error on the link, for the log.</summary>
    public Task<string> LastErrorAsync() => Perform(string.Empty, client => client.LastError);

    /// <summary>
    /// Closes the link once the call in flight, if any, has finished. Calls made
    /// after this return their fallback values.
    /// </summary>
    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _ = Task.Run(async () =>
        {
            await _gate.WaitAsync().ConfigureAwait(false);
            try
            {
                _client.Dispose();
            }
            finally
            {
                _gate.Release();
            }
        });
    }

    private async Task<T> Perform<T>(T fallback, Func<CpSeriesClient, T> body)
    {
        if (_disposed) return fallback;
        await _gate.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_disposed) return fallback;
            return await Task.Run(() => body(_client)).ConfigureAwait(false);
        }
        finally
        {
            _gate.Release();
        }
    }
}

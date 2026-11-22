using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using CPRemote.Core;
using Xunit;
using Xunit.Abstractions;

namespace CPRemote.Core.Tests;

public sealed class CpSeriesClientTests(ITestOutputHelper output)
{
    [Theory]
    [InlineData("CP650", 61412)]
    [InlineData("CP750", 61408)]
    [InlineData("CP850", 61408)]
    [InlineData("CP950", 61408)]
    [InlineData("CP950A", 61408)]
    public void DefaultPort_is_the_documented_port_of_each_model(string model, int port)
    {
        Assert.Equal(port, CpSeriesClient.DefaultPort(model));
    }

    [Fact]
    public void DefaultPort_rejects_an_unknown_model()
    {
        Assert.Throws<ArgumentException>(() => CpSeriesClient.DefaultPort("CP999"));
    }

    [Fact]
    public void Constructor_rejects_an_unknown_model()
    {
        Assert.Throws<ArgumentException>(() => new CpSeriesClient("127.0.0.1", 0, "CP999"));
    }

    [Fact]
    public void A_new_client_has_nothing_queued_and_a_closed_port_does_not_connect()
    {
        int closedPort = FreeLocalPort();
        using var client = new CpSeriesClient("127.0.0.1", closedPort, "CP750");

        Assert.Equal(CpSeriesStatus.Initializing, client.Status);
        Assert.Equal(0, client.Queued);
        Assert.False(client.Connect());
    }

    private static int FreeLocalPort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    [Fact]
    public void Using_a_disposed_client_throws()
    {
        var client = new CpSeriesClient("127.0.0.1", 0, "CP750");
        client.Dispose();

        Assert.Throws<ObjectDisposedException>(() => client.Queued);
    }

    [SkippableFact]
    public void Against_the_simulator_a_SET_is_queued_sent_and_read_back()
    {
        using var simulator = Simulator.Start(output, "CP750");
        using var client = new CpSeriesClient("127.0.0.1", simulator.Port, "CP750");

        Assert.True(client.Connect());
        Assert.Equal(CpSeriesSetResult.Queued, client.SetBool("cp750.sys.mute", true));
        Assert.Equal(1, client.Queued);

        client.Run();
        Assert.Equal(0, client.Queued);

        string? value = client.Get("cp750.sys.mute", TimeSpan.FromSeconds(6));
        output.WriteLine($"cp750.sys.mute read back as: {value ?? "(null)"}");
        output.WriteLine($"last error: '{client.LastError}'");
        Assert.NotNull(value);
    }

    /// <summary>A simulator process on a free local port, stopped on dispose.</summary>
    internal sealed class Simulator : IDisposable
    {
        private readonly Process _process;

        private Simulator(Process process, int port)
        {
            _process = process;
            Port = port;
        }

        public int Port { get; }

        public static Simulator Start(ITestOutputHelper output, string model)
        {
            string? path = Environment.GetEnvironmentVariable("CPSERIES_SIMULATOR");
            Skip.If(string.IsNullOrEmpty(path) || !File.Exists(path), "CPSERIES_SIMULATOR does not name processor_sim");

            int port = FreePort();
            var process = Process.Start(new ProcessStartInfo(path!, ["--model", model, "--port", port.ToString(System.Globalization.CultureInfo.InvariantCulture)])
            {
                UseShellExecute = false,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            }) ?? throw new InvalidOperationException("processor_sim did not start.");

            WaitForPort(port);
            output.WriteLine($"simulator {model} on 127.0.0.1:{port}");
            return new Simulator(process, port);
        }

        public void Dispose()
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
            }
            _process.Dispose();
        }

        private static int FreePort()
        {
            var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            listener.Stop();
            return port;
        }

        private static void WaitForPort(int port)
        {
            var deadline = DateTime.UtcNow.AddSeconds(5);
            while (DateTime.UtcNow < deadline)
            {
                try
                {
                    using var probe = new TcpClient();
                    probe.Connect(IPAddress.Loopback, port);
                    return;
                }
                catch (SocketException)
                {
                    Thread.Sleep(50);
                }
            }
            throw new TimeoutException($"processor_sim did not listen on port {port}.");
        }
    }
}

using System.Globalization;
using System.Text;
using System.Threading.Channels;

namespace CPRemote.Core;

/// <summary>
/// A plain-text log of what the app and its link to the processor do, for
/// finding why a connection was lost. One line per event, with the time to the
/// millisecond. It records the lines exchanged with the processor, the status
/// changes with their reason, and the window and focus changes of the app, and
/// at start the app version and the Windows version. It records nothing else
/// about the PC or the user.
/// </summary>
/// <remarks>
/// Lines are written by one background task, in order, so <see cref="Write"/>
/// never blocks its caller and never throws.
/// </remarks>
public sealed class ConnectionLog : IDisposable
{
    private readonly string _path;
    private readonly long _maximumBytes;
    private readonly Channel<Action> _work = Channel.CreateUnbounded<Action>(new UnboundedChannelOptions { SingleReader = true });
    private readonly Task _worker;

    /// <param name="path">The log file. The directory is created when missing.</param>
    /// <param name="maximumBytes">
    /// When the file grows past this, it becomes <c>connection.log.1</c>
    /// (replacing the older one) and a new file starts, so the log never takes
    /// more than twice this.
    /// </param>
    public ConnectionLog(string path, long maximumBytes = 1_000_000)
    {
        _path = path;
        _maximumBytes = maximumBytes;
        string? directory = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path));
        if (directory is not null)
        {
            Directory.CreateDirectory(directory);
        }

        _worker = Task.Run(async () =>
        {
            await foreach (Action action in _work.Reader.ReadAllAsync().ConfigureAwait(false))
            {
                action();
            }
        });
    }

    /// <summary>The log of the running app: <c>%LOCALAPPDATA%\CP Remote\Logs\connection.log</c>.</summary>
    public static ConnectionLog Shared { get; } = new(DefaultPath());

    /// <summary>The file the log writes to.</summary>
    public string Path => _path;

    /// <summary>Appends one line. Never blocks the caller and never throws.</summary>
    public void Write(string text)
    {
        string line = $"{DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ", CultureInfo.InvariantCulture)} {text}\n";
        _work.Writer.TryWrite(() => Append(line));
    }

    /// <summary>Waits until every line written so far is on disk (for tests and quit).</summary>
    public void Flush()
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        _work.Writer.TryWrite(() => done.SetResult());
        done.Task.Wait();
    }

    /// <summary>Writes what is queued, then stops the background task.</summary>
    public void Dispose()
    {
        _work.Writer.TryComplete();
        _worker.Wait();
    }

    private static string DefaultPath() => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "CP Remote", "Logs", "connection.log");

    private void Append(string line)
    {
        try
        {
            if (File.Exists(_path) && new FileInfo(_path).Length > _maximumBytes)
            {
                string older = _path + ".1";
                File.Delete(older);
                File.Move(_path, older);
            }

            File.AppendAllText(_path, line, Encoding.UTF8);
        }
        catch (IOException)
        {
            // The log never takes the app down; a line that cannot be written is lost.
        }
        catch (UnauthorizedAccessException)
        {
            // Same: a read-only folder loses the lines, the app goes on.
        }
    }
}

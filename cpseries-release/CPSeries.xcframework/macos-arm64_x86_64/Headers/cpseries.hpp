// cpseries -- the C++ control client for CP650/CP750/CP850/CP950/CP950A
// cinema processors over TCP/IP: the third client, next to the Python
// cpx50.comms and the Lua client, with the same wire protocol and the same rules.
//
//     cpseries::Client cp("192.168.1.10", 0, cpseries::Model::CP750);
//     cp.connect();
//     cp.set("cp750.sys.mute", 0);             // non-blocking: enqueues
//     cp.run();                                // drains the queue, one in flight
//     auto fader = cp.get("cp750.sys.fader");  // blocking query
//     cp.disconnect();
//
// It is blocking, like the Lua client: set() enqueues (coalesced, QMAX 10),
// run() sends what is queued, get() sends one query and waits for its answer.
// The rules are the Python client's (cpx50.comms.client):
//   1. one command in flight, and the model's inter-command gap (0.25 s
//      CP650, 0.10 s otherwise), kept between sends rather than slept after
//      each send, so a reply is read as soon as it arrives;
//   2. CP650: `key=?` queries, CRLF line ends, a SET (which the unit never
//      answers) confirmed by a query, and a 2 s pause before a link is
//      reopened (the unit takes one connection);
//   3. other models: a SET records the value in its reply, a bare ACK the
//      commanded value, a blank line or other text nothing; CP650 and CP750
//      names match without case;
//   4. a query resyncs past lines naming another parameter (stale replies,
//      CP650 front-panel lines, the CP650's greeting), at most RESYNC_MAX;
//   5. MISSING at once on a lost link, and on a live link only for an
//      unanswered query once nothing has succeeded for the watchdog window.
//
// Optimized for a hot control loop: no allocation per line read (lines are
// views into one receive buffer), one write per command (the line and its
// terminator together), TCP_NODELAY, poll() with exact deadlines, a fixed
// command queue, and wire text computed once, when the command is enqueued.
#pragma once

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace cpseries {

// Public-API visibility. Only the symbols marked CPSERIES_API are exported:
//   - Windows DLL (-DCPSERIES_DLL): dllexport when building (-DCPSERIES_BUILD),
//     dllimport when consuming; with --exclude-all-symbols the internals are
//     hidden. A static .lib leaves CPSERIES_DLL undefined, so it is empty.
//   - the obfuscation build (cmake -DCPSERIES_OBFUSCATE=ON, -fvisibility=hidden):
//     visibility("default"), the internals left hidden.
//   - otherwise empty. See cpp/README.md, "Hiding the client".
#if defined(CPSERIES_C_ONLY)
#  define CPSERIES_API  // a library whose only export is the C API (cpseries_c.h)
#elif defined(_WIN32) && defined(CPSERIES_DLL)
#  if defined(CPSERIES_BUILD)
#    define CPSERIES_API __declspec(dllexport)
#  else
#    define CPSERIES_API __declspec(dllimport)
#  endif
#elif defined(CPSERIES_OBFUSCATE) && (defined(__GNUC__) || defined(__clang__))
#  define CPSERIES_API __attribute__((visibility("default")))
#else
#  define CPSERIES_API
#endif

// A socket handle, wide enough for a Windows SOCKET (UINT_PTR) and an fd.
#if defined(_WIN32)
using socket_t = std::uintptr_t;
inline constexpr socket_t invalid_socket = ~static_cast<socket_t>(0);
#else
using socket_t = int;
inline constexpr socket_t invalid_socket = static_cast<socket_t>(-1);
#endif

// ---- models ----
enum class Model { CP650, CP750, CP850, CP950, CP950A };

CPSERIES_API std::optional<Model> parse_model(std::string_view name);
CPSERIES_API const char* model_name(Model model);
CPSERIES_API int default_port(Model model);             // 61412 CP650, 61408 otherwise
CPSERIES_API bool uses_key_value(Model model);          // the CP650's KEY=VALUE dialect
CPSERIES_API const char* line_terminator(Model model);  // "\r\n" CP650, "\n" otherwise

// ---- timers (cpx50.comms.timers) ----
namespace timers {
constexpr double GAP_CP650 = 0.25;
constexpr double GAP_DEFAULT = 0.10;
constexpr double QUERY_TIMEOUT = 1.5;
constexpr double SET_TIMEOUT = 6.0;
constexpr double WATCHDOG = 3.0;
constexpr double WRITE_TIMEOUT = 2.0;
constexpr double CONNECT_TIMEOUT = 5.0;
constexpr double REOPEN_CP650 = 2.0;
CPSERIES_API double gap_seconds(Model model);
CPSERIES_API double reopen_seconds(Model model);
}  // namespace timers

// ---- status ----
enum class Status { Initializing, Ok, Compromised, Missing, Fault };
CPSERIES_API const char* status_name(Status status);

// ---- protocol ----

// The wire text of a SET value, as the Python and Lua clients write it
// (lua/tests/vectors/format_value.tsv): integers in decimal, booleans 1/0,
// whole floats with every digit, other floats as Python's shortest repr.
class Value {
public:
    CPSERIES_API Value(int v);
    CPSERIES_API Value(long v);
    CPSERIES_API Value(long long v);
    CPSERIES_API Value(double v);
    CPSERIES_API Value(bool v);
    CPSERIES_API Value(const char* v);
    CPSERIES_API Value(std::string_view v);
    CPSERIES_API Value(const std::string& v);
    const std::string& wire() const { return text_; }

private:
    std::string text_;
};

CPSERIES_API std::string format_double(double v);

// Throw std::invalid_argument when `param` or `value` would break the line
// framing (a CR or LF) or is not ASCII, like the Python ValueError.
CPSERIES_API std::string format_message(Model model, std::string_view param, const Value& value);
CPSERIES_API std::string format_query(Model model, std::string_view param);

struct Pair {
    std::string_view param;
    std::string_view value;
};
// One reply line as a (param, value) pair, or nothing ("error", a blank
// line, a lone word). The views point into `line`.
CPSERIES_API std::optional<Pair> parse_line(Model model, std::string_view line);
CPSERIES_API std::string_view strip(std::string_view s);  // Python str.strip() on ASCII

// ---- transport ----

// A blocking TCP link built on a non-blocking socket and poll(). Lines are
// split at LF with a trailing CR removed; read_line() returns a view into the
// receive buffer that stays valid until the next read on this connection.
class Connection {
public:
    CPSERIES_API Connection(std::string host, int port, std::string terminator);
    CPSERIES_API ~Connection();
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;

    CPSERIES_API bool connect(double timeout = timers::CONNECT_TIMEOUT);
    CPSERIES_API void close();
    bool is_open() const { return fd_ != invalid_socket; }
    // True once the peer has closed its side and every byte it sent is consumed.
    CPSERIES_API bool peer_closed();
    CPSERIES_API bool send_line(std::string_view line, double timeout = timers::WRITE_TIMEOUT);
    CPSERIES_API std::optional<std::string_view> read_line(double timeout);

private:
    static constexpr std::size_t MAX_LINE = 65536;  // asyncio StreamReader's limit
    bool fill(int wait_ms);                          // poll, then one recv()
    std::string host_;
    int port_;
    std::string terminator_;
    socket_t fd_ = invalid_socket;
    bool closed_ = false;            // EOF seen from the peer
    std::vector<char> in_;           // receive buffer: [head_, tail_) holds unread bytes
    std::size_t head_ = 0, tail_ = 0;
    std::string out_;                // reused send buffer
};

// ---- client ----

struct Options {
    bool auto_reconnect = false;     // re-open a dropped link inline, in get() and run()
    int get_retries = 2;             // extra attempts of a lost or unanswered query
    double watchdog = timers::WATCHDOG;
    std::optional<double> gap;           // default: timers::gap_seconds(model)
    std::optional<double> reopen_delay;  // default: timers::reopen_seconds(model)
};

class Client {
public:
    static constexpr std::size_t QMAX = 10;
    static constexpr int RESYNC_MAX = 32;

    CPSERIES_API Client(std::string host, int port, Model model, Options options = {});

    CPSERIES_API bool connect();
    CPSERIES_API void disconnect();
    CPSERIES_API bool reconnect();

    // Enqueue a SET (coalesced with a queued SET of the same param) and return
    // at once; false when the link is down and auto_reconnect is off. Throws
    // std::invalid_argument for a param or value that cannot be framed.
    CPSERIES_API bool set(std::string_view param, const Value& value, double timeout = timers::SET_TIMEOUT);
    // Send every queued SET, one in flight; stops when the link is down.
    CPSERIES_API void run();
    // Query `param`; its value, or nothing on timeout, `error` or a lost link.
    CPSERIES_API std::optional<std::string> get(std::string_view param, double timeout = timers::QUERY_TIMEOUT);

    Status status() const { return status_; }
    const std::unordered_map<std::string, std::string>& state() const { return state_; }
    std::size_t queued() const { return count_; }
    Model model() const { return model_; }

private:
    struct Command {
        std::string param;
        std::string wire;
        double timeout = timers::SET_TIMEOUT;
    };

    bool link_up();
    bool names(std::string_view name, std::string_view param) const;
    std::optional<std::string_view> value_of(std::optional<std::string_view> response,
                                             std::string_view param) const;
    std::optional<std::string_view> transact(std::string_view line, double timeout,
                                             std::optional<std::string_view> expect_param);
    void set_and_confirm(const Command& command);
    bool send_spaced(std::string_view line);
    void close_link();
    bool open_link();
    void record(std::string_view param, std::string_view value);

    // the fixed command queue (a ring of QMAX slots)
    void enqueue(Command&& command);
    Command dequeue();
    void requeue_front(Command&& command);

    Model model_;
    Options options_;
    Connection conn_;
    double gap_;
    double reopen_;
    Status status_ = Status::Initializing;
    std::unordered_map<std::string, std::string> state_;
    std::array<Command, QMAX> ring_;
    std::size_t first_ = 0, count_ = 0;
    std::chrono::steady_clock::time_point last_activity_{};
    std::optional<std::chrono::steady_clock::time_point> last_send_;
    std::optional<std::chrono::steady_clock::time_point> closed_at_;
    bool send_ok_ = false;
};

}  // namespace cpseries

// cpx50comms (namespace cpx50comms) -- the C++ control client for
// CP650/CP750/CP850/CP950/CP950A
// cinema processors over TCP/IP: the third client, next to the Python
// cpx50.comms and the Lua client, with the same wire protocol and the same rules.
//
//     cpx50comms::Client cp("192.168.1.10", 0, cpx50comms::Model::CP750);
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
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "cpx50comms_export.h"  // CPX50COMMS_API: which symbols are exported

namespace cpx50comms {

// A POSIX socket descriptor.
using socket_t = int;
inline constexpr socket_t invalid_socket = static_cast<socket_t>(-1);

// ---- models ----
enum class Model { CP650, CP750, CP850, CP950, CP950A };

CPX50COMMS_API std::optional<Model> parse_model(std::string_view name);
CPX50COMMS_API const char* model_name(Model model);
CPX50COMMS_API int default_port(Model model);             // 61412 CP650, 61408 otherwise
CPX50COMMS_API bool uses_key_value(Model model);          // the CP650's KEY=VALUE dialect
CPX50COMMS_API const char* line_terminator(Model model);  // "\r\n" CP650, "\n" otherwise

// ---- timers ----
// The same values as the Python module, packages/cpx50-comms/src/cpx50/comms/
// timers.py; keep the two in step.
namespace timers {
constexpr double GAP_CP650 = 0.25;
constexpr double GAP_DEFAULT = 0.10;
constexpr double QUERY_TIMEOUT = 1.5;
constexpr double SET_TIMEOUT = 6.0;
constexpr double WATCHDOG = 3.0;
constexpr double WRITE_TIMEOUT = 2.0;
constexpr double CONNECT_TIMEOUT = 5.0;
constexpr double REOPEN_CP650 = 2.0;
CPX50COMMS_API double gap_seconds(Model model);
CPX50COMMS_API double reopen_seconds(Model model);
}  // namespace timers

// ---- status ----
enum class Status { Initializing, Ok, Compromised, Missing, Fault };
CPX50COMMS_API const char* status_name(Status status);

// ---- protocol ----

// The wire text of a SET value, as the Python and Lua clients write it
// (lua/tests/vectors/format_value.tsv): integers in decimal, booleans 1/0,
// whole floats with every digit, other floats as Python's shortest repr.
class Value {
public:
    CPX50COMMS_API Value(int v);
    CPX50COMMS_API Value(long v);
    CPX50COMMS_API Value(long long v);
    CPX50COMMS_API Value(double v);
    CPX50COMMS_API Value(bool v);
    CPX50COMMS_API Value(const char* v);
    CPX50COMMS_API Value(std::string_view v);
    CPX50COMMS_API Value(const std::string& v);
    const std::string& wire() const { return text_; }

private:
    std::string text_;
};

// The wire helpers (format_message, format_query, parse_line, strip,
// format_double) are declared in cpx50comms_wire.hpp, an internal header that
// is not installed: a consumer of this API never needs them.

// ---- transport ----

// The wire log: every byte the processor sends, as it arrives, and every line
// sent. Received: one line, without its LF but with a CR the unit put before
// it (so the line end shows), whether or not anything reads it as a reply.
// ReceivedCut: bytes that never got their LF (the link closed, or a line over
// the buffer). Sent: the line, without the model's terminator. Called on the
// thread that is in the library call; an exception it throws is swallowed.
enum class Wire { Received, ReceivedCut, Sent };
using WireLog = std::function<void(Wire, std::string_view)>;

// The TCP link (Connection) is in cpx50comms_transport.hpp: internal, not part
// of this API.

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
    // A list reply ends once the link is quiet this long after the last item;
    // at most LIST_MAX items are kept (cpx50.comms.client LIST_QUIET/LIST_MAX).
    static constexpr double LIST_QUIET = 0.3;
    static constexpr std::size_t LIST_MAX = 256;

    CPX50COMMS_API Client(std::string host, int port, Model model, Options options = {});
    CPX50COMMS_API ~Client();
    Client(const Client&) = delete;
    Client& operator=(const Client&) = delete;

    CPX50COMMS_API bool connect();
    CPX50COMMS_API void disconnect();
    CPX50COMMS_API bool reconnect();

    // Enqueue a SET (coalesced with a queued SET of the same param) and return
    // at once; false when the link is down and auto_reconnect is off. Throws
    // std::invalid_argument for a param or value that cannot be framed.
    CPX50COMMS_API bool set(std::string_view param, const Value& value, double timeout = timers::SET_TIMEOUT);
    // Send every queued SET, one in flight; stops when the link is down.
    CPX50COMMS_API void run();
    // Query `param`; its value, or nothing on timeout, `error` or a lost link.
    CPX50COMMS_API std::optional<std::string> get(std::string_view param, double timeout = timers::QUERY_TIMEOUT);
    // Query a list param (`sys.macros`): a header line naming it, then one
    // `N:name` item per line [M1 CP850 Iss2 Table B-1] and no end marker, so
    // the list ends after LIST_QUIET of silence. A header with a value is a
    // one-item list. Nothing on timeout or a lost link; the state records the
    // items joined by '\n'. Throws std::invalid_argument on the CP650, which
    // has no list reply. Mirrors cpx50.comms DolbyCP.get_list.
    CPX50COMMS_API std::optional<std::vector<std::string>> get_list(std::string_view param,
                                                                    double timeout = timers::QUERY_TIMEOUT);

    CPX50COMMS_API Status status() const;
    CPX50COMMS_API const std::unordered_map<std::string, std::string>& state() const;
    CPX50COMMS_API std::size_t queued() const;
    CPX50COMMS_API Model model() const;
    // Why the last get() returned nothing, one entry per attempt (the line
    // sent, then what came back): "" after a get() that was answered.
    CPX50COMMS_API const std::string& last_miss() const;
    // Every line received and sent on this client's link (see Wire); an
    // empty function turns the log off.
    CPX50COMMS_API void set_wire_log(WireLog log);

private:
    struct Command {
        std::string param;
        std::string wire;
        double timeout = timers::SET_TIMEOUT;
        std::string value;               // the value's wire text, as recorded on an ACK
    };

    // What transact() brings back.
    struct Reply {
        bool sent = false;                          // the line reached the wire
        std::optional<std::string_view> line;       // the answer, a view into the connection's buffer
        std::string unmatched;                      // the first line read that was not the answer
    };

    bool link_up();
    bool names(std::string_view name, std::string_view param) const;
    std::optional<std::string_view> value_of(std::optional<std::string_view> response,
                                             std::string_view param) const;
    Reply transact(std::string_view line, double timeout, std::optional<std::string_view> expect_param);
    std::optional<std::vector<std::string>> transact_list(std::string_view line, std::string_view param,
                                                          double timeout);
    bool set_and_confirm(const Command& command);   // false: the SET never reached the wire
    bool send_spaced(std::string_view line);
    void close_link();
    bool open_link();
    void record(std::string_view param, std::string_view value);

    // the fixed command queue (a ring of QMAX slots)
    void enqueue(Command&& command);
    Command dequeue();
    void requeue_front(Command&& command);

    // The data, and the link (a Connection, see cpx50comms_transport.hpp), live
    // in the implementation: the installed header shows none of them.
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace cpx50comms

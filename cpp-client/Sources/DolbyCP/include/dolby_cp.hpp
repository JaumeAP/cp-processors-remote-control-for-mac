// dolby_cp -- the C++ control client for Dolby CP650/CP750/CP850/CP950/CP950A
// processors over TCP/IP: the third client, next to the Python cpx50.comms
// and the Lua dolby_cp_lua, with the same wire protocol and the same rules.
//
//     dolbycp::Client cp("192.168.1.10", 0, dolbycp::Model::CP750);
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
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

namespace dolbycp {

// ---- models ----
enum class Model { CP650, CP750, CP850, CP950, CP950A };

std::optional<Model> parse_model(std::string_view name);
const char* model_name(Model model);
int default_port(Model model);             // 61412 CP650, 61408 otherwise
bool uses_key_value(Model model);          // the CP650's KEY=VALUE dialect
const char* line_terminator(Model model);  // "\r\n" CP650, "\n" otherwise

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
double gap_seconds(Model model);
double reopen_seconds(Model model);
}  // namespace timers

// ---- status ----
enum class Status { Initializing, Ok, Compromised, Missing, Fault };
const char* status_name(Status status);

// ---- protocol ----

// The wire text of a SET value, as the Python and Lua clients write it
// (lua/tests/vectors/format_value.tsv): integers in decimal, booleans 1/0,
// whole floats with every digit, other floats as Python's shortest repr.
class Value {
public:
    Value(int v);
    Value(long v);
    Value(long long v);
    Value(double v);
    Value(bool v);
    Value(const char* v);
    Value(std::string_view v);
    Value(const std::string& v);
    const std::string& wire() const { return text_; }

private:
    std::string text_;
};

std::string format_double(double v);

// Throw std::invalid_argument when `param` or `value` would break the line
// framing (a CR or LF) or is not ASCII, like the Python ValueError.
std::string format_message(Model model, std::string_view param, const Value& value);
std::string format_query(Model model, std::string_view param);

struct Pair {
    std::string_view param;
    std::string_view value;
};
// One reply line as a (param, value) pair, or nothing ("error", a blank
// line, a lone word). The views point into `line`.
std::optional<Pair> parse_line(Model model, std::string_view line);
std::string_view strip(std::string_view s);  // Python str.strip() on ASCII

// ---- transport ----

// A blocking TCP link built on a non-blocking socket and poll(). Lines are
// split at LF with a trailing CR removed; read_line() returns a view into the
// receive buffer that stays valid until the next read on this connection.
class Connection {
public:
    Connection(std::string host, int port, std::string terminator);
    ~Connection();
    Connection(const Connection&) = delete;
    Connection& operator=(const Connection&) = delete;

    bool connect(double timeout = timers::CONNECT_TIMEOUT);
    void close();
    bool is_open() const { return fd_ >= 0; }
    // True once the peer has closed its side and every byte it sent is consumed.
    bool peer_closed();
    bool send_line(std::string_view line, double timeout = timers::WRITE_TIMEOUT);
    std::optional<std::string_view> read_line(double timeout);

private:
    static constexpr std::size_t MAX_LINE = 65536;  // asyncio StreamReader's limit
    bool fill(int wait_ms);                          // poll, then one recv()
    std::string host_;
    int port_;
    std::string terminator_;
    int fd_ = -1;
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

    Client(std::string host, int port, Model model, Options options = {});

    bool connect();
    void disconnect();
    bool reconnect();

    // Enqueue a SET (coalesced with a queued SET of the same param) and return
    // at once; false when the link is down and auto_reconnect is off. Throws
    // std::invalid_argument for a param or value that cannot be framed.
    bool set(std::string_view param, const Value& value, double timeout = timers::SET_TIMEOUT);
    // Send every queued SET, one in flight; stops when the link is down.
    void run();
    // Query `param`; its value, or nothing on timeout, `error` or a lost link.
    std::optional<std::string> get(std::string_view param, double timeout = timers::QUERY_TIMEOUT);

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

}  // namespace dolbycp

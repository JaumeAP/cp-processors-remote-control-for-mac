// dolby_cp -- implementation. See dolby_cp.hpp for the rules it follows.
#include "dolby_cp.hpp"

#include <algorithm>
#include <cerrno>
#include <charconv>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <stdexcept>
#include <thread>
#include <utility>

#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

namespace dolbycp {

using Clock = std::chrono::steady_clock;

namespace {

double seconds_since(Clock::time_point t) {
    return std::chrono::duration<double>(Clock::now() - t).count();
}

// Milliseconds left until `deadline`, rounded up, for poll(); 0 once past.
int ms_until(Clock::time_point deadline) {
    const auto left = deadline - Clock::now();
    if (left <= Clock::duration::zero()) return 0;
    const auto ms = std::chrono::duration_cast<std::chrono::microseconds>(left).count();
    return static_cast<int>(std::min<long long>((ms + 999) / 1000, 1LL << 30));
}

Clock::time_point after(double seconds) {
    return Clock::now() + std::chrono::duration_cast<Clock::duration>(
                              std::chrono::duration<double>(std::max(0.0, seconds)));
}

void sleep_for_seconds(double seconds) {
    if (seconds > 0) std::this_thread::sleep_for(std::chrono::duration<double>(seconds));
}

// Python's str.isspace() on an ASCII byte: space, \t \n \v \f \r, \x1c-\x1f.
constexpr bool is_ws(char c) {
    return c == ' ' || (c >= '\t' && c <= '\r') || (c >= '\x1c' && c <= '\x1f');
}

char ascii_lower(char c) { return (c >= 'A' && c <= 'Z') ? static_cast<char>(c + 32) : c; }

bool iequals(std::string_view a, std::string_view b) {
    if (a.size() != b.size()) return false;
    for (std::size_t i = 0; i < a.size(); ++i)
        if (ascii_lower(a[i]) != ascii_lower(b[i])) return false;
    return true;
}

void reject_control(std::string_view s, const char* what) {
    for (char c : s) {
        if (c == '\n' || c == '\r')
            throw std::invalid_argument(std::string(what) + " contains a newline/CR (" + std::string(s) +
                                        "); would corrupt the wire framing");
        if (static_cast<unsigned char>(c) >= 0x80)
            throw std::invalid_argument(std::string(what) + " contains a non-ASCII character (" +
                                        std::string(s) + "); the wire is ASCII");
    }
}

// Python repr layout of `digits` x 10^(exp10 - len(digits) + 1): scientific
// when the decimal exponent is < -4 or >= 16 (lua protocol.layout_repr).
std::string layout_repr(std::string digits, int exp10) {
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    if (exp10 < -4 || exp10 >= 16) {
        std::string out(1, digits[0]);
        if (digits.size() > 1) out += "." + digits.substr(1);
        char e[16];
        std::snprintf(e, sizeof e, "e%c%02d", exp10 < 0 ? '-' : '+', std::abs(exp10));
        return out + e;
    }
    if (exp10 >= 0) {
        const auto int_len = static_cast<std::size_t>(exp10) + 1;
        if (digits.size() <= int_len) return digits + std::string(int_len - digits.size(), '0');
        return digits.substr(0, int_len) + "." + digits.substr(int_len);
    }
    return "0." + std::string(static_cast<std::size_t>(-exp10 - 1), '0') + digits;
}

template <typename Int>
std::string int_text(Int v) {
    char b[32];
    const auto r = std::to_chars(b, b + sizeof b, v);
    return std::string(b, r.ptr);
}

}  // namespace

// ---- models ----

std::optional<Model> parse_model(std::string_view name) {
    if (name == "CP650") return Model::CP650;
    if (name == "CP750") return Model::CP750;
    if (name == "CP850") return Model::CP850;
    if (name == "CP950") return Model::CP950;
    if (name == "CP950A") return Model::CP950A;
    return std::nullopt;
}

const char* model_name(Model model) {
    switch (model) {
    case Model::CP650: return "CP650";
    case Model::CP750: return "CP750";
    case Model::CP850: return "CP850";
    case Model::CP950: return "CP950";
    case Model::CP950A: return "CP950A";
    }
    return "?";
}

int default_port(Model model) { return model == Model::CP650 ? 61412 : 61408; }
bool uses_key_value(Model model) { return model == Model::CP650; }
const char* line_terminator(Model model) { return uses_key_value(model) ? "\r\n" : "\n"; }

double timers::gap_seconds(Model model) { return model == Model::CP650 ? GAP_CP650 : GAP_DEFAULT; }
double timers::reopen_seconds(Model model) { return model == Model::CP650 ? REOPEN_CP650 : 0.0; }

const char* status_name(Status status) {
    switch (status) {
    case Status::Initializing: return "INITIALIZING";
    case Status::Ok: return "OK";
    case Status::Compromised: return "COMPROMISED";
    case Status::Missing: return "MISSING";
    case Status::Fault: return "FAULT";
    }
    return "?";
}

// ---- protocol ----

std::string format_double(double v) {
    if (std::isnan(v)) return "nan";
    if (std::isinf(v)) return v > 0 ? "inf" : "-inf";
    if (v == std::floor(v)) {
        if (v == 0) return "0";                       // -0.0 too
        char b[400];                                  // 1.8e308 has 309 digits
        std::snprintf(b, sizeof b, "%.0f", v);
        return b;
    }
    // Shortest round-trip digits, then Python's layout.
    char b[64];
    const auto r = std::to_chars(b, b + sizeof b, std::fabs(v), std::chars_format::scientific);
    const std::string_view sci(b, static_cast<std::size_t>(r.ptr - b));   // d.ddde-XX
    const std::size_t e = sci.find('e');
    std::string digits;
    for (char c : sci.substr(0, e))
        if (c != '.') digits.push_back(c);
    int exp10 = 0;
    std::from_chars(sci.data() + e + 1 + (sci[e + 1] == '+' ? 1 : 0), sci.data() + sci.size(), exp10);
    return (v < 0 ? "-" : "") + layout_repr(std::move(digits), exp10);
}

Value::Value(int v) : text_(int_text(v)) {}
Value::Value(long v) : text_(int_text(v)) {}
Value::Value(long long v) : text_(int_text(v)) {}
Value::Value(double v) : text_(format_double(v)) {}
Value::Value(bool v) : text_(v ? "1" : "0") {}
Value::Value(const char* v) : text_(v) {}
Value::Value(std::string_view v) : text_(v) {}
Value::Value(const std::string& v) : text_(v) {}

std::string format_message(Model model, std::string_view param, const Value& value) {
    reject_control(param, "param");
    reject_control(value.wire(), "value");
    std::string out;
    out.reserve(param.size() + 1 + value.wire().size());
    out.append(param).push_back(uses_key_value(model) ? '=' : ' ');
    out.append(value.wire());
    return out;
}

std::string format_query(Model model, std::string_view param) {
    reject_control(param, "param");
    std::string out(param);
    out.append(uses_key_value(model) ? "=?" : " ?");
    return out;
}

std::string_view strip(std::string_view s) {
    std::size_t a = 0, b = s.size();
    while (a < b && is_ws(s[a])) ++a;
    while (b > a && is_ws(s[b - 1])) --b;
    return s.substr(a, b - a);
}

std::optional<Pair> parse_line(Model model, std::string_view line) {
    line = strip(line);
    if (line.empty()) return std::nullopt;
    if (uses_key_value(model)) {
        const std::size_t eq = line.find('=');
        if (eq == std::string_view::npos) return std::nullopt;
        return Pair{strip(line.substr(0, eq)), strip(line.substr(eq + 1))};
    }
    // Python's line.split(None, 1): a param, white space, then a value.
    std::size_t i = 0;
    while (i < line.size() && !is_ws(line[i])) ++i;
    if (i == line.size()) return std::nullopt;
    return Pair{line.substr(0, i), strip(line.substr(i))};
}

// ---- transport ----

Connection::Connection(std::string host, int port, std::string terminator)
    : host_(std::move(host)), port_(port), terminator_(std::move(terminator)), in_(MAX_LINE * 2) {}

Connection::~Connection() { close(); }

bool Connection::connect(double timeout) {
    close();
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    addrinfo* found = nullptr;
    const std::string port = int_text(port_);
    if (::getaddrinfo(host_.c_str(), port.c_str(), &hints, &found) != 0) return false;
    const auto deadline = after(timeout);
    for (addrinfo* a = found; a != nullptr && fd_ < 0; a = a->ai_next) {
        const int fd = ::socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        ::fcntl(fd, F_SETFL, ::fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
        const int one = 1;
        ::setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
        ::setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        bool ok = ::connect(fd, a->ai_addr, a->ai_addrlen) == 0;
        if (!ok && errno == EINPROGRESS) {
            pollfd p{fd, POLLOUT, 0};
            int rc;
            do rc = ::poll(&p, 1, ms_until(deadline));
            while (rc < 0 && errno == EINTR);
            int err = 0;
            socklen_t len = sizeof err;
            ok = rc > 0 && ::getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0;
        }
        if (ok) fd_ = fd;
        else ::close(fd);
    }
    ::freeaddrinfo(found);
    head_ = tail_ = 0;
    closed_ = false;
    return fd_ >= 0;
}

void Connection::close() {
    if (fd_ >= 0) ::close(fd_);
    fd_ = -1;
    head_ = tail_ = 0;
    closed_ = false;
}

bool Connection::fill(int wait_ms) {
    if (fd_ < 0 || closed_) return false;
    if (head_ > 0 && tail_ == in_.size()) {          // compact before reading more
        std::memmove(in_.data(), in_.data() + head_, tail_ - head_);
        tail_ -= head_;
        head_ = 0;
    }
    if (tail_ == in_.size()) {                       // a line longer than MAX_LINE * 2:
        head_ = tail_ = 0;                           // drop it, it can never be a reply
    }
    pollfd p{fd_, POLLIN, 0};
    int rc;
    do rc = ::poll(&p, 1, wait_ms);
    while (rc < 0 && errno == EINTR);
    if (rc <= 0) return false;
    const ssize_t n = ::recv(fd_, in_.data() + tail_, in_.size() - tail_, 0);
    if (n > 0) {
        tail_ += static_cast<std::size_t>(n);
        return true;
    }
    if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)) return false;
    closed_ = true;                                  // EOF, reset or error: the peer is gone
    return false;
}

bool Connection::peer_closed() {
    if (fd_ < 0) return false;
    if (!closed_) fill(0);
    return closed_ && head_ == tail_;
}

bool Connection::send_line(std::string_view line, double timeout) {
    if (fd_ < 0) return false;
    out_.assign(line);
    out_.append(terminator_);
    const auto deadline = after(timeout);
    std::size_t off = 0;
#ifdef MSG_NOSIGNAL
    constexpr int flags = MSG_NOSIGNAL;
#else
    constexpr int flags = 0;
#endif
    while (off < out_.size()) {
        const ssize_t n = ::send(fd_, out_.data() + off, out_.size() - off, flags);
        if (n > 0) {
            off += static_cast<std::size_t>(n);
            continue;
        }
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            const int wait = ms_until(deadline);
            pollfd p{fd_, POLLOUT, 0};
            if (wait == 0 || ::poll(&p, 1, wait) <= 0) return false;
            continue;
        }
        return false;
    }
    return true;
}

std::optional<std::string_view> Connection::read_line(double timeout) {
    if (fd_ < 0) return std::nullopt;
    const auto deadline = after(timeout);
    for (;;) {
        if (const void* hit = std::memchr(in_.data() + head_, '\n', tail_ - head_)) {
            const auto nl = static_cast<std::size_t>(static_cast<const char*>(hit) - in_.data());
            std::size_t end = nl;
            if (end > head_ && in_[end - 1] == '\r') --end;
            const std::string_view line(in_.data() + head_, end - head_);
            head_ = nl + 1;
            if (head_ == tail_) head_ = tail_ = 0;   // the next read starts at the front
            // The view stays valid: the buffer is only moved by the next read.
            return line;
        }
        if (closed_) {
            // Peer closed mid-line: the cut point is unknown, so the tail is
            // never a reply (lua connection.read_line).
            head_ = tail_ = 0;
            return std::nullopt;
        }
        // Wait for more bytes; the next pass searches the whole unread part
        // again (fill() may have compacted it to the front).
        if (!fill(ms_until(deadline)) && !closed_ && ms_until(deadline) == 0) return std::nullopt;
    }
}

// ---- client ----

Client::Client(std::string host, int port, Model model, Options options)
    : model_(model),
      options_(options),
      conn_(std::move(host), port > 0 ? port : default_port(model), line_terminator(model)),
      gap_(options.gap.value_or(timers::gap_seconds(model))),
      reopen_(options.reopen_delay.value_or(timers::reopen_seconds(model))) {
    state_.reserve(64);
}

bool Client::open_link() {
    if (closed_at_) sleep_for_seconds(reopen_ - seconds_since(*closed_at_));
    const bool ok = conn_.connect();
    last_send_.reset();
    return ok;
}

void Client::close_link() {
    conn_.close();
    closed_at_ = Clock::now();
}

bool Client::connect() {
    const bool ok = open_link();
    status_ = ok ? Status::Ok : Status::Missing;
    if (ok) last_activity_ = Clock::now();
    return ok;
}

void Client::disconnect() {
    close_link();
    status_ = Status::Missing;
}

bool Client::reconnect() {
    close_link();
    return connect();
}

bool Client::link_up() { return conn_.is_open() && !conn_.peer_closed(); }

bool Client::names(std::string_view name, std::string_view param) const {
    // CP650 keys and CP750 names are not case sensitive [CP650 Iss6 App. D,
    // CP750 Iss5 7.2.2]; the CP850/CP950/CP950A manuals do not say.
    if (model_ == Model::CP650 || model_ == Model::CP750) return iequals(name, param);
    return name == param;
}

std::optional<std::string_view> Client::value_of(std::optional<std::string_view> response,
                                                 std::string_view param) const {
    if (!response) return std::nullopt;
    const auto pair = parse_line(model_, *response);
    if (pair && names(pair->param, param)) return pair->value;
    return std::nullopt;
}

void Client::record(std::string_view param, std::string_view value) {
    auto it = state_.find(std::string(param));
    if (it == state_.end()) state_.emplace(std::string(param), std::string(value));
    else it->second.assign(value);
}

// Keep the inter-command gap measured from the previous send, then send.
bool Client::send_spaced(std::string_view line) {
    if (last_send_) sleep_for_seconds(gap_ - seconds_since(*last_send_));
    const bool ok = conn_.send_line(line);
    last_send_ = Clock::now();
    return ok;
}

static bool is_ack(std::string_view response) { return iequals(strip(response), "ACK"); }

std::optional<std::string_view> Client::transact(std::string_view line, double timeout,
                                                 std::optional<std::string_view> expect_param) {
    send_ok_ = false;
    if (!conn_.is_open()) {
        status_ = Status::Missing;
        return std::nullopt;
    }
    if (!send_spaced(line)) {
        status_ = Status::Missing;                   // a lost link
        return std::nullopt;
    }
    send_ok_ = true;
    auto response = conn_.read_line(timeout);
    if (model_ == Model::CP650 && response && *response == line)
        response = conn_.read_line(timeout);         // CP650 echo guard (the unit echoes nothing)
    bool got_line = response.has_value(), parsed_ok = false;
    std::optional<Pair> pair;
    if (response) {
        pair = parse_line(model_, *response);
        parsed_ok = pair.has_value() || is_ack(*response);
    }
    if (expect_param && response) {
        for (int skipped = 0; !(pair && names(pair->param, *expect_param)); ++skipped) {
            if (skipped >= RESYNC_MAX) {             // flood cap; the link is still alive
                response.reset();
                break;
            }
            response = conn_.read_line(timeout);
            if (!response) break;                    // no more lines within the timeout
            pair = parse_line(model_, *response);
            if (pair || is_ack(*response)) parsed_ok = true;
        }
    }
    if (parsed_ok) {
        status_ = Status::Ok;
        last_activity_ = Clock::now();
    } else if (!got_line &&
               (!link_up() || (expect_param && seconds_since(last_activity_) >= options_.watchdog))) {
        // A lost link is MISSING at once; on a live link only an unanswered
        // query, once nothing has succeeded for the watchdog window.
        status_ = Status::Missing;
    }
    return response;
}

bool Client::set(std::string_view param, const Value& value, double timeout) {
    Command command{std::string(param), format_message(model_, param, value), timeout};
    if (!link_up() && !options_.auto_reconnect) return false;
    enqueue(std::move(command));
    return true;
}

std::optional<std::string> Client::get(std::string_view param, double timeout) {
    if (!link_up() && options_.auto_reconnect) reconnect();
    if (!link_up()) {
        status_ = Status::Missing;
        return std::nullopt;
    }
    const std::string line = format_query(model_, param);
    const int attempts = options_.get_retries + 1;
    for (int i = 1; i <= attempts; ++i) {
        if (const auto value = value_of(transact(line, timeout, param), param)) {
            std::string out(*value);
            record(param, out);
            return out;
        }
        if (i < attempts && !link_up() && options_.auto_reconnect) reconnect();
    }
    return std::nullopt;
}

// A CP650 SET has no output [CP650 Iss6 Table D-2]: send it, then confirm it
// with a `key=?` query and record what the unit answers.
void Client::set_and_confirm(const Command& command) {
    send_ok_ = false;
    if (!conn_.is_open() || !send_spaced(command.wire)) {
        status_ = Status::Missing;
        return;
    }
    send_ok_ = true;
    const std::string query = format_query(model_, command.param);
    if (const auto value = value_of(transact(query, command.timeout, command.param), command.param))
        record(command.param, *value);
    send_ok_ = true;                                 // the SET reached the wire
}

void Client::run() {
    while (count_ > 0) {
        if (!link_up()) {
            if (options_.auto_reconnect) reconnect();
            if (!link_up()) break;
        }
        Command command = dequeue();
        if (model_ == Model::CP650) {
            set_and_confirm(command);
        } else {
            const auto response = transact(command.wire, command.timeout, std::nullopt);
            if (response) {
                if (is_ack(*response)) record(command.param, command.wire.substr(command.param.size() + 1));
                else if (const auto value = value_of(response, command.param)) record(command.param, *value);
            }
        }
        if (!send_ok_) {                             // never reached the wire: retry later
            requeue_front(std::move(command));
            break;
        }
    }
}

// ---- the fixed queue ----

void Client::enqueue(Command&& command) {
    for (std::size_t i = 0; i < count_; ++i) {      // coalesce a SET of the same param
        Command& slot = ring_[(first_ + i) % QMAX];
        if (slot.param == command.param) {
            slot = std::move(command);
            return;
        }
    }
    if (count_ == QMAX) {                            // saturation: drop the oldest
        first_ = (first_ + 1) % QMAX;
        --count_;
    }
    ring_[(first_ + count_) % QMAX] = std::move(command);
    ++count_;
}

Client::Command Client::dequeue() {
    Command command = std::move(ring_[first_]);
    first_ = (first_ + 1) % QMAX;
    --count_;
    return command;
}

void Client::requeue_front(Command&& command) {
    for (std::size_t i = 0; i < count_; ++i)        // a newer SET of the param wins
        if (ring_[(first_ + i) % QMAX].param == command.param) return;
    if (count_ == QMAX) --count_;                    // over capacity: drop the newest tail
    first_ = (first_ + QMAX - 1) % QMAX;
    ring_[first_] = std::move(command);
    ++count_;
}

}  // namespace dolbycp

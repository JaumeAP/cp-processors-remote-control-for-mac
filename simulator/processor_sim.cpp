// processor_sim -- a C++17 simulator of the processors' control channel.
//
// A live, stateful fake CP650-CP950A processor served over TCP. A SET updates
// state, a later GET reads it back; each model's wire dialect is spoken, the
// documented CP750 ranges are applied (clipping like the doc says real
// hardware does), and the CP650 echoes the raw command before its response.
//
// POSIX only (Linux, macOS). No dependencies beyond the C++17 standard
// library and BSD sockets. Its in-process hooks map to
// the command line: --serial (serve_fd), --seed (initial_state), --log
// (received) and SIGUSR1 (drop_connections).
//
//     processor_sim --model CP850 --port 61408

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <termios.h>
#include <sys/types.h>
#include <unistd.h>

#include <atomic>
#include <cctype>
#include <cerrno>
#include <algorithm>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <list>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>
#include <system_error>
#include <thread>
#include <utility>
#include <vector>

namespace {

// ---- models ----

struct ModelConfig {
    int port;
    bool key_value;  // CP650 KEY=VALUE dialect
};

const std::map<std::string, ModelConfig> MODELS = {
    {"CP650", {61412, true}},
    {"CP750", {61408, false}},
    {"CP850", {61408, false}},
    {"CP950", {61408, false}},
    {"CP950A", {61408, false}},
};

const std::map<std::string, std::pair<double, double>> CP750_PARAM_RANGES = {
    {"cp750.sys.master_level", {0, 96}},
    {"cp750.sys.ch_level", {-96, 12}},
    {"cp750.sys.mute", {0, 1}},
    {"cp750.sys.surround_delay", {0, 150}},
    {"cp750.sys.subwoofer_filter", {50, 100}},
    {"cp750.sys.eq", {-60, 60}},
    {"cp750.sys.mute_fade_out_time", {200, 5000}},
};

bool starts_with(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

const std::pair<double, double>* range_of(const std::string& param) {
    auto it = CP750_PARAM_RANGES.find(param);
    if (it != CP750_PARAM_RANGES.end()) return &it->second;
    const char* key = nullptr;
    if (starts_with(param, "cp750.sys.ch_level_")) key = "cp750.sys.ch_level";
    else if (starts_with(param, "cp750.sys.eq_")) key = "cp750.sys.eq";
    if (!key) return nullptr;
    return &CP750_PARAM_RANGES.at(key);
}

// ---- Python-compatible text handling ----

// Characters Python's str.isspace() accepts in an ASCII-decoded line.
bool py_space(unsigned char c) {
    return c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f);
}

std::string py_strip(const std::string& s) {
    size_t a = 0, b = s.size();
    while (a < b && py_space(s[a])) ++a;
    while (b > a && py_space(s[b - 1])) --b;
    return s.substr(a, b - a);
}

// bytes.decode('ascii', 'replace'): each byte >= 0x80 becomes U+FFFD.
std::string ascii_replace(const std::string& raw) {
    std::string out;
    out.reserve(raw.size());
    for (unsigned char c : raw) {
        if (c < 0x80) out.push_back(char(c));
        else out += "\xEF\xBF\xBD";
    }
    return out;
}

bool is_digit(char c) { return c >= '0' && c <= '9'; }

// float(str) as Python parses it: optional sign, digits with '_' between
// digits, optional fraction and exponent, or inf / infinity / nan.
bool py_float(const std::string& s, double& out) {
    std::string lower;
    for (char c : s) lower.push_back(char(std::tolower((unsigned char)c)));
    size_t i = 0;
    if (!lower.empty() && (lower[0] == '+' || lower[0] == '-')) i = 1;
    const std::string word = lower.substr(i);
    const bool neg = !lower.empty() && lower[0] == '-';
    if (word == "inf" || word == "infinity") {
        out = neg ? -INFINITY : INFINITY;
        return true;
    }
    if (word == "nan") {
        out = NAN;
        return true;
    }
    std::string clean;
    for (size_t k = 0; k < s.size(); ++k) {
        if (s[k] == '_') {
            if (k == 0 || k + 1 >= s.size() || !is_digit(s[k - 1]) || !is_digit(s[k + 1]))
                return false;
            continue;
        }
        clean.push_back(s[k]);
    }
    size_t p = 0;
    if (p < clean.size() && (clean[p] == '+' || clean[p] == '-')) ++p;
    size_t int_digits = 0, frac_digits = 0;
    while (p < clean.size() && is_digit(clean[p])) { ++p; ++int_digits; }
    if (p < clean.size() && clean[p] == '.') {
        ++p;
        while (p < clean.size() && is_digit(clean[p])) { ++p; ++frac_digits; }
    }
    if (int_digits + frac_digits == 0) return false;
    if (p < clean.size() && (clean[p] == 'e' || clean[p] == 'E')) {
        ++p;
        if (p < clean.size() && (clean[p] == '+' || clean[p] == '-')) ++p;
        size_t exp_digits = 0;
        while (p < clean.size() && is_digit(clean[p])) { ++p; ++exp_digits; }
        if (exp_digits == 0) return false;
    }
    if (p != clean.size()) return false;
    out = std::strtod(clean.c_str(), nullptr);
    return true;
}

// str(float) as Python's repr: the shortest digit string that round-trips,
// scientific form when the decimal exponent is < -4 or >= 16. printf's
// correctly rounded n-digit string can fail to round-trip where a neighbouring
// n-digit string does (the narrower interval below a power of two), so the
// neighbours are tried before moving to n + 1 digits, as Python's algorithm
// would.
std::string py_float_repr(double d) {
    if (std::isnan(d)) return "nan";
    if (std::isinf(d)) return d < 0 ? "-inf" : "inf";
    const bool neg = std::signbit(d);
    const double a = std::fabs(d);
    std::string digits;
    int exp10 = 0;
    for (int n = 1; n <= 17; ++n) {
        char buf[64];
        std::snprintf(buf, sizeof buf, "%.*e", n - 1, a);
        const char* epos = std::strchr(buf, 'e');
        const int e = std::atoi(epos + 1);
        std::uint64_t m = 0;
        for (const char* q = buf; q < epos; ++q)
            if (*q != '.') m = m * 10 + std::uint64_t(*q - '0');
        bool found = false;
        for (std::uint64_t cand : {m, m + 1, m - 1}) {
            if (cand == 0) continue;
            char tmp[64];
            std::snprintf(tmp, sizeof tmp, "%llue%d", (unsigned long long)cand, e - (n - 1));
            if (std::strtod(tmp, nullptr) == a) {
                digits = std::to_string(cand);
                exp10 = e - (n - 1) + int(digits.size()) - 1;
                found = true;
                break;
            }
        }
        if (found) break;
    }
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    std::string out;
    if (exp10 < -4 || exp10 >= 16) {
        out = digits.substr(0, 1);
        if (digits.size() > 1) out += "." + digits.substr(1);
        char ebuf[16];
        std::snprintf(ebuf, sizeof ebuf, "e%c%02d", exp10 < 0 ? '-' : '+', std::abs(exp10));
        out += ebuf;
    } else if (exp10 >= 0) {
        const size_t int_len = size_t(exp10) + 1;
        if (digits.size() <= int_len) {
            out = digits + std::string(int_len - digits.size(), '0');
        } else {
            out = digits.substr(0, int_len) + "." + digits.substr(int_len);
        }
    } else {
        out = "0." + std::string(size_t(-exp10 - 1), '0') + digits;
    }
    return neg ? "-" + out : out;
}

// Whole numbers print as integers, everything else as Python's float repr
// (protocol._fmt_value).
std::string fmt_number(double d) {
    if (std::isfinite(d) && d == std::floor(d)) {
        if (std::fabs(d) < 9.2e18) return std::to_string((long long)d);
        char buf[400];
        std::snprintf(buf, sizeof buf, "%.0f", d);
        return buf;
    }
    return py_float_repr(d);
}

std::atomic<bool> g_stop{false};
std::atomic<bool> g_drop{false};

// ---- state ----

struct Value {
    bool numeric = false;
    bool is_list = false;               // a multi-line reply: the param, then one line per item
    double num = 0;
    std::string text;
    std::vector<std::string> items;

    std::string wire() const { return numeric ? fmt_number(num) : text; }
};

// ---- plugin profile ----

// What the control plugin polls on each model, with plausible values:
// fader 70 on the wire is fader 7.0 in the plugin. The macro list is a
// multi-line reply, as the real CP850/CP950/CP950A answer `sys.macros ?`.
struct Profile {
    std::vector<std::pair<std::string, std::string>> values;
    std::vector<std::pair<std::string, std::vector<std::string>>> lists;
};

Profile plugin_profile(const std::string& model) {
    if (model == "CP650")
        return {{{"fader_level", "70"}, {"mute", "0"}, {"format_button", "1"},
                 {"format_list", "01, 04, 05, 10, 93, 94, 95, 99"}}, {}};
    if (model == "CP750")
        return {{{"cp750.sysinfo.version", "1.4.2"}, {"cp750.sys.fader", "70"}, {"cp750.sys.mute", "0"},
                 {"cp750.sys.input_mode", "analog"}}, {}};
    return {{{"sys.fader", "70"}, {"sys.mute", "0"}, {"sys.macro_preset", "1"},
             {"sys.macro_name", "5.1 + Dolby Atmos"}},
            {{"sys.macros", {"3:7.1 + Dolby Atmos", "1:5.1 + Dolby Atmos", "4:Music", "11:RCA",
                             "7:BNC 1", "6:BNC 2", "9:HDMI"}}}};
}

// ---- simulator ----

struct Options {
    std::string model = "CP750";
    std::string host = "127.0.0.1";
    int port = -1;  // -1: the model's documented port
    double latency = 0.0;
    long drop_after = -1;  // -1: never
    bool clip = true;
    bool silent = false;
    bool partial_response = false;
    double write_timeout = 2.0;   // seconds a send may wait on a client that is not reading
    double idle_timeout = 300.0;  // seconds a TCP client may stay silent before it is dropped
    bool log = false;
    bool control = false;  // read control commands on stdin (see Sim::control)
    std::vector<std::pair<std::string, std::string>> seeds;
    std::vector<std::pair<std::string, std::vector<std::string>>> seed_lists;
    bool profile = false;  // seed what the control plugin polls
    std::vector<std::string> serial;
    std::vector<int> fds;  // inherited descriptors to serve, like serve_fd()
};

enum class Outcome { None, Reply, Fatal };

class Sim {
public:
    explicit Sim(Options o)
        : opt_(std::move(o)),
          key_value_(MODELS.at(opt_.model).key_value),
          latency_(opt_.latency),
          drop_after_(opt_.drop_after),
          clip_(opt_.clip),
          silent_(opt_.silent),
          partial_(opt_.partial_response) {
        if (opt_.profile) {
            const Profile p = plugin_profile(opt_.model);
            for (const auto& kv : p.values) {
                Value v;
                v.text = kv.second;
                state_[kv.first] = v;
            }
            for (const auto& kv : p.lists) set_list(kv.first, kv.second);
        }
        for (const auto& kv : opt_.seeds) {
            Value v;
            v.text = kv.second;
            state_[kv.first] = v;
        }
        for (const auto& kv : opt_.seed_lists) set_list(kv.first, kv.second);
    }

    // Serve one connection until it ends. Mirrors ProcessorSim._serve.
    // `tcp` enables the idle timeout (a serial line stays open while quiet).
    void serve(int fd, bool tcp = true) {
        std::string buf;
        long count = 0;
        char chunk[CHUNK];
        bool eof = false;
        while (!eof) {
            std::string raw;
            if (!read_line(fd, buf, chunk, raw, eof, tcp ? opt_.idle_timeout : 0.0)) break;
            const std::string line = rstrip_crlf(ascii_replace(raw));
            ++count;
            if (opt_.log || record_) {
                std::lock_guard<std::mutex> lock(log_mu());
                if (record_) received_.push_back(line);
            }
            trace("recv", line);

            if (latency_ > 0.0 && !sleep_interruptibly(latency_)) break;

            const bool silent = silent_;
            // The CP650 echoes the received bytes untouched (a byte the line
            // decode replaced for parsing is still echoed as it came).
            if (opt_.model == "CP650" && !silent) {
                const std::string echo = rstrip_crlf(raw);
                trace("send", echo);
                if (!send_all(fd, echo + "\n", opt_.write_timeout)) break;
            }

            std::string reply;
            Outcome out = silent ? Outcome::None : respond(line, reply);
            if (out == Outcome::Fatal) break;
            if (out == Outcome::Reply) {
                trace("send", reply);
                if (partial_ && reply.size() > 1) {
                    send_all(fd, reply.substr(0, reply.size() / 2), opt_.write_timeout);
                    break;
                }
                if (!send_all(fd, reply + "\n", opt_.write_timeout)) break;
            }
            const long drop_after = drop_after_;
            if (drop_after >= 0 && count >= drop_after) break;
        }
    }

    // --log: one line per received line and per line sent, stamped with the
    // seconds since the simulator started, on stderr.
    void trace(const char* dir, const std::string& text) {
        if (!opt_.log) return;
        const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - started_).count();
        std::lock_guard<std::mutex> lock(log_mu());
        size_t from = 0;
        for (;;) {
            const size_t nl = text.find('\n', from);
            std::fprintf(stderr, "[+%8.3fs] %s: %s\n", t, dir,
                         text.substr(from, nl == std::string::npos ? nl : nl - from).c_str());
            if (nl == std::string::npos) break;
            from = nl + 1;
        }
    }

    void set_list(const std::string& param, const std::vector<std::string>& items) {
        Value v;
        v.is_list = true;
        v.items = items;
        state_[param] = v;
    }

    // One control command (--control): the live counterpart of the
    // simulator's plain attributes and test hooks. Writes the reply to `out`:
    //   set <silent|partial|clip> <0|1> | set latency <seconds> |
    //   set drop_after <n|none>          -> OK
    //   state                            -> STATE <hex param> <hex value> <n|s> ... END
    //   received                         -> RECV <hex line> ... END
    // Returns false for an unknown command.
    bool control(const std::string& command, std::string& out) {
        std::vector<std::string> w;
        for (size_t i = 0; i < command.size();) {
            while (i < command.size() && command[i] == ' ') ++i;
            const size_t j = command.find(' ', i);
            if (i < command.size()) w.push_back(command.substr(i, j == std::string::npos ? j : j - i));
            if (j == std::string::npos) break;
            i = j;
        }
        if (w.size() == 3 && w[0] == "set") {
            if (w[1] == "silent") silent_ = w[2] == "1";
            else if (w[1] == "partial") partial_ = w[2] == "1";
            else if (w[1] == "clip") clip_ = w[2] == "1";
            else if (w[1] == "latency") latency_ = std::strtod(w[2].c_str(), nullptr);
            else if (w[1] == "drop_after") drop_after_ = w[2] == "none" ? -1 : std::strtol(w[2].c_str(), nullptr, 10);
            else return false;
            out = "OK\n";
            return true;
        }
        if (w.size() == 1 && w[0] == "state") {
            std::lock_guard<std::mutex> lock(mu_);
            for (const auto& kv : state_)
            {
                const Value& v = kv.second;
                std::string joined;
                for (size_t i = 0; i < v.items.size(); ++i) joined += (i ? "\n" : "") + v.items[i];
                out += "STATE " + hex(kv.first) + " " + hex(v.is_list ? joined : v.wire()) +
                       (v.is_list ? " l\n" : v.numeric ? " n\n" : " s\n");
            }
            out += "END\n";
            return true;
        }
        if (w.size() == 1 && w[0] == "received") {
            std::lock_guard<std::mutex> lock(log_mu());
            for (const auto& l : received_) out += "RECV " + hex(l) + "\n";
            out += "END\n";
            return true;
        }
        return false;
    }

    // Record received lines for the "received" control command.
    void record_received(bool on) { record_ = on; }

private:
    Options opt_;
    bool key_value_;
    std::mutex mu_;
    std::map<std::string, Value> state_;
    std::atomic<double> latency_;
    std::atomic<long> drop_after_;
    std::atomic<bool> clip_;
    std::atomic<bool> silent_;
    std::atomic<bool> partial_;
    std::atomic<bool> record_{false};
    const std::chrono::steady_clock::time_point started_ = std::chrono::steady_clock::now();
    std::vector<std::string> received_;  // guarded by log_mu()

    static std::string hex(const std::string& s) {
        static const char* digits = "0123456789abcdef";
        std::string out;
        for (unsigned char c : s) {
            out.push_back(digits[c >> 4]);
            out.push_back(digits[c & 15]);
        }
        return out.empty() ? "-" : out;
    }

    // Sleep in short slices so shutdown is not held up by a large --latency.
    // False if a stop was requested meanwhile.
    static bool sleep_interruptibly(double seconds) {
        const auto end = std::chrono::steady_clock::now() +
                         std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                             std::chrono::duration<double>(seconds));
        while (!g_stop) {
            const auto left = end - std::chrono::steady_clock::now();
            if (left <= std::chrono::steady_clock::duration::zero()) return true;
            std::this_thread::sleep_for(
                std::min<std::chrono::steady_clock::duration>(left, std::chrono::milliseconds(100)));
        }
        return false;
    }

    static std::mutex& log_mu() {
        static std::mutex m;
        return m;
    }

    static constexpr size_t MAX_LINE = 65536;  // asyncio StreamReader default limit
    static constexpr size_t CHUNK = 65536;     // read size; asyncio reads up to 256 KiB at once

    static std::string rstrip_crlf(std::string s) {
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        return s;
    }

    // Next '\n'-terminated line (terminator kept out). At EOF a non-empty
    // remainder is returned as a last line, like StreamReader.readline().
    // False after `idle` seconds without a byte (0: no idle limit).
    static bool read_line(int fd, std::string& buf, char (&chunk)[CHUNK], std::string& line,
                          bool& eof, double idle) {
        auto last = std::chrono::steady_clock::now();
        for (;;) {
            const size_t nl = buf.find('\n');
            if (nl != std::string::npos) {
                if (nl > MAX_LINE) return false;  // asyncio: LimitOverrunError
                line = buf.substr(0, nl);
                buf.erase(0, nl + 1);
                return true;
            }
            if (buf.size() > MAX_LINE) return false;
            if (eof) return false;
            // Poll so a blocked reader notices shutdown; works for sockets,
            // ptys and serial devices alike.
            pollfd p{fd, POLLIN, 0};
            const int ready = ::poll(&p, 1, 200);
            if (g_stop) return false;
            if (idle > 0 && std::chrono::steady_clock::now() - last > std::chrono::duration<double>(idle))
                return false;
            if (ready == 0 || (ready < 0 && errno == EINTR)) continue;
            // poll() may not support some tty devices (POLLNVAL); fall back to
            // a short sleep and a non-blocking read.
            if (ready > 0 && (p.revents & POLLNVAL))
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            const ssize_t n = ready < 0 ? -1 : ::read(fd, chunk, sizeof chunk);
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (n <= 0) {
                eof = true;
                if (buf.empty()) return false;
                line = std::move(buf);
                buf.clear();
                return true;
            }
            buf.append(chunk, size_t(n));
            last = std::chrono::steady_clock::now();
        }
    }

    // Write all of data, waiting at most `timeout` seconds for the peer to
    // take it (a client that stopped reading would otherwise block the
    // thread, and the shutdown join, forever). False on error or timeout.
    static bool send_all(int fd, const std::string& data, double timeout) {
        const auto deadline = std::chrono::steady_clock::now() +
                              std::chrono::duration_cast<std::chrono::steady_clock::duration>(
                                  std::chrono::duration<double>(timeout));
        size_t off = 0;
        while (off < data.size()) {
            const auto left = deadline - std::chrono::steady_clock::now();
            if (left <= std::chrono::steady_clock::duration::zero() || g_stop) return false;
            pollfd p{fd, POLLOUT, 0};
            const int wait_ms = int(std::min<long long>(
                200, std::chrono::duration_cast<std::chrono::milliseconds>(left).count() + 1));
            const int ready = ::poll(&p, 1, wait_ms);
            if (ready == 0 || (ready < 0 && errno == EINTR)) continue;
            if (ready < 0 || (p.revents & (POLLERR | POLLNVAL))) return false;
#ifdef MSG_DONTWAIT
            ssize_t n = ::send(fd, data.data() + off, data.size() - off, MSG_DONTWAIT);
            if (n < 0 && errno == ENOTSOCK) n = ::write(fd, data.data() + off, data.size() - off);
#else
            const ssize_t n = ::write(fd, data.data() + off, data.size() - off);
#endif
            if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (n <= 0) return false;
            off += size_t(n);
        }
        return true;
    }

    // (param, value); value "?" means query. nullopt if unparseable.
    std::optional<std::pair<std::string, std::string>> parse(const std::string& line) const {
        if (key_value_) {
            if (!line.empty() && line.back() == '?') {
                // "KEY?" and the Dolby-verified "KEY=?" both query KEY.
                std::string param = py_strip(line.substr(0, line.size() - 1));
                if (!param.empty() && param.back() == '=') param.pop_back();
                return std::make_pair(py_strip(param), std::string("?"));
            }
            const size_t eq = line.find('=');
            if (eq != std::string::npos)
                return std::make_pair(py_strip(line.substr(0, eq)), py_strip(line.substr(eq + 1)));
            return std::nullopt;
        }
        size_t a = 0;
        while (a < line.size() && py_space(line[a])) ++a;
        size_t b = a;
        while (b < line.size() && !py_space(line[b])) ++b;
        size_t c = b;
        while (c < line.size() && py_space(line[c])) ++c;
        if (c == line.size()) return std::nullopt;  // no value part
        return std::make_pair(line.substr(a, b - a), py_strip(line.substr(c)));
    }

    // protocol.ProtocolFormatter.format_message: a control char or non-ASCII
    // byte makes the reference raise ValueError, which kills the connection.
    bool value_line(const std::string& param, const Value& v, std::string& out) const {
        if (v.is_list) {                       // header line, then one line per item
            std::string text = param;
            for (const std::string& item : v.items) text += "\n" + item;
            for (unsigned char c : param)
                if (c == '\n' || c == '\r' || c >= 0x80) return false;
            for (const std::string& item : v.items)
                for (unsigned char c : item)
                    if (c == '\n' || c == '\r' || c >= 0x80) return false;
            out = text;
            return true;
        }
        const std::string val = v.wire();
        for (const std::string* s : {&param, &val})
            for (unsigned char c : *s)
                if (c == '\n' || c == '\r' || c >= 0x80) return false;
        out = key_value_ ? param + "=" + val : param + " " + val;
        return true;
    }

    Outcome respond(const std::string& line, std::string& reply) {
        auto parsed = parse(line);
        if (!parsed) return Outcome::None;
        const std::string& param = parsed->first;
        const std::string& value = parsed->second;

        std::lock_guard<std::mutex> lock(mu_);
        if (value == "?") {
            auto it = state_.find(param);
            if (it == state_.end()) return Outcome::None;  // unknown param -> silence
            return value_line(param, it->second, reply) ? Outcome::Reply : Outcome::Fatal;
        }
        Value stored = coerce_and_clip(param, value);
        state_[param] = stored;  // stored before the reply is built, as in the reference
        return value_line(param, stored, reply) ? Outcome::Reply : Outcome::Fatal;
    }

    Value coerce_and_clip(const std::string& param, const std::string& value) const {
        Value v;
        double num;
        if (!py_float(value, num)) {
            v.text = value;
            return v;
        }
        if (clip_) {
            if (const auto* r = range_of(param)) {
                const bool ok = r->first <= num && num <= r->second;
                if (!ok) {
                    const double m = (num < r->second) ? num : r->second;  // min(hi, num)
                    num = (m > r->first) ? m : r->first;                   // max(lo, m)
                }
            }
        }
        v.numeric = true;
        v.num = num;
        return v;
    }
};

// ---- server ----

void on_signal(int) { g_stop = true; }
void on_usr1(int) { g_drop = true; }

int listen_on(const std::string& host, int port, int& bound_port) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_flags = AI_PASSIVE;
    addrinfo* res = nullptr;
    const std::string service = std::to_string(port);
    const int rc = getaddrinfo(host.c_str(), service.c_str(), &hints, &res);
    if (rc != 0) {
        std::fprintf(stderr, "processor_sim: cannot resolve %s: %s\n", host.c_str(), gai_strerror(rc));
        return -1;
    }
    int fd = -1;
    for (addrinfo* ai = res; ai; ai = ai->ai_next) {
        fd = ::socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        const int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        if (::bind(fd, ai->ai_addr, ai->ai_addrlen) == 0 && ::listen(fd, 128) == 0) break;
        ::close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) {
        std::fprintf(stderr, "processor_sim: cannot listen on %s:%d: %s\n", host.c_str(), port,
                     std::strerror(errno));
        return -1;
    }
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
    sockaddr_storage ss{};
    socklen_t len = sizeof ss;
    getsockname(fd, reinterpret_cast<sockaddr*>(&ss), &len);
    bound_port = ss.ss_family == AF_INET6
                     ? ntohs(reinterpret_cast<sockaddr_in6*>(&ss)->sin6_port)
                     : ntohs(reinterpret_cast<sockaddr_in*>(&ss)->sin_port);
    return fd;
}

// tty.setraw(): no line-discipline munging (ONLCR, echo). A no-op for
// anything that is not a tty.
void configure_raw(int fd) {
    termios t{};
    if (tcgetattr(fd, &t) != 0) return;
    cfmakeraw(&t);
    tcsetattr(fd, TCSAFLUSH, &t);
}

void usage(FILE* to) {
    std::fputs(
        "usage: processor_sim [--model CP650|CP750|CP850|CP950|CP950A] [--host HOST]\n"
        "                     [--port PORT] [--latency SECONDS] [--drop-after N]\n"
        "                     [--no-clip] [--silent] [--partial-response]\n"
        "                     [--seed PARAM=VALUE]... [--serial DEVICE]... [--fd N]...\n"
        "                     [--write-timeout SECONDS] [--idle-timeout SECONDS]\n"
        "                     [--seed-list PARAM=ITEM;ITEM...]... [--profile] [--log] [--control]\n"
        "\n"
        "Live fake CP processor (TCP). Default port: the model's documented port.\n"
        "--seed preloads a value for GETs; --seed-list a multi-line reply (the param,\n"
        "then one line per item, like sys.macros); --profile seeds everything the Dolby\n"
        "control plugin polls on the model (explicit seeds override it). --serial also serves a serial device or pty\n"
        "(raw mode). --log prints every line received and sent to stderr, with the time. SIGUSR1 closes all\n"
        "live TCP connections while the server keeps running. --fd serves an inherited\n"
        "descriptor (a pty master). --control reads commands on stdin (set, state,\n"
        "received) and answers on stdout; for test harnesses. --write-timeout (default\n"
        "2) bounds a send to a client that stopped reading; --idle-timeout (default\n"
        "300) drops a TCP client silent that long.\n",
        to);
}

// Returns false (after printing) on a bad command line.
bool parse_args(int argc, char** argv, Options& o, bool& help) {
    help = false;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        std::string inline_value;
        bool has_inline = false;
        const size_t eq = arg.find('=');
        if (starts_with(arg, "--") && eq != std::string::npos) {
            inline_value = arg.substr(eq + 1);
            arg = arg.substr(0, eq);
            has_inline = true;
        }
        auto value = [&](std::string& dst) {
            if (has_inline) { dst = inline_value; return true; }
            if (i + 1 >= argc) {
                std::fprintf(stderr, "processor_sim: %s needs a value\n", arg.c_str());
                return false;
            }
            dst = argv[++i];
            return true;
        };
        std::string v;
        const bool is_flag = arg == "--help" || arg == "--no-clip" || arg == "--silent" ||
                             arg == "--partial-response" || arg == "--log" || arg == "--control" ||
                             arg == "--profile";
        if (is_flag && has_inline) {
            std::fprintf(stderr, "processor_sim: %s takes no value\n", arg.c_str());
            return false;
        }
        if (arg == "-h" || arg == "--help") { help = true; return true; }
        else if (arg == "--no-clip") o.clip = false;
        else if (arg == "--silent") o.silent = true;
        else if (arg == "--partial-response") o.partial_response = true;
        else if (arg == "--log") o.log = true;
        else if (arg == "--profile") o.profile = true;
        else if (arg == "--seed-list") {
            if (!value(v)) return false;
            const size_t eq3 = v.find('=');
            if (eq3 == std::string::npos) {
                std::fprintf(stderr, "processor_sim: --seed-list needs PARAM=ITEM;ITEM..., got %s\n", v.c_str());
                return false;
            }
            std::vector<std::string> items;
            std::string rest = v.substr(eq3 + 1);
            for (size_t from = 0;;) {
                const size_t semi = rest.find(';', from);
                items.push_back(rest.substr(from, semi == std::string::npos ? semi : semi - from));
                if (semi == std::string::npos) break;
                from = semi + 1;
            }
            o.seed_lists.emplace_back(v.substr(0, eq3), items);
        }
        else if (arg == "--control") o.control = true;
        else if (arg == "--fd") {
            if (!value(v)) return false;
            char* end = nullptr;
            const long n = std::strtol(v.c_str(), &end, 10);
            if (v.empty() || *end || n < 0) {
                std::fprintf(stderr, "processor_sim: invalid --fd %s\n", v.c_str());
                return false;
            }
            o.fds.push_back(int(n));
        }
        else if (arg == "--serial") {
            if (!value(v)) return false;
            o.serial.push_back(v);
        } else if (arg == "--seed") {
            if (!value(v)) return false;
            const size_t eq2 = v.find('=');
            if (eq2 == std::string::npos) {
                std::fprintf(stderr, "processor_sim: --seed needs PARAM=VALUE, got %s\n", v.c_str());
                return false;
            }
            o.seeds.emplace_back(v.substr(0, eq2), v.substr(eq2 + 1));
        }
        else if (arg == "--model") {
            if (!value(o.model)) return false;
            if (!MODELS.count(o.model)) {
                std::fprintf(stderr, "processor_sim: invalid --model %s\n", o.model.c_str());
                return false;
            }
        } else if (arg == "--host") {
            if (!value(o.host)) return false;
        } else if (arg == "--port") {
            if (!value(v)) return false;
            char* end = nullptr;
            const long p = std::strtol(v.c_str(), &end, 10);
            if (v.empty() || *end || p < 0 || p > 65535) {
                std::fprintf(stderr, "processor_sim: invalid --port %s\n", v.c_str());
                return false;
            }
            o.port = int(p);
        } else if (arg == "--latency") {
            if (!value(v)) return false;
            char* end = nullptr;
            o.latency = std::strtod(v.c_str(), &end);
            if (v.empty() || *end || !std::isfinite(o.latency) || o.latency < 0) {
                std::fprintf(stderr, "processor_sim: invalid --latency %s\n", v.c_str());
                return false;
            }
        } else if (arg == "--write-timeout" || arg == "--idle-timeout") {
            if (!value(v)) return false;
            char* end = nullptr;
            const double t = std::strtod(v.c_str(), &end);
            if (v.empty() || *end || !std::isfinite(t) || t <= 0) {
                std::fprintf(stderr, "processor_sim: invalid %s %s\n", arg.c_str(), v.c_str());
                return false;
            }
            (arg == "--write-timeout" ? o.write_timeout : o.idle_timeout) = t;
        } else if (arg == "--drop-after") {
            if (!value(v)) return false;
            char* end = nullptr;
            o.drop_after = std::strtol(v.c_str(), &end, 10);
            if (v.empty() || *end || o.drop_after < 0) {
                std::fprintf(stderr, "processor_sim: invalid --drop-after %s\n", v.c_str());
                return false;
            }
        } else {
            std::fprintf(stderr, "processor_sim: unknown argument %s\n", arg.c_str());
            return false;
        }
    }
    return true;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt;
    bool help = false;
    if (!parse_args(argc, argv, opt, help)) {
        usage(stderr);
        return 2;
    }
    if (help) {
        usage(stdout);
        return 0;
    }
    if (opt.port < 0) opt.port = MODELS.at(opt.model).port;

    struct sigaction sa{};
    sa.sa_handler = on_signal;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    std::signal(SIGPIPE, SIG_IGN);
    struct sigaction su{};
    su.sa_handler = on_usr1;
    sigemptyset(&su.sa_mask);
    sigaction(SIGUSR1, &su, nullptr);

    int port = 0;
    const int listener = listen_on(opt.host, opt.port, port);
    if (listener < 0) return 1;

    Sim sim(opt);
    std::mutex conn_mu;
    std::set<int> live;
    struct Worker {
        std::thread thread;
        std::atomic<bool> done{false};
    };
    std::list<std::unique_ptr<Worker>> workers;

    // Open the serial devices first, so a bad path fails the start.
    struct SerialEnd {
        int fd;
        bool owned;  // opened here; inherited descriptors are left to the caller
        std::string name;
    };
    std::vector<SerialEnd> serial_fds;
    for (const std::string& dev : opt.serial) {
        const int fd = ::open(dev.c_str(), O_RDWR | O_NOCTTY | O_NONBLOCK);
        if (fd < 0) {
            std::fprintf(stderr, "processor_sim: cannot open %s: %s\n", dev.c_str(),
                         std::strerror(errno));
            for (const SerialEnd& e : serial_fds)
                if (e.owned) ::close(e.fd);
            ::close(listener);
            return 1;
        }
        configure_raw(fd);
        serial_fds.push_back({fd, true, dev});
    }
    for (int fd : opt.fds) {
        if (fcntl(fd, F_GETFL, 0) < 0) {
            std::fprintf(stderr, "processor_sim: --fd %d is not open\n", fd);
            for (const SerialEnd& e : serial_fds)
                if (e.owned) ::close(e.fd);
            ::close(listener);
            return 1;
        }
        configure_raw(fd);
        serial_fds.push_back({fd, false, "fd " + std::to_string(fd)});
    }

    std::printf("ProcessorSim %s listening on %s:%d (Ctrl-C to stop)\n", opt.model.c_str(),
                opt.host.c_str(), port);
    for (const SerialEnd& e : serial_fds)
        std::printf("ProcessorSim serving %s\n", e.name.c_str());
    std::fflush(stdout);

    for (const SerialEnd& e : serial_fds) {
        auto w = std::make_unique<Worker>();
        Worker* raw = w.get();
        raw->thread = std::thread([&sim, raw, e] {
            sim.serve(e.fd, false);
            if (e.owned) ::close(e.fd);
            raw->done = true;
        });
        workers.push_back(std::move(w));
    }

    if (opt.control) {
        // Test-harness control channel: one command per stdin line, one reply
        // on stdout. Detached because getline cannot be interrupted; it ends
        // at stdin EOF or with the process.
        sim.record_received(true);
        std::thread([&sim, &conn_mu, &live] {
            std::string pending, cmd;
            char chunk[4096];
            for (;;) {
                // Poll stdin so the thread also notices shutdown, instead of
                // blocking in getline until the harness closes the pipe.
                const size_t nl = pending.find('\n');
                if (nl == std::string::npos) {
                    if (g_stop) return;
                    pollfd p{0, POLLIN, 0};
                    const int ready = ::poll(&p, 1, 200);
                    if (ready <= 0) continue;
                    const ssize_t n = ::read(0, chunk, sizeof chunk);
                    if (n <= 0) return;  // stdin closed
                    pending.append(chunk, size_t(n));
                    continue;
                }
                cmd = pending.substr(0, nl);
                pending.erase(0, nl + 1);
                std::string out;
                if (cmd == "drop") {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    for (int fd : live) ::shutdown(fd, SHUT_RDWR);
                    out = "OK\n";
                } else if (cmd == "connections") {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    out = "COUNT " + std::to_string(live.size()) + "\nEND\n";
                } else if (!sim.control(cmd, out)) {
                    out = "ERR\n";
                }
                std::fputs(out.c_str(), stdout);
                std::fflush(stdout);
            }
        }).detach();
    }

    while (!g_stop) {
        // Reap finished workers so a long soak does not accumulate threads.
        for (auto it = workers.begin(); it != workers.end();) {
            if ((*it)->done) {
                (*it)->thread.join();
                it = workers.erase(it);
            } else {
                ++it;
            }
        }
        if (g_drop.exchange(false)) {
            std::lock_guard<std::mutex> lock(conn_mu);
            for (int fd : live) ::shutdown(fd, SHUT_RDWR);
        }
        pollfd p{listener, POLLIN, 0};
        const int rc = ::poll(&p, 1, 200);
        if (rc <= 0) continue;
        const int fd = ::accept(listener, nullptr, nullptr);
        if (fd < 0) {
            // EAGAIN / ECONNABORTED: the connection vanished, nothing to do.
            // EMFILE / ENFILE: back off instead of spinning on the backlog.
            if (errno == EMFILE || errno == ENFILE)
                std::this_thread::sleep_for(std::chrono::milliseconds(100));
            continue;
        }
        const int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
#ifdef SO_NOSIGPIPE
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
#endif
        {
            std::lock_guard<std::mutex> lock(conn_mu);
            live.insert(fd);
        }
        auto w = std::make_unique<Worker>();
        Worker* raw = w.get();
        try {
            raw->thread = std::thread([&sim, &conn_mu, &live, raw, fd] {
                sim.serve(fd);
                {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    if (live.erase(fd)) ::close(fd);
                }
                raw->done = true;
            });
            workers.push_back(std::move(w));
        } catch (const std::system_error& e) {
            std::fprintf(stderr, "processor_sim: cannot start a connection thread: %s\n", e.what());
            std::lock_guard<std::mutex> lock(conn_mu);
            if (live.erase(fd)) ::close(fd);
        }
    }

    // Stop: drop every client link, as ProcessorSim.stop() does.
    ::close(listener);
    {
        std::lock_guard<std::mutex> lock(conn_mu);
        for (int fd : live) ::shutdown(fd, SHUT_RDWR);
    }
    for (auto& w : workers) w->thread.join();
    return 0;
}

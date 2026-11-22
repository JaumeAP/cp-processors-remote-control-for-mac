// processor_sim -- standalone C++17 port of cpx50.comms.ProcessorSim.
//
// A live, stateful fake CP650-CP950A processor served over TCP. A SET updates
// state, a later GET reads it back; each model's wire dialect is spoken, the
// documented CP750 ranges are applied (clipping like the doc says real
// hardware does), and the CP650 echoes the raw command before its response.
//
// POSIX only (Linux, macOS). No dependencies beyond the C++17 standard
// library and BSD sockets. The in-process hooks of the Python class map to
// the command line: --seed (initial_state), --log (received) and SIGUSR1
// (drop_connections). TCP/IP only: there is no serial support.
//
//     processor_sim --model CP850 --port 61408

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <fcntl.h>
#include <sys/socket.h>
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
#include <limits>
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

// ---- models (cpx50.comms.models) ----

// Sources, cited in comments as [M1 <doc>]: Dolby manuals read in full --
//   CP650 Installation Manual Issue 6 (2008), Appendix D (D-1..D-3); Issue 2,
//     Appendix E, for the output terminator;
//   CP750 Manual Issue 5, section 7.2 and Table 7-1;
//   CP950 Manual Issue 6 (2019), Table 17, and CP950/CP950A Issue 13, s. 3.2.5, 10.3;
//   CP850 Release Notes 2.1.0.10.
// [C] marks a field report (Film-Tech, GitHub issues of people testing real
// units), [N] a point no source covers, kept as this simulator's own choice.
// The research behind this table: cpp/README.md, "Provenance".

struct ModelConfig {
    int port;
    bool key_value;       // CP650 KEY=VALUE dialect
    double gap;           // minimum seconds the conformance judge asks between commands
    int max_connections;  // 0: no limit documented
};

const std::map<std::string, ModelConfig> MODELS = {
    // [C] 61412 (Christie, integrators); [C] one connection; the 0.25 s gap is
    // the repo spec's own figure: field practice is 0.5-1 s, no source gives one.
    {"CP650", {61412, true, 0.25, 1}},
    // [M1 CP750 7.2.1] 61408, 20 connections (the 21st evicts the oldest).
    {"CP750", {61408, false, 0.10, 20}},
    // [M1 CP950 Iss6] 61408; [N] no connection limit is documented.
    {"CP850", {61408, false, 0.10, 0}},
    {"CP950", {61408, false, 0.10, 0}},
    {"CP950A", {61408, false, 0.10, 0}},
};

// Slack on the inter-command gap check, for scheduling and network jitter.
constexpr double GAP_TOLERANCE = 0.010;
// [C] CP Remote release 1.0.7, tested on a real CP650: wait two seconds after
// closing a link before opening the next, so the unit has dropped the old
// session. The conformance judge asks for it; the slack covers the time the
// simulator takes to see the client's close.
constexpr double CP650_REOPEN = 2.0;
constexpr const char* CP650_BANNER = "---===[ Welcome to the CP650. ]===---";
constexpr double REOPEN_TOLERANCE = 0.050;

bool starts_with(const std::string& s, const char* prefix) {
    return s.rfind(prefix, 0) == 0;
}

std::string lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

// ---- per-model parameter tables: what each real unit accepts ----

struct ParamSpec {
    enum class Kind { Int, Enum, Text, ReadOnly };
    Kind kind = Kind::Text;
    long lo = 0, hi = 0;               // Int: the documented range, inclusive
    std::vector<std::string> choices;  // Enum: the documented tokens (lower case)
    std::string initial;               // the value before any SET
};
using Schema = std::map<std::string, ParamSpec>;

ParamSpec int_param(long lo, long hi, std::string initial) {
    ParamSpec p;
    p.kind = ParamSpec::Kind::Int;
    p.lo = lo;
    p.hi = hi;
    p.initial = std::move(initial);
    return p;
}

ParamSpec enum_param(std::vector<std::string> choices, std::string initial) {
    ParamSpec p;
    p.kind = ParamSpec::Kind::Enum;
    p.choices = std::move(choices);
    p.initial = std::move(initial);
    return p;
}

ParamSpec text_param(std::string initial) {
    ParamSpec p;
    p.initial = std::move(initial);
    return p;
}

ParamSpec read_only(std::string initial) {
    ParamSpec p;
    p.kind = ParamSpec::Kind::ReadOnly;
    p.initial = std::move(initial);
    return p;
}

// [M1 CP650 Iss6 Table D-1] the keys and ranges; the initial values are the
// unit's own answers in Dolby's example (Table D-2, `All = ?`). `exit` is a
// command, handled apart; `global_delays` appears only in that example output.
Schema cp650_schema() {
    return {
        {"fader_level", int_param(0, 100, "70")},  // 0..100 = fader 0.0..10.0, 70 = 0 dB
        {"fader_setting", enum_param({"local", "auditorium"}, "local")},
        {"format_button", int_param(0, 7, "4")},   // a button index: 0 = Format 01 .. 7 = Nonsync
        {"format_list", read_only("64, 76, 5, 10, 11, 88, 80, 75")},
        {"global_delays", read_only("0, 0, 0, 0, 0, 110, 0, 0")},
        {"mute", int_param(0, 2, "0")},            // 0 unmute, 1 mute, 2 toggle
        {"preset_fader_level", read_only("-1, 45, 60, 70, -1, -1, -1, -1")},
        {"projector", read_only("1")},
        {"user_formats", read_only("88, 80, 75")},
    };
}

const std::vector<std::string> CP750_DECODE_MODES = {
    "4_discrete_sur", "auto", "invalid", "lr_discrete", "n_a", "prologic", "prologic_2", "surround_ex"};
const std::vector<std::string> CP750_INPUTS = {"analog", "dig_1", "dig_2", "dig_3",
                                               "dig_4", "last", "mic", "non_sync"};
const std::vector<std::string> CP750_PROCESS_MODES = {"minimum_latency", "mute", "silent_switch"};

// [M1 CP750 Table 7-1] every parameter and its valid values. The manual gives
// no factory values except the version (1.2.8.3) and the fader's reference 7.0
// (70): the other initial values are [N] plausible ones.
Schema cp750_schema() {
    Schema s = {
        {"cp750.sysinfo.version", read_only("1.2.8.3")},
        {"cp750.ctrl.calc_surround_delays", int_param(0, 1, "0")},
        {"cp750.ctrl.default_params", int_param(0, 1, "0")},
        {"cp750.ctrl.fader_delta", int_param(-100, 100, "0")},
        {"cp750.ctrl.log_erase", int_param(0, 1, "0")},
        {"cp750.ctrl.log_uptime", int_param(0, 2147483647, "0")},
        {"cp750.ctrl.reboot", int_param(0, 2147483647, "0")},
        {"cp750.sys.analog_route", text_param("L R C Sw Ls Rs 7 8")},
        {"cp750.sys.dialnorm", enum_param({"n_a", "off", "on"}, "n_a")},
        {"cp750.sys.dig_1_route", text_param("L R C Sw Ls Rs 7 8")},
        {"cp750.sys.fader", int_param(0, 100, "70")},
        {"cp750.sys.full_ascii_ctrl", enum_param({"n_a", "off", "on"}, "n_a")},
        {"cp750.sys.input_7_8_mute", int_param(0, 1, "0")},
        {"cp750.sys.input_7_8_mute_1", int_param(0, 1, "0")},
        {"cp750.sys.input_7_8_mute_a", int_param(0, 1, "0")},
        {"cp750.sys.input_mode", enum_param(CP750_INPUTS, "analog")},
        {"cp750.sys.ip_setting", text_param("192.168.1.100 255.255.255.0 192.168.1.1 off cp750")},
        {"cp750.sys.log_content", int_param(0, 1, "0")},
        {"cp750.sys.mic_global_delay", int_param(0, 170, "0")},
        {"cp750.sys.mic_route", enum_param({"center", "surrounds"}, "center")},
        {"cp750.sys.mute", int_param(0, 1, "0")},
        {"cp750.sys.non_sync_format", enum_param({"60", "61", "70", "71", "73", "74", "75"}, "60")},
        {"cp750.sys.non_sync_global_delay", int_param(0, 170, "0")},
        {"cp750.sys.output_aux_source", enum_param({"dig_2", "none"}, "none")},
        {"cp750.sys.output_wiring_config", enum_param({"bsl_bsr", "le_re", "none"}, "none")},
        {"cp750.sys.pcm_process_mode", enum_param(CP750_PROCESS_MODES, "minimum_latency")},
        {"cp750.sys.pl_surround_delay", int_param(20, 50, "20")},
        {"cp750.sys.power_on_input", enum_param(CP750_INPUTS, "last")},
        {"cp750.sys.screen_distance", int_param(0, 147483647, "0")},
        {"cp750.sys.serial_number", int_param(0, 147483647, "0")},
        {"cp750.sys.subwoofer_filter", int_param(50, 100, "80")},
        {"cp750.sys.surround_boost", int_param(0, 1, "0")},
        {"cp750.sys.surround_boost_a", int_param(0, 1, "0")},
        {"cp750.sys.surround_delay", int_param(0, 150, "0")},
        {"cp750.sys.time", text_param("0")},
        {"cp750.sys.time_update_int", int_param(1, 60, "1")},
        {"cp750.sys.two_channel_decode_mode", enum_param(CP750_DECODE_MODES, "auto")},
    };
    for (const char* in : {"analog", "dig_1", "dig_2", "dig_3", "dig_4"})
        s[std::string("cp750.sys.") + in + "_global_delay"] = int_param(0, 170, "0");
    for (const char* n : {"1", "2", "3", "4"}) {
        s[std::string("cp750.sys.dolby_digital_2_channel_decode_mode_") + n] = enum_param(CP750_DECODE_MODES, "auto");
        s[std::string("cp750.sys.dolby_digital_dialnorm_") + n] = enum_param({"n_a", "off", "on"}, "n_a");
        s[std::string("cp750.sys.process_mode_") + n] = enum_param(CP750_PROCESS_MODES, "minimum_latency");
    }
    for (const char* n : {"1", "2", "3", "4", "a"})
        s[std::string("cp750.sys.pcm_2_channel_decode_mode_") + n] = enum_param(CP750_DECODE_MODES, "auto");
    for (const char* n : {"1", "2", "3", "4", "a", "m", "n"}) {
        s[std::string("cp750.sys.fader_preset_") + n] = int_param(0, 100, "70");
        s[std::string("cp750.sys.fader_preset_") + n + "_enable"] = int_param(0, 1, "0");
    }
    return s;
}

// [M1 CP950 Iss6 Table 17] the whole text command set of the CP850 / CP950 /
// CP950A; sys.macros and sys.macro_name are handled with the macro table
// below, and `sys.ip_settings ?` (documented, reply format undocumented) is
// not modelled.
Schema cp850_schema() {
    return {
        {"sys.fader", int_param(0, 100, "70")},      // "Dolby fader level 0-100; default 70"
        {"ctrl.fader_delta", int_param(-100, 100, "0")},
        {"sys.mute", int_param(0, 1, "0")},
        {"sys.macro_preset", int_param(1, 8, "1")},  // "Integer (1-8)": the front-panel buttons
    };
}

// [N] the macros a CP850 / CP950 ships with: Dolby recommends macro 1 = 5.1
// and 2 = 7.1 (Iss13); the names and the rest are plausible, not recorded.
struct Macro {
    int number;
    std::string name;
    int fader_preset;  // -1: the macro leaves the fader alone
};

const std::vector<Macro> CP850_MACROS = {
    {1, "5.1", -1}, {2, "7.1", -1}, {3, "Dolby Atmos", -1}, {4, "Non-Sync", 70}};

Schema schema_for(const std::string& model) {
    if (model == "CP650") return cp650_schema();
    if (model == "CP750") return cp750_schema();
    return cp850_schema();
}

// ---- Python-compatible text handling ----

// Characters Python's str.isspace() accepts in an ASCII-decoded line.
bool py_space(char ch) {
    const auto c = static_cast<unsigned char>(ch);
    return c == ' ' || (c >= '\t' && c <= '\r') || (c >= 0x1c && c <= 0x1f);
}

// True for a byte the wire refuses in a reply: CR, LF or anything non-ASCII.
bool unframeable(char ch) {
    const auto c = static_cast<unsigned char>(ch);
    return c == '\n' || c == '\r' || c >= 0x80;
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
    for (char c : raw) {
        if (static_cast<unsigned char>(c) < 0x80) out.push_back(c);
        else out += "\xEF\xBF\xBD";
    }
    return out;
}

bool is_digit(char c) { return c >= '0' && c <= '9'; }

// float(str) as Python parses it: optional sign, digits with '_' between
// digits, optional fraction and exponent, or inf / infinity / nan.
bool py_float(const std::string& s, double& out) {
    std::string lower;
    for (char c : s) lower.push_back(static_cast<char>(std::tolower(static_cast<unsigned char>(c))));
    size_t i = 0;
    if (!lower.empty() && (lower[0] == '+' || lower[0] == '-')) i = 1;
    const std::string word = lower.substr(i);
    const bool neg = !lower.empty() && lower[0] == '-';
    if (word == "inf" || word == "infinity") {
        const double inf = std::numeric_limits<double>::infinity();
        out = neg ? -inf : inf;
        return true;
    }
    if (word == "nan") {
        out = std::numeric_limits<double>::quiet_NaN();
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
            std::snprintf(tmp, sizeof tmp, "%llue%d", static_cast<unsigned long long>(cand), e - (n - 1));
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

// [convention] Whole numbers print as integers, everything else as Python's float repr
// (protocol._fmt_value).
std::string fmt_number(double d) {
    if (std::isfinite(d) && d == std::floor(d)) {
        if (std::fabs(d) < 9.2e18) return std::to_string(static_cast<long long>(d));
        char buf[400];
        std::snprintf(buf, sizeof buf, "%.0f", d);
        return buf;
    }
    return py_float_repr(d);
}

std::atomic<bool> g_stop{false};
std::atomic<bool> g_drop{false};

// Every time option (--latency, --write-timeout, --idle-timeout, `set latency`)
// is a finite number of seconds in [0, MAX_SECONDS]: a larger double would
// overflow the integer nanosecond count of steady_clock::duration (UB).
constexpr double MAX_SECONDS = 1e9;

bool valid_seconds(double s) { return std::isfinite(s) && s >= 0 && s <= MAX_SECONDS; }

std::chrono::steady_clock::duration to_duration(double seconds) {
    const double s = std::isfinite(seconds) ? std::clamp(seconds, 0.0, MAX_SECONDS) : MAX_SECONDS;
    return std::chrono::duration_cast<std::chrono::steady_clock::duration>(
        std::chrono::duration<double>(s));
}

// strtol / strtod over the whole of `text`, no leading space or sign tricks:
// false unless every character was consumed and the value is in range.
bool parse_long(const std::string& text, long& out) {
    if (text.empty() || !(is_digit(text[0]) || (text[0] == '-' && text.size() > 1))) return false;
    char* end = nullptr;
    errno = 0;
    const long v = std::strtol(text.c_str(), &end, 10);
    if (*end != '\0' || errno == ERANGE) return false;
    out = v;
    return true;
}

bool parse_double(const std::string& text, double& out) {
    if (text.empty() || !(is_digit(text[0]) || text[0] == '.' || text[0] == '-')) return false;
    char* end = nullptr;
    errno = 0;
    const double v = std::strtod(text.c_str(), &end);
    if (*end != '\0' || errno == ERANGE) return false;
    out = v;
    return true;
}

// ---- state ----

struct Value {
    bool numeric = false;
    bool is_list = false;               // a multi-line reply: the param, then one line per item
    double num = 0;
    std::string text;
    std::vector<std::string> items;

    std::string wire() const { return numeric ? fmt_number(num) : text; }
};

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
    bool profile = false;  // accepted for compatibility: every model now starts from its own table
    // Accept any parameter name, not just the model's documented ones, for
    // tests of generic client mechanics; every other behaviour stays literal.
    bool lenient = false;
    // Overrides for what each model does by default (see cpp/README.md,
    // Provenance). "auto" is the model's documented or chosen behaviour.
    std::string set_reply = "auto";     // auto | value | ack | none
    std::string unknown_get = "auto";   // auto | silent | blank | error
    std::string out_of_range = "auto";  // auto | status | ignore | clip
    std::string eol = "auto";           // auto | lf | crlf
    std::string input_eol = "auto";     // auto | any | crlf
    std::string banner = "auto";        // auto | on | off
    std::string cp650_key_query = "auto";  // auto | error | answer: a CP650 `key?`
};

enum class Outcome { None, Reply, Fatal, Close };

class Sim {
public:
    explicit Sim(Options o)
        : opt_(std::move(o)),
          key_value_(MODELS.at(opt_.model).key_value),
          latency_(opt_.latency),
          drop_after_(opt_.drop_after),
          clip_(opt_.clip),
          silent_(opt_.silent),
          partial_(opt_.partial_response),
          schema_(schema_for(opt_.model)) {
        // Resolve "auto" to each model's own behaviour.
        const bool cp650 = opt_.model == "CP650", cp750 = opt_.model == "CP750";
        if (opt_.set_reply == "auto") opt_.set_reply = cp650 ? "none" : "value";
        if (opt_.unknown_get == "auto") opt_.unknown_get = cp650 ? "error" : cp750 ? "blank" : "silent";
        if (opt_.out_of_range == "auto") opt_.out_of_range = cp650 ? "ignore" : "status";
        if (opt_.eol == "auto") opt_.eol = cp650 ? "crlf" : "lf";
        eol_ = opt_.eol == "crlf" ? "\r\n" : "\n";
        // [C] CP Remote PR #44: a real CP650 answered `error` to every line
        // that ended in LF alone; [M1 CP650 D-1] a command ends in CRLF.
        if (opt_.input_eol == "auto") opt_.input_eol = cp650 ? "crlf" : "any";
        crlf_only_ = opt_.input_eol == "crlf";
        if (opt_.banner == "auto") opt_.banner = cp650 ? "on" : "off";
        if (opt_.cp650_key_query == "auto") opt_.cp650_key_query = "error";
        for (const auto& kv : schema_) {
            Value v;
            v.text = kv.second.initial;
            state_[kv.first] = v;
        }
        if (!cp650 && !cp750) {
            std::vector<std::string> items;
            for (const Macro& m : CP850_MACROS) items.push_back(std::to_string(m.number) + ":" + m.name);
            set_list("sys.macros", items);
            state_["sys.macro_name"].text = CP850_MACROS.front().name;
        }
        // Seeds are a test hook: a seeded name that the model does not
        // document becomes a free text parameter, so it can be queried.
        for (const auto& kv : opt_.seeds) {
            const std::string name = key_name(kv.first);
            Value v;
            v.text = kv.second;
            state_[name] = v;
            if (!schema_.count(name)) extra_.insert(name);
        }
        for (const auto& kv : opt_.seed_lists) {
            set_list(key_name(kv.first), kv.second);
            if (!schema_.count(key_name(kv.first))) extra_.insert(key_name(kv.first));
        }
    }

    const std::string& eol() const { return eol_; }

    // Serve one TCP connection until it ends. Mirrors ProcessorSim._serve.
    // `conn` numbers the connection in the client-conformance record.
    void serve(int fd, long conn) {
        std::string buf;
        long count = 0;
        char chunk[CHUNK];
        bool eof = false;
        bool skip_lf = false;  // the last line ended in a CR at the end of a read
        std::optional<std::chrono::steady_clock::time_point> previous;  // last command's arrival
        const double gap = MODELS.at(opt_.model).gap;
        if (opt_.banner == "on" && !silent_) {   // a hung unit sends nothing
            // [C] a real CP650 over TCP (Bitfocus companion-module-dolby-
            // cinemaprocessor issue #10, 2025) greets a new connection with
            // this line, then a blank line, before it answers anything.
            trace("send", CP650_BANNER);
            // A failed send (the client already left) is not fatal here: what
            // the client sent before leaving is still read and judged.
            send_out(fd, std::string(CP650_BANNER) + eol_ + eol_);
        }
        while (!eof) {
            std::string raw;
            bool overlong = false, crlf = false;
            if (!read_line(fd, buf, chunk, raw, eof, opt_.idle_timeout, overlong, skip_lf, crlf)) {
                if (overlong) violation(conn, "a line longer than 65536 bytes");
                break;
            }
            const auto arrived = std::chrono::steady_clock::now();
            judge_line(conn, raw, eof, crlf, arrived, previous, gap);
            previous = arrived;
            const std::string line = rstrip_crlf(ascii_replace(raw));
            ++count;
            if (record_) {
                // Bounded, so a long --control soak cannot grow without limit;
                // the first lines are the ones kept (tests read the start).
                std::lock_guard<std::mutex> lock(log_mu());
                if (received_.size() < MAX_RECEIVED) received_.push_back(line);
            }
            trace("recv", line);

            if (latency_ > 0.0 && !sleep_interruptibly(latency_)) break;

            const bool silent = silent_;
            // One command in flight (spec 02:8): with no fault injected the
            // reply leaves at once, so a byte of the next command already
            // here means the client sent it before seeing this reply. With a
            // fault (latency, silence, partial reply) a client's retry after
            // its own timeout is legitimate, so it is not judged.
            if (!silent && !partial_ && latency_ == 0.0 && next_command_waiting(fd, buf))
                violation(conn, "next command sent before the reply to the previous one");
            // No echo on any model: [M1 CP650 Iss6 D-3] "Characters are not
            // echoed back to the controller"; [M1 CP750 7.2.1] the same.

            std::string reply;
            Outcome out = Outcome::None;
            if (silent) {
            } else if (crlf_only_ && !crlf && !py_strip(line).empty()) {
                reply = "error";   // [C CP Remote PR #44] a line not ended by CRLF
                out = Outcome::Reply;
            } else {
                out = respond(line, reply);
            }
            if (out == Outcome::Fatal || out == Outcome::Close) break;
            if (out == Outcome::Reply) {
                trace("send", reply);
                // A multi-line reply is joined by '\n' here; every line goes
                // out with the model's terminator.
                std::string wire;
                for (size_t from = 0;;) {
                    const size_t nl = reply.find('\n', from);
                    wire += reply.substr(from, nl == std::string::npos ? nl : nl - from) + eol_;
                    if (nl == std::string::npos) break;
                    from = nl + 1;
                }
                if (partial_ && wire.size() > 1) {
                    const std::string half = reply.substr(0, reply.size() / 2);
                    send_out(fd, half);
                    break;
                }
                if (!send_out(fd, wire)) break;
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

    // One control command (--control), the live counterpart of the Python
    // class's plain attributes and test hooks. Writes the reply to `out`:
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
            // Strict: a malformed value is an ERR and changes nothing, so a
            // harness typo can never silently turn a fault off (or on).
            const std::string& v = w[2];
            const bool is_bool = v == "0" || v == "1";
            if (w[1] == "silent" || w[1] == "partial" || w[1] == "clip") {
                if (!is_bool) return false;
                (w[1] == "silent" ? silent_ : w[1] == "partial" ? partial_ : clip_) = v == "1";
            } else if (w[1] == "latency") {
                double s = 0;
                if (!parse_double(v, s) || !valid_seconds(s)) return false;
                latency_ = s;
            } else if (w[1] == "drop_after") {
                long n = -1;
                if (v != "none" && (!parse_long(v, n) || n < 0)) return false;
                drop_after_ = n;
            } else {
                return false;
            }
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
        if (w.size() == 1 && w[0] == "violations") {
            std::lock_guard<std::mutex> lock(log_mu());
            for (const auto& v : violations_) out += "VIOL " + hex(v) + "\n";
            out += "END\n";
            return true;
        }
        if (w.size() == 2 && w[0] == "violations" && w[1] == "clear") {
            std::lock_guard<std::mutex> lock(log_mu());
            violations_.clear();
            out = "OK\n";
            return true;
        }
        return false;
    }

    // [C] CP Remote commit c33e23a: a real CP650 sends a line of its own when
    // a front-panel key is pressed. [N] The text of that line is not
    // recorded; the simulator sends the key's query reply, `key=value`.
    // Applies `value` as the panel would and puts the line to send in `line`;
    // false (nothing changes) on another model, an unknown key or an invalid
    // value.
    bool panel(const std::string& key, const std::string& value, std::string& line) {
        if (!key_value_) return false;
        std::lock_guard<std::mutex> lock(mu_);
        const std::string k = lower(key);
        const auto it = schema_.find(k);
        std::string canonical, ignored;
        if (it == schema_.end() || !valid_value(it->second, value, canonical)) return false;
        apply_set(k, value, ignored);
        if (!value_line(k, state_.at(k), line)) return false;
        trace("push", line);
        line += eol_;
        return true;
    }

    // Send `data` to a client. On the CP650, which takes one connection, the
    // control channel's panel lines share the socket with the replies, so
    // every write there is serialized; the other models never push.
    bool send_out(int fd, const std::string& data) {
        if (!key_value_) return send_all(fd, data, opt_.write_timeout);
        std::lock_guard<std::mutex> lock(write_mu_);
        return send_all(fd, data, opt_.write_timeout);
    }

    // Record received lines for the "received" control command.
    void record_received(bool on) { record_ = on; }

    // Client conformance: one entry per rule a client broke, for the
    // "violations" control command (and stderr under --log). The simulator
    // records and carries on; it does not punish the client, because what a
    // real processor does on each of these is not documented.
    void violation(long conn, const std::string& what) {
        const double t = std::chrono::duration<double>(std::chrono::steady_clock::now() - started_).count();
        char head[64];
        std::snprintf(head, sizeof head, "[+%.3fs] conn %ld: ", t, conn);
        std::lock_guard<std::mutex> lock(log_mu());
        if (violations_.size() < MAX_VIOLATIONS) violations_.push_back(head + what);
        if (opt_.log) std::fprintf(stderr, "%sVIOLATION %s\n", head, what.c_str());
    }

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
    std::vector<std::string> received_;    // guarded by log_mu()
    std::vector<std::string> violations_;  // guarded by log_mu()
    Schema schema_;                        // the model's documented parameters
    std::set<std::string> extra_;          // seeded names the model does not document
    std::string eol_ = "\n";               // the model's output line terminator
    bool crlf_only_ = false;               // a line not ended by CRLF gets `error`
    std::mutex write_mu_;                  // CP650 writes (replies and panel lines)

    // The framing rules a client's line must keep, and the inter-command gap.
    void judge_line(long conn, const std::string& raw, bool unterminated, bool crlf,
                    std::chrono::steady_clock::time_point arrived,
                    const std::optional<std::chrono::steady_clock::time_point>& previous, double gap) {
        if (unterminated) violation(conn, "a line not terminated by a newline when the client closed");
        else if (crlf_only_ && !crlf && !py_strip(raw).empty())
            violation(conn, "a line not ended by CRLF; the " + opt_.model + " needs CRLF");
        if (std::any_of(raw.begin(), raw.end(), [](char c) { return static_cast<unsigned char>(c) >= 0x80; }))
            violation(conn, "a non-ASCII byte in the line");
        if (py_strip(raw).empty()) violation(conn, "a blank line");
        if (previous) {
            const double dt = std::chrono::duration<double>(arrived - *previous).count();
            if (dt < gap - GAP_TOLERANCE) {
                char msg[160];
                std::snprintf(msg, sizeof msg, "%.0f ms after the previous command; the %s needs %.0f ms",
                              dt * 1000, opt_.model.c_str(), gap * 1000);
                violation(conn, msg);
            }
        }
    }

    // True when a byte beyond the current command is already here: buffered
    // by an earlier read, or waiting in the socket (peeked, not consumed).
    static bool next_command_waiting(int fd, const std::string& buf) {
        if (!buf.empty()) return true;
        char c;
        const ssize_t n = ::recv(fd, &c, 1, MSG_PEEK | MSG_DONTWAIT);
        return n > 0;
    }

    static std::string hex(const std::string& s) {
        static const char* digits = "0123456789abcdef";
        std::string out;
        for (char ch : s) {
            const auto c = static_cast<unsigned char>(ch);
            out.push_back(digits[c >> 4]);
            out.push_back(digits[c & 15]);
        }
        return out.empty() ? "-" : out;
    }

    // Sleep in short slices so shutdown is not held up by a large --latency.
    // False if a stop was requested meanwhile.
    static bool sleep_interruptibly(double seconds) {
        const auto end = std::chrono::steady_clock::now() + to_duration(seconds);
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

    static constexpr size_t MAX_LINE = 65536;  // [convention] asyncio StreamReader default limit
    static constexpr size_t MAX_RECEIVED = 1000000;  // lines kept for the `received` command
    static constexpr size_t MAX_VIOLATIONS = 10000;  // entries kept for `violations`
    static constexpr size_t CHUNK = 65536;     // read size; asyncio reads up to 256 KiB at once

    static std::string rstrip_crlf(std::string s) {
        while (!s.empty() && (s.back() == '\n' || s.back() == '\r')) s.pop_back();
        return s;
    }

    // Next '\n'-terminated line (terminator kept out). At EOF a non-empty
    // remainder is returned as a last line, like StreamReader.readline()
    // (`eof` is then already true: the line was unterminated). False after
    // `idle` seconds without a byte (0: no idle limit), and with `overlong`
    // set when a line exceeds MAX_LINE.
    // A line ends at LF, CR or CRLF: [M1 CP650 D-1] commands end in "\r\n",
    // [C] CP750 serial and Christie use CR alone, [M1 CP950 Iss13 10.3] "\n".
    // `skip_lf` carries a CR seen at the end of one read, so the LF of its
    // CRLF, if it follows, does not count as an empty line. `crlf` tells
    // whether the line ended in CRLF; a CR that is the last byte read waits
    // up to 100 ms for its LF, so a CRLF split across two reads still counts.
    static bool read_line(int fd, std::string& buf, char (&chunk)[CHUNK], std::string& line,
                          bool& eof, double idle, bool& overlong, bool& skip_lf, bool& crlf) {
        auto last = std::chrono::steady_clock::now();
        bool cr_waited = false;
        crlf = false;
        for (;;) {
            if (skip_lf && !buf.empty()) {
                if (buf[0] == '\n') buf.erase(0, 1);
                skip_lf = false;
            }
            const size_t nl = buf.find_first_of("\r\n");
            if (nl != std::string::npos) {
                if (nl > MAX_LINE) {              // asyncio: LimitOverrunError
                    overlong = true;
                    return false;
                }
                if (buf[nl] == '\r' && nl + 1 == buf.size() && !eof && !cr_waited) {
                    cr_waited = true;
                    pollfd p{fd, POLLIN, 0};
                    if (::poll(&p, 1, 100) > 0) {
                        const ssize_t n = ::read(fd, chunk, sizeof chunk);
                        if (n > 0) {
                            buf.append(chunk, size_t(n));
                            last = std::chrono::steady_clock::now();
                            continue;
                        }
                    }
                }
                line = buf.substr(0, nl);
                if (buf[nl] == '\r' && nl + 1 < buf.size() && buf[nl + 1] == '\n') {
                    crlf = true;
                    buf.erase(0, nl + 2);
                } else {
                    if (buf[nl] == '\r') skip_lf = true;
                    buf.erase(0, nl + 1);
                }
                return true;
            }
            if (buf.size() > MAX_LINE) {
                overlong = true;
                return false;
            }
            if (eof) return false;
            // Poll so a blocked reader notices shutdown.
            pollfd p{fd, POLLIN, 0};
            const int ready = ::poll(&p, 1, 200);
            if (g_stop) return false;
            if (idle > 0 && std::chrono::steady_clock::now() - last > to_duration(idle))
                return false;
            if (ready == 0 || (ready < 0 && errno == EINTR)) continue;
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
        const auto deadline = std::chrono::steady_clock::now() + to_duration(timeout);
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

    // A parameter name as the model compares it: [M1 CP650 D-3, CP750 7.2.2]
    // "Command parsing is not case sensitive"; [N] the CP850 / CP950 manuals
    // do not say, so their names are compared as sent.
    std::string key_name(const std::string& name) const {
        return (opt_.model == "CP650" || opt_.model == "CP750") ? lower(name) : name;
    }

    // Known to the model, or accepted because of --lenient or a seed.
    bool known(const std::string& name) const {
        return schema_.count(name) || extra_.count(name) ||
               (opt_.lenient && state_.count(name)) ||
               (name == "sys.macros" && state_.count(name)) ||
               (name == "sys.macro_name" && state_.count(name));
    }

    // True when `value` is one the parameter accepts; `canonical` gets the
    // text the unit then holds (an Int in decimal, an Enum token in lower case).
    static bool valid_value(const ParamSpec& spec, const std::string& value, std::string& canonical) {
        switch (spec.kind) {
        case ParamSpec::Kind::Int: {
            long n = 0;
            if (!parse_long(value, n) || n < spec.lo || n > spec.hi) return false;
            canonical = std::to_string(n);
            return true;
        }
        case ParamSpec::Kind::Enum: {
            const std::string v = lower(value);
            if (std::find(spec.choices.begin(), spec.choices.end(), v) == spec.choices.end()) return false;
            canonical = v;
            return true;
        }
        case ParamSpec::Kind::Text:
            canonical = value;
            return !value.empty();
        case ParamSpec::Kind::ReadOnly:
            return false;
        }
        return false;
    }

    // The text of one parameter's reply in the model's dialect. False when it
    // cannot be framed (CR, LF or non-ASCII), which ends the connection.
    bool value_line(const std::string& param, const Value& v, std::string& out) const {
        if (v.is_list) {                       // [N] header line, then one line per item
            std::string text = param;
            for (const std::string& item : v.items) text += "\n" + item;
            for (char c : param)
                if (unframeable(c)) return false;
            for (const std::string& item : v.items)
                for (char c : item)
                    if (unframeable(c)) return false;
            out = text;
            return true;
        }
        const std::string val = v.wire();
        for (const std::string* s : {&param, &val})
            for (char c : *s)
                if (unframeable(c)) return false;
        out = key_value_ ? param + "=" + val : param + " " + val;
        return true;
    }

    Outcome respond(const std::string& line, std::string& reply) {
        std::lock_guard<std::mutex> lock(mu_);
        return key_value_ ? respond_cp650(line, reply) : respond_spaced(line, reply);
    }

    // [M1 CP650 Iss6 D-1..D-3] `<key>=<value>` sets, `<key>=?` queries, `all=?`
    // dumps every key; white space is ignored, parsing is not case sensitive,
    // a SET produces no output (Table D-2), an out-of-range value or the
    // current value "has no effect", and an unparseable query or an unknown key
    // outputs `error`.
    Outcome respond_cp650(const std::string& line, std::string& reply) {
        std::string s;
        for (char c : line)
            if (!py_space(c)) s.push_back(c);
        if (s.empty()) return Outcome::None;   // "control characters are ignored"
        const size_t eq = s.find('=');
        if (eq == std::string::npos) {
            // [M1 D-3] the query is `key=?`, below; a query that cannot be
            // parsed outputs `error`, and `key?` is one. The manual, a real
            // CP650 answering `all=?` over TCP and an integrator's plugin
            // that worked on a real unit all use `key=?`; only CP Remote PR
            // #13 reports `key?` answered, sent with LF alone, which that
            // unit later answered with `error` (C, disputed).
            // `--cp650-key-query answer` accepts `key?` as a query.
            // [N] anything else without '=' is ignored.
            if (s.back() == '?') {
                if (opt_.cp650_key_query == "answer")
                    return query_cp650(lower(s.substr(0, s.size() - 1)), reply);
                return unknown_query(lower(s), reply);
            }
            return Outcome::None;
        }
        const std::string key = lower(s.substr(0, eq)), value = s.substr(eq + 1);
        if (value == "?") return query_cp650(key, reply);
        if (key == "exit") return value == "1" ? Outcome::Close : Outcome::None;   // "Closes the ... connection"
        return apply_set(key, value, reply);
    }

    // A CP650 query: `all` dumps every key, an unknown key is `error`.
    Outcome query_cp650(const std::string& key, std::string& reply) {
        if (key == "all") {
            std::string text;
            for (const auto& kv : state_) {
                if (!kv.second.is_list && !known(kv.first)) continue;
                std::string one;
                if (!value_line(kv.first, kv.second, one)) return Outcome::Fatal;
                text += (text.empty() ? "" : "\n") + one;
            }
            reply = text;
            return Outcome::Reply;
        }
        if (!known(key)) return unknown_query(key, reply);
        return value_line(key, state_.at(key), reply) ? Outcome::Reply : Outcome::Fatal;
    }

    // [M1 CP750 7.2.2, CP950 Iss6 Table 17] `<param> <value>` and `<param> ?`.
    Outcome respond_spaced(const std::string& line, std::string& reply) {
        std::vector<std::string> words;
        for (size_t i = 0; i < line.size();) {
            while (i < line.size() && py_space(line[i])) ++i;
            size_t j = i;
            while (j < line.size() && !py_space(line[j])) ++j;
            if (j > i) words.push_back(line.substr(i, j - i));
            i = j;
        }
        if (words.empty()) return Outcome::None;
        const std::string name = key_name(words[0]);
        if (words.size() == 1) {
            // [M1 CP750 7.2.2] the single-word commands help, status and exit;
            // [N] what help and status print is undocumented, so they answer
            // like an unknown parameter.
            if (opt_.model == "CP750" && name == "exit") return Outcome::Close;
            return unknown_query(name, reply);
        }
        std::string value = words[1];
        for (size_t k = 2; k < words.size(); ++k) value += " " + words[k];
        if (value == "?") {
            if (!known(name)) return unknown_query(name, reply);
            return value_line(name, state_.at(name), reply) ? Outcome::Reply : Outcome::Fatal;
        }
        if (opt_.model == "CP750" && name == "exit") return Outcome::Close;
        return apply_set(name, value, reply);
    }

    // What a query of a name the model does not hold gets.
    Outcome unknown_query(const std::string& name, std::string& reply) {
        (void)name;
        if (opt_.unknown_get == "error") {
            reply = key_value_ ? "error" : "ERR";   // [M1 CP650 D-3] the literal text is "error"
            return Outcome::Reply;
        }
        if (opt_.unknown_get == "blank") {          // [M1 CP750 7.2.2] "returns a blank new line"
            reply.clear();
            return Outcome::Reply;
        }
        return Outcome::None;                       // [C CP850] unknown queries "returned empty"
    }

    // The reply to a SET once it has been applied (or refused).
    Outcome set_reply(const std::string& name, std::string& reply) {
        if (opt_.set_reply == "none") return Outcome::None;
        if (opt_.set_reply == "ack") {
            reply = "ACK";
            return Outcome::Reply;
        }
        return value_line(name, state_.at(name), reply) ? Outcome::Reply : Outcome::Fatal;
    }

    Outcome apply_set(const std::string& name, const std::string& value, std::string& reply) {
        const auto spec_it = schema_.find(name);
        if (spec_it == schema_.end()) {
            if (name == "sys.macro_name" && state_.count(name)) return select_macro_by_name(value, reply);
            if (!(opt_.lenient || extra_.count(name))) {
                // [M1 CP750] an unrecognized parameter gets the blank line;
                // [M1 CP650] an unknown key has no effect (the `error` rule
                // covers queries only); [N CP850] treated like a query.
                if (key_value_) return Outcome::None;
                return unknown_query(name, reply);
            }
            // --lenient or a seeded name: a free value, number text in the
            // toolkit's own formatting (whole floats as integers).
            Value v;
            double num;
            if (py_float(value, num)) {
                v.numeric = true;
                v.num = num;
            } else {
                v.text = value;
            }
            state_[name] = v;
            std::string checked;
            if (!value_line(name, v, checked)) return Outcome::Fatal;
            return set_reply(name, reply);
        }
        const ParamSpec& spec = spec_it->second;
        std::string canonical;
        if (!valid_value(spec, value, canonical)) {
            // [M1 CP750 7.2.2] "takes no action and returns parameter status";
            // [M1 CP650 D-3] "no error is issued and the command has no effect".
            if (opt_.out_of_range == "clip" && spec.kind == ParamSpec::Kind::Int) {
                long n = 0;
                double d = 0;
                if (parse_long(value, n) || py_float(value, d)) {
                    // the old clip rule, max(lo, min(hi, x)): NaN lands on hi
                    if (!parse_long(value, n))
                        n = (std::isnan(d) || d > 0) ? std::numeric_limits<long>::max()
                                                     : std::numeric_limits<long>::min();
                    if (clip_) n = std::clamp(n, spec.lo, spec.hi);
                    state_[name].text = std::to_string(n);
                    state_[name].numeric = false;
                    return set_reply(name, reply);
                }
            }
            if (opt_.out_of_range == "ignore") return Outcome::None;
            return value_line(name, state_.at(name), reply) ? Outcome::Reply : Outcome::Fatal;
        }
        // Side effects the manuals document.
        if (name == "ctrl.fader_delta" || name == "cp750.ctrl.fader_delta") {
            // [M1 CP850 RN 2.1.0.10, CP750 Table 7-1] a step, in tenths, on the
            // fader; [N] clamped to the fader's own 0..100.
            const std::string fader = key_value_ ? "fader_level" : (opt_.model == "CP750" ? "cp750.sys.fader" : "sys.fader");
            long now = 0;
            parse_long(state_.at(fader).text, now);
            state_[fader].text = std::to_string(std::clamp(now + std::stol(canonical), 0L, 100L));
            state_[name].text = canonical;
            return set_reply(name, reply);
        }
        if (key_value_ && name == "mute" && canonical == "2") {      // [M1 CP650 D-1] 2 = toggle
            canonical = state_.at("mute").text == "1" ? "0" : "1";
        }
        if (key_value_ && state_.at(name).text == canonical) return Outcome::None;   // "the same as the current setting"
        state_[name].text = canonical;
        state_[name].numeric = false;
        if (key_value_ && name == "format_button") apply_button_preset(std::stol(canonical));
        if (name == "sys.macro_preset") return select_macro(std::stoi(canonical), reply);
        return set_reply(name, reply);
    }

    // [M1 CP650 D-1] "Any preset fader level associated with the indicated
    // button is also applied" (preset_fader_level, -1 = none).
    void apply_button_preset(long button) {
        std::vector<long> presets;
        const std::string& list = state_.at("preset_fader_level").text;
        for (size_t from = 0; from <= list.size();) {
            const size_t comma = list.find(',', from);
            long v = -1;
            parse_long(py_strip(list.substr(from, comma == std::string::npos ? comma : comma - from)), v);
            presets.push_back(v);
            if (comma == std::string::npos) break;
            from = comma + 1;
        }
        if (button >= 0 && size_t(button) < presets.size() && presets[size_t(button)] >= 0)
            state_["fader_level"].text = std::to_string(presets[size_t(button)]);
    }

    // [M1 CP950 Iss13 3.2.5] selecting a macro applies its fader preset, and
    // sys.macro_name follows; [N] a number with no macro behind it changes
    // nothing and answers the current status.
    Outcome select_macro(int number, std::string& reply) {
        for (const Macro& m : CP850_MACROS) {
            if (m.number != number) continue;
            state_["sys.macro_preset"].text = std::to_string(number);
            state_["sys.macro_name"].text = m.name;
            if (m.fader_preset >= 0) state_["sys.fader"].text = std::to_string(m.fader_preset);
            return set_reply("sys.macro_preset", reply);
        }
        return value_line("sys.macro_preset", state_.at("sys.macro_preset"), reply) ? Outcome::Reply
                                                                                     : Outcome::Fatal;
    }

    // [M1 CP950 Iss6 Table 17] sys.macro_name also selects a macro by its
    // name, [M1 Iss13] case-sensitively.
    Outcome select_macro_by_name(const std::string& name, std::string& reply) {
        for (const Macro& m : CP850_MACROS) {
            if (m.name != name) continue;
            const Outcome out = select_macro(m.number, reply);
            if (out != Outcome::Reply || opt_.set_reply != "value") return out;
            return value_line("sys.macro_name", state_.at("sys.macro_name"), reply) ? Outcome::Reply
                                                                                     : Outcome::Fatal;
        }
        return value_line("sys.macro_name", state_.at("sys.macro_name"), reply) ? Outcome::Reply : Outcome::Fatal;
    }

};

// ---- server ----

// Read and discard whatever the peer still sends, for at most ~200 ms or
// until EOF, after our own shutdown(SHUT_WR).
void drain_briefly(int fd) {
    char sink[4096];
    const auto end = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
    while (std::chrono::steady_clock::now() < end) {
        pollfd p{fd, POLLIN, 0};
        const int ready = ::poll(&p, 1, 20);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) {
            if (g_stop) return;
            continue;
        }
        const ssize_t n = ::recv(fd, sink, sizeof sink, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return;  // EOF or error: nothing left to drain
    }
}

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

void usage(FILE* to) {
    std::fputs(
        "usage: processor_sim [--model CP650|CP750|CP850|CP950|CP950A] [--host HOST]\n"
        "                     [--port PORT] [--latency SECONDS] [--drop-after N]\n"
        "                     [--no-clip] [--silent] [--partial-response]\n"
        "                     [--seed PARAM=VALUE]...\n"
        "                     [--write-timeout SECONDS] [--idle-timeout SECONDS]\n"
        "                     [--seed-list PARAM=ITEM;ITEM...]... [--profile] [--log] [--control]\n"
        "                     [--lenient] [--set-reply auto|value|ack|none]\n"
        "                     [--unknown-get auto|silent|blank|error]\n"
        "                     [--out-of-range auto|status|ignore|clip] [--eol auto|lf|crlf]\n"
        "                     [--input-eol auto|any|crlf] [--banner auto|on|off]\n"
        "                     [--cp650-key-query auto|error|answer]\n"
        "\n"
        "Live fake Dolby CP processor (TCP), literal to the Dolby manuals: each model\n"
        "starts from its own documented parameters and answers as its manual says.\n"
        "Default port: the model's documented port. --seed preloads a value for GETs\n"
        "(a name the model does not document becomes a free parameter); --seed-list a\n"
        "multi-line reply (the param, then one line per item, like sys.macros).\n"
        "--lenient accepts any parameter name. --profile is accepted and does nothing.\n"
        "--set-reply, --unknown-get, --out-of-range, --eol and --input-eol override the\n"
        "model's own behaviour (auto: the model's; --input-eol crlf answers `error` to a\n"
        "line not ended by CRLF, the CP650's default). --banner on sends the CP650's\n"
        "greeting and a blank line to every new connection (auto: CP650 only).\n"
        "--cp650-key-query answer takes a CP650 `key?` as a query (auto: `error`, as\n"
        "the manual says).\n"
        "--log prints every line received and sent to stderr, with the time. SIGUSR1 closes all\n"
        "live TCP connections while the server keeps running. --control reads commands on stdin (set, state,\n"
        "received, violations, panel KEY VALUE) and answers on stdout; for test harnesses. --write-timeout (default\n"
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
                             arg == "--profile" || arg == "--lenient";
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
        else if (arg == "--lenient") o.lenient = true;
        else if (arg == "--set-reply" || arg == "--unknown-get" || arg == "--out-of-range" || arg == "--eol" ||
                 arg == "--input-eol" || arg == "--banner" || arg == "--cp650-key-query") {
            if (!value(v)) return false;
            auto one_of = [&v](std::initializer_list<const char*> names) {
                for (const char* n : names)
                    if (v == n) return true;
                return false;
            };
            const bool ok = arg == "--set-reply"      ? one_of({"auto", "value", "ack", "none"})
                            : arg == "--unknown-get"  ? one_of({"auto", "silent", "blank", "error"})
                            : arg == "--out-of-range" ? one_of({"auto", "status", "ignore", "clip"})
                            : arg == "--input-eol"    ? one_of({"auto", "any", "crlf"})
                            : arg == "--banner"       ? one_of({"auto", "on", "off"})
                            : arg == "--cp650-key-query" ? one_of({"auto", "error", "answer"})
                                                      : one_of({"auto", "lf", "crlf"});
            if (!ok) {
                std::fprintf(stderr, "processor_sim: invalid %s %s\n", arg.c_str(), v.c_str());
                return false;
            }
            (arg == "--set-reply"      ? o.set_reply
             : arg == "--unknown-get"  ? o.unknown_get
             : arg == "--out-of-range" ? o.out_of_range
             : arg == "--input-eol"    ? o.input_eol
             : arg == "--banner"       ? o.banner
             : arg == "--cp650-key-query" ? o.cp650_key_query
                                       : o.eol) = v;
        }
        else if (arg == "--seed-list") {
            if (!value(v)) return false;
            const size_t eq3 = v.find('=');
            if (eq3 == std::string::npos || eq3 == 0) {
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
        else if (arg == "--seed") {
            if (!value(v)) return false;
            const size_t eq2 = v.find('=');
            if (eq2 == std::string::npos || eq2 == 0) {
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
            if (o.host.empty()) {
                std::fprintf(stderr, "processor_sim: --host needs a host name or address\n");
                return false;
            }
        } else if (arg == "--port") {
            if (!value(v)) return false;
            long p = -1;
            if (!parse_long(v, p) || p < 0 || p > 65535) {
                std::fprintf(stderr, "processor_sim: invalid --port %s\n", v.c_str());
                return false;
            }
            o.port = static_cast<int>(p);
        } else if (arg == "--latency") {
            if (!value(v)) return false;
            if (!parse_double(v, o.latency) || !valid_seconds(o.latency)) {
                std::fprintf(stderr, "processor_sim: invalid --latency %s\n", v.c_str());
                return false;
            }
        } else if (arg == "--write-timeout" || arg == "--idle-timeout") {
            if (!value(v)) return false;
            double t = 0;
            if (!parse_double(v, t) || !valid_seconds(t) || t <= 0) {
                std::fprintf(stderr, "processor_sim: invalid %s %s\n", arg.c_str(), v.c_str());
                return false;
            }
            (arg == "--write-timeout" ? o.write_timeout : o.idle_timeout) = t;
        } else if (arg == "--drop-after") {
            if (!value(v)) return false;
            if (!parse_long(v, o.drop_after) || o.drop_after < 0) {
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
    std::map<int, long> live;  // fd -> connection number (the lowest is the oldest)
    struct Worker {
        std::thread thread;
        std::atomic<bool> done{false};
    };
    std::list<std::unique_ptr<Worker>> workers;
    long next_conn = 0;                                   // connection numbers, from 1
    // When the last served client closed its side (guarded by conn_mu), for
    // the CP650 reopen rule.
    std::optional<std::chrono::steady_clock::time_point> last_close;
    const int model_max_connections = MODELS.at(opt.model).max_connections;

    std::printf("ProcessorSim %s listening on %s:%d (Ctrl-C to stop)\n", opt.model.c_str(),
                opt.host.c_str(), port);
    std::fflush(stdout);

    std::thread control_thread;
    if (opt.control) {
        // Test-harness control channel: one command per stdin line, one reply
        // on stdout. It polls stdin in 200 ms slices and returns on g_stop or
        // stdin EOF, and is joined before `sim`, `conn_mu` and `live` go out
        // of scope (a detached thread here outlived them: a data race at exit).
        sim.record_received(true);
        control_thread = std::thread([&sim, &conn_mu, &live] {
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
                if (!cmd.empty() && cmd.back() == '\r') cmd.pop_back();  // a CRLF harness
                std::string out;
                if (cmd == "drop") {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    for (const auto& kv : live) ::shutdown(kv.first, SHUT_RDWR);
                    out = "OK\n";
                } else if (cmd == "connections") {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    out = "COUNT " + std::to_string(live.size()) + "\nEND\n";
                } else if (starts_with(cmd, "panel ")) {
                    // panel KEY VALUE: a front-panel change, pushed to the client.
                    std::vector<std::string> w;
                    for (size_t i = 0; i < cmd.size();) {
                        while (i < cmd.size() && cmd[i] == ' ') ++i;
                        size_t j = i;
                        while (j < cmd.size() && cmd[j] != ' ') ++j;
                        if (j > i) w.push_back(cmd.substr(i, j - i));
                        i = j;
                    }
                    std::string line;
                    if (w.size() == 3 && sim.panel(w[1], w[2], line)) {
                        std::lock_guard<std::mutex> lock(conn_mu);
                        for (const auto& kv : live) sim.send_out(kv.first, line);
                        out = "OK\n";
                    } else {
                        out = "ERR\n";
                    }
                } else if (!sim.control(cmd, out)) {
                    out = "ERR\n";
                }
                std::fputs(out.c_str(), stdout);
                std::fflush(stdout);
            }
        });
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
            for (const auto& kv : live) ::shutdown(kv.first, SHUT_RDWR);
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
        const long conn = ++next_conn;
        size_t open_now = 0;
        std::optional<double> since_close;
        {
            std::lock_guard<std::mutex> lock(conn_mu);
            if (live.empty() && last_close)
                since_close = std::chrono::duration<double>(std::chrono::steady_clock::now() - *last_close).count();
            live[fd] = conn;
            open_now = live.size();
        }
        if (opt.model == "CP650" && since_close && *since_close < CP650_REOPEN - REOPEN_TOLERANCE) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "opened %.0f ms after the previous connection closed; the CP650 needs %.0f ms",
                          *since_close * 1000, CP650_REOPEN * 1000);
            sim.violation(conn, msg);
        }
        if (model_max_connections > 0 && open_now > size_t(model_max_connections)) {
            sim.violation(conn, std::to_string(open_now) + " connections open at once; the " + opt.model +
                                    " allows " + std::to_string(model_max_connections));
            if (opt.model == "CP650") {
                // [C] "if something has the port open ... then you can't get
                // in": the new connection is closed at once.
                std::lock_guard<std::mutex> lock(conn_mu);
                live.erase(fd);
                ::shutdown(fd, SHUT_RDWR);
                ::close(fd);
                continue;
            }
            // [M1 CP750 7.2.1] "The 21st TCP connection causes the oldest TCP
            // session to disconnect, and sends a warning message to the
            // client"; [N] the warning's text is undocumented.
            std::lock_guard<std::mutex> lock(conn_mu);
            auto oldest = live.begin();
            for (auto it = live.begin(); it != live.end(); ++it)
                if (it->second < oldest->second) oldest = it;
            const std::string warning = "warning: too many connections, closing this session" + sim.eol();
            const ssize_t sent = ::send(oldest->first, warning.data(), warning.size(), MSG_DONTWAIT);
            (void)sent;
            ::shutdown(oldest->first, SHUT_RDWR);
        }
        auto w = std::make_unique<Worker>();
        Worker* raw = w.get();
        try {
            raw->thread = std::thread([&sim, &conn_mu, &live, &last_close, raw, fd, conn] {
                sim.serve(fd, conn);
                {
                    std::lock_guard<std::mutex> lock(conn_mu);
                    last_close = std::chrono::steady_clock::now();
                }
                // Graceful close: FIN first, then drain what the client
                // pipelined, so close() does not turn unread input into an RST
                // that can discard the reply just sent (--drop-after, a partial
                // reply, a fatal line).
                ::shutdown(fd, SHUT_WR);
                drain_briefly(fd);
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
        for (const auto& kv : live) ::shutdown(kv.first, SHUT_RDWR);
    }
    for (auto& w : workers) w->thread.join();
    if (control_thread.joinable()) control_thread.join();
    return 0;
}

// Cross-language interop driver for the C++ client: drives a processor (real
// or the C++ processor_sim) over TCP and prints KEY=VALUE lines, exactly as
// lua/interop_client.lua does, so tests/test_cpp_client.py can hold the C++
// client to the same checks as the Lua one.
//
//     cp_client <port> [model] [scenario [args]]
//     cp_client --vectors lua/tests/vectors/format_value.tsv
//
// Scenarios: (none) the default run; cp750-literal; poll PARAM N (N queries
// of PARAM, 0.1 s apart); reopen (query, reconnect, query, with the time the
// reconnect took); bench N (N queries back to back, gap removed).
#include "dolby_cp.hpp"

#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <thread>

using dolbycp::Client;
using dolbycp::Model;
using dolbycp::Options;

namespace {

std::string show(const std::optional<std::string>& v) { return v ? *v : "nil"; }

std::string state_of(const Client& cp, const std::string& param) {
    const auto it = cp.state().find(param);
    return it == cp.state().end() ? "nil" : it->second;
}

void say(const std::string& key, const std::string& value) {
    std::printf("%s=%s\n", key.c_str(), value.c_str());
}

// The shared format vectors: kind <TAB> input <TAB> expected.
int check_vectors(const char* path) {
    std::ifstream in(path);
    if (!in) {
        std::fprintf(stderr, "cannot read %s\n", path);
        return 2;
    }
    int failures = 0, checked = 0;
    for (std::string line; std::getline(in, line);) {
        if (line.empty() || line[0] == '#') continue;
        const auto t1 = line.find('\t'), t2 = line.find('\t', t1 + 1);
        const std::string kind = line.substr(0, t1), input = line.substr(t1 + 1, t2 - t1 - 1),
                          expected = line.substr(t2 + 1);
        std::string got;
        if (kind == "float") got = dolbycp::Value(std::strtod(input.c_str(), nullptr)).wire();
        else if (kind == "int") got = dolbycp::Value(std::strtoll(input.c_str(), nullptr, 10)).wire();
        else if (kind == "bool") got = dolbycp::Value(input == "true").wire();
        else got = dolbycp::Value(input).wire();
        ++checked;
        if (got != expected) {
            ++failures;
            std::printf("MISMATCH %s %s: got %s, expected %s\n", kind.c_str(), input.c_str(), got.c_str(),
                        expected.c_str());
        }
    }
    std::printf("CHECKED=%d\nFAILURES=%d\n", checked, failures);
    return failures == 0 ? 0 : 1;
}

}  // namespace

int main(int argc, char** argv) {
    if (argc >= 3 && std::string(argv[1]) == "--vectors") return check_vectors(argv[2]);
    if (argc < 2) {
        std::fprintf(stderr, "usage: cp_client <port> [model] [scenario [args]]\n");
        return 2;
    }
    const int port = std::atoi(argv[1]);
    const auto model = dolbycp::parse_model(argc > 2 ? argv[2] : "CP750");
    if (!model) {
        std::fprintf(stderr, "unknown model\n");
        return 2;
    }
    const std::string scenario = argc > 3 ? argv[3] : "";
    const bool cp650 = *model == Model::CP650;

    Options options;
    if (scenario == "cp750-literal") options.get_retries = 0;
    if (scenario == "bench") options.gap = 0.0;
    Client cp("127.0.0.1", port, *model, options);
    if (!cp.connect()) {
        say("CONNECT", "false");
        return 1;
    }
    say("CONNECT", "true");
    say("STATUS", dolbycp::status_name(cp.status()));

    if (scenario == "cp750-literal") {
        auto set_and_show = [&](const char* key, const char* param, const dolbycp::Value& value) {
            cp.set(param, value);
            cp.run();
            say(key, state_of(cp, param));
        };
        set_and_show("REFUSED_FADER", "cp750.sys.fader", 200);
        set_and_show("REFUSED_INPUT", "cp750.sys.input_mode", "bogus");
        set_and_show("SET_FADER", "cp750.sys.fader", 40);
        set_and_show("UNKNOWN_SET", "cp750.sys.master_level", 50);
        say("STATUS_AFTER_UNKNOWN_SET", dolbycp::status_name(cp.status()));
        say("UNKNOWN_GET", show(cp.get("cp750.sys.master_level", 0.3)));
        say("UPPER_GET", show(cp.get("CP750.SYS.FADER")));
        set_and_show("MIXED_SET", "CP750.Sys.Fader", 30);
        say("STATUS_END", dolbycp::status_name(cp.status()));
        cp.disconnect();
        return 0;
    }
    if (scenario == "poll" && argc > 5) {
        const std::string param = argv[4];
        const int n = std::atoi(argv[5]);
        for (int i = 0; i < n; ++i) {
            say("POLL_" + std::to_string(i), show(cp.get(param)));
            std::this_thread::sleep_for(std::chrono::milliseconds(100));
        }
        say("STATUS_END", dolbycp::status_name(cp.status()));
        cp.disconnect();
        return 0;
    }
    if (scenario == "reopen") {
        const char* param = cp650 ? "fader_level" : "sys.fader";
        say("BEFORE", show(cp.get(param)));
        const auto start = std::chrono::steady_clock::now();
        say("RECONNECT", cp.reconnect() ? "true" : "false");
        const auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(
                            std::chrono::steady_clock::now() - start).count();
        say("REOPEN_MS", std::to_string(ms));
        say("AFTER", show(cp.get(param)));
        cp.disconnect();
        return 0;
    }
    if (scenario == "bench" && argc > 4) {
        const int n = std::atoi(argv[4]);
        const char* param = cp650 ? "fader_level" : "sys.fader";
        int answered = 0;
        const auto start = std::chrono::steady_clock::now();
        for (int i = 0; i < n; ++i) answered += cp.get(param).has_value() ? 1 : 0;
        const double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
        say("ANSWERED", std::to_string(answered));
        say("GETS_PER_SEC", std::to_string(static_cast<long>(n / s)));
        cp.disconnect();
        return 0;
    }

    // The default run, as lua/interop_client.lua: non-blocking SETs, then
    // drain them through the blocking loop.
    if (cp650) {
        cp.set("MASTER", 100);
    } else {
        cp.set("sys.mute", 0);
        cp.set("cp750.sys.master_level", 70);
    }
    cp.run();
    say("STATUS_AFTER_RUN", dolbycp::status_name(cp.status()));
    say("GET", show(cp.get(cp650 ? "MASTER" : "sys.fader")));
    say("UNKNOWN", show(cp.get(cp650 ? "NOPE" : "sys.does_not_exist", 0.3)));
    say("STATUS_AFTER_UNKNOWN", dolbycp::status_name(cp.status()));
    cp.disconnect();
    return 0;
}

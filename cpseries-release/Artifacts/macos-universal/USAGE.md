# cpseries control client (C++) — 1.1.0, macOS universal

A TCP/IP control client for the CP650/CP750/CP850/CP950/CP950A cinema
processors. Standard library and POSIX sockets only; blocking API, both a
C++ class and a plain-C API over it.

## Contents

- `libcpseries.a` — static library, obfuscated logic.
- `libcpseries.dylib` — shared library, internal names hidden and logic
  obfuscated.
- `include/cpseries.hpp` — the C++ public header.
- `include/cpseries_c.h` — the plain-C API over the same client: no C++
  type crosses it, no exception escapes it, so it can be called from a
  program that does not share this library's C++ standard library.
- `LICENSE` — proprietary; see the file.

Universal binary: **arm64 (Apple Silicon) + x86_64 (Intel)**, macOS 11 and
later. The logic is obfuscated with o-mvll; the shared library also hides
every internal symbol name — `nm -gU libcpseries.dylib` lists only
`cpseries::*` and `cpseries_*`.

Note on the x86_64 slice: it is cross-compiled from the same source with the
same obfuscation passes and passes the static checks (no internal names leak,
the public API is exported), but it was not run on an Intel Mac or under
Rosetta during the build. The arm64 slice is run-verified (the test suite,
the format vectors, and both drivers against a live simulator).

## Use — C++

    #include "cpseries.hpp"

    cpseries::Client cp("192.168.1.10", 0, cpseries::Model::CP650);  // 0 = model's port
    cp.connect();
    cp.set("mute", 1);                         // enqueues (coalesced)
    cp.run();                                  // sends the queue, one in flight
    std::optional<std::string> level = cp.get("fader_level");
    cp.disconnect();

Link against one of the libraries, C++17:

    c++ -std=c++17 app.cpp -Iinclude libcpseries.a -o app
    # or, shared:
    c++ -std=c++17 app.cpp -Iinclude -L. -lcpseries -Wl,-rpath,. -o app

- `cpseries::Client(host, port, model, options)` — `set` / `run` / `get` /
  `connect` / `reconnect` / `disconnect`, plus `status`, `state`, `queued`.
- `cpseries::Model` — CP650, CP750, CP850, CP950, CP950A.
- `cpseries::Value` — a SET value (int, double, bool, string).

## Use — C

    #include "cpseries_c.h"

    cpseries_client* cp = cpseries_new("192.168.1.10", 0, "CP750", NULL);
    if (cp && cpseries_connect(cp)) {
        char fader[32];
        cpseries_set_int(cp, "cp750.sys.mute", 0);
        cpseries_run(cp);
        if (cpseries_get(cp, "cp750.sys.fader", fader, sizeof fader, 0) >= 0) puts(fader);
    }
    cpseries_free(cp);

Build and link the same way as the C++ example; the C API is in the same
library, so no separate file is needed. A handle is not thread-safe; use one
per thread, or serialise the calls.

The full behaviour (the per-model wire protocol, the timers, the CP650 rules)
is documented in the headers' comments.

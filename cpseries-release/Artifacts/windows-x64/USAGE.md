# cpseries control client (C++) — 1.1.0, Windows x64

A TCP/IP control client for the CP650/CP750/CP850/CP950/CP950A cinema
processors, cross-compiled from macOS with llvm-mingw. Blocking API, both a
C++ class and a plain-C API over it.

## Contents

- `libcpseries.dll` — shared library: both the C++ API (`cpseries::Client`,
  dllexport) and the plain-C API (`cpseries_*`) in one DLL. The C++ runtime
  (libc++, libunwind) is statically linked in, so the DLL needs only
  Windows system DLLs (KERNEL32, WS2_32, the UCRT `api-ms-win-crt-*` set) —
  nothing else needs to sit beside it.
- `libcpseries.dll.a` — the import library to link against (MinGW-style; for
  MSVC, generate an import `.lib` from the DLL's exports instead).
- `cp_client.exe` — the interop/demo driver for the C++ API (`cp_client
  [--host HOST] <port> [model] [scenario]`, `--vectors FILE`). Statically
  linked itself, for the same reason as the DLL.
- `cp_client_c.exe` — a consumer of the plain-C API only, written in plain
  C99: proof that a program built with any compiler, not just this one, can
  use `cpseries_c.h` without sharing a C++ runtime.
- `cpseries.hpp` — the C++ public header.
- `cpseries_c.h` — the plain-C header; include it and link `libcpseries.dll.a`
  (define `CPSERIES_DLL`) to consume the DLL from your own program.
- `LICENSE` — proprietary; see the file.

x64 only (no x86 or ARM64 build). Checked in a Windows 11 VM: the shared
format vectors (`cp_client.exe --vectors`, 31/31) and a live run against the
C++ simulator over the real Winsock transport (`--host`), output identical
to the native macOS build.

## Use — C++

    #include "cpseries.hpp"

    cpseries::Client cp("192.168.1.10", 0, cpseries::Model::CP650);  // 0 = model's port
    cp.connect();
    cp.set("mute", 1);
    cp.run();
    std::optional<std::string> level = cp.get("fader_level");
    cp.disconnect();

Build against the DLL with the matching toolchain (llvm-mingw):

    clang++ -std=c++17 -DCPSERIES_DLL app.cpp libcpseries.dll.a -lws2_32 -o app.exe

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

The C API works from any compiler, MSVC included: define `CPSERIES_DLL`,
include `cpseries_c.h`, and link an import library built from
`libcpseries.dll`'s exports (MSVC: generate a `.lib` with `lib.exe /def:...`
or `dlltool`).

The full behaviour (the per-model wire protocol, the timers, the CP650 rules)
is documented in `cpseries.hpp`'s comments.

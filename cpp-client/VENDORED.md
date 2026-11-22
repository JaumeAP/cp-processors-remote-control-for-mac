# Vendored: the CPSeries C++ control client

These sources are copied verbatim from the CPSeries repository (the
read-only `CPSeries/` submodule of this repository), `cpp/client/`. Do not
edit them here: change them in CPSeries and copy them again.

| File here | File in CPSeries | SHA-256 |
| --- | --- | --- |
| `Sources/DolbyCP/dolby_cp.cpp` | `cpp/client/dolby_cp.cpp` | `48cc9a3596b499a04016c1a928e0b4867830fd4bdf24957df590bcb05321a8ad` |
| `Sources/DolbyCP/include/dolby_cp.hpp` | `cpp/client/dolby_cp.hpp` | `aaefa6e9e037414a05611946ec1553179b72d4a17f25095f0e6fa46d850a4f5a` |
| `Sources/cp_client/interop_client.cpp` | `cpp/client/interop_client.cpp` | `d247b86207590ece0355abc89cf14a6981396d66f11bf74977403cfc6c2776ef` |

Source: CPSeries `a4953a957d4948f7421d5d98739c6916a420d00a` (the pinned
submodule commit); the last change to `cpp/client/` there is
`d41c48b4385f5c292779b1895c7023c1c7419a36` ("Raise the SET timeout to 6 s in
all three clients").

Only the layout differs: SwiftPM wants the public header in `include/` and
each target in its own folder. The CMake build in CPSeries (`cpp/CMakeLists.txt`)
is not copied; this package builds with SwiftPM instead.

## Build

    cd cpp-client && swift build --scratch-path <scratchpad>/cpp-client-build

This builds the `DolbyCP` C++ library and the `cp_client` driver
(`cp_client <port> [model] [scenario [args]]`, see the header of
`interop_client.cpp`). The client is C++17, standard library and POSIX
sockets only, TCP/IP only (no serial).

## Refreshing

1. Move the submodule pointer only when the user asks:
   `git submodule update --remote CPSeries`.
2. Copy the three files over the ones here, update the table above (hashes
   from `shasum -a 256`) and the source commit, and build.

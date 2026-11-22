# Vendored: the CPSeries processor simulator (v1.1.0)

`processor_sim.cpp` and `LICENSE` come unchanged from the private repository
`JaumeAP/CPSeries`, `main` at `5ea82b6`, the commit the `v1.1.0` release was
built from (`cpseries-release/RELEASE.md`). Do not edit them here: refresh them
from a newer CPSeries release.

`CMakeLists.txt` is lines 1 to 18 of CPSeries' `cpp/CMakeLists.txt` (the
`processor_sim` target, the strict warning set, no client library), which is
the only change: the rest of that file builds the client, which this repository
takes from `cpseries-release`.

CI builds it with `cmake -S cpseries-simulator -B <dir>`, so the macOS test job
needs no access to the private repository.

| File | SHA-256 |
| --- | --- |
| `processor_sim.cpp` | `3ec704861f6efb678a97d1653427ecd946de37aa3992176c2eafd5599e38fe80` |
| `LICENSE` | `f85f9829442e0d8d4dcbbec1f12d101d8620da2276c94e8ddbf029f8d55f3f17` |
| `cpp/CMakeLists.txt` (source of lines 1 to 18) | `41d18a48ce6ae65f544fc4c1071d92a2e672cc5bc0678eea9161caf5eeee9134` |

## Build

    cmake -S cpseries-simulator -B <scratchpad>/sim-build && cmake --build <scratchpad>/sim-build

Usage: `processor_sim --model CP650|CP750|CP850|CP950|CP950A --port PORT`.

## Refreshing

Copy `cpp/processor_sim.cpp` and `LICENSE` from the new release's commit, redo
`head -18 cpp/CMakeLists.txt` (check the lines still end after
`install(TARGETS processor_sim ...)`), update the hashes above and the commit.

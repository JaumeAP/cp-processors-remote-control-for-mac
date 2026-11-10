# processor_sim (C++)

A stateful fake CP650, CP750, CP850, CP950 or CP950A served over TCP. No dependencies beyond the
C++ standard library and POSIX sockets. Builds on Linux and macOS.

## Build

    cmake -S simulator -B simulator/build && cmake --build simulator/build

or, without CMake:

    c++ -std=c++17 -O2 -pthread simulator/processor_sim.cpp -o processor_sim

(both from the repository root)

## Run

    processor_sim --model CP850 --port 61408

Options: `--model`, `--host`, `--port` (0 picks a free port; default is the
model's documented port), `--latency SECONDS`, `--drop-after N`, `--no-clip`,
`--silent`, `--partial-response`. Ctrl-C stops it.

Every wait is bounded: `--write-timeout SECONDS` (default 2) gives up a send
to a client that stopped reading and drops it; `--idle-timeout SECONDS`
(default 300) drops a TCP client that has sent nothing for that long. Reads,
accept and the control channel poll in 200 ms slices, so Ctrl-C always ends
the process promptly.

Replies and seeding:

1. `--seed-list PARAM=ITEM;ITEM...` (repeatable): a multi-line reply, the param
   then one line per item, as the CP850/CP950/CP950A answer `sys.macros ?`. A
   SET replaces it with a plain value.
2. `--profile`: seed everything the control plugin polls on the model
   (fader 70 on the wire is 7.0 in the plugin, mute, format, the macro list).
   Explicit `--seed` and `--seed-list` override it.
3. The CP650 echoes the received bytes untouched. A blank line gets no reply
   and does not close the link.
4. `--log` stamps each line received and sent with the seconds since start:
   `[+   0.456s] recv: sys.macros ?`.

Its in-process hooks are exposed on the command line:

1. `--serial DEVICE` (repeatable): also serve a serial device or pty in raw
   mode, like `serve_fd()`. State is shared with the TCP clients.
2. `--seed PARAM=VALUE` (repeatable): preload a value for GETs, like
   `initial_state`. Stored as text.
3. `--log`: print every received line to stderr, like `received`.
4. `SIGUSR1`: close all live TCP connections while the server keeps running,
   like `drop_connections()`.
5. `--fd N` (repeatable): serve an inherited descriptor such as a pty master,
   like `serve_fd()` on an fd the caller already holds. It is not closed.
6. `--control`: read commands on stdin and answer on stdout, for test
   harnesses (the Swift tests
   do not use it). Commands: `set silent|partial|clip 0|1`,
   `set latency SECONDS`, `set drop_after N|none`, `drop`, `connections`,
   `state`, `received`. Each answers `OK`, or lines ending in `END`.

## CI

There is no CI job for the simulator. The macOS build is always done locally,
on the Mac, never in a macOS CI job: build it with the commands above, then run
the Swift tests in `macos/` (`swift test`, see `macos/README.md`). They launch
the simulator themselves, from the binary `$CPSIM_BIN` names (there is no
default path), so poll(), sockets and ptys are checked on a Mac. Linux is built with the same
commands; the Swift tests that exercise it run on the Mac.

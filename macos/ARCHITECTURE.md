# Architecture

## The three parts

1. **`CPx50Comms`** (library): the control channel of the processors. It has
   no user interface and no knowledge of the app.
2. **`CPRemote`** (app): the window, the front panels and the Setup sheet.
   It owns one `DolbyCP` client and reads the processor's state through it.
3. **`simulator/`** (C++17): a stand-in for the processor's control channel,
   used by the tests.

## The library

1. `DolbyCP` (actor): the client. Every command goes through it, one at a
   time, in call order.
2. `LineTransport` (protocol) with two implementations:
   1. `TCPTransport`: Network.framework, port per model (61412 for the
      CP650, 61408 for the others).
   2. `SerialTransport`: a POSIX terminal, for models with a serial port.
3. `LineBuffer`: splits incoming bytes into lines.
4. `WireProtocol`: the command framing. The CP650 uses `KEY=VALUE` and
   `KEY?`; the other models use `param value` and `param ?`.
5. `ProcessorModel`: each model's port, framing, gap between commands and
   connection limit.
6. `CommandQueue`: the SETs waiting to be sent. A SET to a parameter already
   queued replaces it, so only the newest value goes out. The queue is
   bounded.
7. `ProcessorState`: the last known value of each parameter, and the status
   (`initializing`, `ok`, `missing`).
8. `ProtocolTiming`: the timeouts and gaps.

Supervision (optional): a watchdog that marks the link `missing` when it stops
answering, and an automatic reconnect with back-off.

## The app

1. `CPRemoteApp`: the window, the menu and the scene.
2. `RemoteModel` (main actor): the state the panel shows. It reads the
   processor every two seconds and sends the controls' commands. It keeps a
   control's new value over a poll reply that was read before the change
   reached the processor.
3. `PanelProfile` (in `RemoteModel`): each model's parameter names and scales.
4. `FrontPanelView` (CP650), `OtherPanels` (CP750, CP850 / CP950): the drawn
   fronts. Positions are fractions of the panel, so they scale with the window.
5. `SetupView`: the processor choice, the address and the Test button.

## The connection log

`DolbyCP.setEventLog` hands the library's events (status changes with their
reason, every line sent and received, timeouts, reconnects) to a closure.
`ConnectionLog` in the app writes them, with the app's own events and its
focus and window events, to `~/Library/Logs/CP Remote/connection.log`.

## Concurrency

1. The library is actors and `async` functions. `DolbyCP` serialises its
   commands; the transports are `Sendable`.
2. The app's model is `@MainActor`. Lifecycle calls (connect, reconnect,
   disconnect) run one after another through a chain of tasks.

## What is not known

1. Only the commands listed in each model's `PanelProfile` are used. The
   front-panel keys without a known command are drawn but do nothing.
2. The CP750 default fader value is assumed to be 70 (7.0), as on the CP650
   and CP950.

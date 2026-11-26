# Architecture

The app draws the fronts and controls the processor over TCP/IP through the
released cpseries library (`../cpseries-release`, its plain-C API).

## The app

1. `CPRemoteApp`: the window, the menu and the scene.
2. `RemoteModel` (main actor): the state the panel shows. It reads the panel
   every two seconds and sends each control change; a reply read since just
   before a change made here is not applied over it. The controls come on
   once the fader and the mute have been read on the current link.
3. `ProcessorLink`: one link to a processor. The library blocks, so every
   call runs on the link's own serial queue, never on the main actor. The
   library re-opens a dropped link itself, keeps one command in flight and
   the model's timing rules (the CP650's pause before a reopen included).
4. `ProcessorModel`: the processor models and the TCP port each one's control
   channel uses, shown in Setup.
5. `PanelProfile` (in `RemoteModel`): each model's wire names and what its
   front offers (input buttons, the fader's lowest value, macros).
6. `FrontPanelView` (CP650), `CP750Panel`, `CP850Panel`, `CP950Panel` (CP950 / CP950A), with `PanelGrid` for the shared drawing:
   the drawn fronts, after the manuals' figures (the CP850 after Dolby's
   product photos). Positions are fractions of the panel, so they scale with
   the window.
7. `SetupView`: the processor choice, the address and the Test button.

## The connection log

`ConnectionLog` writes the app's own events and its focus and window events
to `~/Library/Logs/CP Remote/connection.log`.

## Concurrency

The app's model is `@MainActor`. `ProcessorLink` touches the library's
handle only on its own serial queue.

## What is not known

1. The front-panel keys without a known command are drawn but do nothing.
2. The CP750 default fader value is assumed to be 70 (7.0), as on the CP650
   and CP950.

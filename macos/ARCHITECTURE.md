# Architecture

The app is currently interface-only: it has no processor communication. It
draws the fronts and keeps the user's choices; nothing connects.

## The app

1. `CPRemoteApp`: the window, the menu and the scene.
2. `RemoteModel` (main actor): the state the panel shows. It is never
   connected, so the controls stay disabled.
3. `ProcessorModel`: the processor models and the TCP port each one's control
   channel uses, shown in Setup.
4. `PanelProfile` (in `RemoteModel`): what each model's front offers (input
   buttons, the fader's lowest value, macros).
5. `FrontPanelView` (CP650), `OtherPanels` (CP750, CP850, CP950 / CP950A):
   the drawn fronts, after the manuals' figures (the CP850 after Dolby's
   product photos). Positions are fractions of the panel, so they scale with
   the window.
6. `SetupView`: the processor choice, the address and the Test button.

## The connection log

`ConnectionLog` writes the app's own events and its focus and window events
to `~/Library/Logs/CP Remote/connection.log`.

## Concurrency

The app's model is `@MainActor`.

## What is not known

1. The front-panel keys without a known command are drawn but do nothing.
2. The CP750 default fader value is assumed to be 70 (7.0), as on the CP650
   and CP950.

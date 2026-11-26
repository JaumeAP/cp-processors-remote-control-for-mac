// The main fader knob, drawn for the CP650 (inside its cradle) and for the
// CP750, CP850 and CP950 fronts. It turns with the pointer and with the arrow
// keys, and it is live only while the processor is connected.

import SwiftUI

/// The recess the knob sits in.
struct KnobCradle: View {
    let mapping: Figure

    var body: some View {
        Circle()
            .fill(Color(white: 0.62))
            .overlay(Circle().stroke(Color(white: 0.3), lineWidth: mapping.length(1.5)))
            .frame(width: mapping.length(150), height: mapping.length(150))
            .accessibilityHidden(true)
    }
}

/// The main fader knob: an endless encoder with a finger dimple, as in
/// figure 2-1 (see `RemoteModel.degreesPerUnit`).
struct FaderKnob: View {
    @ObservedObject var model: RemoteModel
    let diameter: CGFloat
    @StateObject private var tracker = PointerTracker()
    /// True while a drag is live. SwiftUI resets it when a drag ends or is
    /// cancelled (onEnded is not called on a cancel, e.g. when the knob is
    /// disabled mid-drag), so the turn state is cleared either way.
    @GestureState private var dragging = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.36), Color(white: 0.1)],
                        center: .init(x: 0.38, y: 0.3),
                        startRadius: 0, endRadius: diameter * 0.65)
                )
                .shadow(color: .black.opacity(0.8), radius: diameter * 0.05, y: diameter * 0.03)
            Circle().stroke(Color.black, lineWidth: diameter * 0.02)
            // Finger dimple; turns with the knob.
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(white: 0.08), Color(white: 0.28)],
                        center: .init(x: 0.4, y: 0.35),
                        startRadius: 0, endRadius: diameter * 0.13)
                )
                .overlay(Circle().stroke(Color(white: 0.45), lineWidth: diameter * 0.012))
                .frame(width: diameter * 0.26, height: diameter * 0.26)
                .offset(y: -diameter * 0.24)
                .rotationEffect(.degrees(model.knobRotation))
        }
        .frame(width: diameter, height: diameter)
        .frame(width: diameter * 1.2, height: diameter * 1.2)
        .contentShape(Circle())
        .gesture(
            // Turn it like the real knob: follow the pointer around the centre.
            DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    let centre = diameter * 0.6
                    let offsetX = drag.location.x - centre
                    let offsetY = drag.location.y - centre
                    // Near the centre the angle is meaningless: drop the anchor
                    // there and re-anchor past it, so crossing the centre
                    // never reads as half a turn.
                    guard offsetX * offsetX + offsetY * offsetY > diameter * diameter * 0.01 else {
                        tracker.angle = nil
                        return
                    }
                    let pointer = atan2(offsetY, offsetX) * 180 / .pi
                    if let last = tracker.angle {
                        var delta = pointer - last
                        if delta > 180 { delta -= 360 }
                        if delta < -180 { delta += 360 }
                        model.turnKnob(byDegrees: delta)
                    } else if !model.isTurningKnob {
                        model.beginKnobTurn()
                    }
                    tracker.angle = pointer
                }
                .updating($dragging) { _, state, _ in state = true }
        )
        .onChange(of: dragging) { live in
            if !live {
                tracker.angle = nil
                model.endKnobTurn()
            }
        }
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up, .right: model.stepKnob(up: true)
            case .down, .left: model.stepKnob(up: false)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Main fader")
        .accessibilityValue(model.levelTextWithUnit)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: model.stepKnob(up: true)
            case .decrement: model.stepKnob(up: false)
            @unknown default: break
            }
        }
        .disabled(!model.isConnected)
        .opacity(model.isConnected ? 1 : disabledOpacity)
    }
}

/// Holds the last pointer angle of a knob drag. (A class, not `@State`:
/// the Command Line Tools ship no SwiftUI macro plugin.)
@MainActor
private final class PointerTracker: ObservableObject {
    var angle: Double?
}

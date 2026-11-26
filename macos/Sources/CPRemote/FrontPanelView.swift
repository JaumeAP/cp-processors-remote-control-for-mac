// The CP650 front panel, drawn in vectors after figure 2-1 of the CP650
// user's manual: every element sits at the position and size it has in that
// drawing, scaled to the window, so the panel keeps the real proportions.
//
// Live: the eight format buttons, the mute button, the level display, the
// main fader knob and the front-panel LCD. Drawn only (no wire command is
// known for them): the menu buttons, the power button and the P1/P2 lamps.

import AppKit
import SwiftUI

/// The panel's outline in figure 2-1, in the figure's own pixel units.
private let figure = CGRect(x: 112, y: 642, width: 956, height: 280)
let panelAspect: CGFloat = figure.width / figure.height

/// Maps figure 2-1 coordinates to the view.
private struct Figure {
    let scale: CGFloat

    func point(_ xCoord: CGFloat, _ yCoord: CGFloat) -> CGPoint {
        CGPoint(x: (xCoord - figure.minX) * scale, y: (yCoord - figure.minY) * scale)
    }

    func length(_ value: CGFloat) -> CGFloat { value * scale }
}

extension View {
    /// Place the view over the figure rectangle `left...right` by `top...bottom`.
    fileprivate func placed(
        _ mapping: Figure, _ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat
    ) -> some View {
        frame(width: mapping.length(right - left), height: mapping.length(bottom - top))
            .position(mapping.point((left + right) / 2, (top + bottom) / 2))
    }

    /// Centre the view on the figure point `(xCoord, yCoord)`.
    fileprivate func centred(_ mapping: Figure, _ xCoord: CGFloat, _ yCoord: CGFloat) -> some View {
        position(mapping.point(xCoord, yCoord))
    }
}

// The face is light grey and its lettering dark, as on the unit.
private let faceColor = Color(white: 0.74)
private let printColor = Color(white: 0.12)
/// Controls that cannot act (no answering link) are drawn faded.
private let disabledOpacity = 0.4

/// The front panel of the processor the app is set to: the CP650's live
/// panel, or the CP750's, CP850's and CP950's drawn fronts.
struct FrontPanelView: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        let aspect = model.processorModel.aspect
        Group {
            switch model.processorModel {
            case .cp750: CP750Panel(model: model)
            case .cp850: CP850Panel(model: model)
            case .cp950, .cp950a: CP950Panel(model: model)
            case .cp650: CP650Panel(model: model)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .frame(minWidth: 900, minHeight: 900 / aspect)
        .background(Color.black)
        .background(WindowAspectLock(aspect: aspect))
    }
}

/// The CP650's live front panel.
struct CP650Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geometry in
            let mapping = Figure(scale: geometry.size.width / figure.width)
            ZStack(alignment: .topLeading) {
                PanelBody(mapping: mapping)

                // Front-panel LCD, menu buttons and mute (left section).
                LCDView(model: model, mapping: mapping)
                    .placed(mapping, 308, 690, 560, 750)
                SectionLabel(text: "menu", mapping: mapping, lineFrom: 368, lineTo: 496)
                    .centred(mapping, 432, 767)
                DecorativeButton(symbol: "square.and.pencil", mapping: mapping).centred(mapping, 380, 790)
                DecorativeButton(symbol: "list.bullet.indent", mapping: mapping).centred(mapping, 432, 790)
                DecorativeButton(text: "OK", mapping: mapping).centred(mapping, 484, 790)
                SectionLabel(text: "mute", mapping: mapping, lineFrom: 602, lineTo: 602)
                    .centred(mapping, 602, 767)
                MuteButton(model: model, mapping: mapping).centred(mapping, 602, 790)
                SetupDoor(mapping: mapping).placed(mapping, 272, 815, 628, 916)

                // Level display, projector lamps and the main fader knob (centre).
                LevelDisplay(model: model, mapping: mapping)
                    .placed(mapping, 683, 696, 768, 746)
                KnobCradle(mapping: mapping).centred(mapping, 714, 822)
                ProjectorLamps(mapping: mapping).centred(mapping, 722, 758)
                FaderKnob(model: model, diameter: mapping.length(116))
                    .centred(mapping, 714, 822)

                // Format buttons and power (right section).
                RoundedRectangle(cornerRadius: mapping.length(12))
                    .stroke(Color(white: 0.4), lineWidth: mapping.length(1.5))
                    .placed(mapping, 815, 695, 1018, 803)
                    .accessibilityHidden(true)
                SectionLabel(text: "format", mapping: mapping, lineFrom: 840, lineTo: 997)
                    .centred(mapping, 918, 750)
                ForEach(0..<8, id: \.self) { index in
                    FormatButton(model: model, number: index + 1, mapping: mapping)
                        .centred(mapping, [838, 891, 944, 997][index % 4], index < 4 ? 724 : 777)
                }
                PowerButton(mapping: mapping).placed(mapping, 910, 862, 980, 890)
            }
        }
    }
}

// MARK: - Body

private struct PanelBody: View {
    let mapping: Figure

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: mapping.length(6))
                .fill(
                    LinearGradient(
                        colors: [Color(white: 0.70), Color(white: 0.58)],
                        startPoint: .top, endPoint: .bottom)
                )
                .placed(mapping, 112, 642, 1068, 922)
            // Ventilation louvres on both sides.
            ForEach(0..<11, id: \.self) { slat in
                let top = 652 + CGFloat(slat) * 24.6
                Louvre().placed(mapping, 114, top, 262, top + 13)
                Louvre().placed(mapping, 1030, top, 1066, top + 13)
            }
            // The black rack ears at both ends, each with two white slots.
            Rectangle().fill(Color.black).placed(mapping, 112, 642, 145, 922)
            Rectangle().fill(Color.black).placed(mapping, 1035, 642, 1068, 922)
            ForEach([120.0, 1043.0], id: \.self) { slotX in
                ForEach([716.0, 846.0], id: \.self) { slotY in
                    Capsule().fill(Color.white).placed(mapping, slotX, slotY, slotX + 17, slotY + 11)
                }
            }
            // The face between the louvres.
            Rectangle().fill(faceColor).placed(mapping, 262, 645, 1030, 920)
            // Header band in three parts, red as on the unit, with the Dolby
            // mark on the left and the model name on the right.
            ForEach([(262.0, 638.0), (642.0, 800.0), (805.0, 1030.0)], id: \.0) { part in
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.93, green: 0.13, blue: 0.17),
                                Color(red: 0.80, green: 0.08, blue: 0.12),
                            ],
                            startPoint: .top, endPoint: .bottom)
                    )
                    .placed(mapping, part.0, 655, part.1, 688)
            }
            Text("DOLBY")
                .font(.system(size: mapping.length(9), weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, mapping.length(5))
                .overlay(
                    RoundedRectangle(cornerRadius: mapping.length(1.5))
                        .stroke(Color.white, lineWidth: mapping.length(1))
                )
                .centred(mapping, 300, 672)
            VStack(alignment: .trailing, spacing: 0) {
                Text("CP650").font(.system(size: mapping.length(13), weight: .heavy).italic())
                Text("Digital Cinema Processor")
                    .font(.system(size: mapping.length(10.5), weight: .semibold).italic())
            }
            .foregroundStyle(Color(white: 0.95))
            .frame(width: mapping.length(220), alignment: .trailing)
            .centred(mapping, 912, 672)
            // Section dividers on the face.
            Rectangle().fill(Color.black.opacity(0.6)).placed(mapping, 638, 688, 642, 920)
            Rectangle().fill(Color.black.opacity(0.6)).placed(mapping, 800, 688, 805, 920)
        }
        .accessibilityHidden(true)
    }
}

private struct Louvre: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.46), Color(white: 0.74)],
                    startPoint: .top, endPoint: .bottom))
    }
}

private struct SetupDoor: View {
    let mapping: Figure

    var body: some View {
        RoundedRectangle(cornerRadius: mapping.length(4))
            .fill(Color(white: 0.66))
            .overlay(
                RoundedRectangle(cornerRadius: mapping.length(4))
                    .stroke(Color(white: 0.35), lineWidth: mapping.length(1))
            )
            .accessibilityHidden(true)
    }
}

private struct SectionLabel: View {
    let text: String
    let mapping: Figure
    let lineFrom: CGFloat
    let lineTo: CGFloat

    var body: some View {
        let width = mapping.length(max(lineTo - lineFrom, 40))
        ZStack {
            if lineTo > lineFrom {
                Rectangle().fill(printColor).frame(width: width, height: mapping.length(0.8))
            }
            Text(text)
                .font(.system(size: mapping.length(9), weight: .semibold).italic())
                .foregroundStyle(printColor)
                .padding(.horizontal, mapping.length(4))
                .background(faceColor)
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

// MARK: - Displays

private struct LCDView: View {
    @ObservedObject var model: RemoteModel
    let mapping: Figure

    private var formatLine: String { "Format \(model.currentFormat ?? "--")" }
    private var nameLine: String { model.currentFormat.flatMap { RemoteModel.formatNames[$0] } ?? "" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: mapping.length(5)).fill(Color(white: 0.42))
            RoundedRectangle(cornerRadius: mapping.length(2))
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.56, green: 0.76, blue: 0.27),
                            Color(red: 0.44, green: 0.64, blue: 0.2),
                        ],
                        startPoint: .top, endPoint: .bottom)
                )
                .frame(width: mapping.length(150), height: mapping.length(50))
                .overlay(
                    VStack(alignment: .leading, spacing: mapping.length(1.5)) {
                        Text(formatLine)
                        Text(nameLine)
                    }
                    .font(.system(size: mapping.length(10), weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color(red: 0.08, green: 0.15, blue: 0.05))
                    .padding(.horizontal, mapping.length(5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display")
        .accessibilityValue([formatLine, nameLine].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

private struct LevelDisplay: View {
    @ObservedObject var model: RemoteModel
    let mapping: Figure

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: mapping.length(3)).fill(Color(red: 0.07, green: 0, blue: 0))
            Group {
                Text(model.levelInDecibels ? "-88.8" : "88.8")
                    .foregroundStyle(Color(red: 0.15, green: 0.01, blue: 0.01))
                Text(model.levelText)
                    .foregroundStyle(Color(red: 1, green: 0.12, blue: 0.08))
                    .shadow(color: .red, radius: mapping.length(3))
            }
            .font(.system(size: mapping.length(model.levelInDecibels ? 20 : 25), weight: .bold, design: .monospaced))
            .padding(.trailing, mapping.length(6))
        }
        .contentShape(Rectangle())
        .onTapGesture { model.toggleLevelUnit() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fader level")
        .accessibilityValue(model.levelTextWithUnit)
        .accessibilityHint("Switches between the fader number and decibels")
        .accessibilityAddTraits(.isButton)
    }
}

private struct ProjectorLamps: View {
    let mapping: Figure

    var body: some View {
        HStack(spacing: mapping.length(12)) {
            Text("P1")
            Image(systemName: "power")
            Text("P2")
        }
        .font(.system(size: mapping.length(9), weight: .bold))
        .foregroundStyle(printColor)
        .accessibilityHidden(true)
    }
}

// MARK: - Buttons

private struct PanelButtonFace: View {
    let diameter: CGFloat
    let glow: Color?

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    glow.map { AnyShapeStyle($0) }
                        ?? AnyShapeStyle(
                            RadialGradient(
                                colors: [Color(white: 0.92), Color(white: 0.66)],
                                center: .init(x: 0.35, y: 0.3),
                                startRadius: 0, endRadius: diameter * 0.6))
                )
                .shadow(color: glow ?? .clear, radius: diameter * 0.3)
            Circle().stroke(Color.black, lineWidth: diameter * 0.06)
        }
        .frame(width: diameter, height: diameter)
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}

private struct FormatButton: View {
    @ObservedObject var model: RemoteModel
    let number: Int
    let mapping: Figure

    private var silkscreen: String { RemoteModel.buttonSilkscreen[number - 1] }
    private var selected: Bool { model.formatButton == number }

    var body: some View {
        Button {
            model.pressButton(number)
        } label: {
            ZStack {
                PanelButtonFace(diameter: mapping.length(34), glow: selected ? .white : nil)
                Text(silkscreen)
                    .font(.system(size: mapping.length(10), weight: .heavy).italic())
                    .foregroundStyle(Color(white: 0.1))
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!model.isConnected)
        .opacity(model.isConnected ? 1 : disabledOpacity)
        .accessibilityLabel("Format button \(silkscreen)")
        .accessibilityValue(selected ? "Selected" : "")
    }
}

private struct MuteButton: View {
    @ObservedObject var model: RemoteModel
    let mapping: Figure

    var body: some View {
        Button {
            model.toggleMute()
        } label: {
            Group {
                if model.muted {
                    // Flashes red while muted, as on the unit.
                    TimelineView(.periodic(from: .now, by: 0.5)) { context in
                        face(lit: Int(context.date.timeIntervalSinceReferenceDate * 2) % 2 == 0)
                    }
                } else {
                    face(lit: false)
                }
            }
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!model.isConnected)
        .opacity(model.isConnected ? 1 : disabledOpacity)
        .accessibilityLabel("Mute")
        .accessibilityValue(model.muted ? "On" : "Off")
    }

    private func face(lit: Bool) -> some View {
        ZStack {
            PanelButtonFace(diameter: mapping.length(30), glow: lit ? .red : nil)
            Image(systemName: "speaker.slash")
                .font(.system(size: mapping.length(11), weight: .bold))
                .foregroundStyle(lit ? Color.white : Color(white: 0.1))
        }
    }
}

/// A button drawn for completeness; it sends nothing.
private struct DecorativeButton: View {
    var symbol: String?
    var text: String?
    let mapping: Figure

    var body: some View {
        ZStack {
            PanelButtonFace(diameter: mapping.length(30), glow: nil)
            if let symbol {
                Image(systemName: symbol).font(.system(size: mapping.length(11), weight: .bold))
            } else if let text {
                Text(text).font(.system(size: mapping.length(10), weight: .heavy).italic())
            }
        }
        .foregroundStyle(Color(white: 0.1))
        .accessibilityHidden(true)
    }
}

private struct PowerButton: View {
    let mapping: Figure

    var body: some View {
        Capsule()
            .fill(Color(white: 0.88))
            .overlay(Capsule().stroke(Color.black, lineWidth: mapping.length(2)))
            .overlay(
                Image(systemName: "power")
                    .font(.system(size: mapping.length(13), weight: .bold))
                    .foregroundStyle(Color(white: 0.1))
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Knob

/// The recess the knob sits in.
private struct KnobCradle: View {
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

// MARK: - Window

/// Makes the window the processor itself: no title bar, no buttons, no
/// background, so the panel's own edges are the window's edges and it looks
/// set into the desktop. It keeps the panel's proportions, and it is moved by
/// dragging the panel.
private struct WindowAspectLock: NSViewRepresentable {
    let aspect: CGFloat

    /// The aspect last applied to the window; nil before the first.
    @MainActor final class Coordinator {
        var appliedAspect: CGFloat?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let applied = context.coordinator
        DispatchQueue.main.async { apply(to: view, applied) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The panel changes shape with the processor model: follow it. Any
        // other update (a poll, a fader move) leaves the window alone, so a
        // size the user chose is kept.
        let applied = context.coordinator
        guard applied.appliedAspect != aspect else { return }
        DispatchQueue.main.async { apply(to: nsView, applied) }
    }

    private func apply(to view: NSView, _ applied: Coordinator) {
        // Not in a window yet: the next update tries again.
        guard let window = view.window, applied.appliedAspect != aspect else { return }
        let first = applied.appliedAspect == nil
        applied.appliedAspect = aspect
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        // The window opens at least 1100 wide; on a model change it keeps the
        // user's width (never below the panel's 900 minimum) and takes the
        // new shape.
        let width = max(window.frame.width, first ? 1100 : 900)
        window.setContentSize(NSSize(width: width, height: width / aspect))
        guard first else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
    }
}

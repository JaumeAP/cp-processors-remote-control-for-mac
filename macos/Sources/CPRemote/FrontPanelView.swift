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

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        CGPoint(x: (x - figure.minX) * scale, y: (y - figure.minY) * scale)
    }

    func length(_ value: CGFloat) -> CGFloat { value * scale }
}

private extension View {
    /// Place the view over the figure rectangle `x1...x2` by `y1...y2`.
    func placed(_ f: Figure, _ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat) -> some View {
        frame(width: f.length(x2 - x1), height: f.length(y2 - y1))
            .position(f.point((x1 + x2) / 2, (y1 + y2) / 2))
    }

    /// Centre the view on the figure point `(x, y)`.
    func centred(_ f: Figure, _ x: CGFloat, _ y: CGFloat) -> some View {
        position(f.point(x, y))
    }
}

private let faceColor = Color(white: 0.13)
private let printColor = Color(white: 0.78)
/// Controls that cannot act (no answering link) are drawn faded.
private let disabledOpacity = 0.4

/// The front panel of the processor the app is set to: the CP650's live
/// panel, or the CP750's and CP850/CP950's drawn fronts.
struct FrontPanelView: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        let aspect = model.processorModel.aspect
        Group {
            switch model.processorModel {
            case .cp750: CP750Panel(model: model)
            case .cp850, .cp950, .cp950a: CP950Panel(model: model)
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
        GeometryReader { geo in
            let f = Figure(scale: geo.size.width / figure.width)
            ZStack(alignment: .topLeading) {
                PanelBody(f: f)

                // Front-panel LCD, menu buttons and mute (left section).
                LCDView(model: model, f: f)
                    .placed(f, 308, 690, 560, 750)
                SectionLabel(text: "menu", f: f, lineFrom: 368, lineTo: 496)
                    .centred(f, 432, 767)
                DecorativeButton(symbol: "square.and.pencil", f: f).centred(f, 380, 790)
                DecorativeButton(symbol: "list.bullet.indent", f: f).centred(f, 432, 790)
                DecorativeButton(text: "OK", f: f).centred(f, 484, 790)
                SectionLabel(text: "mute", f: f, lineFrom: 602, lineTo: 602)
                    .centred(f, 602, 767)
                MuteButton(model: model, f: f).centred(f, 602, 790)
                SetupDoor(f: f).placed(f, 272, 815, 628, 916)

                // Level display, projector lamps and the main fader knob (centre).
                LevelDisplay(value: model.fader, f: f)
                    .placed(f, 683, 696, 768, 746)
                KnobCradle(f: f).centred(f, 714, 822)
                ProjectorLamps(f: f).centred(f, 722, 758)
                FaderKnob(model: model, diameter: f.length(116))
                    .centred(f, 714, 822)

                // Format buttons and power (right section).
                RoundedRectangle(cornerRadius: f.length(12))
                    .stroke(Color(white: 0.4), lineWidth: f.length(1.5))
                    .placed(f, 815, 695, 1018, 803)
                    .accessibilityHidden(true)
                SectionLabel(text: "format", f: f, lineFrom: 840, lineTo: 997)
                    .centred(f, 918, 750)
                ForEach(0..<8, id: \.self) { index in
                    FormatButton(model: model, number: index + 1, f: f)
                        .centred(f, [838, 891, 944, 997][index % 4], index < 4 ? 724 : 777)
                }
                PowerButton(f: f).placed(f, 910, 862, 980, 890)
            }
        }
    }
}

// MARK: - Body

private struct PanelBody: View {
    let f: Figure

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: f.length(6))
                .fill(LinearGradient(colors: [Color(white: 0.24), Color(white: 0.15)],
                                     startPoint: .top, endPoint: .bottom))
                .placed(f, 112, 642, 1068, 922)
            // Ventilation louvres on both sides.
            ForEach(0..<11, id: \.self) { slat in
                let y = 652 + CGFloat(slat) * 24.6
                Louvre().placed(f, 114, y, 262, y + 13)
                Louvre().placed(f, 1030, y, 1066, y + 13)
            }
            // The face between the louvres.
            Rectangle().fill(faceColor).placed(f, 262, 645, 1030, 920)
            // Header band in three parts, red as on the unit, with the Dolby
            // mark on the left and the model name on the right.
            ForEach([(262.0, 638.0), (642.0, 800.0), (805.0, 1030.0)], id: \.0) { part in
                Rectangle()
                    .fill(LinearGradient(colors: [Color(red: 0.93, green: 0.13, blue: 0.17),
                                                  Color(red: 0.80, green: 0.08, blue: 0.12)],
                                         startPoint: .top, endPoint: .bottom))
                    .placed(f, part.0, 655, part.1, 688)
            }
            Text("DOLBY")
                .font(.system(size: f.length(9), weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, f.length(5))
                .overlay(RoundedRectangle(cornerRadius: f.length(1.5)).stroke(Color.white, lineWidth: f.length(1)))
                .centred(f, 300, 672)
            VStack(alignment: .trailing, spacing: 0) {
                Text("CP650").font(.system(size: f.length(13), weight: .heavy).italic())
                Text("Digital Cinema Processor").font(.system(size: f.length(10.5), weight: .semibold).italic())
            }
            .foregroundStyle(Color(white: 0.95))
            .frame(width: f.length(220), alignment: .trailing)
            .centred(f, 912, 672)
            // Section dividers on the face.
            Rectangle().fill(Color.black.opacity(0.6)).placed(f, 638, 688, 642, 920)
            Rectangle().fill(Color.black.opacity(0.6)).placed(f, 800, 688, 805, 920)
        }
        .accessibilityHidden(true)
    }
}

private struct Louvre: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(LinearGradient(colors: [Color(white: 0.05), Color(white: 0.2)],
                                 startPoint: .top, endPoint: .bottom))
    }
}

private struct SetupDoor: View {
    let f: Figure

    var body: some View {
        RoundedRectangle(cornerRadius: f.length(4))
            .fill(Color(white: 0.16))
            .overlay(RoundedRectangle(cornerRadius: f.length(4))
                .stroke(Color(white: 0.35), lineWidth: f.length(1)))
            .accessibilityHidden(true)
    }
}

private struct SectionLabel: View {
    let text: String
    let f: Figure
    let lineFrom: CGFloat
    let lineTo: CGFloat

    var body: some View {
        let width = f.length(max(lineTo - lineFrom, 40))
        ZStack {
            if lineTo > lineFrom {
                Rectangle().fill(printColor).frame(width: width, height: f.length(0.8))
            }
            Text(text)
                .font(.system(size: f.length(9), weight: .semibold).italic())
                .foregroundStyle(printColor)
                .padding(.horizontal, f.length(4))
                .background(faceColor)
        }
        .frame(width: width)
        .accessibilityHidden(true)
    }
}

// MARK: - Displays

private struct LCDView: View {
    @ObservedObject var model: RemoteModel
    let f: Figure

    private var formatLine: String { "Format \(model.currentFormat ?? "--")" }
    private var nameLine: String { model.currentFormat.flatMap { RemoteModel.formatNames[$0] } ?? "" }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: f.length(5)).fill(Color(white: 0.04))
            RoundedRectangle(cornerRadius: f.length(2))
                .fill(LinearGradient(colors: [Color(red: 0.56, green: 0.76, blue: 0.27),
                                              Color(red: 0.44, green: 0.64, blue: 0.2)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: f.length(150), height: f.length(50))
                .overlay(
                    VStack(alignment: .leading, spacing: f.length(1.5)) {
                        Text(formatLine)
                        Text(nameLine)
                    }
                    .font(.system(size: f.length(10), weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(Color(red: 0.08, green: 0.15, blue: 0.05))
                    .padding(.horizontal, f.length(5))
                    .frame(maxWidth: .infinity, alignment: .leading)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display")
        .accessibilityValue([formatLine, nameLine].filter { !$0.isEmpty }.joined(separator: ". "))
    }
}

private struct LevelDisplay: View {
    let value: Double
    let f: Figure

    var body: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: f.length(3)).fill(Color(red: 0.07, green: 0, blue: 0))
            Group {
                Text("88.8").foregroundStyle(Color(red: 0.15, green: 0.01, blue: 0.01))
                Text(RemoteModel.faderText(value))
                    .foregroundStyle(Color(red: 1, green: 0.12, blue: 0.08))
                    .shadow(color: .red, radius: f.length(3))
            }
            .font(.system(size: f.length(25), weight: .bold, design: .monospaced))
            .padding(.trailing, f.length(6))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Fader level")
        .accessibilityValue(RemoteModel.faderText(value))
    }
}

private struct ProjectorLamps: View {
    let f: Figure

    var body: some View {
        HStack(spacing: f.length(12)) {
            Text("P1")
            Image(systemName: "power")
            Text("P2")
        }
        .font(.system(size: f.length(9), weight: .bold))
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
                .fill(glow.map { AnyShapeStyle($0) } ?? AnyShapeStyle(
                    RadialGradient(colors: [Color(white: 0.42), Color(white: 0.2)],
                                   center: .init(x: 0.35, y: 0.3),
                                   startRadius: 0, endRadius: diameter * 0.6)))
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
    let f: Figure

    private var silkscreen: String { RemoteModel.buttonSilkscreen[number - 1] }
    private var selected: Bool { model.formatButton == number }

    var body: some View {
        Button { model.pressButton(number) } label: {
            ZStack {
                PanelButtonFace(diameter: f.length(34), glow: selected ? .white : nil)
                Text(silkscreen)
                    .font(.system(size: f.length(10), weight: .heavy).italic())
                    .foregroundStyle(selected ? Color.black : Color(white: 0.9))
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
    let f: Figure

    var body: some View {
        Button { model.toggleMute() } label: {
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
            PanelButtonFace(diameter: f.length(30), glow: lit ? .red : nil)
            Image(systemName: "speaker.slash")
                .font(.system(size: f.length(11), weight: .bold))
                .foregroundStyle(lit ? Color.white : Color(white: 0.9))
        }
    }
}

/// A button drawn for completeness; it sends nothing.
private struct DecorativeButton: View {
    var symbol: String?
    var text: String?
    let f: Figure

    var body: some View {
        ZStack {
            PanelButtonFace(diameter: f.length(30), glow: nil)
            if let symbol {
                Image(systemName: symbol).font(.system(size: f.length(11), weight: .bold))
            } else if let text {
                Text(text).font(.system(size: f.length(10), weight: .heavy).italic())
            }
        }
        .foregroundStyle(Color(white: 0.9))
        .accessibilityHidden(true)
    }
}

private struct PowerButton: View {
    let f: Figure

    var body: some View {
        Capsule()
            .fill(Color(white: 0.2))
            .overlay(Capsule().stroke(Color.black, lineWidth: f.length(2)))
            .overlay(Image(systemName: "power")
                .font(.system(size: f.length(13), weight: .bold))
                .foregroundStyle(Color(white: 0.9)))
            .accessibilityHidden(true)
    }
}

// MARK: - Knob

/// The recess the knob sits in.
private struct KnobCradle: View {
    let f: Figure

    var body: some View {
        Circle()
            .fill(Color(white: 0.09))
            .overlay(Circle().stroke(Color(white: 0.35), lineWidth: f.length(1.5)))
            .frame(width: f.length(150), height: f.length(150))
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
                .fill(RadialGradient(colors: [Color(white: 0.36), Color(white: 0.1)],
                                     center: .init(x: 0.38, y: 0.3),
                                     startRadius: 0, endRadius: diameter * 0.65))
                .shadow(color: .black.opacity(0.8), radius: diameter * 0.05, y: diameter * 0.03)
            Circle().stroke(Color.black, lineWidth: diameter * 0.02)
            // Finger dimple; turns with the knob.
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.08), Color(white: 0.28)],
                                     center: .init(x: 0.4, y: 0.35),
                                     startRadius: 0, endRadius: diameter * 0.13))
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
                    let dx = drag.location.x - centre
                    let dy = drag.location.y - centre
                    // Near the centre the angle is meaningless: drop the anchor
                    // there and re-anchor past it, so crossing the centre
                    // never reads as half a turn.
                    guard dx * dx + dy * dy > diameter * diameter * 0.01 else {
                        tracker.angle = nil
                        return
                    }
                    let pointer = atan2(dy, dx) * 180 / .pi
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
        .onChange(of: dragging) { _, live in
            if !live {
                tracker.angle = nil
                model.endKnobTurn()
            }
        }
        .focusable()
        .onKeyPress(.upArrow) { model.stepKnob(up: true); return .handled }
        .onKeyPress(.rightArrow) { model.stepKnob(up: true); return .handled }
        .onKeyPress(.downArrow) { model.stepKnob(up: false); return .handled }
        .onKeyPress(.leftArrow) { model.stepKnob(up: false); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Main fader")
        .accessibilityValue(RemoteModel.faderText(model.fader))
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

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // The panel changes shape with the processor model: follow it.
        DispatchQueue.main.async { apply(to: nsView) }
    }

    private func apply(to view: NSView) {
        guard let window = view.window else { return }
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
        window.contentAspectRatio = NSSize(width: aspect, height: 1)
        if abs(window.frame.width / max(window.frame.height, 1) - aspect) > 0.001 || window.frame.width < 1100 {
            let width = max(window.frame.width, 1100)
            window.setContentSize(NSSize(width: width, height: width / aspect))
        }
    }
}

// The CP750 and the CP850/CP950 fronts, drawn after the front-panel figures
// of their manuals: the CP750 manual's figure 1-1, and the CP950/CP950A
// manual's figure 1. Each element sits where the figure puts it, as a
// fraction of the panel's width and height.
//
// The CP850 has no front-panel figure in the manuals we could get: it is
// drawn with the CP950 front. The controls the manuals name are live: the
// CP750's input buttons, mute and fader, and the CP950's fader and mute
// (on its screen). The lamps, the menu keys and the booth knob have no
// command the app knows, so they are drawn but do nothing.

import CPx50Comms
import SwiftUI

/// The panel's size, for placing elements by their centre as fractions.
private struct Grid {
    let w: CGFloat
    let h: CGFloat

    /// A disc whose diameter is a fraction of the panel's height.
    func disc<Fill: ShapeStyle>(_ x: CGFloat, _ y: CGFloat, _ d: CGFloat, fill: Fill) -> some View {
        Circle().fill(fill)
            .frame(width: h * d, height: h * d)
            .position(x: w * x, y: h * y)
    }

    /// A rectangle `dw` by `dh` (fractions of width and height) centred at `x`, `y`.
    func rect<Fill: ShapeStyle>(_ x: CGFloat, _ y: CGFloat, _ dw: CGFloat, _ dh: CGFloat,
                                fill: Fill, radius: CGFloat = 0) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .frame(width: w * dw, height: h * dh)
            .position(x: w * x, y: h * y)
    }

    /// Any view centred at `x`, `y`.
    func put<V: View>(_ x: CGFloat, _ y: CGFloat, _ view: V) -> some View {
        view.position(x: w * x, y: h * y)
    }

    /// Text centred at `x`, `y`, sized as a fraction of the height.
    func label(_ text: String, _ x: CGFloat, _ y: CGFloat, size: CGFloat, width: CGFloat = 0.2,
               weight: Font.Weight = .semibold, italic: Bool = false, color: Color) -> some View {
        Text(text)
            .font(.system(size: h * size, weight: weight, design: .default))
            .italic(italic)
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(text.contains("\n") ? 2 : 1)
            .minimumScaleFactor(0.4)
            .frame(width: w * width, height: h * size * (text.contains("\n") ? 2.6 : 1.6))
            .position(x: w * x, y: h * y)
    }
}

private let frontGrey = Color(white: 0.74)
private let frontDark = Color(white: 0.09)
private let keyCap = RadialGradient(colors: [Color(white: 0.9), Color(white: 0.55)],
                                    center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40)
private let knobBody = RadialGradient(colors: [Color(white: 0.3), Color(white: 0.08)],
                                      center: .init(x: 0.38, y: 0.3), startRadius: 0, endRadius: 120)

// MARK: - Live keys

/// A round key drawn after the panel's keycaps. A press calls `action`.
private struct Key: View {
    let diameter: CGFloat
    var lit: Color? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(lit ?? Color.clear)
                .overlay(Circle().fill(keyCap))
                .overlay(Circle().stroke(Color.black, lineWidth: diameter * 0.08))
                .shadow(color: lit ?? .clear, radius: diameter * 0.35)
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

// MARK: - CP750

/// The CP750 front, after figure 1-1 of the CP750 manual.
struct CP750Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geo in
            let g = Grid(w: geo.size.width, h: geo.size.height)
            ZStack {
                // Rack ears and the grey front.
                Rectangle().fill(Color(white: 0.1))
                g.rect(0.5, 0.5, 0.86, 0.9, fill: LinearGradient(colors: [Color(white: 0.86), Color(white: 0.6)],
                                                                  startPoint: .top, endPoint: .bottom),
                       radius: g.h * 0.04)
                // The red Dolby badge, top right.
                g.rect(0.8, 0.09, 0.27, 0.2, fill: Color(red: 0.8, green: 0.08, blue: 0.1), radius: g.h * 0.03)
                g.label("DOLBY", 0.76, 0.09, size: 0.11, width: 0.12, weight: .heavy, color: .white)
                g.label("CP750", 0.85, 0.13, size: 0.1, width: 0.12, weight: .heavy, italic: true, color: .white)
                // The seven input-select keys, with their names above; the
                // selected one lights.
                g.label("Input Select", 0.763, 0.86, size: 0.06, width: 0.2, color: Color(white: 0.3))
                let inputs = ["Digital\n1", "Digital\n2", "Digital\n3", "Digital\n4", "Multi-Ch\nAnalog", "\nNonSync", "\nMic"]
                let inputX: [CGFloat] = [0.643, 0.685, 0.722, 0.763, 0.802, 0.843, 0.883]
                ForEach(0..<7, id: \.self) { index in
                    g.put(inputX[index], 0.5, Key(diameter: g.h * 0.133, lit: model.formatButton == index + 1 ? .white : nil,
                                                 enabled: model.isConnected) { model.pressButton(index + 1) })
                    g.label(inputs[index], inputX[index], 0.31, size: 0.05, width: 0.038,
                            weight: .bold, color: Color(white: 0.2))
                }
                // The four Valid lamps under the inputs (no wire command here).
                ForEach(0..<4, id: \.self) { index in
                    g.disc([0.643, 0.684, 0.725, 0.763][index], 0.69, 0.044, fill: Color(white: 0.35))
                }
                // Menu keys and check mark (no wire command here), mute (live), USB.
                g.disc(0.19, 0.2, 0.122, fill: keyCap)
                g.disc(0.19, 0.68, 0.122, fill: keyCap)
                g.put(0.39, 0.68, Key(diameter: g.h * 0.122,
                                      lit: model.muted ? Color(red: 1, green: 0.15, blue: 0.1) : nil,
                                      enabled: model.isConnected) { model.toggleMute() })
                g.rect(0.55, 0.69, 0.025, 0.12, fill: Color(white: 0.25), radius: 2)
                // The display: the fader level, as the unit shows it.
                g.disc(0.28, 0.53, 0.72, fill: frontDark)
                g.label("Volume \(RemoteModel.faderText(model.fader))", 0.28, 0.5, size: 0.1, width: 0.15,
                        weight: .regular, color: Color(white: 0.7))
                g.label(model.currentInputName, 0.28, 0.6, size: 0.07, width: 0.12, weight: .regular,
                        color: Color(white: 0.5))
                // The main fader knob, to the right of the display: live.
                g.put(0.46, 0.44, FaderKnob(model: model, diameter: g.h * 0.53))
            }
        }
        .aspectRatio(ProcessorModel.cp750.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - CP850 / CP950

/// The CP950 front, after figure 1 of the CP950 and CP950A manual.
struct CP950Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geo in
            let g = Grid(w: geo.size.width, h: geo.size.height)
            ZStack {
                // The dark front, its left rack ear included.
                Rectangle().fill(Color(white: 0.16))
                g.rect(0.565, 0.5, 0.87, 0.96, fill: LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                                                                    startPoint: .top, endPoint: .bottom),
                       radius: g.h * 0.03)
                // The main fader knob, large, at the left: live.
                g.put(0.322, 0.483, FaderKnob(model: model, diameter: g.h * 0.413))
                // The touch screen: the fader level, and the speaker icon that
                // mutes (the manual's soft button for it).
                g.rect(0.52, 0.48, 0.209, 0.558, fill: Color(red: 0.05, green: 0.07, blue: 0.1), radius: g.h * 0.03)
                g.label("FADER \(RemoteModel.faderText(model.fader))", 0.52, 0.36, size: 0.075, width: 0.18,
                        weight: .bold, color: Color(white: 0.85))
                g.put(0.44, 0.36, Button { model.toggleMute() } label: {
                    Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: g.h * 0.07))
                        .foregroundStyle(model.muted ? Color.red : Color(white: 0.85))
                }
                .buttonStyle(.plain)
                .disabled(!model.isConnected))
                // The vertical status LEDs (no wire command here): green, as in the photo.
                g.rect(0.66, 0.5, 0.005, 0.72, fill: Color(red: 0.2, green: 0.8, blue: 0.3), radius: 1)
                // The booth monitor volume knob and its speaker grille (no wire command here).
                g.disc(0.70, 0.48, 0.165, fill: knobBody)
                grille(g, x: 0.85, y: 0.52, dw: 0.199, dh: 0.579)
                // The Dolby mark, bottom left.
                g.label("DOLBY", 0.27, 0.85, size: 0.1, width: 0.12, weight: .heavy, color: Color(white: 0.9))
            }
        }
        .aspectRatio(ProcessorModel.cp950.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    /// The speaker grille: a field of small dots.
    private func grille(_ g: Grid, x: CGFloat, y: CGFloat, dw: CGFloat, dh: CGFloat) -> some View {
        Canvas { context, size in
            let step = size.height / 14
            for row in 0..<14 {
                for column in 0..<Int(size.width / step) {
                    let point = CGRect(x: CGFloat(column) * step + step / 2 - 1,
                                       y: CGFloat(row) * step + step / 2 - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: point), with: .color(Color(white: 0.4)))
                }
            }
        }
        .background(Color(white: 0.06))
        .frame(width: g.w * dw, height: g.h * dh)
        .position(x: g.w * x, y: g.h * y)
    }
}

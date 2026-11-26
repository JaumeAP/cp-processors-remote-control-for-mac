// The CP650's buttons: the format buttons and the mute button (live), and the
// decorative menu and power buttons (drawn, sending nothing).

import SwiftUI

struct PanelButtonFace: View {
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

struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .brightness(configuration.isPressed ? -0.1 : 0)
    }
}

struct FormatButton: View {
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

struct MuteButton: View {
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
struct DecorativeButton: View {
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

struct PowerButton: View {
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

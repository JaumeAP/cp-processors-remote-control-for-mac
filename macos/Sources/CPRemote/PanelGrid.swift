// The drawing helpers shared by the CP750, CP850 and CP950 fronts: a grid that
// places elements by fractions of the panel, the round live key, and the
// colours of their keycaps and knobs.

import SwiftUI

/// The panel's size, for placing elements by their centre as fractions.
struct PanelGrid {
    let panelWidth: CGFloat
    let panelHeight: CGFloat

    /// A disc whose diameter is a fraction of the panel's height.
    func disc<Fill: ShapeStyle>(
        _ xFraction: CGFloat, _ yFraction: CGFloat, _ diameterFraction: CGFloat, fill: Fill
    ) -> some View {
        Circle().fill(fill)
            .frame(width: panelHeight * diameterFraction, height: panelHeight * diameterFraction)
            .position(x: panelWidth * xFraction, y: panelHeight * yFraction)
    }

    /// A rectangle `widthFraction` by `heightFraction` (fractions of width and height) centred at
    /// `xFraction`, `yFraction`.
    func rect<Fill: ShapeStyle>(
        _ xFraction: CGFloat, _ yFraction: CGFloat, _ widthFraction: CGFloat, _ heightFraction: CGFloat,
        fill: Fill, radius: CGFloat = 0
    ) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .frame(width: panelWidth * widthFraction, height: panelHeight * heightFraction)
            .position(x: panelWidth * xFraction, y: panelHeight * yFraction)
    }

    /// Any view centred at `xFraction`, `yFraction`.
    func put<V: View>(_ xFraction: CGFloat, _ yFraction: CGFloat, _ view: V) -> some View {
        view.position(x: panelWidth * xFraction, y: panelHeight * yFraction)
    }

    /// Text centred at `xFraction`, `yFraction`, sized as a fraction of the height.
    func label(
        _ text: String, _ xFraction: CGFloat, _ yFraction: CGFloat, size: CGFloat, width: CGFloat = 0.2,
        weight: Font.Weight = .semibold, italic: Bool = false, color: Color
    ) -> some View {
        Text(text)
            .font(
                italic
                    ? Font.system(size: panelHeight * size, weight: weight).italic()
                    : Font.system(size: panelHeight * size, weight: weight)
            )
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .lineLimit(text.contains("\n") ? 2 : 1)
            .minimumScaleFactor(0.4)
            .frame(width: panelWidth * width, height: panelHeight * size * (text.contains("\n") ? 2.6 : 1.6))
            .position(x: panelWidth * xFraction, y: panelHeight * yFraction)
    }
}

let frontDark = Color(white: 0.09)
let keyCap = RadialGradient(
    colors: [Color(white: 0.9), Color(white: 0.55)],
    center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40)
let knobBody = RadialGradient(
    colors: [Color(white: 0.3), Color(white: 0.08)],
    center: .init(x: 0.38, y: 0.3), startRadius: 0, endRadius: 120)

// MARK: - Live keys

/// A round key drawn after the panel's keycaps. A press calls `action`.
struct Key: View {
    let diameter: CGFloat
    var lit: Color?
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // The lit colour is drawn over the keycap: under it, the opaque
            // cap hid it and a selected key looked like the others.
            Circle()
                .fill(keyCap)
                .overlay(Circle().fill(lit ?? Color.clear).opacity(0.75))
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

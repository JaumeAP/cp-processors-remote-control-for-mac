// The CP950 front, after figure 1 of the CP950 and CP950A manual. The fader,
// its mute and the macro list are live; the LEDs, the booth knob and the
// speaker grille are drawn only.

import SwiftUI

/// The CP950 front, after figure 1 of the CP950 and CP950A manual.
struct CP950Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geometry in
            let grid = PanelGrid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
            ZStack {
                // The dark front, its left rack ear included.
                Rectangle().fill(Color(white: 0.16))
                grid.rect(
                    0.565, 0.5, 0.87, 0.96,
                    fill: LinearGradient(
                        colors: [Color(white: 0.22), Color(white: 0.12)],
                        startPoint: .top, endPoint: .bottom),
                    radius: grid.panelHeight * 0.03)
                // The main fader knob, large, at the left: live.
                grid.put(0.322, 0.483, FaderKnob(model: model, diameter: grid.panelHeight * 0.413))
                // The touch screen: the fader level, and the speaker icon that
                // mutes (the manual's soft button for it).
                grid.rect(
                    0.52, 0.48, 0.209, 0.558, fill: Color(red: 0.05, green: 0.07, blue: 0.1),
                    radius: grid.panelHeight * 0.03)
                grid.label(
                    "FADER \(model.levelTextWithUnit)", 0.535, 0.36, size: model.levelInDecibels ? 0.06 : 0.075,
                    width: 0.15,
                    weight: .bold, color: Color(white: 0.85)
                )
                .onTapGesture { model.toggleLevelUnit() }
                .accessibilityLabel("Fader \(model.levelTextWithUnit)")
                .accessibilityHint("Switches between the fader number and decibels")
                .accessibilityAddTraits(.isButton)
                if let macros = model.macros {
                    // The macros the unit offers; the selected one is white.
                    ForEach(Array(macros.prefix(8).enumerated()), id: \.element.number) { index, macro in
                        let selected = macro.number == model.macroPreset
                        grid.put(
                            0.52, 0.45 + 0.042 * CGFloat(index),
                            Button {
                                model.selectMacro(macro.number)
                            } label: {
                                Text("\(selected ? "\u{25B8} " : "")\(macro.name)")
                                    .font(.system(size: grid.panelHeight * 0.036, weight: selected ? .bold : .regular))
                                    .foregroundStyle(selected ? Color.white : Color(white: 0.6))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.5)
                                    .frame(width: grid.panelWidth * 0.19, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                            .disabled(!model.isConnected)
                            .accessibilityLabel("Macro \(macro.number): \(macro.name)")
                            .accessibilityAddTraits(selected ? .isSelected : []))
                    }
                } else if let macro = model.macroName {
                    grid.label(macro, 0.52, 0.5, size: 0.06, width: 0.19, weight: .regular, color: Color(white: 0.7))
                }
                grid.put(
                    0.44, 0.36,
                    Button {
                        model.toggleMute()
                    } label: {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: grid.panelHeight * 0.07))
                            .foregroundStyle(model.muted ? Color.red : Color(white: 0.85))
                    }
                    .buttonStyle(.plain)
                    .disabled(!model.isConnected)
                    .accessibilityLabel(model.muted ? "Unmute" : "Mute"))
                // The vertical status LEDs (no wire command here): green, as in the photo.
                grid.rect(0.66, 0.5, 0.005, 0.72, fill: Color(red: 0.2, green: 0.8, blue: 0.3), radius: 1)
                // The booth monitor volume knob and its speaker grille (no wire command here).
                grid.disc(0.70, 0.48, 0.165, fill: knobBody)
                grille(grid, xFraction: 0.85, yFraction: 0.52, widthFraction: 0.199, heightFraction: 0.579)
                // The Dolby mark, bottom left.
                grid.label("DOLBY", 0.27, 0.85, size: 0.1, width: 0.12, weight: .heavy, color: Color(white: 0.9))
            }
        }
        .aspectRatio(ProcessorModel.cp950.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    /// The speaker grille: a field of small dots.
    private func grille(
        _ grid: PanelGrid, xFraction: CGFloat, yFraction: CGFloat, widthFraction: CGFloat, heightFraction: CGFloat
    ) -> some View {
        Canvas { context, size in
            let step = size.height / 14
            for row in 0..<14 {
                for column in 0..<Int(size.width / step) {
                    let point = CGRect(
                        x: CGFloat(column) * step + step / 2 - 1,
                        y: CGFloat(row) * step + step / 2 - 1, width: 2, height: 2)
                    context.fill(Path(ellipseIn: point), with: .color(Color(white: 0.4)))
                }
            }
        }
        .background(Color(white: 0.06))
        .frame(width: grid.panelWidth * widthFraction, height: grid.panelHeight * heightFraction)
        .position(x: grid.panelWidth * xFraction, y: grid.panelHeight * yFraction)
    }
}

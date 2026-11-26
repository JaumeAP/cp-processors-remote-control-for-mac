// The CP850 front, after Dolby's product photos (no front-panel figure in the
// manuals we could get). The fader, mute and the eight macro keys are live;
// the navigation cross, the power key and the lamps are drawn only.

import SwiftUI

/// A black round key of the CP850 with its engraved label; `lit` colours the
/// label (the selected macro's number glows blue on the unit).
private struct DarkKey: View {
    let diameter: CGFloat
    var label: String = ""
    var symbol: String?
    var lit: Color?
    var enabled: Bool = true
    var action: (() -> Void)?

    var body: some View {
        let face = ZStack {
            Circle().fill(
                RadialGradient(
                    colors: [Color(white: 0.25), Color(white: 0.03)],
                    center: .init(x: 0.4, y: 0.3), startRadius: 0, endRadius: diameter))
            Circle().stroke(Color(white: 0.55), lineWidth: diameter * 0.05)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.42, weight: .bold))
                    .foregroundStyle(lit ?? Color(white: 0.85))
            } else {
                Text(label)
                    .font(.system(size: diameter * 0.45, weight: .bold))
                    .foregroundStyle(lit ?? Color(white: 0.85))
            }
        }
        .frame(width: diameter, height: diameter)
        .shadow(color: lit ?? .clear, radius: diameter * 0.2)
        if let action {
            Button(action: action) { face.contentShape(Circle()) }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.45)
        } else {
            face.accessibilityHidden(true)
        }
    }
}

/// The CP850 front, after Dolby's product photos (no front-panel figure in
/// the manuals we could get).
struct CP850Panel: View {
    @ObservedObject var model: RemoteModel

    private static let macroXFractions: [CGFloat] = (0..<8).map { 0.648 + 0.0315 * CGFloat($0) }
    private static let blue = Color(red: 0.25, green: 0.55, blue: 1)

    var body: some View {
        GeometryReader { geometry in
            let grid = PanelGrid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
            ZStack {
                // Rack ears and the black front.
                Rectangle().fill(Color(white: 0.06))
                grid.rect(
                    0.5, 0.5, 0.9, 0.98,
                    fill: LinearGradient(
                        colors: [Color(white: 0.13), Color(white: 0.05)],
                        startPoint: .top, endPoint: .bottom),
                    radius: grid.panelHeight * 0.03)
                // The left block: Dolby mark, the fader knob (live), mute (live).
                grid.label("DOLBY", 0.17, 0.17, size: 0.12, width: 0.12, weight: .heavy, color: Color(white: 0.9))
                grid.put(0.165, 0.52, FaderKnob(model: model, diameter: grid.panelHeight * 0.5))
                grid.put(
                    0.262, 0.52,
                    DarkKey(
                        diameter: grid.panelHeight * 0.13, symbol: "speaker.slash.fill",
                        lit: model.muted ? Color(red: 1, green: 0.15, blue: 0.1) : nil,
                        enabled: model.isConnected
                    ) { model.toggleMute() }
                    .accessibilityLabel(model.muted ? "Unmute" : "Mute"))
                // The blue light strip between the blocks.
                grid.rect(0.312, 0.5, 0.004, 0.94, fill: Self.blue, radius: 1)
                // The brushed aluminium inlay, a long capsule.
                grid.rect(
                    0.655, 0.49, 0.62, 0.44,
                    fill: LinearGradient(
                        colors: [Color(white: 0.88), Color(white: 0.66)],
                        startPoint: .top, endPoint: .bottom),
                    radius: grid.panelHeight * 0.22)
                // The four-line LCD: the fader and the macro, then the menu.
                grid.rect(
                    0.435, 0.49, 0.175, 0.33, fill: Color(red: 0.62, green: 0.74, blue: 0.78),
                    radius: grid.panelHeight * 0.02)
                lcdLine("Fader: \(model.levelTextWithUnit)", grid, row: 0)
                    .onTapGesture { model.toggleLevelUnit() }
                    .accessibilityLabel("Fader \(model.levelTextWithUnit)")
                    .accessibilityHint("Switches between the fader number and decibels")
                    .accessibilityAddTraits(.isButton)
                lcdLine(model.macroName.map { " \($0)" } ?? "", grid, row: 1)
                lcdLine("\u{22A0}Macros  \u{25A1}Network", grid, row: 2).accessibilityHidden(true)
                lcdLine("\u{25A1}Messages \u{25A1}Options", grid, row: 3).accessibilityHidden(true)
                // The navigation cross (no wire command here).
                let navKey = grid.panelHeight * 0.11
                grid.put(0.565, 0.33, DarkKey(diameter: navKey, symbol: "chevron.up"))
                grid.put(0.54, 0.49, DarkKey(diameter: navKey, symbol: "chevron.left"))
                grid.put(0.565, 0.49, DarkKey(diameter: navKey, symbol: "circle.fill"))
                grid.put(0.59, 0.49, DarkKey(diameter: navKey, symbol: "chevron.right"))
                grid.put(0.54, 0.65, DarkKey(diameter: navKey, symbol: "arrow.uturn.left"))
                grid.put(0.565, 0.65, DarkKey(diameter: navKey, symbol: "chevron.down"))
                // The eight macro keys (live): key n sends sys.macro_preset n,
                // "change to a macro by number", 1 to 8 as mapped in the macro
                // editor (CP950/CP950A manual issue 9, table 18, p. 157; the
                // CP850 uses the same command). The selected key's number is blue.
                ForEach(1...8, id: \.self) { key in
                    let selected = model.macroPreset == key
                    grid.put(
                        Self.macroXFractions[key - 1], 0.49,
                        DarkKey(
                            diameter: grid.panelHeight * 0.12, label: "\(key)", lit: selected ? Self.blue : nil,
                            enabled: model.isConnected
                        ) { model.selectMacro(key) }
                        .accessibilityLabel(macroLabel(key: key))
                        .accessibilityAddTraits(selected ? .isSelected : []))
                }
                // The power key, at the right end (no wire command here).
                grid.put(0.93, 0.49, DarkKey(diameter: grid.panelHeight * 0.12, symbol: "power"))
                grid.label(
                    "Dolby Atmos Cinema Processor CP850", 0.82, 0.86, size: 0.075, width: 0.3,
                    weight: .medium, italic: true, color: Color(white: 0.85))
            }
        }
        .aspectRatio(ProcessorModel.cp850.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }

    /// One line of the LCD, in the unit's monospaced dark lettering.
    private func lcdLine(_ text: String, _ grid: PanelGrid, row: Int) -> some View {
        Text(text)
            .font(.system(size: grid.panelHeight * 0.074, weight: .medium, design: .monospaced))
            .foregroundStyle(Color(red: 0.06, green: 0.12, blue: 0.16))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(width: grid.panelWidth * 0.165, alignment: .leading)
            .position(x: grid.panelWidth * 0.435, y: grid.panelHeight * (0.375 + 0.077 * CGFloat(row)))
    }

    private func macroLabel(key: Int) -> String {
        let name = model.macros?.first { $0.number == key }?.name
        return "Macro key \(key)" + (name.map { ": \($0)" } ?? "")
    }
}

// The CP750, CP850 and CP950 fronts. The CP750 and CP950 are drawn after the
// front-panel figures of their manuals (the CP750 manual's figure 1-1, the
// CP950/CP950A manual's figure 1); the CP850, which has no such figure in the
// manuals we could get, after Dolby's own product photos of it. Each element
// sits where the figure or photo puts it, as a fraction of the panel's width
// and height.
//
// The controls the app has commands for are live: the CP750's input buttons,
// mute and fader; the CP850's fader, mute and eight macro keys; the CP950's
// fader and mute (on its screen) and its macro list. The lamps, the menu and
// navigation keys, the power key and the booth knob are drawn but do nothing.

import SwiftUI

/// The panel's size, for placing elements by their centre as fractions.
private struct Grid {
    let panelWidth: CGFloat
    let panelHeight: CGFloat

    /// A disc whose diameter is a fraction of the panel's height.
    func disc<Fill: ShapeStyle>(_ xFraction: CGFloat, _ yFraction: CGFloat, _ diameterFraction: CGFloat, fill: Fill)
        -> some View
    {
        Circle().fill(fill)
            .frame(width: panelHeight * diameterFraction, height: panelHeight * diameterFraction)
            .position(x: panelWidth * xFraction, y: panelHeight * yFraction)
    }

    /// A rectangle `widthFraction` by `heightFraction` (fractions of width and height) centred at `xFraction`,
    /// `yFraction`.
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

private let frontGrey = Color(white: 0.74)
private let frontDark = Color(white: 0.09)
private let keyCap = RadialGradient(
    colors: [Color(white: 0.9), Color(white: 0.55)],
    center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 40)
private let knobBody = RadialGradient(
    colors: [Color(white: 0.3), Color(white: 0.08)],
    center: .init(x: 0.38, y: 0.3), startRadius: 0, endRadius: 120)

// MARK: - Live keys

/// A round key drawn after the panel's keycaps. A press calls `action`.
private struct Key: View {
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

// MARK: - CP750

/// The CP750 front, after figure 1-1 of the CP750 manual.
struct CP750Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geometry in
            let grid = Grid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
            ZStack {
                // Rack ears and the grey front.
                Rectangle().fill(Color(white: 0.1))
                grid.rect(
                    0.5, 0.5, 0.86, 0.9,
                    fill: LinearGradient(
                        colors: [Color(white: 0.86), Color(white: 0.6)],
                        startPoint: .top, endPoint: .bottom),
                    radius: grid.panelHeight * 0.04)
                // The red Dolby badge, top right.
                grid.rect(
                    0.8, 0.09, 0.27, 0.2, fill: Color(red: 0.8, green: 0.08, blue: 0.1), radius: grid.panelHeight * 0.03
                )
                grid.label("DOLBY", 0.76, 0.09, size: 0.11, width: 0.12, weight: .heavy, color: .white)
                grid.label("CP750", 0.85, 0.13, size: 0.1, width: 0.12, weight: .heavy, italic: true, color: .white)
                // The seven input-select keys, with their names above; the
                // selected one lights.
                grid.label("Input Select", 0.763, 0.86, size: 0.06, width: 0.2, color: Color(white: 0.3))
                let inputs = [
                    "Digital\n1", "Digital\n2", "Digital\n3", "Digital\n4", "Multi-Ch\nAnalog", "\nNonSync", "\nMic",
                ]
                let inputXFractions: [CGFloat] = [0.643, 0.685, 0.722, 0.763, 0.802, 0.843, 0.883]
                let inputNames = [
                    "Digital 1", "Digital 2", "Digital 3", "Digital 4", "Multi-Ch Analog",
                    "NonSync", "Mic",
                ]
                ForEach(0..<7, id: \.self) { index in
                    let selected = model.formatButton == index + 1
                    grid.put(
                        inputXFractions[index], 0.5,
                        Key(
                            diameter: grid.panelHeight * 0.133, lit: selected ? .white : nil,
                            enabled: model.isConnected
                        ) { model.pressButton(index + 1) }
                        .accessibilityLabel("Input \(inputNames[index])")
                        .accessibilityAddTraits(selected ? .isSelected : []))
                    grid.label(
                        inputs[index], inputXFractions[index], 0.31, size: 0.05, width: 0.038,
                        weight: .bold, color: Color(white: 0.2)
                    )
                    .accessibilityHidden(true)
                }
                // The four Valid lamps under the inputs (no wire command here).
                ForEach(0..<4, id: \.self) { index in
                    grid.disc([0.643, 0.684, 0.725, 0.763][index], 0.69, 0.044, fill: Color(white: 0.35))
                }
                // Menu keys and check mark (no wire command here), mute (live), USB.
                grid.disc(0.19, 0.2, 0.122, fill: keyCap)
                grid.disc(0.19, 0.68, 0.122, fill: keyCap)
                grid.put(
                    0.39, 0.68,
                    Key(
                        diameter: grid.panelHeight * 0.122,
                        lit: model.muted ? Color(red: 1, green: 0.15, blue: 0.1) : nil,
                        enabled: model.isConnected
                    ) { model.toggleMute() }
                    .accessibilityLabel(model.muted ? "Unmute" : "Mute"))
                grid.rect(0.55, 0.69, 0.025, 0.12, fill: Color(white: 0.25), radius: 2)
                // The display: the fader level, as the unit shows it.
                grid.disc(0.28, 0.53, 0.72, fill: frontDark)
                grid.label(
                    "Volume \(model.levelTextWithUnit)", 0.28, 0.5, size: 0.1, width: 0.15,
                    weight: .regular, color: Color(white: 0.7)
                )
                .onTapGesture { model.toggleLevelUnit() }
                .accessibilityLabel("Volume \(model.levelTextWithUnit)")
                .accessibilityHint("Switches between the fader number and decibels")
                .accessibilityAddTraits(.isButton)
                grid.label(
                    model.currentInputName, 0.28, 0.6, size: 0.07, width: 0.12, weight: .regular,
                    color: Color(white: 0.5))
                // The main fader knob, to the right of the display: live.
                grid.put(0.46, 0.44, FaderKnob(model: model, diameter: grid.panelHeight * 0.53))
            }
        }
        .aspectRatio(ProcessorModel.cp750.aspect, contentMode: .fit)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - CP850

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
            let grid = Grid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
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
    private func lcdLine(_ text: String, _ grid: Grid, row: Int) -> some View {
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

// MARK: - CP950

/// The CP950 front, after figure 1 of the CP950 and CP950A manual.
struct CP950Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geometry in
            let grid = Grid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
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
        _ grid: Grid, xFraction: CGFloat, yFraction: CGFloat, widthFraction: CGFloat, heightFraction: CGFloat
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

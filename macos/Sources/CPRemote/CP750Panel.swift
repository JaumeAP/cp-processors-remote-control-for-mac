// The CP750 front, after figure 1-1 of the CP750 manual. The input buttons,
// mute and fader are live; the lamps and the Dolby badge are drawn only.

import SwiftUI

/// The CP750 front, after figure 1-1 of the CP750 manual.
struct CP750Panel: View {
    @ObservedObject var model: RemoteModel

    var body: some View {
        GeometryReader { geometry in
            let grid = PanelGrid(panelWidth: geometry.size.width, panelHeight: geometry.size.height)
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
                    0.8, 0.09, 0.27, 0.2, fill: Color(red: 0.8, green: 0.08, blue: 0.1),
                    radius: grid.panelHeight * 0.03)
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

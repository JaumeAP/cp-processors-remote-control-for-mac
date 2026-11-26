// The CP650 front panel, drawn in vectors after figure 2-1 of the CP650
// user's manual: every element sits at the position and size it has in that
// drawing, scaled to the window, so the panel keeps the real proportions.
//
// Live: the eight format buttons, the mute button, the level display, the
// main fader knob and the front-panel LCD. Drawn only (no wire command is
// known for them): the menu buttons, the power button and the P1/P2 lamps.

import SwiftUI

/// The panel's outline in figure 2-1, in the figure's own pixel units.
private let figure = CGRect(x: 112, y: 642, width: 956, height: 280)
let panelAspect: CGFloat = figure.width / figure.height

/// Maps figure 2-1 coordinates to the view.
struct Figure {
    let scale: CGFloat

    func point(_ xCoord: CGFloat, _ yCoord: CGFloat) -> CGPoint {
        CGPoint(x: (xCoord - figure.minX) * scale, y: (yCoord - figure.minY) * scale)
    }

    func length(_ value: CGFloat) -> CGFloat { value * scale }
}

extension View {
    /// Place the view over the figure rectangle `left...right` by `top...bottom`.
    func placed(
        _ mapping: Figure, _ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat
    ) -> some View {
        frame(width: mapping.length(right - left), height: mapping.length(bottom - top))
            .position(mapping.point((left + right) / 2, (top + bottom) / 2))
    }

    /// Centre the view on the figure point `(xCoord, yCoord)`.
    func centred(_ mapping: Figure, _ xCoord: CGFloat, _ yCoord: CGFloat) -> some View {
        position(mapping.point(xCoord, yCoord))
    }
}

// The face is light grey and its lettering dark, as on the unit.
let faceColor = Color(white: 0.74)
let printColor = Color(white: 0.12)
/// Controls that cannot act (no answering link) are drawn faded.
let disabledOpacity = 0.4

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

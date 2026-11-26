// The CP650's displays: the front-panel LCD, the fader level display and the
// projector lamps. The level display is live (tap to switch the unit).

import SwiftUI

struct LCDView: View {
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

struct LevelDisplay: View {
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

struct ProjectorLamps: View {
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

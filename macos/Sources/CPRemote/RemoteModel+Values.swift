// The conversions between the processor's wire values and what the screens
// show: the fader number, the decibels, the names of the choices and formats.

import Foundation

extension RemoteModel {
    static func faderText(_ value: Double) -> String { String(format: "%.1f", value) }

    /// The fader scale of the Dolby processors: 0.0 to 4.0 in steps of 20 dB
    /// from -90 to -10 dB, then 3 1/3 dB per unit up to +10 dB at 10;
    /// 7.0 is 0 dB (the CP650 and CP750 manuals, read from public copies).
    static func decibels(forFader fader: Double) -> Double {
        fader < 4 ? -90 + 20 * fader : (fader - 7) * 10 / 3
    }

    /// The level as shown: the fader number, or decibels with a sign.
    static func levelText(_ fader: Double, decibels: Bool) -> String {
        guard decibels else { return faderText(fader) }
        let value = (Self.decibels(forFader: fader) * 10).rounded() / 10
        return value == 0 ? "0.0" : String(format: "%+.1f", value)
    }

    /// The name shown for a choice in Setup.
    static func choiceName(_ model: ProcessorModel) -> String {
        model == .cp950 ? "CP950 / CP950A" : model.rawValue
    }

    /// Names of the standard Dolby cinema formats (CP650 user's manual);
    /// a number not listed has no name shown.
    static let formatNames = [
        "01": "Mono", "04": "Dolby A-Type", "05": "Dolby SR", "10": "Dolby Digital",
        "11": "External 6-channel", "60": "Nonsync",
    ]

    /// A fader reply in tenths as a level, held within 0.0 to 10.0; nil when
    /// it is not a finite number (`nan`, `inf`, text).
    static func faderLevel(_ reply: String?) -> Double? {
        guard let reply, let tenths = Double(reply), tenths.isFinite else { return nil }
        return clampFader(tenths / 10)
    }

    static func clampFader(_ value: Double) -> Double {
        min(max((value * 10).rounded() / 10, faderRange.lowerBound), faderRange.upperBound)
    }
}

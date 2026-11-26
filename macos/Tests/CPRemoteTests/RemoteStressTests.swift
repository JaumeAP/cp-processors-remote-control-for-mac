// Tests of the app's model (`RemoteModel`) that need no processor: what it
// remembers, how its fronts draw, its connection log and its level unit.

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import CPRemote

// MARK: - Tests

// Every test removes its own defaults suite, so none leaves a file in
// ~/Library/Preferences.

/// The app's choices survive a restart: the model and the address are stored
/// in the defaults and read back by a new model.
@MainActor
@Suite struct PersistenceTests {
    @Test func modelAndAddressAreRemembered() throws {
        let suite = "CPRemoteTests.persistence"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let first = RemoteModel(defaults: defaults, log: nil)
        first.host = "10.0.0.5"
        first.choose(.cp750)
        let second = RemoteModel(defaults: defaults, log: nil)
        #expect(second.host == "10.0.0.5")
        #expect(second.processorModel == .cp750)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func unknownStoredModelFallsBackToTheCP650() throws {
        let suite = "CPRemoteTests.fallback"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("CP999", forKey: "processorModel")
        #expect(RemoteModel(defaults: defaults, log: nil).processorModel == .cp650)
        defaults.removePersistentDomain(forName: suite)
    }

    /// A stored CP950A reads back as the CP950 choice, so Setup's picker shows it.
    @Test func storedCP950AIsTheCP950Choice() throws {
        let suite = "CPRemoteTests.cp950a.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("CP950A", forKey: "processorModel")
        let model = RemoteModel(defaults: defaults, log: nil)
        #expect(model.processorModel == .cp950)
        #expect(RemoteModel.choices.contains(model.processorModel))
    }
}

/// Fader replies from the wire, in tenths, as levels.
@MainActor
@Suite struct FaderValueTests {
    @Test func repliesInTenthsBecomeLevels() {
        #expect(RemoteModel.faderLevel("70") == 7.0)
        #expect(RemoteModel.faderLevel("55") == 5.5)
        #expect(RemoteModel.faderLevel("0") == 0)
    }

    @Test func repliesOutsideTheRangeAreHeldAtItsEnds() {
        #expect(RemoteModel.faderLevel("150") == 10)
        #expect(RemoteModel.faderLevel("-5") == 0)
    }

    @Test func repliesThatAreNotFiniteNumbersAreRefused() {
        #expect(RemoteModel.faderLevel(nil) == nil)
        #expect(RemoteModel.faderLevel("nan") == nil)
        #expect(RemoteModel.faderLevel("inf") == nil)
        #expect(RemoteModel.faderLevel("error") == nil)
    }

    @Test func levelsAreRoundedToTenths() {
        #expect(RemoteModel.clampFader(6.04) == 6.0)
        #expect(RemoteModel.clampFader(6.06) == 6.1)
    }
}

/// Every front panel draws, the same way twice (a blank or unstable panel
/// fails here). The two pictures are compared pixel by pixel with a small
/// tolerance: byte-equal PNGs failed now and then under load (antialiasing
/// and compression varied) while the pictures were the same. The pictures
/// are kept only when CPREMOTE_RENDER_DIR names a folder.
@MainActor
@Suite struct PanelRenderTests {
    @Test(arguments: [ProcessorModel.cp650, .cp750, .cp850, .cp950])
    func frontDrawsDeterministically(_ processor: ProcessorModel) throws {
        let suite = "CPRemoteTests.render.\(processor.rawValue)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = RemoteModel(defaults: defaults, log: nil)
        model.choose(processor)
        let width: CGFloat = 900
        let size = CGSize(width: width, height: width / processor.aspect)
        func render() throws -> NSBitmapImageRep {
            let renderer = ImageRenderer(
                content: FrontPanelView(model: model).frame(width: size.width, height: size.height))
            renderer.scale = 1
            return NSBitmapImageRep(cgImage: try #require(renderer.cgImage))
        }
        let first = try render()
        let second = try render()
        let png = try #require(first.representation(using: .png, properties: [:]))
        // CPREMOTE_RENDER_DIR keeps the picture, to look at a front by eye.
        if let folder = ProcessInfo.processInfo.environment["CPREMOTE_RENDER_DIR"], !folder.isEmpty {
            try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(processor.rawValue).png"))
        }
        #expect(png.count > 20_000, "a blank panel would be almost empty")
        #expect(first.pixelsWide == second.pixelsWide && first.pixelsHigh == second.pixelsHigh)
        // Pixels differing by more than a few levels, sampled every 3 pixels.
        var differing = 0
        var sampled = 0
        for row in stride(from: 0, to: first.pixelsHigh, by: 3) {
            for column in stride(from: 0, to: first.pixelsWide, by: 3) {
                guard let firstColor = first.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB),
                    let secondColor = second.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB)
                else { continue }
                sampled += 1
                let delta =
                    abs(firstColor.redComponent - secondColor.redComponent)
                    + abs(firstColor.greenComponent - secondColor.greenComponent)
                    + abs(firstColor.blueComponent - secondColor.blueComponent)
                if delta > 0.05 { differing += 1 }
            }
        }
        #expect(
            Double(differing) <= Double(sampled) * 0.001,
            "the same state must draw the same picture (\(differing) of \(sampled) pixels differ)")
    }
}

/// The connection log: its file and its rotation.
@MainActor
@Suite struct ConnectionLogTests {
    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("CPRemoteLogTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func linesAreTimestampedAndKeptInOrder() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ConnectionLog(directory: folder)
        log.write("first")
        log.write("second")
        log.flush()
        let lines = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].hasSuffix(" first") && lines[1].hasSuffix(" second"))
        // 2026-11-10T11:22:25.123Z: the time, to the millisecond, in UTC.
        #expect(
            lines[0].range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z "#, options: .regularExpression) != nil)
    }

    @Test func theFileRotatesAndNeverGrowsWithoutLimit() throws {
        let folder = temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = ConnectionLog(directory: folder, maximumBytes: 2_000)
        for number in 0..<400 { log.write("line number \(number) with some padding to fill the file") }
        log.flush()
        let sizes = ["connection.log", "connection.log.1"].map {
            (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path))?[.size] as? Int
                ?? 0
        }
        #expect(sizes[1] > 0, "the older file exists")
        #expect(sizes[0] <= 2_000 + 200 && sizes[1] <= 2_000 + 200, "each file stays near the limit")
        let newest = try String(contentsOf: log.url, encoding: .utf8)
        #expect(newest.contains("line number 399"), "the newest line is kept")
    }
}

/// The level shown as the fader number or in decibels (7.0 is 0 dB).
@MainActor
@Suite struct LevelUnitTests {
    @Test func theDolbyFaderScaleInDecibels() {
        #expect(RemoteModel.decibels(forFader: 7.0) == 0)
        #expect(RemoteModel.decibels(forFader: 4.0) == -10)
        #expect(RemoteModel.decibels(forFader: 10.0) == 10)
        #expect(RemoteModel.decibels(forFader: 0.0) == -90)
        #expect(RemoteModel.levelText(7.0, decibels: true) == "0.0")
        #expect(RemoteModel.levelText(8.0, decibels: true) == "+3.3")
        #expect(RemoteModel.levelText(5.0, decibels: true) == "-6.7")
        #expect(RemoteModel.levelText(2.0, decibels: true) == "-50.0")
        #expect(RemoteModel.levelText(7.0, decibels: false) == "7.0")
    }

    @Test func theChoiceIsRemembered() throws {
        let name = "CPRemoteTests.level.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let first = RemoteModel(defaults: defaults, log: nil)
        #expect(first.levelInDecibels == false)
        first.toggleLevelUnit()
        #expect(first.levelText == RemoteModel.levelText(first.fader, decibels: true))
        let second = RemoteModel(defaults: defaults, log: nil)
        #expect(second.levelInDecibels == true)
    }
}

// Draws the app icon and writes it as an .icns file.
// Usage: swift make-icon.swift <output.icns>
//
// The icon is a light grey rounded square with a red band across the top, as
// the front of the processors, and "CP" in dark lettering below the band.

import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.icns>\n".utf8))
    exit(2)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])

/// The icon as a PNG, `pixels` wide and high.
func png(pixels: Int) -> Data {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let side = CGFloat(pixels)
    let inset = side * 0.08
    let body = NSRect(x: inset, y: inset, width: side - 2 * inset, height: side - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: side * 0.18, yRadius: side * 0.18)
    NSGradient(starting: NSColor(white: 0.88, alpha: 1), ending: NSColor(white: 0.68, alpha: 1))!
        .draw(in: shape, angle: -90)
    // The red band, clipped to the rounded shape.
    shape.addClip()
    NSColor(red: 0.88, green: 0.10, blue: 0.14, alpha: 1).setFill()
    NSRect(x: body.minX, y: body.maxY - body.height * 0.30, width: body.width, height: body.height * 0.30).fill()
    NSGraphicsContext.current?.cgContext.resetClip()
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: side * 0.34, weight: .heavy),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
    ]
    let label = NSAttributedString(string: "CP", attributes: attributes)
    let size = label.size()
    label.draw(at: NSPoint(x: body.midX - size.width / 2, y: body.minY + body.height * 0.14))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("CPRemote-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }
for (name, pixels) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
                       ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
                       ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    try png(pixels: pixels).write(to: iconset.appendingPathComponent("\(name).png"))
}
let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}

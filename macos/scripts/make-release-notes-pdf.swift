// Renders RELEASE_NOTES.md as a PDF, for the disk image.
// Usage: swift make-release-notes-pdf.swift <notes.md> <output.pdf> <version>
//
// The notes use a small subset of Markdown: "# " title, "## " one heading per
// version, "- " bullets, and plain paragraphs. The newest version must come
// first and must be the version being built, so a release cannot ship notes
// that leave its own changes out.

import AppKit
import CoreText

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("usage: make-release-notes-pdf.swift <notes.md> <output.pdf> <version>\n".utf8))
    exit(2)
}
let (inputPath, outputPath, version) = (arguments[1], arguments[2], arguments[3])
guard let text = try? String(contentsOfFile: inputPath, encoding: .utf8) else {
    FileHandle.standardError.write(Data("cannot read \(inputPath)\n".utf8))
    exit(1)
}
let lines = text.components(separatedBy: "\n")
let firstVersion = lines.first { $0.hasPrefix("## ") }?.dropFirst(3).split(separator: " ").first.map(String.init)
guard firstVersion == version else {
    FileHandle.standardError.write(Data("the newest entry of \(inputPath) is \(firstVersion ?? "missing"), not \(version): add this version's changes first\n".utf8))
    exit(1)
}

func paragraph(indent: CGFloat = 0, firstLine: CGFloat = 0, spacing: CGFloat) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.headIndent = indent
    style.firstLineHeadIndent = firstLine
    style.paragraphSpacing = spacing
    style.lineSpacing = 2
    return style
}

let body = NSMutableAttributedString()
func add(_ string: String, font: NSFont, style: NSParagraphStyle) {
    body.append(NSAttributedString(string: string + "\n", attributes: [
        .font: font, .paragraphStyle: style, .foregroundColor: NSColor.black,
    ]))
}
for line in lines {
    if line.hasPrefix("# ") {
        add(String(line.dropFirst(2)), font: .systemFont(ofSize: 24, weight: .bold), style: paragraph(spacing: 14))
    } else if line.hasPrefix("## ") {
        add(String(line.dropFirst(3)), font: .systemFont(ofSize: 15, weight: .bold), style: paragraph(spacing: 6))
    } else if line.hasPrefix("- ") {
        add("•\t" + line.dropFirst(2), font: .systemFont(ofSize: 11), style: {
            let style = NSMutableParagraphStyle()
            style.headIndent = 16
            style.firstLineHeadIndent = 0
            style.tabStops = [NSTextTab(textAlignment: .left, location: 16)]
            style.paragraphSpacing = 4
            style.lineSpacing = 2
            return style
        }())
    } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
        add(line, font: .systemFont(ofSize: 11), style: paragraph(spacing: 6))
    }
}

var mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)   // A4
let info = [kCGPDFContextTitle: "CP Remote release notes", kCGPDFContextAuthor: "CP Remote",
            kCGPDFContextSubject: "Release notes up to version \(version)"] as CFDictionary
guard let context = CGContext(URL(fileURLWithPath: outputPath) as CFURL, mediaBox: &mediaBox, info) else {
    FileHandle.standardError.write(Data("cannot create \(outputPath)\n".utf8))
    exit(1)
}
let framesetter = CTFramesetterCreateWithAttributedString(body)
let page = mediaBox.insetBy(dx: 56, dy: 64)
var start = 0
repeat {
    context.beginPDFPage(nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: start, length: 0),
                                         CGPath(rect: page, transform: nil), nil)
    CTFrameDraw(frame, context)
    context.endPDFPage()
    let shown = CTFrameGetVisibleStringRange(frame)
    guard shown.length > 0 else { break }
    start += shown.length
} while start < body.length
context.closePDF()

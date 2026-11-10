// Prints the text of a PDF. Usage: swift pdf-text.swift <file.pdf>
import PDFKit
guard CommandLine.arguments.count == 2, let document = PDFDocument(url: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    FileHandle.standardError.write(Data("usage: pdf-text.swift <file.pdf>\n".utf8))
    exit(2)
}
print(document.string ?? "")

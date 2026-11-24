import AppKit
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentAttachmentTests {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-attach-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePNGData(width: Int = 16, height: Int = 12) throws -> Data {
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func makeTIFFData(width: Int = 20, height: Int = 10) throws -> Data {
        let png = try makePNGData(width: width, height: height)
        let image = try #require(NSImage(data: png))
        return try #require(image.tiffRepresentation)
    }

    @Test
    func loader_loads_png_and_utf8_text_files() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let imageURL = dir.appendingPathComponent("diagram.png")
        let pngData = try makePNGData(width: 24, height: 18)
        try pngData.write(to: imageURL)

        let textURL = dir.appendingPathComponent("notes.md")
        let textContent = "# Heading\nSecond line\nThird line\n"
        try Data(textContent.utf8).write(to: textURL)

        let result = AgentAttachmentLoader.load(urls: [imageURL, textURL], existing: [])
        #expect(result.error == nil)
        #expect(result.attachments.count == 2)

        let imageAttachment = result.attachments[0]
        #expect(imageAttachment.kind == .image)
        #expect(imageAttachment.name == "diagram.png")
        #expect(imageAttachment.mimeType == "image/png")
        #expect(imageAttachment.decodedImageData == pngData)
        #expect(imageAttachment.path == imageURL.path(percentEncoded: false))

        let cachedImage = try #require(AgentImageCache.shared.image(for: imageAttachment))
        let pixels = AgentImageCache.shared.pixelSize(for: cachedImage)
        #expect(pixels.width == 24)
        #expect(pixels.height == 18)

        let textAttachment = result.attachments[1]
        #expect(textAttachment.kind == .text)
        #expect(textAttachment.name == "notes.md")
        #expect(textAttachment.text == textContent)
        #expect(textAttachment.lineCount == 3)
        #expect(textAttachment.textPreviewSnippet == "# Heading")
    }

    @Test
    func loader_normalizes_tiff_images_to_supported_mime_type() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tiffURL = dir.appendingPathComponent("capture.tiff")
        try makeTIFFData(width: 32, height: 24).write(to: tiffURL)

        let result = AgentAttachmentLoader.load(urls: [tiffURL], existing: [], mode: .imagesOnly)
        #expect(result.error == nil)
        let attachment = try #require(result.attachments.first)
        #expect(attachment.kind == .image)
        #expect(attachment.mimeType == "image/png" || attachment.mimeType == "image/jpeg")
        let decoded = try #require(AgentImageCache.shared.image(for: attachment))
        let pixels = AgentImageCache.shared.pixelSize(for: decoded)
        #expect(pixels.width == 32)
        #expect(pixels.height == 24)
    }

    @Test
    func loader_rejects_binary_files_directories_and_oversized_text() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binaryURL = dir.appendingPathComponent("archive.bin")
        try Data([0x50, 0x4B, 0x00, 0x04, 0xFF]).write(to: binaryURL)
        let binaryResult = AgentAttachmentLoader.load(urls: [binaryURL], existing: [], mode: .textOnly)
        #expect(binaryResult.attachments.isEmpty)
        #expect(binaryResult.error == .unsupportedFile(name: "archive.bin"))

        let subdir = dir.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let dirResult = AgentAttachmentLoader.load(urls: [subdir], existing: [])
        #expect(dirResult.attachments.isEmpty)
        #expect(dirResult.error == .unsupportedFile(name: "folder"))

        let largeTextURL = dir.appendingPathComponent("big.txt")
        try Data(repeating: 0x61, count: AgentAttachmentLimits.maxTextFileBytes + 1).write(to: largeTextURL)
        let largeResult = AgentAttachmentLoader.load(urls: [largeTextURL], existing: [], mode: .textOnly)
        #expect(largeResult.attachments.isEmpty)
        #expect(largeResult.error == .fileTooLarge(name: "big.txt"))
    }

    @Test
    func loader_enforces_attachment_count_limit() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let textURL = dir.appendingPathComponent("extra.txt")
        try Data("hello".utf8).write(to: textURL)

        let existing = (0 ..< AgentAttachmentLimits.maxCount).map { index in
            AgentAttachment(
                id: "existing-\(index)",
                kind: .text,
                name: "file-\(index).txt",
                mimeType: "text/plain",
                text: "ok",
                byteCount: 2
            )
        }
        let result = AgentAttachmentLoader.load(urls: [textURL], existing: existing)
        #expect(result.attachments.isEmpty)
        #expect(result.error == .tooManyAttachments(max: AgentAttachmentLimits.maxCount))
    }

    @Test
    func pasteboard_loader_handles_files_images_and_leaves_plain_text_alone() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        // 1. Plain text falls through to NSTextView.paste.
        pasteboard.clearContents()
        pasteboard.setString("just text", forType: .string)
        if case .handled = AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: []) {
            Issue.record("Plain text should not be intercepted as an attachment")
        }

        // 2. TIFF alongside plain text (e.g. rich-text/spreadsheet copy) falls through to text paste.
        let tiff = try makeTIFFData()
        pasteboard.clearContents()
        pasteboard.setString("cell value", forType: .string)
        pasteboard.setData(tiff, forType: .tiff)
        if case .handled = AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: []) {
            Issue.record("TIFF paired with plain text should prefer text paste")
        }

        // 3. Pure TIFF screenshot attaches as an image.
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        switch AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: []) {
        case .notHandled:
            Issue.record("Expected TIFF image paste to be handled")
        case let .handled(attachments, error):
            #expect(error == nil)
            #expect(attachments.count == 1)
            #expect(attachments[0].kind == .image)
        }

        // 4. Direct PNG image attaches as image/png.
        let png = try makePNGData()
        pasteboard.clearContents()
        pasteboard.setData(png, forType: .png)
        switch AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: []) {
        case .notHandled:
            Issue.record("Expected PNG paste to be handled")
        case let .handled(attachments, error):
            #expect(error == nil)
            #expect(attachments.count == 1)
            #expect(attachments[0].mimeType == "image/png")
        }

        // 5. Copied file URLs from Finder attach as file attachments.
        let fileURL = dir.appendingPathComponent("snippet.txt")
        try Data("hello file".utf8).write(to: fileURL)
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        switch AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: []) {
        case .notHandled:
            Issue.record("Expected Finder file URL paste to be handled")
        case let .handled(attachments, error):
            #expect(error == nil)
            #expect(attachments.count == 1)
            #expect(attachments[0].kind == .text)
            #expect(attachments[0].name == "snippet.txt")
            #expect(attachments[0].text == "hello file")
        }
    }
}

import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An image or text file attached to an Agent GUI draft or conversation message.
struct AgentAttachment: Codable, Identifiable, Equatable, Hashable {
    enum Kind: String, Codable, Equatable, Hashable {
        case image
        case text
    }

    let id: String
    let kind: Kind
    let name: String
    let mimeType: String
    var data: String?
    var text: String?
    var byteCount: Int?
    var path: String?

    var isImage: Bool { kind == .image }
    var isText: Bool { kind == .text }

    var resolvedByteCount: Int {
        if let byteCount, byteCount >= 0 { return byteCount }
        switch kind {
        case .text:
            return text?.utf8.count ?? 0
        case .image:
            guard let data else { return 0 }
            let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
            let padding = trimmed.hasSuffix("==") ? 2 : (trimmed.hasSuffix("=") ? 1 : 0)
            return max(0, (trimmed.count * 3) / 4 - padding)
        }
    }

    var formattedByteCount: String {
        ByteCountFormatter.string(fromByteCount: Int64(resolvedByteCount), countStyle: .file)
    }

    var lineCount: Int? {
        guard kind == .text, let text else { return nil }
        if text.isEmpty { return 0 }
        var count = 1
        for scalar in text.unicodeScalars where scalar == "\n" {
            count += 1
        }
        if text.hasSuffix("\n") { count -= 1 }
        return max(1, count)
    }

    var textPreviewSnippet: String? {
        guard kind == .text, let text else { return nil }
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                return String(trimmed.prefix(80))
            }
        }
        return nil
    }

    var decodedImageData: Data? {
        guard kind == .image, let data, !data.isEmpty else { return nil }
        return Data(base64Encoded: data, options: .ignoreUnknownCharacters)
    }
}

/// Size and count limits shared between the composer, loader, and socket protocol.
enum AgentAttachmentLimits {
    static let maxCount = 10
    static let maxTextFileBytes = 128 * 1024
    static let maxImageBytes = 5 * 1024 * 1024
    static let maxRawImageFileBytes = 50 * 1024 * 1024
    static let maxTotalBytes = 12 * 1024 * 1024
    static let maxImageDimension: CGFloat = 2048
}

/// Validation failure surfaced in the composer status line when attaching files or images.
enum AgentAttachmentError: Equatable {
    case tooManyAttachments(max: Int)
    case fileTooLarge(name: String)
    case totalSizeExceeded
    case unsupportedFile(name: String)
    case unreadableFile(name: String)

    var localizedMessage: String {
        switch self {
        case let .tooManyAttachments(max):
            String(localized: "You can attach up to \(max) files per message.")
        case let .fileTooLarge(name):
            String(localized: "\(name) exceeds the attachment size limit.")
        case .totalSizeExceeded:
            String(localized: "Attachments exceed the total size limit.")
        case let .unsupportedFile(name):
            String(localized: "\(name) is not a supported image or UTF-8 text file.")
        case let .unreadableFile(name):
            String(localized: "Could not read \(name).")
        }
    }
}

/// Loads and normalizes image and UTF-8 text attachments from files or the macOS pasteboard.
enum AgentAttachmentLoader {
    enum Mode {
        case any
        case imagesOnly
        case textOnly
    }

    enum PasteResult {
        case notHandled
        case handled(attachments: [AgentAttachment], error: AgentAttachmentError?)
    }

    private struct PasteboardImageCandidate {
        let type: NSPasteboard.PasteboardType
        let mime: String
        let ext: String
    }

    private static let jpegPasteboardType = NSPasteboard.PasteboardType(UTType.jpeg.identifier)
    private static let gifPasteboardType = NSPasteboard.PasteboardType(UTType.gif.identifier)
    private static let webpPasteboardType = NSPasteboard.PasteboardType(UTType.webP.identifier)
    private static let heicPasteboardType = NSPasteboard.PasteboardType(UTType.heic.identifier)

    private static let directPasteboardImageTypes: [PasteboardImageCandidate] = [
        PasteboardImageCandidate(type: .png, mime: "image/png", ext: "png"),
        PasteboardImageCandidate(type: jpegPasteboardType, mime: "image/jpeg", ext: "jpg"),
        PasteboardImageCandidate(type: gifPasteboardType, mime: "image/gif", ext: "gif"),
        PasteboardImageCandidate(type: webpPasteboardType, mime: "image/webp", ext: "webp"),
        PasteboardImageCandidate(type: heicPasteboardType, mime: "image/heic", ext: "heic"),
    ]

    static func load(
        urls: [URL],
        existing: [AgentAttachment],
        mode: Mode = .any
    ) -> (attachments: [AgentAttachment], error: AgentAttachmentError?) {
        var added: [AgentAttachment] = []
        var firstError: AgentAttachmentError?
        var totalCount = existing.count
        var totalBytes = existing.reduce(0) { $0 + $1.resolvedByteCount }

        for url in urls {
            guard totalCount < AgentAttachmentLimits.maxCount else {
                firstError = firstError ?? .tooManyAttachments(max: AgentAttachmentLimits.maxCount)
                break
            }
            let result = loadSingleFile(url: url, mode: mode, remainingTotalBytes: AgentAttachmentLimits.maxTotalBytes - totalBytes)
            switch result {
            case let .success(attachment):
                added.append(attachment)
                totalCount += 1
                totalBytes += attachment.resolvedByteCount
            case let .failure(error):
                firstError = firstError ?? error
            }
        }
        return (added, firstError)
    }

    static func loadFromPasteboard(
        _ pasteboard: NSPasteboard,
        existing: [AgentAttachment]
    ) -> PasteResult {
        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            let result = load(urls: fileURLs, existing: existing, mode: .any)
            return .handled(attachments: result.attachments, error: result.error)
        }

        for candidate in directPasteboardImageTypes {
            if let data = pasteboard.data(forType: candidate.type), !data.isEmpty {
                let name = nextPastedImageName(ext: candidate.ext, existing: existing)
                let result = loadImageData(
                    data,
                    suggestedName: name,
                    preferredMIMEType: candidate.mime,
                    path: nil,
                    existing: existing
                )
                return .handled(
                    attachments: result.attachment.map { [$0] } ?? [],
                    error: result.error
                )
            }
        }

        let plainText = pasteboard.string(forType: .string)
        if plainText?.isEmpty ?? true,
           let tiffData = pasteboard.data(forType: .tiff), !tiffData.isEmpty
        {
            let name = nextPastedImageName(ext: "png", existing: existing)
            let result = loadImageData(
                tiffData,
                suggestedName: name,
                preferredMIMEType: "image/tiff",
                path: nil,
                existing: existing
            )
            return .handled(
                attachments: result.attachment.map { [$0] } ?? [],
                error: result.error
            )
        }

        return .notHandled
    }

    static func loadImageData(
        _ rawData: Data,
        suggestedName: String?,
        preferredMIMEType: String?,
        path: String?,
        existing: [AgentAttachment]
    ) -> (attachment: AgentAttachment?, error: AgentAttachmentError?) {
        guard existing.count < AgentAttachmentLimits.maxCount else {
            return (nil, .tooManyAttachments(max: AgentAttachmentLimits.maxCount))
        }
        let totalBytes = existing.reduce(0) { $0 + $1.resolvedByteCount }
        let remaining = AgentAttachmentLimits.maxTotalBytes - totalBytes
        let displayName = sanitizedName(suggestedName, fallback: "image.png")
        let result = makeImageAttachment(
            rawData: rawData,
            name: displayName,
            preferredMIMEType: preferredMIMEType,
            path: path,
            remainingTotalBytes: remaining
        )
        switch result {
        case let .success(attachment): return (attachment, nil)
        case let .failure(error): return (nil, error)
        }
    }

    static func loadImage(
        _ image: NSImage,
        suggestedName: String?,
        existing: [AgentAttachment]
    ) -> (attachment: AgentAttachment?, error: AgentAttachmentError?) {
        guard let tiff = image.tiffRepresentation else {
            return (nil, .unreadableFile(name: sanitizedName(suggestedName, fallback: "image.png")))
        }
        return loadImageData(
            tiff,
            suggestedName: suggestedName ?? nextPastedImageName(ext: "png", existing: existing),
            preferredMIMEType: "image/tiff",
            path: nil,
            existing: existing
        )
    }

    static func nextPastedImageName(ext: String, existing: [AgentAttachment]) -> String {
        let existingNames = Set(existing.map(\.name))
        var index = 1
        while true {
            let candidate = index == 1 ? "pasted-image.\(ext)" : "pasted-image-\(index).\(ext)"
            if !existingNames.contains(candidate) { return candidate }
            index += 1
        }
    }

    // MARK: - Private helpers

    private enum LoadResult {
        case success(AgentAttachment)
        case failure(AgentAttachmentError)
    }

    private static func loadSingleFile(url: URL, mode: Mode, remainingTotalBytes: Int) -> LoadResult {
        let name = sanitizedName(url.lastPathComponent, fallback: "attachment")
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentTypeKey])
        if values?.isDirectory == true {
            return .failure(.unsupportedFile(name: name))
        }

        let contentType = values?.contentType ?? UTType(filenameExtension: url.pathExtension)
        let isImageByType = contentType?.conforms(to: .image) == true

        if mode == .imagesOnly || isImageByType {
            if let fileSize = values?.fileSize, fileSize > AgentAttachmentLimits.maxRawImageFileBytes {
                return .failure(.fileTooLarge(name: name))
            }
            guard let data = try? Data(contentsOf: url) else {
                return .failure(.unreadableFile(name: name))
            }
            return makeImageAttachment(
                rawData: data,
                name: name,
                preferredMIMEType: contentType?.preferredMIMEType,
                path: url.path(percentEncoded: false),
                remainingTotalBytes: remainingTotalBytes
            )
        }

        if let fileSize = values?.fileSize, fileSize > AgentAttachmentLimits.maxTextFileBytes {
            return .failure(.fileTooLarge(name: name))
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure(.unreadableFile(name: name))
        }

        // If the file has an unrecognized extension (or none) in .any mode, check if it is actually an image.
        if mode == .any, isDecodableImageData(data) {
            return makeImageAttachment(
                rawData: data,
                name: name,
                preferredMIMEType: nil,
                path: url.path(percentEncoded: false),
                remainingTotalBytes: remainingTotalBytes
            )
        }

        return makeTextAttachment(
            data: data,
            name: name,
            mimeType: resolveTextMIMEType(url: url, contentType: contentType),
            path: url.path(percentEncoded: false),
            remainingTotalBytes: remainingTotalBytes
        )
    }

    private static func makeTextAttachment(
        data: Data,
        name: String,
        mimeType: String,
        path: String?,
        remainingTotalBytes: Int
    ) -> LoadResult {
        guard data.count <= AgentAttachmentLimits.maxTextFileBytes else {
            return .failure(.fileTooLarge(name: name))
        }
        guard data.count <= remainingTotalBytes else {
            return .failure(.totalSizeExceeded)
        }
        guard !data.contains(0x00), let text = String(data: data, encoding: .utf8) else {
            return .failure(.unsupportedFile(name: name))
        }
        let attachment = AgentAttachment(
            id: UUID().uuidString,
            kind: .text,
            name: name,
            mimeType: mimeType,
            text: text,
            byteCount: data.count,
            path: path
        )
        return .success(attachment)
    }

    private static func makeImageAttachment(
        rawData: Data,
        name: String,
        preferredMIMEType: String?,
        path: String?,
        remainingTotalBytes: Int
    ) -> LoadResult {
        guard !rawData.isEmpty,
              let source = CGImageSourceCreateWithData(rawData as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else {
            return .failure(.unsupportedFile(name: name))
        }

        let detectedType = (CGImageSourceGetType(source) as String?).flatMap(UTType.init)
        let passthroughMIME = passthroughImageMIMEType(for: detectedType, fallback: preferredMIMEType)

        let finalData: Data
        let finalMIME: String

        if let passthroughMIME, rawData.count <= AgentAttachmentLimits.maxImageBytes {
            finalData = rawData
            finalMIME = passthroughMIME
        } else {
            guard let encoded = normalizeImage(from: source) else {
                return .failure(.unsupportedFile(name: name))
            }
            guard encoded.data.count <= AgentAttachmentLimits.maxImageBytes else {
                return .failure(.fileTooLarge(name: name))
            }
            finalData = encoded.data
            finalMIME = encoded.mimeType
        }

        guard finalData.count <= remainingTotalBytes else {
            return .failure(.totalSizeExceeded)
        }

        let attachment = AgentAttachment(
            id: UUID().uuidString,
            kind: .image,
            name: name,
            mimeType: finalMIME,
            data: finalData.base64EncodedString(),
            byteCount: finalData.count,
            path: path
        )
        return .success(attachment)
    }

    private static func passthroughImageMIMEType(for type: UTType?, fallback: String?) -> String? {
        if let type {
            if type.conforms(to: .png) { return "image/png" }
            if type.conforms(to: .jpeg) { return "image/jpeg" }
            if type.conforms(to: .gif) { return "image/gif" }
            if type.conforms(to: .webP) { return "image/webp" }
            return nil
        }
        switch fallback?.lowercased() {
        case "image/png",
             "image/jpeg",
             "image/gif",
             "image/webp":
            return fallback?.lowercased()
        default:
            return nil
        }
    }

    private static func isDecodableImageData(_ data: Data) -> Bool {
        guard data.count >= 12,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let utType = UTType(typeID)
        else { return false }
        return utType.conforms(to: .image)
    }

    private static func normalizeImage(from source: CGImageSource) -> (data: Data, mimeType: String)? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(AgentAttachmentLimits.maxImageDimension),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            ?? CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        if let pngData = bitmap.representation(using: .png, properties: [:]),
           pngData.count <= min(AgentAttachmentLimits.maxImageBytes, 2 * 1024 * 1024)
        {
            return (pngData, "image/png")
        }
        for quality in [0.85, 0.72, 0.55] {
            if let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: quality]),
               jpegData.count <= AgentAttachmentLimits.maxImageBytes
            {
                return (jpegData, "image/jpeg")
            }
        }
        if let pngData = bitmap.representation(using: .png, properties: [:]),
           pngData.count <= AgentAttachmentLimits.maxImageBytes
        {
            return (pngData, "image/png")
        }
        return nil
    }

    private static func resolveTextMIMEType(url: URL, contentType: UTType?) -> String {
        if let mime = contentType?.preferredMIMEType, !mime.isEmpty {
            return mime
        }
        switch url.pathExtension.lowercased() {
        case "md",
             "markdown": return "text/markdown"
        case "json": return "application/json"
        case "yaml",
             "yml": return "text/yaml"
        case "csv": return "text/csv"
        case "xml": return "application/xml"
        case "html",
             "htm": return "text/html"
        default: return "text/plain"
        }
    }

    private static func sanitizedName(_ raw: String?, fallback: String) -> String {
        let cleaned = (raw ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return cleaned.isEmpty ? fallback : String(cleaned.prefix(128))
    }
}

/// Caches decoded `NSImage` instances for attachments so SwiftUI redraws and streaming do not re-decode base64.
@MainActor
final class AgentImageCache {
    static let shared = AgentImageCache()

    private let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()

    func image(for attachment: AgentAttachment) -> NSImage? {
        guard attachment.isImage, let base64 = attachment.data, !base64.isEmpty else { return nil }
        let key = "\(attachment.id):\(base64.count)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let decoded = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
              let image = NSImage(data: decoded)
        else { return nil }
        cache.setObject(image, forKey: key, cost: decoded.count)
        return image
    }

    func pixelSize(for image: NSImage) -> (width: Int, height: Int) {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return (rep.pixelsWide, rep.pixelsHigh)
        }
        return (Int(image.size.width.rounded()), Int(image.size.height.rounded()))
    }
}

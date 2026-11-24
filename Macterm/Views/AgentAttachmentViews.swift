import AppKit
import SwiftUI

/// Identifies an attachment preview session scoped to one message or the composer draft.
struct AgentAttachmentPreviewContext: Identifiable {
    let id = UUID()
    let attachments: [AgentAttachment]
    var selectedID: String
}

/// Horizontal strip of pending image thumbnails and text file chips inside the composer.
struct AgentComposerAttachmentsBar: View {
    let attachments: [AgentAttachment]
    let isDisabled: Bool
    let appearance: AgentAppearance
    let onPreview: (AgentAttachment) -> Void
    let onRemove: (AgentAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    if attachment.isImage {
                        imageTile(attachment)
                    } else {
                        textChip(attachment)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
        }
    }

    private func imageTile(_ attachment: AgentAttachment) -> some View {
        let image = AgentImageCache.shared.image(for: attachment)
        return ZStack(alignment: .topTrailing) {
            Button {
                onPreview(attachment)
            } label: {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(MactermTheme.fgMuted)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(MactermTheme.bg)
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(MactermTheme.border)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .agentPointingHandCursor()
            .help(Text(verbatim: "\(attachment.name) (\(attachment.formattedByteCount))"))
            .accessibilityLabel(Text("Preview image \(attachment.name)"))

            removeButton(for: attachment)
                .padding(3)
        }
    }

    private func textChip(_ attachment: AgentAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                onPreview(attachment)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(appearance.calloutFont())
                        .foregroundStyle(MactermTheme.accent)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: attachment.name)
                            .font(appearance.captionFont(weight: .medium))
                            .foregroundStyle(MactermTheme.fg)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(verbatim: textMetadata(attachment))
                            .font(appearance.captionFont())
                            .foregroundStyle(MactermTheme.fgMuted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 14)
                }
                .padding(.horizontal, 10)
                .frame(minWidth: 136, maxWidth: 220, minHeight: 64, maxHeight: 64, alignment: .leading)
                .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(MactermTheme.border)
                        .allowsHitTesting(false)
                }
            }
            .buttonStyle(.plain)
            .agentPointingHandCursor()
            .help(Text(verbatim: "\(attachment.name) (\(attachment.formattedByteCount))"))
            .accessibilityLabel(Text("Preview text file \(attachment.name)"))

            removeButton(for: attachment)
                .padding(4)
        }
    }

    private func removeButton(for attachment: AgentAttachment) -> some View {
        Button {
            onRemove(attachment)
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.palette)
                .foregroundStyle(MactermTheme.fg, MactermTheme.bg.opacity(0.9))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .agentPointingHandCursor(!isDisabled)
        .help(Text("Remove Attachment"))
        .accessibilityLabel(Text("Remove \(attachment.name)"))
    }

    private func textMetadata(_ attachment: AgentAttachment) -> String {
        if let lines = attachment.lineCount {
            let lineLabel = String(localized: "\(lines) lines")
            return "\(lineLabel) · \(attachment.formattedByteCount)"
        }
        return attachment.formattedByteCount
    }
}

/// Renders image thumbnails and clickable text file chips inside a conversation message.
struct AgentMessageAttachmentsView: View {
    let attachments: [AgentAttachment]
    let alignment: HorizontalAlignment
    let maxWidth: CGFloat
    let appearance: AgentAppearance
    let onPreview: (AgentAttachment) -> Void

    private var images: [AgentAttachment] {
        attachments.filter(\.isImage)
    }

    private var textFiles: [AgentAttachment] {
        attachments.filter(\.isText)
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            if !images.isEmpty {
                imageGrid
            }
            if !textFiles.isEmpty {
                textFileList
            }
        }
    }

    @ViewBuilder
    private var imageGrid: some View {
        if images.count == 1, let single = images.first {
            singleImageThumbnail(single)
        } else {
            let columns = max(2, min(images.count, Int(max(1, maxWidth) / 128)))
            let tileSize = min(136, max(88, floor((maxWidth - CGFloat(columns - 1) * 8) / CGFloat(columns))))
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(tileSize), spacing: 8), count: columns),
                alignment: alignment,
                spacing: 8
            ) {
                ForEach(images) { attachment in
                    multiImageThumbnail(attachment, size: tileSize)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func singleImageThumbnail(_ attachment: AgentAttachment) -> some View {
        let image = AgentImageCache.shared.image(for: attachment)
        let box = singleImageBoxSize(for: image)
        return Button {
            onPreview(attachment)
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    imageFallback(name: attachment.name)
                }
            }
            .frame(width: box.width, height: box.height)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(MactermTheme.border)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .agentPointingHandCursor()
        .help(Text(verbatim: "\(attachment.name) (\(attachment.formattedByteCount))"))
        .accessibilityLabel(Text("Preview image \(attachment.name)"))
    }

    private func multiImageThumbnail(_ attachment: AgentAttachment, size: CGFloat) -> some View {
        let image = AgentImageCache.shared.image(for: attachment)
        return Button {
            onPreview(attachment)
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    imageFallback(name: attachment.name)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(MactermTheme.border)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .agentPointingHandCursor()
        .help(Text(verbatim: "\(attachment.name) (\(attachment.formattedByteCount))"))
        .accessibilityLabel(Text("Preview image \(attachment.name)"))
    }

    private var textFileList: some View {
        VStack(alignment: alignment, spacing: 6) {
            ForEach(textFiles) { attachment in
                Button {
                    onPreview(attachment)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "doc.text")
                            .font(appearance.calloutFont())
                            .foregroundStyle(MactermTheme.accent)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: attachment.name)
                                .font(appearance.captionFont(weight: .medium))
                                .foregroundStyle(MactermTheme.fg)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let snippet = attachment.textPreviewSnippet {
                                Text(verbatim: snippet)
                                    .font(appearance.codeFont(size: appearance.captionCodeSize))
                                    .foregroundStyle(MactermTheme.fgMuted)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        Spacer(minLength: 4)
                        Text(verbatim: attachment.formattedByteCount)
                            .font(appearance.captionFont())
                            .foregroundStyle(MactermTheme.fgMuted)
                            .monospacedDigit()
                            .fixedSize()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: min(maxWidth, 320), alignment: .leading)
                    .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(MactermTheme.border)
                            .allowsHitTesting(false)
                    }
                }
                .buttonStyle(.plain)
                .agentPointingHandCursor()
                .help(Text(verbatim: "\(attachment.name) (\(attachment.formattedByteCount))"))
                .accessibilityLabel(Text("Preview text file \(attachment.name)"))
            }
        }
    }

    private func imageFallback(name: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "photo")
                .font(.title2)
                .foregroundStyle(MactermTheme.fgMuted)
            Text(verbatim: name)
                .font(appearance.captionFont())
                .foregroundStyle(MactermTheme.fgMuted)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(MactermTheme.surface)
    }

    private func singleImageBoxSize(for image: NSImage?) -> CGSize {
        let capWidth = min(max(120, maxWidth), 280)
        let capHeight: CGFloat = 200
        guard let image, image.size.width > 0, image.size.height > 0 else {
            return CGSize(width: min(capWidth, 160), height: 120)
        }
        let ratio = image.size.width / image.size.height
        var width = min(capWidth, max(80, image.size.width))
        var height = width / ratio
        if height > capHeight {
            height = capHeight
            width = height * ratio
        }
        width = max(72, min(capWidth, width))
        height = max(72, min(capHeight, height))
        return CGSize(width: width.rounded(), height: height.rounded())
    }
}

/// Modal preview sheet for inspecting attached images (with zoom and navigation) and text files.
struct AgentAttachmentPreviewSheet: View {
    let context: AgentAttachmentPreviewContext
    let appearance: AgentAppearance
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String
    @State private var zoomScale: CGFloat?

    init(context: AgentAttachmentPreviewContext, appearance: AgentAppearance) {
        self.context = context
        self.appearance = appearance
        _selectedID = State(initialValue: context.selectedID)
    }

    private var currentIndex: Int {
        context.attachments.firstIndex(where: { $0.id == selectedID }) ?? 0
    }

    private var currentAttachment: AgentAttachment? {
        guard !context.attachments.isEmpty else { return nil }
        return context.attachments[currentIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            content
        }
        .foregroundStyle(MactermTheme.fg)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
        .frame(minWidth: 540, idealWidth: 740, minHeight: 420, idealHeight: 580)
        .onChange(of: selectedID) { _, _ in
            zoomScale = nil
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let attachment = currentAttachment {
                Image(systemName: attachment.isImage ? "photo" : "doc.text")
                    .foregroundStyle(MactermTheme.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: attachment.name)
                        .font(appearance.calloutFont(weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: subtitle(for: attachment))
                        .font(appearance.captionFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if context.attachments.count > 1 {
                HStack(spacing: 4) {
                    Button {
                        stepSelection(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .agentPointingHandCursor()
                    .accessibilityLabel(Text("Previous Attachment"))

                    Text(verbatim: "\(currentIndex + 1) / \(context.attachments.count)")
                        .font(appearance.captionFont())
                        .monospacedDigit()
                        .foregroundStyle(MactermTheme.fgMuted)
                        .padding(.horizontal, 4)

                    Button {
                        stepSelection(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .agentPointingHandCursor()
                    .accessibilityLabel(Text("Next Attachment"))
                }
            }
            if let attachment = currentAttachment, attachment.isImage {
                zoomControls
            }
            if let attachment = currentAttachment {
                Button {
                    copyAttachment(attachment)
                } label: {
                    if attachment.isImage {
                        Label("Copy Image", systemImage: "doc.on.doc")
                    } else {
                        Label("Copy Text", systemImage: "doc.on.doc")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .agentPointingHandCursor()
            }
            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.cancelAction)
            .agentPointingHandCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button {
                adjustZoom(by: -0.25)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .agentPointingHandCursor()
            .accessibilityLabel(Text("Zoom Out"))

            Button {
                zoomScale = zoomScale == nil ? 1.0 : nil
            } label: {
                if let scale = zoomScale {
                    Text(verbatim: "\(Int((scale * 100).rounded()))%")
                        .monospacedDigit()
                } else {
                    Text("Fit")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .agentPointingHandCursor()
            .help(Text("Toggle Fit and Actual Size"))

            Button {
                adjustZoom(by: 0.25)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .agentPointingHandCursor()
            .accessibilityLabel(Text("Zoom In"))
        }
    }

    @ViewBuilder
    private var content: some View {
        if let attachment = currentAttachment {
            if attachment.isImage {
                imagePreview(attachment)
            } else {
                textPreview(attachment)
            }
        }
    }

    @ViewBuilder
    private func imagePreview(_ attachment: AgentAttachment) -> some View {
        if let image = AgentImageCache.shared.image(for: attachment) {
            if let scale = zoomScale {
                let pixels = AgentImageCache.shared.pixelSize(for: image)
                let width = max(1, CGFloat(pixels.width)) * scale
                let height = max(1, CGFloat(pixels.height)) * scale
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: width, height: height)
                        .padding(24)
                        .frame(minWidth: 540, minHeight: 360)
                        .onTapGesture(count: 2) {
                            zoomScale = nil
                        }
                }
                .background(MactermTheme.bg)
            } else {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(MactermTheme.bg)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        zoomScale = 1.0
                    }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.largeTitle)
                    .foregroundStyle(MactermTheme.fgMuted)
                Text("Could not render image preview.")
                    .font(appearance.calloutFont())
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MactermTheme.bg)
        }
    }

    private func textPreview(_ attachment: AgentAttachment) -> some View {
        ScrollView {
            Text(verbatim: attachment.text ?? "")
                .font(appearance.codeFont())
                .lineSpacing(max(1, appearance.lineSpacingPoints * 0.75))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .background(MactermTheme.bg)
    }

    private func subtitle(for attachment: AgentAttachment) -> String {
        if attachment.isImage, let image = AgentImageCache.shared.image(for: attachment) {
            let size = AgentImageCache.shared.pixelSize(for: image)
            return "\(size.width) × \(size.height) · \(attachment.formattedByteCount)"
        }
        if let lines = attachment.lineCount {
            let lineLabel = String(localized: "\(lines) lines")
            return "\(lineLabel) · \(attachment.formattedByteCount)"
        }
        return attachment.formattedByteCount
    }

    private func stepSelection(by delta: Int) {
        guard context.attachments.count > 1 else { return }
        let count = context.attachments.count
        let nextIndex = (currentIndex + delta + count) % count
        selectedID = context.attachments[nextIndex].id
    }

    private func adjustZoom(by delta: CGFloat) {
        let current = zoomScale ?? 1.0
        zoomScale = min(4.0, max(0.25, current + delta))
    }

    private func copyAttachment(_ attachment: AgentAttachment) {
        if attachment.isImage, let image = AgentImageCache.shared.image(for: attachment) {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
        } else if let text = attachment.text {
            copyAgentText(text)
        }
    }
}

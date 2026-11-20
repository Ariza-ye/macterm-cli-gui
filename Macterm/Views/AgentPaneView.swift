import AppKit
import Carbon.HIToolbox
import SwiftUI

private let agentColumnWidth: CGFloat = 680

struct AgentPaneView: View {
    @Bindable var bridge: PiBridge
    let surface: PaneSurface
    let focus: AgentPaneFocus
    let showTerminal: () -> Void

    var body: some View {
        GeometryReader { pane in
            VStack(spacing: 0) {
                header
                Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
                AgentTranscript(rows: bridge.rows)
                composer(maxEditorHeight: min(240, max(36, pane.size.height * 0.4)))
            }
        }
        .foregroundStyle(MactermTheme.fg)
        .tint(MactermTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.body.weight(.medium))
                .foregroundStyle(MactermTheme.accent)
                .accessibilityHidden(true)
            Text(verbatim: "Pi").font(.headline)
            Spacer(minLength: 4)
            if bridge.isWaiting {
                Text("Continue in Terminal")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.warning)
                    .lineLimit(1)
            } else if bridge.isBusy {
                ProgressView().controlSize(.mini).accessibilityLabel(Text("Pi is working"))
            }
            Button(action: showTerminal) {
                Label("Show Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func composer(maxEditorHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                if bridge.draft.isEmpty {
                    Text("Ask Pi a question…")
                        .foregroundStyle(MactermTheme.fgMuted)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                AgentComposer(
                    text: $bridge.draft,
                    focus: focus,
                    isEditable: !surface.isReadOnly && bridge.pendingSend == nil,
                    maxHeight: maxEditorHeight,
                    submit: { bridge.submit(from: surface) }
                )
            }
            HStack(spacing: 8) {
                composerStatus
                    .font(.caption)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if bridge.isBusy {
                    Button {
                        bridge.stop(from: surface)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(surface.isReadOnly || !bridge.isReady)
                } else {
                    Button {
                        bridge.submit(from: surface)
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(MactermTheme.border).allowsHitTesting(false)
        }
        .frame(maxWidth: agentColumnWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var composerStatus: some View {
        if surface.isReadOnly {
            Label("Read-Only", systemImage: "lock").foregroundStyle(MactermTheme.fgMuted)
        } else if bridge.pendingSend != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            }
            .foregroundStyle(MactermTheme.fgMuted)
        } else if bridge.sendRejected {
            Text("Pi did not confirm the message.").foregroundStyle(MactermTheme.failure)
        } else if bridge.draft.utf8.count > 128 * 1024 {
            Text("The message is too long.").foregroundStyle(MactermTheme.failure)
        } else if bridge.isBusy {
            Text("Pi is working").foregroundStyle(MactermTheme.fgMuted)
        }
    }

    private var canSubmit: Bool {
        !surface.isReadOnly && bridge.isReady && !bridge.isBusy && !bridge.isWaiting && bridge.pendingSend == nil
            && !bridge.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bridge.draft.utf8.count <= 128 * 1024
    }
}

private struct AgentTranscript: View {
    let rows: [PiBridge.Row]
    var body: some View {
        GeometryReader { viewport in
            let columnWidth = max(0, min(agentColumnWidth, viewport.size.width - 32))
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start a conversation").font(.title2.weight(.semibold))
                    Text("Ask a question or describe a task.").foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AgentTranscriptScroll(viewportHeight: viewport.size.height) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(entries) { entry in
                            switch entry {
                            case let .message(row):
                                message(row, width: columnWidth)
                            case let .tools(rows):
                                AgentToolGroup(rows: rows)
                            }
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(width: columnWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private enum Entry: Identifiable {
        case message(PiBridge.Row)
        case tools([PiBridge.Row])

        var id: String {
            switch self {
            case let .message(row): row.id
            case let .tools(rows): rows[0].id
            }
        }
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        var tools: [PiBridge.Row] = []
        for row in rows {
            if row.kind == .tool {
                tools.append(row)
            } else {
                if !tools.isEmpty {
                    entries.append(.tools(tools))
                    tools = []
                }
                entries.append(.message(row))
            }
        }
        if !tools.isEmpty { entries.append(.tools(tools)) }
        return entries
    }

    @ViewBuilder
    private func message(_ row: PiBridge.Row, width: CGFloat) -> some View {
        if row.kind == .user {
            VStack(alignment: .trailing, spacing: 4) {
                Text("You").font(.caption.weight(.medium)).foregroundStyle(MactermTheme.fgMuted)
                Text(verbatim: row.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MactermTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).strokeBorder(MactermTheme.border).allowsHitTesting(false)
                    }
            }
            .frame(maxWidth: width * 0.84, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu { Button("Copy Message") { copyAgentText(row.text) } }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(MactermTheme.accent).accessibilityHidden(true)
                    Text(verbatim: "Pi").foregroundStyle(MactermTheme.fgMuted)
                }
                .font(.caption.weight(.semibold))
                AgentMarkdownView(source: row.text)
            }
            .contextMenu { Button("Copy Message") { copyAgentText(row.text) } }
        }
    }
}

private struct AgentTranscriptScroll<Content: View>: View {
    let viewportHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var followsBottom = true
    @State private var contentFrame = CGRect.zero

    private static var end: String { "agent-transcript-end" }

    var body: some View {
        ScrollViewReader { reader in
            let jump = { reader.scrollTo(Self.end, anchor: .bottom) }
            ScrollView {
                VStack(spacing: 0) {
                    content()
                    Color.clear.frame(height: 1).id(Self.end).accessibilityHidden(true)
                }
                .onGeometryChange(for: CGRect.self) { geometry in
                    geometry.frame(in: .scrollView(axis: .vertical))
                } action: { frame in
                    let previous = contentFrame
                    contentFrame = frame
                    if frame.height == previous.height {
                        followsBottom = frame.maxY <= viewportHeight + 24
                    } else if followsBottom {
                        jump()
                    }
                }
            }
            .overlay(alignment: .bottom) {
                if !followsBottom {
                    Button(action: jump) {
                        Label("Jump to Latest", systemImage: "arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .background(Color(nsColor: MactermTheme.nsConfiguredBg), in: RoundedRectangle(cornerRadius: 6))
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct AgentToolGroup: View {
    let rows: [PiBridge.Row]

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    tool(row)
                }
            }
            .padding(.top, 8)
            .padding(.leading, 8)
        } label: {
            HStack(spacing: 8) {
                Label("Tool Activity", systemImage: "wrench.and.screwdriver")
                    .fontWeight(.medium)
                Text(verbatim: rows.count.formatted())
                    .monospacedDigit()
                    .foregroundStyle(MactermTheme.fgMuted)
                Spacer(minLength: 0)
                if let running = rows.last(where: { $0.status == .running }) {
                    Text(verbatim: running.name ?? "")
                        .lineLimit(1)
                        .foregroundStyle(MactermTheme.fgMuted)
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Pi is working"))
                } else if rows.contains(where: { $0.status == .failed }) {
                    Label("Failed", systemImage: "exclamationmark.circle").foregroundStyle(MactermTheme.failure)
                } else {
                    Image(systemName: "checkmark").foregroundStyle(MactermTheme.fgMuted)
                        .accessibilityLabel(Text("Completed"))
                }
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tool(_ row: PiBridge.Row) -> some View {
        DisclosureGroup {
            Text(verbatim: row.text)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
        } label: {
            HStack(spacing: 8) {
                Text(verbatim: row.name ?? "").lineLimit(1)
                Spacer(minLength: 0)
                switch row.status {
                case .running:
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Pi is working"))
                case .failed:
                    Text("Failed").foregroundStyle(MactermTheme.failure)
                default:
                    Text("Completed").foregroundStyle(MactermTheme.fgMuted)
                }
            }
        }
        .font(.caption)
    }
}

@MainActor
final class AgentPaneFocus {
    weak var input: NSTextView?
    var onFocus: (() -> Void)?
}

/// A native multiline editor with an AppKit focus target for FocusRestoration.
private struct AgentComposer: NSViewRepresentable {
    @Binding var text: String
    let focus: AgentPaneFocus
    let isEditable: Bool
    let maxHeight: CGFloat
    let submit: () -> Void

    private static let inset = NSSize(width: 12, height: 8)

    final class InputView: NSTextView {
        weak var focus: AgentPaneFocus?
        var submit: (() -> Void)?

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            guard event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter,
                  !hasMarkedText(), modifiers.isEmpty
            else {
                super.keyDown(with: event)
                return
            }
            if !event.isARepeat { submit?() }
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            focus?.onFocus?()
            return true
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            if let input = notification.object as? NSTextView { text.wrappedValue = input.string }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = InputView.scrollableTextView()
        guard let input = scroll.documentView as? InputView else { return scroll }
        input.focus = focus
        focus.input = input
        input.delegate = context.coordinator
        input.setAccessibilityLabel(String(localized: "Message to Pi"))
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.font = .systemFont(ofSize: NSFont.systemFontSize)
        input.textContainerInset = Self.inset
        input.textContainer?.lineFragmentPadding = 0
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let input = scroll.documentView as? InputView else { return }
        input.isEditable = isEditable
        input.submit = submit
        input.textColor = MactermTheme.nsFg
        input.insertionPointColor = MactermTheme.nsFg
        if input.string != text, !input.hasMarkedText() { input.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView scroll: NSScrollView, context _: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, let input = scroll.documentView as? NSTextView,
              let font = input.font
        else { return nil }

        let storage = NSTextStorage(string: text, attributes: [.font: font])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(
            width: max(1, width - Self.inset.width * 2), height: .greatestFiniteMagnitude
        ))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(for: container)

        let height = max(layout.usedRect(for: container).maxY, layout.extraLineFragmentRect.maxY)
        return CGSize(width: width, height: min(maxHeight, max(36, ceil(height + Self.inset.height * 2))))
    }
}

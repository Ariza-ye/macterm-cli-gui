import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

struct AgentPaneView: View {
    @Bindable var bridge: AgentBridge
    let surface: PaneSurface
    let focus: AgentPaneFocus
    let showTerminal: () -> Void
    let closeAgent: () -> Void
    @State private var previewContext: AgentAttachmentPreviewContext?
    @State private var isGitDiffPresented = false
    @State private var isHistoryPresented = false
    @State private var historyInitialQuery = ""
    @State private var isDropTargeted = false

    private var appearanceSettings: AgentAppearanceSettings { .shared }

    var body: some View {
        let appearance = appearanceSettings.appearance
        GeometryReader { pane in
            VStack(spacing: 0) {
                header(appearance: appearance)
                Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
                AgentTranscript(
                    conversationID: bridge.conversation,
                    rows: bridge.displayRows,
                    agentName: bridge.provider.displayName,
                    isPendingSend: bridge.pendingSend != nil,
                    isBusy: bridge.isBusy,
                    isWaiting: bridge.isWaiting,
                    hasPendingPermission: !bridge.pendingPermissions.isEmpty,
                    appearance: appearance,
                    onPreviewAttachment: { row, attachment in
                        previewContext = AgentAttachmentPreviewContext(
                            attachments: row.resolvedAttachments,
                            selectedID: attachment.id
                        )
                    }
                )
                if let permission = bridge.pendingPermissions.first {
                    AgentPermissionCard(
                        request: permission,
                        remainingCount: bridge.pendingPermissions.count - 1,
                        isPending: bridge.pendingPermissionID == permission.id,
                        isDisabled: surface.isReadOnly || !bridge.isReady || bridge.isExiting || bridge.pendingPermissionID != nil,
                        isRejected: bridge.permissionRejected,
                        appearance: appearance,
                        onSelect: { optionID in
                            bridge.respondToPermission(permission.id, optionID: optionID, from: surface)
                        },
                        onCancel: {
                            bridge.respondToPermission(permission.id, optionID: nil, from: surface)
                        }
                    )
                    .frame(maxWidth: appearance.contentWidth.maxWidth ?? .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                }
                composer(
                    maxEditorHeight: min(240, max(appearance.composerMinHeight, pane.size.height * 0.4)),
                    appearance: appearance
                )
            }
        }
        .foregroundStyle(MactermTheme.fg)
        .tint(MactermTheme.accent)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
        .sheet(item: $previewContext) { context in
            AgentAttachmentPreviewSheet(context: context, appearance: appearance)
        }
        .sheet(
            isPresented: $isGitDiffPresented,
            onDismiss: {
                if let input = focus.input {
                    input.window?.makeFirstResponder(input)
                }
            },
            content: {
                AgentGitDiffSheet(
                    workingDirectory: resolvedWorkingDirectory,
                    appearance: appearance,
                    cliComplete: Self.makeGitDiffCLICompletion(for: bridge)
                )
            }
        )
    }

    private static func makeGitDiffCLICompletion(
        for bridge: AgentBridge
    ) -> AgentGitCommitMessageGenerator.CLICompletionHandler {
        { [weak bridge] instructions, prompt, maxTokens, onPartial in
            guard let bridge else { return nil }
            return await bridge.complete(
                instructions: instructions,
                prompt: prompt,
                maximumResponseTokens: maxTokens,
                onPartial: onPartial
            )
        }
    }

    private func header(appearance: AgentAppearance) -> some View {
        HStack(spacing: 8) {
            if let icon = bridge.provider.icon {
                Image(icon.rawValue)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 16, height: 16)
                    .foregroundStyle(icon.brandColor)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(.body.weight(.medium))
                    .foregroundStyle(MactermTheme.accent)
                    .accessibilityHidden(true)
            }
            Text(verbatim: bridge.provider.displayName).font(appearance.headlineFont)
            Spacer(minLength: 4)
            if !bridge.pendingPermissions.isEmpty {
                Text("Permission Required")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.warning)
                    .lineLimit(1)
            } else if bridge.isWaiting {
                Text("Continue in Terminal")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.warning)
                    .lineLimit(1)
            } else if bridge.isBusy {
                ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
            }
            Button {
                isGitDiffPresented = true
            } label: {
                Label("Git Diff", systemImage: "arrow.triangle.branch")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .pointingHandCursor()
            .help(Text("Review Git changes, commit, push, and pull"))
            if bridge.canResume {
                Button {
                    historyInitialQuery = ""
                    isHistoryPresented.toggle()
                } label: {
                    if bridge.pendingResumeSession != nil {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("History")
                        }
                    } else {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canStartAction)
                .fixedSize()
                .pointingHandCursor(canStartAction)
                .help(Text("Browse and resume previous conversations"))
                .popover(isPresented: $isHistoryPresented, arrowEdge: .bottom) {
                    AgentSessionHistoryPopover(
                        bridge: bridge,
                        surface: surface,
                        initialQuery: historyInitialQuery,
                        onSelect: { sessionID in
                            isHistoryPresented = false
                            if sessionID != bridge.conversation {
                                bridge.resumeSession(sessionID, from: surface)
                            }
                            if let input = focus.input {
                                input.window?.makeFirstResponder(input)
                            }
                        }
                    )
                }
            }
            Button {
                bridge.newConversation(from: surface)
                if let input = focus.input {
                    input.window?.makeFirstResponder(input)
                }
            } label: {
                if bridge.pendingNewConversation != nil {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("New Conversation")
                    }
                } else {
                    Label("New Conversation", systemImage: "square.and.pencil")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canStartAction)
            .fixedSize()
            .pointingHandCursor(canStartAction)
            .help(HotkeyRegistry.tooltip(AppCommand.agentNewConversation.title, for: .agentNewConversation))
            Button(action: showTerminal) {
                Label("Show Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .pointingHandCursor()
            .help(HotkeyRegistry.tooltip(AppCommand.agentShowTerminal.title, for: .agentShowTerminal))
            Button(action: closeAgent) {
                if bridge.isExiting {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "xmark")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!canExitAgent)
            .fixedSize()
            .pointingHandCursor(canExitAgent)
            .help(Text("Close Agent GUI and exit the agent CLI"))
            .accessibilityLabel(Text("Close Agent"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func composer(maxEditorHeight: CGFloat, appearance: AgentAppearance) -> some View {
        VStack(spacing: 4) {
            if !bridge.draftAttachments.isEmpty {
                AgentComposerAttachmentsBar(
                    attachments: bridge.draftAttachments,
                    isDisabled: surface.isReadOnly || bridge.isExiting || bridge.pendingSend != nil,
                    appearance: appearance,
                    onPreview: { attachment in
                        previewContext = AgentAttachmentPreviewContext(
                            attachments: bridge.draftAttachments,
                            selectedID: attachment.id
                        )
                    },
                    onRemove: { attachment in
                        bridge.removeDraftAttachment(id: attachment.id)
                    }
                )
            }
            AgentComposer(
                text: $bridge.draft,
                placeholder: String(localized: "Write a message…"),
                focus: focus,
                isEditable: !surface.isReadOnly && !bridge.isExiting,
                font: appearance.bodyNSFont(),
                minHeight: appearance.composerMinHeight,
                maxHeight: maxEditorHeight,
                submit: { submitDraft() },
                canPaste: { pasteboard in canPasteAttachment(from: pasteboard) },
                onPaste: { pasteboard in handlePaste(pasteboard) },
                onCycleMode: (bridge.modeOption?.options.count ?? 0) > 1
                    ? { bridge.cycleMode(from: surface) }
                    : nil
            )
            if hasComposerStatus {
                composerStatus
                    .font(appearance.captionFont())
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 6) {
                addAttachmentButton
                if hasComposerControls {
                    composerControls
                }
                Spacer(minLength: 4)
                if bridge.isBusy {
                    let canStop = !surface.isReadOnly && bridge.isReady && !bridge.isExiting
                    Button {
                        bridge.stop(from: surface)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!canStop)
                    .fixedSize()
                    .pointingHandCursor(canStop)
                } else {
                    Button {
                        submitDraft()
                    } label: {
                        Label("Send", systemImage: "arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                    .fixedSize()
                    .pointingHandCursor(canSubmit)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isDropTargeted ? MactermTheme.accent : MactermTheme.border, lineWidth: isDropTargeted ? 1.5 : 1)
                .allowsHitTesting(false)
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .frame(maxWidth: appearance.contentWidth.maxWidth ?? .infinity)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private var addAttachmentButton: some View {
        let canAttach = !surface.isReadOnly && !bridge.isExiting && bridge.pendingSend == nil
        return Menu {
            Button {
                pickAttachments(mode: .imagesOnly)
            } label: {
                Label("Add Image…", systemImage: "photo")
            }
            Button {
                pickAttachments(mode: .textOnly)
            } label: {
                Label("Add Text File…", systemImage: "doc.text")
            }
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .foregroundStyle(MactermTheme.fg)
                .frame(width: 24, height: 22)
                .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(MactermTheme.border)
                        .allowsHitTesting(false)
                }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!canAttach)
        .opacity(canAttach ? 1 : 0.6)
        .pointingHandCursor(canAttach)
        .help(Text("Add Image or Text File"))
        .accessibilityLabel(Text("Add Image or Text File"))
    }

    private var hasComposerControls: Bool {
        bridge.modeOption != nil || bridge.modelOption != nil || !bridge.speedOptions.isEmpty
    }

    private var hasComposerStatus: Bool {
        surface.isReadOnly || bridge.sendRejected || bridge.configRejected
            || bridge.newConversationRejected || bridge.resumeSessionRejected
            || bridge.attachmentError != nil || bridge.isDraftTooLong
    }

    private var canStartAction: Bool {
        !surface.isReadOnly && bridge.isReady && !bridge.isExiting && !bridge.isBusy && !bridge.isWaiting
            && bridge.pendingSend == nil && bridge.pendingConfigID == nil
            && bridge.pendingNewConversation == nil && bridge.pendingResumeSession == nil
    }

    private var canExitAgent: Bool {
        !surface.isReadOnly && bridge.isReady && !bridge.isExiting
    }

    @ViewBuilder
    private var composerControls: some View {
        if let mode = bridge.modeOption {
            AgentConfigControl(
                option: mode,
                isPending: bridge.pendingConfigID == mode.id,
                isDisabled: !canStartAction || mode.options.count <= 1,
                allowsTruncation: false,
                onSelect: { bridge.setConfig(mode.id, value: $0, from: surface) }
            )
        }
        if let model = bridge.modelOption {
            AgentConfigControl(
                option: model,
                isPending: bridge.pendingConfigID == model.id,
                isDisabled: !canStartAction || model.options.count <= 1,
                allowsTruncation: true,
                onSelect: { bridge.setConfig(model.id, value: $0, from: surface) }
            )
            .layoutPriority(-1)
        }
        ForEach(bridge.speedOptions) { speed in
            AgentConfigControl(
                option: speed,
                isPending: bridge.pendingConfigID == speed.id,
                isDisabled: !canStartAction || speed.options.count <= 1,
                allowsTruncation: false,
                onSelect: { bridge.setConfig(speed.id, value: $0, from: surface) }
            )
        }
    }

    @ViewBuilder
    private var composerStatus: some View {
        if surface.isReadOnly {
            Label("Read-Only", systemImage: "lock").foregroundStyle(MactermTheme.fgMuted)
        } else if let attachmentError = bridge.attachmentError {
            Text(verbatim: attachmentError.localizedMessage).foregroundStyle(MactermTheme.failure)
        } else if bridge.sendRejected {
            Text("The agent did not confirm the message.").foregroundStyle(MactermTheme.failure)
        } else if bridge.configRejected {
            Text("The agent did not apply the setting.").foregroundStyle(MactermTheme.failure)
        } else if bridge.newConversationRejected {
            Text("The agent did not start a new conversation.").foregroundStyle(MactermTheme.failure)
        } else if bridge.resumeSessionRejected {
            Text("The agent did not resume the conversation.").foregroundStyle(MactermTheme.failure)
        } else if bridge.isDraftTooLong {
            Text("The message is too long.").foregroundStyle(MactermTheme.failure)
        }
    }

    private func submitDraft() {
        if bridge.canResume, bridge.draftAttachments.isEmpty {
            let trimmed = bridge.draft.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "/resume" || trimmed.hasPrefix("/resume ") {
                guard canStartAction else { return }
                let query = String(trimmed.dropFirst("/resume".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                bridge.draft = ""
                historyInitialQuery = query
                isHistoryPresented = true
                return
            }
        }
        bridge.submit(from: surface)
    }

    private var resolvedWorkingDirectory: String? {
        if let live = surface.pane.liveLocalWorkingDirectory(), !live.isEmpty {
            return live
        }
        if case let .local(path)? = ProjectPath.parse(surface.pane.projectPath) {
            return ProjectPath.canonicalLocal(path)
        }
        return nil
    }

    private var canSubmit: Bool {
        canStartAction && bridge.hasDraftContent && !bridge.isDraftTooLong
    }

    private func pickAttachments(mode: AgentAttachmentLoader.Mode) {
        guard !surface.isReadOnly, !bridge.isExiting, bridge.pendingSend == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        switch mode {
        case .imagesOnly:
            panel.allowedContentTypes = [.image]
            panel.message = String(localized: "Choose one or more images to attach.")
        case .textOnly:
            panel.allowedContentTypes = []
            panel.message = String(localized: "Choose one or more text files to attach.")
        case .any:
            panel.allowedContentTypes = []
        }

        let applySelection: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            let result = AgentAttachmentLoader.load(
                urls: panel.urls,
                existing: bridge.draftAttachments,
                mode: mode
            )
            bridge.appendDraftAttachments(result.attachments, error: result.error)
            if let input = focus.input {
                input.window?.makeFirstResponder(input)
            }
        }

        if let window = focus.input?.window ?? NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: applySelection)
        } else {
            applySelection(panel.runModal())
        }
    }

    private func canPasteAttachment(from pasteboard: NSPasteboard) -> Bool {
        !surface.isReadOnly && !bridge.isExiting && bridge.pendingSend == nil
            && AgentAttachmentLoader.canLoadFromPasteboard(pasteboard)
    }

    private func handlePaste(_ pasteboard: NSPasteboard) -> Bool {
        guard !surface.isReadOnly, !bridge.isExiting, bridge.pendingSend == nil else { return false }
        switch AgentAttachmentLoader.loadFromPasteboard(pasteboard, existing: bridge.draftAttachments) {
        case .notHandled:
            return false
        case let .handled(attachments, error):
            bridge.appendDraftAttachments(attachments, error: error)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard !surface.isReadOnly, !bridge.isExiting, bridge.pendingSend == nil else { return false }
        let matching = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
                || $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !matching.isEmpty else { return false }

        for provider in matching {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    let resolvedURL: URL? = if let url = item as? URL {
                        url
                    } else if let data = item as? Data {
                        URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        nil
                    }
                    guard let resolvedURL else { return }
                    Task { @MainActor in
                        let result = AgentAttachmentLoader.load(
                            urls: [resolvedURL],
                            existing: bridge.draftAttachments,
                            mode: .any
                        )
                        bridge.appendDraftAttachments(result.attachments, error: result.error)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                let suggestedName = provider.suggestedName
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    guard let data else { return }
                    Task { @MainActor in
                        let name = suggestedName ?? AgentAttachmentLoader.nextPastedImageName(
                            ext: "png",
                            existing: bridge.draftAttachments
                        )
                        let result = AgentAttachmentLoader.loadImageData(
                            data,
                            suggestedName: name,
                            preferredMIMEType: nil,
                            path: nil,
                            existing: bridge.draftAttachments
                        )
                        bridge.appendDraftAttachments(
                            result.attachment.map { [$0] } ?? [],
                            error: result.error
                        )
                    }
                }
            }
        }
        return true
    }
}

private struct AgentSessionHistoryPopover: View {
    @Bindable var bridge: AgentBridge
    let surface: PaneSurface
    let initialQuery: String
    let onSelect: (String) -> Void

    @State private var query = ""
    @State private var hoveredID: String?
    @FocusState private var searchFocused: Bool

    private static let isoWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoStandard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var filteredSessions: [AgentBridge.SessionSummary] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return bridge.sessions }
        return bridge.sessions.filter { session in
            let haystack = "\(session.title) \(session.id)".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .accessibilityHidden(true)
                TextField("Search conversations", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onSubmit {
                        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let first = filteredSessions.first
                        else { return }
                        onSelect(first.id)
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MactermTheme.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel(Text("Clear"))
                }
                Button {
                    bridge.loadSessions(from: surface)
                } label: {
                    if bridge.isLoadingSessions {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(MactermTheme.fgMuted)
                    }
                }
                .buttonStyle(.plain)
                .disabled(bridge.isLoadingSessions)
                .pointingHandCursor(!bridge.isLoadingSessions)
                .help(Text("Refresh conversations"))
                .accessibilityLabel(Text("Refresh conversations"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            content
        }
        .frame(width: 380, height: 400)
        .foregroundStyle(MactermTheme.fg)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
        .onAppear {
            query = initialQuery
            searchFocused = true
            bridge.loadSessions(from: surface)
        }
    }

    @ViewBuilder
    private var content: some View {
        let items = filteredSessions
        if bridge.isLoadingSessions, bridge.sessions.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading conversations…")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if bridge.sessionsLoadFailed, bridge.sessions.isEmpty {
            VStack(spacing: 10) {
                Text("Could not load conversations.")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
                Button("Retry") {
                    bridge.loadSessions(from: surface)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .pointingHandCursor()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            Text(bridge.sessions.isEmpty ? "No previous conversations" : "No matching conversations")
                .font(.callout)
                .foregroundStyle(MactermTheme.fgMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(items) { session in
                        sessionRow(session)
                    }
                    if bridge.nextSessionsCursor != nil {
                        HStack {
                            Spacer()
                            Button {
                                bridge.loadMoreSessions(from: surface)
                            } label: {
                                if bridge.isLoadingMoreSessions {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.mini)
                                        Text("Loading…")
                                    }
                                } else {
                                    Text("Load More")
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(bridge.isLoadingMoreSessions)
                            .pointingHandCursor(!bridge.isLoadingMoreSessions)
                            Spacer()
                        }
                        .padding(.vertical, 8)
                    }
                }
                .padding(6)
            }
        }
    }

    private func sessionRow(_ session: AgentBridge.SessionSummary) -> some View {
        let isCurrent = session.id == bridge.conversation
        let isHovered = hoveredID == session.id
        return Button {
            onSelect(session.id)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MactermTheme.accent)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12)
                    .padding(.top, 3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: session.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    HStack(spacing: 6) {
                        if let timeText = Self.formattedRelativeTime(session.updatedAt) {
                            Text(verbatim: timeText)
                        }
                        if let count = session.messageCount, count > 0 {
                            Text("\(count) messages")
                        }
                        if isCurrent {
                            Text("Current")
                                .foregroundStyle(MactermTheme.accent)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? MactermTheme.accentSoft : (isCurrent ? MactermTheme.surface : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            if hovering {
                hoveredID = session.id
            } else if hoveredID == session.id {
                hoveredID = nil
            }
        }
        .help(Text(verbatim: session.id))
    }

    private static func formattedRelativeTime(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let date = isoWithFractional.date(from: raw) ?? isoStandard.date(from: raw)
        guard let date else { return nil }
        return relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct AgentConfigControl: View {
    let option: AgentBridge.ConfigOption
    let isPending: Bool
    let isDisabled: Bool
    let allowsTruncation: Bool
    let onSelect: (String) -> Void
    @State private var showingPopover = false

    private static let searchableThreshold = 20

    var body: some View {
        Group {
            if option.options.count > Self.searchableThreshold {
                Button {
                    showingPopover.toggle()
                } label: {
                    label(showsChevron: true)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingPopover, arrowEdge: .top) {
                    AgentSearchableOptionPopover(
                        option: option,
                        onSelect: { value in
                            showingPopover = false
                            onSelect(value)
                        }
                    )
                }
            } else {
                Menu {
                    menuContent
                } label: {
                    label(showsChevron: false)
                }
                .menuStyle(.borderlessButton)
            }
        }
        .fixedSize(horizontal: !allowsTruncation, vertical: true)
        .disabled(isDisabled)
        .opacity(isDisabled && !isPending ? 0.6 : 1)
        .pointingHandCursor(!isDisabled)
        .help(Text(verbatim: helpText))
        .accessibilityLabel(Text(verbatim: option.name))
        .accessibilityValue(Text(verbatim: option.currentDisplayName))
    }

    private var helpText: String {
        if let description = option.options.first(where: { $0.value == option.currentValue })?.description,
           !description.isEmpty
        {
            return "\(option.name) — \(description)"
        }
        return option.name
    }

    private var iconName: String {
        switch option.effectiveCategory {
        case .model:
            "cpu"
        case .thoughtLevel:
            "gauge.with.dots.needle.67percent"
        case .speed,
             .modelConfig:
            "bolt"
        case .mode:
            switch option.currentValue.lowercased() {
            case "plan": "list.bullet.clipboard"
            case "auto": "sparkles"
            case "accept-edits",
                 "edit",
                 "build": "pencil"
            default: "switch.2"
            }
        default:
            "slider.horizontal.3"
        }
    }

    private func label(showsChevron: Bool) -> some View {
        HStack(spacing: 4) {
            if isPending {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .accessibilityHidden(true)
            }
            Text(verbatim: option.currentDisplayName)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
            if showsChevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(MactermTheme.fgMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6).strokeBorder(MactermTheme.border).allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        let sections = groupedAgentChoices(option.options)
        if sections.count == 1, sections[0].group == nil {
            ForEach(sections[0].choices) { choice in
                menuItem(choice)
            }
        } else {
            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                if let group = section.group {
                    Section(group) {
                        ForEach(section.choices) { choice in
                            menuItem(choice)
                        }
                    }
                } else {
                    ForEach(section.choices) { choice in
                        menuItem(choice)
                    }
                }
            }
        }
    }

    private func menuItem(_ choice: AgentBridge.ConfigOption.Choice) -> some View {
        Toggle(isOn: Binding(
            get: { choice.value == option.currentValue },
            set: { selected in
                if selected { onSelect(choice.value) }
            }
        )) {
            Text(verbatim: choice.name)
        }
    }
}

private struct AgentSearchableOptionPopover: View {
    let option: AgentBridge.ConfigOption
    let onSelect: (String) -> Void
    @State private var query = ""
    @State private var hoveredValue: String?
    @FocusState private var searchFocused: Bool

    private var filteredChoices: [AgentBridge.ConfigOption.Choice] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else { return option.options }
        return option.options.filter { choice in
            let haystack = "\(choice.name) \(choice.value) \(choice.group ?? "")".lowercased()
            return tokens.allSatisfy { haystack.contains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .accessibilityHidden(true)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                    .onSubmit {
                        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              let first = filteredChoices.first
                        else { return }
                        onSelect(first.value)
                    }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(MactermTheme.fgMuted)
                    }
                    .buttonStyle(.plain)
                    .pointingHandCursor()
                    .accessibilityLabel(Text("Clear"))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
            let choices = filteredChoices
            if choices.isEmpty {
                Text("No matching options")
                    .font(.callout)
                    .foregroundStyle(MactermTheme.fgMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            let sections = groupedAgentChoices(choices)
                            ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                                if let group = section.group {
                                    Text(verbatim: group)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(MactermTheme.fgMuted)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 8)
                                        .padding(.bottom, 2)
                                }
                                ForEach(section.choices) { choice in
                                    choiceRow(choice)
                                        .id(choice.value)
                                }
                            }
                        }
                        .padding(6)
                    }
                    .onAppear {
                        searchFocused = true
                        proxy.scrollTo(option.currentValue, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 340, height: 340)
        .foregroundStyle(MactermTheme.fg)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)))
    }

    private func choiceRow(_ choice: AgentBridge.ConfigOption.Choice) -> some View {
        let isSelected = choice.value == option.currentValue
        let isHovered = hoveredValue == choice.value
        return Button {
            onSelect(choice.value)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(MactermTheme.accent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                    .accessibilityHidden(true)
                Text(verbatim: choice.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isHovered ? MactermTheme.accentSoft : (isSelected ? MactermTheme.surface : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .onHover { hovering in
            if hovering {
                hoveredValue = choice.value
            } else if hoveredValue == choice.value {
                hoveredValue = nil
            }
        }
        .help(Text(verbatim: choice.description ?? choice.value))
    }
}

private func groupedAgentChoices(
    _ choices: [AgentBridge.ConfigOption.Choice]
) -> [(group: String?, choices: [AgentBridge.ConfigOption.Choice])] {
    var groups: [(group: String?, choices: [AgentBridge.ConfigOption.Choice])] = []
    var indexByGroup: [String: Int] = [:]
    var ungroupedIndex: Int?
    for choice in choices {
        if let group = choice.group, !group.isEmpty {
            if let index = indexByGroup[group] {
                groups[index].choices.append(choice)
            } else {
                indexByGroup[group] = groups.count
                groups.append((group, [choice]))
            }
        } else if let index = ungroupedIndex {
            groups[index].choices.append(choice)
        } else {
            ungroupedIndex = groups.count
            groups.append((nil, [choice]))
        }
    }
    return groups
}

private struct AgentPermissionCard: View {
    let request: AgentBridge.PermissionRequest
    let remainingCount: Int
    let isPending: Bool
    let isDisabled: Bool
    let isRejected: Bool
    let appearance: AgentAppearance
    let onSelect: (String) -> Void
    let onCancel: () -> Void

    private var primaryOptionID: String? {
        if let allowOnce = request.options.first(where: { $0.kind == .allowOnce }) {
            return allowOnce.optionId
        }
        if let allowAlways = request.options.first(where: { $0.kind == .allowAlways }) {
            return allowAlways.optionId
        }
        if request.options.allSatisfy({ $0.kind == nil }) {
            return request.options.first?.optionId
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(appearance.calloutFont())
                    .foregroundStyle(MactermTheme.warning)
                    .accessibilityHidden(true)
                Text(verbatim: request.title)
                    .font(appearance.calloutFont(weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if remainingCount > 0 {
                    Text(verbatim: "+\(remainingCount)")
                        .font(appearance.captionFont())
                        .monospacedDigit()
                        .foregroundStyle(MactermTheme.fgMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(MactermTheme.bg, in: Capsule())
                }
                if isPending {
                    ProgressView().controlSize(.mini)
                }
            }

            if let details = request.details, !details.isEmpty {
                let detailsText = Text(verbatim: details)
                    .font(appearance.codeFont(size: appearance.captionCodeSize))
                    .lineSpacing(max(1, appearance.lineSpacingPoints * 0.75))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                ViewThatFits(in: .vertical) {
                    detailsText
                    ScrollView {
                        detailsText
                    }
                }
                .frame(maxHeight: 140)
                .background(MactermTheme.bg, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(MactermTheme.border).allowsHitTesting(false)
                }
            }

            if isRejected {
                Text("The agent did not confirm the permission response.")
                    .font(appearance.captionFont())
                    .foregroundStyle(MactermTheme.failure)
            }

            AgentPermissionActionLayout(horizontalSpacing: 8, verticalSpacing: 6) {
                ForEach(request.options) { option in
                    optionButton(option, isPrimary: option.optionId == primaryOptionID)
                }
                Button(action: onCancel) {
                    Text("Cancel")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isDisabled)
                .fixedSize()
                .pointingHandCursor(!isDisabled)
            }
        }
        .padding(12)
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(MactermTheme.warning.opacity(0.45))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func optionButton(_ option: AgentBridge.PermissionRequest.Option, isPrimary: Bool) -> some View {
        let button = Button {
            onSelect(option.optionId)
        } label: {
            Text(verbatim: option.name)
        }
        .controlSize(.small)
        .disabled(isDisabled)
        .fixedSize()
        .pointingHandCursor(!isDisabled)

        if isPrimary {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }
}

private struct AgentPermissionActionLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var lineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if lineWidth > 0, lineWidth + horizontalSpacing + size.width > maxWidth {
                totalWidth = max(totalWidth, lineWidth)
                totalHeight += lineHeight + verticalSpacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                if lineWidth > 0 { lineWidth += horizontalSpacing }
                lineWidth += size.width
                lineHeight = max(lineHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, lineWidth)
        totalHeight += lineHeight
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX + 0.5 {
                x = bounds.minX
                y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + horizontalSpacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// Tracks the visible tail window of transcript entries and anchors expanded history by entry ID.
struct AgentTranscriptPagination: Equatable {
    static let defaultPageSize = 30

    let pageSize: Int
    private(set) var anchorStartID: String?

    init(pageSize: Int = defaultPageSize) {
        self.pageSize = max(1, pageSize)
    }

    func visibleStartIndex(in entryIDs: [String]) -> Int {
        let defaultStart = max(0, entryIDs.count - pageSize)
        guard let anchorStartID, let anchorIndex = entryIDs.firstIndex(of: anchorStartID) else {
            return defaultStart
        }
        return min(anchorIndex, defaultStart)
    }

    func hiddenCount(in entryIDs: [String]) -> Int {
        visibleStartIndex(in: entryIDs)
    }

    mutating func loadMore(in entryIDs: [String]) {
        let currentStart = visibleStartIndex(in: entryIDs)
        guard currentStart > 0 else { return }
        let nextStart = max(0, currentStart - pageSize)
        anchorStartID = entryIDs[nextStart]
    }

    mutating func reset() {
        anchorStartID = nil
    }
}

private struct AgentTranscript: View {
    let conversationID: String
    let rows: [AgentBridge.Row]
    let agentName: String
    let isPendingSend: Bool
    let isBusy: Bool
    let isWaiting: Bool
    let hasPendingPermission: Bool
    let appearance: AgentAppearance
    let onPreviewAttachment: (AgentBridge.Row, AgentAttachment) -> Void

    @State private var pagination = AgentTranscriptPagination()
    @State private var followsBottom = true
    @State private var pendingAnchorID: String?

    private var isWorking: Bool {
        isPendingSend || isBusy || isWaiting
    }

    var body: some View {
        GeometryReader { viewport in
            let columnWidth = appearance.contentWidth.resolvedWidth(for: viewport.size.width)
            if rows.isEmpty, !isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start a conversation").font(appearance.emptyTitleFont)
                    Text("Ask a question or describe a task.")
                        .font(appearance.bodyFont())
                        .foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let currentEntries = entries
                let entryIDs = currentEntries.map(\.id)
                let visibleStart = pagination.visibleStartIndex(in: entryIDs)
                let visibleEntries = currentEntries[visibleStart ..< currentEntries.count]
                let lastEntry = currentEntries.last
                AgentTranscriptScroll(
                    viewportHeight: viewport.size.height,
                    followsBottom: $followsBottom,
                    pendingAnchorID: $pendingAnchorID
                ) {
                    VStack(alignment: .leading, spacing: 16) {
                        if visibleStart > 0 {
                            earlierHistoryBar(
                                hiddenCount: visibleStart,
                                anchorID: visibleEntries.first?.id,
                                entryIDs: entryIDs
                            )
                        }
                        ForEach(visibleEntries) { entry in
                            Group {
                                switch entry {
                                case let .message(row):
                                    message(
                                        row,
                                        width: columnWidth,
                                        isStreaming: isWorking && !isWaiting && !hasPendingPermission && entry.id == lastEntry?.id
                                    )
                                case let .tools(rows):
                                    AgentToolGroup(
                                        rows: rows,
                                        appearance: appearance,
                                        maxExpandedHeight: AgentToolGroupLayout.maxListHeight(
                                            forViewportHeight: viewport.size.height
                                        )
                                    )
                                }
                            }
                            .id(entry.id)
                        }
                        if showsStandaloneProgress(after: lastEntry) {
                            assistantProgress(showHeader: !isAssistantEntry(lastEntry))
                        }
                    }
                    .padding(.vertical, 16)
                    .frame(width: columnWidth)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .onChange(of: conversationID) { _, _ in
            resetTranscriptState()
        }
        .onChange(of: rows.isEmpty) { _, isEmpty in
            if isEmpty {
                resetTranscriptState()
            }
        }
    }

    private func resetTranscriptState() {
        pagination.reset()
        followsBottom = true
        pendingAnchorID = nil
    }

    private func earlierHistoryBar(hiddenCount: Int, anchorID: String?, entryIDs: [String]) -> some View {
        HStack(spacing: 10) {
            Text("\(hiddenCount) earlier items hidden")
                .font(appearance.captionFont())
                .foregroundStyle(MactermTheme.fgMuted)
                .monospacedDigit()
            Button {
                loadMore(anchorID: anchorID, entryIDs: entryIDs)
            } label: {
                Label("Load More", systemImage: "arrow.up")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .pointingHandCursor()
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, 6)
    }

    private func loadMore(anchorID: String?, entryIDs: [String]) {
        pendingAnchorID = anchorID
        followsBottom = false
        pagination.loadMore(in: entryIDs)
    }

    private func isAssistantEntry(_ entry: Entry?) -> Bool {
        guard case let .message(row) = entry else { return false }
        return row.kind == .assistant
    }

    private func showsStandaloneProgress(after lastEntry: Entry?) -> Bool {
        guard isWorking else { return false }
        if hasPendingPermission { return false }
        if isWaiting { return true }
        if isAssistantEntry(lastEntry) { return false }
        if case let .tools(toolRows) = lastEntry, toolRows.contains(where: { $0.status == .running }) {
            return false
        }
        return true
    }

    private func assistantProgress(showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if showHeader {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(MactermTheme.accent).accessibilityHidden(true)
                    Text(verbatim: agentName).foregroundStyle(MactermTheme.fgMuted)
                }
                .font(appearance.captionFont(weight: .semibold))
            }
            HStack(spacing: 8) {
                if isWaiting {
                    Image(systemName: "terminal")
                        .foregroundStyle(MactermTheme.warning)
                        .accessibilityHidden(true)
                    Text("Continue in Terminal")
                        .foregroundStyle(MactermTheme.warning)
                } else {
                    ProgressView().controlSize(.mini)
                    if isPendingSend {
                        Text("Sending…").foregroundStyle(MactermTheme.fgMuted)
                    } else {
                        Text("Agent is working").foregroundStyle(MactermTheme.fgMuted)
                    }
                }
            }
            .font(appearance.calloutFont())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Entry: Identifiable {
        case message(AgentBridge.Row)
        case tools([AgentBridge.Row])

        var id: String {
            switch self {
            case let .message(row): row.id
            case let .tools(rows): rows[0].id
            }
        }
    }

    private var entries: [Entry] {
        var entries: [Entry] = []
        var tools: [AgentBridge.Row] = []
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
    private func message(_ row: AgentBridge.Row, width: CGFloat, isStreaming: Bool) -> some View {
        let attachments = row.resolvedAttachments
        if row.kind == .user {
            VStack(alignment: .trailing, spacing: 6) {
                Text("You").font(appearance.captionFont(weight: .medium)).foregroundStyle(MactermTheme.fgMuted)
                if !attachments.isEmpty {
                    AgentMessageAttachmentsView(
                        attachments: attachments,
                        alignment: .trailing,
                        maxWidth: width * 0.84,
                        appearance: appearance,
                        onPreview: { onPreviewAttachment(row, $0) }
                    )
                }
                if !row.text.isEmpty {
                    Text(verbatim: row.text)
                        .font(appearance.bodyFont())
                        .lineSpacing(appearance.lineSpacingPoints)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(MactermTheme.accentSoft, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10).strokeBorder(MactermTheme.border).allowsHitTesting(false)
                        }
                }
            }
            .frame(maxWidth: width * 0.84, alignment: .trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .contextMenu {
                if !row.text.isEmpty {
                    Button("Copy Message") { copyAgentText(row.text) }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkle").foregroundStyle(MactermTheme.accent).accessibilityHidden(true)
                    Text(verbatim: agentName).foregroundStyle(MactermTheme.fgMuted)
                    if isStreaming {
                        ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
                    }
                }
                .font(appearance.captionFont(weight: .semibold))
                if !row.text.isEmpty {
                    AgentMarkdownView(source: row.text, appearance: appearance)
                }
                if !attachments.isEmpty {
                    AgentMessageAttachmentsView(
                        attachments: attachments,
                        alignment: .leading,
                        maxWidth: width,
                        appearance: appearance,
                        onPreview: { onPreviewAttachment(row, $0) }
                    )
                }
            }
            .contextMenu {
                if !row.text.isEmpty {
                    Button("Copy Message") { copyAgentText(row.text) }
                }
            }
        }
    }
}

private struct AgentTranscriptScroll<Content: View>: View {
    let viewportHeight: CGFloat
    @Binding var followsBottom: Bool
    @Binding var pendingAnchorID: String?
    @ViewBuilder let content: () -> Content
    @State private var contentFrame = CGRect.zero

    private static var end: String { "agent-transcript-end" }

    var body: some View {
        ScrollViewReader { reader in
            let jump = {
                pendingAnchorID = nil
                followsBottom = true
                reader.scrollTo(Self.end, anchor: .bottom)
            }
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
                    if let anchorID = pendingAnchorID {
                        if frame.height != previous.height {
                            pendingAnchorID = nil
                            reader.scrollTo(anchorID, anchor: .top)
                            return
                        }
                        if frame.minY != previous.minY {
                            pendingAnchorID = nil
                        }
                    }
                    if frame.height == previous.height {
                        followsBottom = frame.maxY <= viewportHeight + 24
                    } else if followsBottom {
                        reader.scrollTo(Self.end, anchor: .bottom)
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
                    .pointingHandCursor()
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

/// Computes height bounds and scroll state for an expanded tool activity list.
enum AgentToolGroupLayout {
    static let defaultMaxHeight: CGFloat = 320
    static let minMaxHeight: CGFloat = 160
    static let maxMaxHeight: CGFloat = 420
    static let viewportHeightFraction: CGFloat = 0.5
    static let scrollerTrailingPadding: CGFloat = 12

    static func maxListHeight(forViewportHeight viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight.isFinite, viewportHeight > 0 else {
            return defaultMaxHeight
        }
        return min(maxMaxHeight, max(minMaxHeight, floor(viewportHeight * viewportHeightFraction)))
    }

    static func isScrollable(contentHeight: CGFloat, maxHeight: CGFloat) -> Bool {
        guard contentHeight.isFinite, maxHeight.isFinite, contentHeight > 0, maxHeight > 0 else {
            return false
        }
        return ceil(contentHeight) > maxHeight
    }

    static func resolvedListHeight(contentHeight: CGFloat, maxHeight: CGFloat) -> CGFloat? {
        guard contentHeight.isFinite, maxHeight.isFinite, contentHeight > 0, maxHeight > 0 else {
            return nil
        }
        return min(ceil(contentHeight), maxHeight)
    }
}

private struct AgentToolGroup: View {
    let rows: [AgentBridge.Row]
    let appearance: AgentAppearance
    let maxExpandedHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let isScrollable = AgentToolGroupLayout.isScrollable(
            contentHeight: contentHeight,
            maxHeight: maxExpandedHeight
        )
        let listHeight = AgentToolGroupLayout.resolvedListHeight(
            contentHeight: contentHeight,
            maxHeight: maxExpandedHeight
        )

        DisclosureGroup {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { row in
                        tool(row)
                    }
                }
                .padding(.trailing, isScrollable ? AgentToolGroupLayout.scrollerTrailingPadding : 0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    let rounded = ceil(height)
                    if abs(contentHeight - rounded) > 0.5 {
                        contentHeight = rounded
                    }
                }
            }
            .scrollIndicators(isScrollable ? .visible : .hidden)
            .scrollDisabled(!isScrollable)
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: listHeight)
            .frame(maxHeight: maxExpandedHeight)
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
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
                } else {
                    Image(systemName: "checkmark").foregroundStyle(MactermTheme.fgMuted)
                        .accessibilityLabel(Text("Completed"))
                }
            }
        }
        .font(appearance.calloutFont())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(MactermTheme.surface, in: RoundedRectangle(cornerRadius: 8))
    }

    private func tool(_ row: AgentBridge.Row) -> some View {
        DisclosureGroup {
            Text(verbatim: row.text)
                .font(appearance.codeFont())
                .lineSpacing(max(1, appearance.lineSpacingPoints * 0.75))
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
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
                case .failed:
                    Text("Failed").foregroundStyle(MactermTheme.failure)
                default:
                    Text("Completed").foregroundStyle(MactermTheme.fgMuted)
                }
            }
        }
        .font(appearance.captionFont())
    }
}

@MainActor
final class AgentPaneFocus {
    weak var input: NSTextView?
    var onFocus: (() -> Void)?
}

/// A native multiline editor with an AppKit focus target for FocusRestoration.
struct AgentComposer: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focus: AgentPaneFocus
    let isEditable: Bool
    let font: NSFont
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let submit: () -> Void
    let canPaste: (NSPasteboard) -> Bool
    let onPaste: (NSPasteboard) -> Bool
    var onCycleMode: (() -> Void)?

    private static let inset = NSSize(width: 12, height: 8)

    final class InputView: NSTextView {
        weak var focus: AgentPaneFocus?
        var submit: (() -> Void)?
        var canPaste: ((NSPasteboard) -> Bool)?
        var onPaste: ((NSPasteboard) -> Bool)?
        var onCycleMode: (() -> Void)?
        var pasteboardProvider: () -> NSPasteboard = { .general }

        var placeholder = "" {
            didSet {
                guard placeholder != oldValue else { return }
                wasShowingPlaceholder = showsPlaceholder
                needsDisplay = true
            }
        }

        var placeholderColor: NSColor = .placeholderTextColor {
            didSet {
                guard placeholderColor != oldValue else { return }
                if showsPlaceholder { needsDisplay = true }
            }
        }

        private var wasShowingPlaceholder = false

        var showsPlaceholder: Bool {
            string.isEmpty && !hasMarkedText() && !placeholder.isEmpty
        }

        override var string: String {
            didSet { syncPlaceholderDisplay() }
        }

        override func didChangeText() {
            super.didChangeText()
            syncPlaceholderDisplay()
        }

        override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            syncPlaceholderDisplay()
        }

        override func unmarkText() {
            super.unmarkText()
            syncPlaceholderDisplay()
        }

        override func insertText(_ string: Any, replacementRange: NSRange) {
            super.insertText(string, replacementRange: replacementRange)
            syncPlaceholderDisplay()
        }

        override func draw(_ dirtyRect: NSRect) {
            let showing = showsPlaceholder
            wasShowingPlaceholder = showing
            if showing {
                drawPlaceholder()
            }
            super.draw(dirtyRect)
        }

        override func keyDown(with event: NSEvent) {
            let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if event.keyCode == kVK_Tab, modifiers == .shift, !hasMarkedText(), let onCycleMode {
                if !event.isARepeat { onCycleMode() }
                return
            }
            guard event.keyCode == kVK_Return || event.keyCode == kVK_ANSI_KeypadEnter,
                  !hasMarkedText(), modifiers.isEmpty
            else {
                super.keyDown(with: event)
                return
            }
            if !event.isARepeat { submit?() }
        }

        override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
            if item.action == #selector(paste(_:)) || item.action == #selector(pasteAsPlainText(_:)) {
                guard isEditable else { return false }
                if canPaste?(pasteboardProvider()) == true {
                    return true
                }
            }
            return super.validateUserInterfaceItem(item)
        }

        override func paste(_ sender: Any?) {
            guard isEditable else { return }
            if onPaste?(pasteboardProvider()) == true {
                return
            }
            super.paste(sender)
        }

        override func pasteAsPlainText(_ sender: Any?) {
            guard isEditable else { return }
            if onPaste?(pasteboardProvider()) == true {
                return
            }
            super.pasteAsPlainText(sender)
        }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            focus?.onFocus?()
            return true
        }

        private func syncPlaceholderDisplay() {
            let nowShowing = showsPlaceholder
            guard nowShowing != wasShowingPlaceholder else { return }
            wasShowingPlaceholder = nowShowing
            needsDisplay = true
        }

        private func drawPlaceholder() {
            let origin = textContainerOrigin
            let padding = textContainer?.lineFragmentPadding ?? 0
            let width = max(0, bounds.width - (origin.x + padding) * 2)
            let height = max(0, bounds.height - origin.y * 2)
            guard width > 0, height > 0 else { return }

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byTruncatingTail
            paragraphStyle.alignment = alignment

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: placeholderColor,
                .paragraphStyle: paragraphStyle,
            ]
            let rect = NSRect(x: origin.x + padding, y: origin.y, width: width, height: height)
            NSAttributedString(string: placeholder, attributes: attributes).draw(
                with: rect,
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
            )
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
        input.setAccessibilityLabel(String(localized: "Message to agent"))
        input.isRichText = false
        input.allowsUndo = true
        input.drawsBackground = false
        input.font = font
        input.placeholder = placeholder
        input.placeholderColor = MactermTheme.nsFgMuted
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
        input.canPaste = canPaste
        input.onPaste = onPaste
        input.onCycleMode = onCycleMode
        input.placeholder = placeholder
        input.placeholderColor = MactermTheme.nsFgMuted
        if input.font != font {
            input.font = font
            input.typingAttributes[.font] = font
            if let storage = input.textStorage, storage.length > 0 {
                storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
            }
            if input.showsPlaceholder { input.needsDisplay = true }
        }
        input.textColor = MactermTheme.nsFg
        input.insertionPointColor = MactermTheme.nsFg
        if input.string != text, !input.hasMarkedText() { input.string = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: NSScrollView, context _: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }

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
        return CGSize(width: width, height: min(maxHeight, max(minHeight, ceil(height + Self.inset.height * 2))))
    }
}

extension View {
    func agentPointingHandCursor(_ enabled: Bool = true) -> some View {
        overlay {
            AgentPointerCursor(enabled: enabled)
                .allowsHitTesting(false)
        }
    }
}

private extension View {
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        agentPointingHandCursor(enabled)
    }
}

/// Applies the pointing hand cursor over clickable controls via AppKit cursor rects.
private struct AgentPointerCursor: NSViewRepresentable {
    let enabled: Bool

    final class CursorView: NSView {
        var isCursorEnabled = true

        override func hitTest(_: NSPoint) -> NSView? {
            nil
        }

        override func resetCursorRects() {
            guard isCursorEnabled else { return }
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }

    func makeNSView(context _: Context) -> CursorView {
        let view = CursorView()
        view.isCursorEnabled = enabled
        return view
    }

    func updateNSView(_ view: CursorView, context _: Context) {
        guard view.isCursorEnabled != enabled else { return }
        view.isCursorEnabled = enabled
        view.window?.invalidateCursorRects(for: view)
    }
}

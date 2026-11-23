import AppKit
import Carbon.HIToolbox
import SwiftUI

private let agentColumnWidth: CGFloat = 680

struct AgentPaneView: View {
    @Bindable var bridge: AgentBridge
    let surface: PaneSurface
    let focus: AgentPaneFocus
    let showTerminal: () -> Void

    var body: some View {
        GeometryReader { pane in
            VStack(spacing: 0) {
                header
                Rectangle().fill(MactermTheme.border).frame(height: 1).accessibilityHidden(true)
                AgentTranscript(
                    rows: bridge.displayRows,
                    agentName: bridge.provider.displayName,
                    isPendingSend: bridge.pendingSend != nil,
                    isBusy: bridge.isBusy,
                    isWaiting: bridge.isWaiting,
                    hasPendingPermission: !bridge.pendingPermissions.isEmpty
                )
                if let permission = bridge.pendingPermissions.first {
                    AgentPermissionCard(
                        request: permission,
                        remainingCount: bridge.pendingPermissions.count - 1,
                        isPending: bridge.pendingPermissionID == permission.id,
                        isDisabled: surface.isReadOnly || !bridge.isReady || bridge.pendingPermissionID != nil,
                        isRejected: bridge.permissionRejected,
                        onSelect: { optionID in
                            bridge.respondToPermission(permission.id, optionID: optionID, from: surface)
                        },
                        onCancel: {
                            bridge.respondToPermission(permission.id, optionID: nil, from: surface)
                        }
                    )
                    .frame(maxWidth: agentColumnWidth)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                }
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
            Text(verbatim: bridge.provider.displayName).font(.headline)
            Spacer(minLength: 4)
            if !bridge.pendingPermissions.isEmpty {
                Text("Permission Required")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.warning)
                    .lineLimit(1)
            } else if bridge.isWaiting {
                Text("Continue in Terminal")
                    .font(.caption)
                    .foregroundStyle(MactermTheme.warning)
                    .lineLimit(1)
            } else if bridge.isBusy {
                ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
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
            Button(action: showTerminal) {
                Label("Show Terminal", systemImage: "terminal")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .pointingHandCursor()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func composer(maxEditorHeight: CGFloat) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topLeading) {
                if bridge.draft.isEmpty {
                    Text("Write a message…")
                        .foregroundStyle(MactermTheme.fgMuted)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                AgentComposer(
                    text: $bridge.draft,
                    focus: focus,
                    isEditable: !surface.isReadOnly,
                    maxHeight: maxEditorHeight,
                    submit: { bridge.submit(from: surface) }
                )
            }
            if hasComposerControls, hasComposerStatus {
                composerStatus
                    .font(.caption)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            HStack(spacing: 6) {
                if hasComposerControls {
                    composerControls
                } else {
                    composerStatus
                        .font(.caption)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                if bridge.isBusy {
                    let canStop = !surface.isReadOnly && bridge.isReady
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
                        bridge.submit(from: surface)
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
            RoundedRectangle(cornerRadius: 12).strokeBorder(MactermTheme.border).allowsHitTesting(false)
        }
        .frame(maxWidth: agentColumnWidth)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .padding(.top, 4)
    }

    private var hasComposerControls: Bool {
        bridge.modelOption != nil || !bridge.speedOptions.isEmpty
    }

    private var hasComposerStatus: Bool {
        surface.isReadOnly || bridge.sendRejected || bridge.configRejected
            || bridge.newConversationRejected || bridge.draft.utf8.count > 128 * 1024
    }

    private var canStartAction: Bool {
        !surface.isReadOnly && bridge.isReady && !bridge.isBusy && !bridge.isWaiting
            && bridge.pendingSend == nil && bridge.pendingConfigID == nil && bridge.pendingNewConversation == nil
    }

    @ViewBuilder
    private var composerControls: some View {
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
        } else if bridge.sendRejected {
            Text("The agent did not confirm the message.").foregroundStyle(MactermTheme.failure)
        } else if bridge.configRejected {
            Text("The agent did not apply the setting.").foregroundStyle(MactermTheme.failure)
        } else if bridge.newConversationRejected {
            Text("The agent did not start a new conversation.").foregroundStyle(MactermTheme.failure)
        } else if bridge.draft.utf8.count > 128 * 1024 {
            Text("The message is too long.").foregroundStyle(MactermTheme.failure)
        }
    }

    private var canSubmit: Bool {
        canStartAction
            && !bridge.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bridge.draft.utf8.count <= 128 * 1024
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
        .help(Text(verbatim: option.name))
        .accessibilityLabel(Text(verbatim: option.name))
        .accessibilityValue(Text(verbatim: option.currentDisplayName))
    }

    private var iconName: String {
        switch option.effectiveCategory {
        case .model: "cpu"
        case .thoughtLevel: "gauge.with.dots.needle.67percent"
        case .speed,
             .modelConfig: "bolt"
        default: "slider.horizontal.3"
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
                    .font(.callout)
                    .foregroundStyle(MactermTheme.warning)
                    .accessibilityHidden(true)
                Text(verbatim: request.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                Spacer(minLength: 4)
                if remainingCount > 0 {
                    Text(verbatim: "+\(remainingCount)")
                        .font(.caption.monospacedDigit())
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
                    .font(.system(.caption, design: .monospaced))
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
                    .font(.caption)
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

private struct AgentTranscript: View {
    let rows: [AgentBridge.Row]
    let agentName: String
    let isPendingSend: Bool
    let isBusy: Bool
    let isWaiting: Bool
    let hasPendingPermission: Bool

    private var isWorking: Bool {
        isPendingSend || isBusy || isWaiting
    }

    var body: some View {
        GeometryReader { viewport in
            let columnWidth = max(0, min(agentColumnWidth, viewport.size.width - 32))
            if rows.isEmpty, !isWorking {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Start a conversation").font(.title2.weight(.semibold))
                    Text("Ask a question or describe a task.").foregroundStyle(MactermTheme.fgMuted)
                }
                .frame(maxWidth: columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let currentEntries = entries
                let lastEntry = currentEntries.last
                AgentTranscriptScroll(viewportHeight: viewport.size.height) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(currentEntries) { entry in
                            switch entry {
                            case let .message(row):
                                message(
                                    row,
                                    width: columnWidth,
                                    isStreaming: isWorking && !isWaiting && !hasPendingPermission && entry.id == lastEntry?.id
                                )
                            case let .tools(rows):
                                AgentToolGroup(rows: rows)
                            }
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
                .font(.caption.weight(.semibold))
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
            .font(.callout)
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
                    Text(verbatim: agentName).foregroundStyle(MactermTheme.fgMuted)
                    if isStreaming {
                        ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
                    }
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
                    .pointingHandCursor()
                    .padding(.bottom, 8)
                }
            }
        }
    }
}

private struct AgentToolGroup: View {
    let rows: [AgentBridge.Row]

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
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
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

    private func tool(_ row: AgentBridge.Row) -> some View {
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
                    ProgressView().controlSize(.mini).accessibilityLabel(Text("Agent is working"))
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
        input.setAccessibilityLabel(String(localized: "Message to agent"))
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

private extension View {
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        overlay {
            AgentPointerCursor(enabled: enabled)
                .allowsHitTesting(false)
        }
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

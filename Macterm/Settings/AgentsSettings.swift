import AppKit
import SwiftUI

/// Settings → Agents: controls Agent GUI feature toggle, shortcuts, appearance,
/// automatic terminal command interception, and built-in/custom interception rules.
struct AgentsSettings: View {
    private static let shortcutActions: [HotkeyAction] = [
        .agentNewConversation,
        .agentShowTerminal,
    ]
    private static let keybindColumnWidth: CGFloat = 120

    @Environment(AppState.self) private var appState
    private var agentSettings: AgentSettings { .shared }
    private var store: AgentInterceptStore { .shared }
    private var appearanceSettings: AgentAppearanceSettings { .shared }
    private var preferences: Preferences { .shared }

    @State private var fontCatalog: AgentFontCatalog = .empty
    @State private var editor: AgentInterceptEditorRequest?
    @State private var pendingRemoval: AgentInterceptRule?
    @State private var capturingActionID: String?

    var body: some View {
        let appearance = appearanceSettings.appearance
        let guiEnabled = agentSettings.guiEnabled
        Form {
            Section {
                SettingsInfoBlock(symbol: "bubble.left.and.text.bubble.right") {
                    Text(String(localized: "Agents", comment: "Settings pane"))
                    Text(String(localized: """
                    Open matching terminal commands in Macterm's Agent GUI through the bundled ACP bridge. \
                    Non-interactive runs and other arguments pass through to the original command.
                    """))
                    .settingsSecondaryText()
                }
            }

            Section {
                Toggle(isOn: guiEnabledBinding) {
                    Text("Enable Agent GUI")
                    Text(String(localized: """
                    Show supported coding agents in Macterm's native interface. When off, open Agent GUI panes \
                    return to the terminal and command interception pauses.
                    """))
                    .settingsDescription()
                }
            }

            Section {
                Group {
                    ForEach(Self.shortcutActions) { action in
                        agentShortcutRow(action)
                    }
                }
                .disabled(!guiEnabled)

                Text(String(localized: """
                Shortcuts apply to the focused Agent pane. Pressing the Show Terminal shortcut again returns to the Agent GUI.
                """))
                .settingsSecondaryText()
            } header: {
                Text("Keybinds")
            }

            Section {
                Group {
                    Picker("Font", selection: fontFamilyBinding) {
                        Text("System Default").tag("")
                        let families = fontCatalog.bodyFamilies(including: appearance.fontFamily)
                        if !families.isEmpty {
                            Divider()
                            ForEach(families, id: \.self) { family in
                                Text(verbatim: family).tag(family)
                            }
                        }
                    }

                    Picker("Code font", selection: codeFontFamilyBinding) {
                        Text("System Monospaced").tag("")
                        let sections = fontCatalog.codeFamilySections(including: appearance.codeFontFamily)
                        if !sections.monospaced.isEmpty {
                            Divider()
                            ForEach(sections.monospaced, id: \.self) { family in
                                Text(verbatim: family).tag(family)
                            }
                        }
                        if !sections.other.isEmpty {
                            Divider()
                            ForEach(sections.other, id: \.self) { family in
                                Text(verbatim: family).tag(family)
                            }
                        }
                    }

                    AgentSettingsSlider(
                        label: "Text size",
                        value: fontSizeBinding,
                        range: AgentAppearance.fontSizeRange,
                        step: 1,
                        display: { "\(Int($0.rounded())) pt" }
                    )

                    AgentSettingsSlider(
                        label: "Line spacing",
                        value: lineSpacingBinding,
                        range: AgentAppearance.lineSpacingRange,
                        step: 1,
                        display: { "\(Int($0.rounded())) pt" }
                    )

                    Picker("Content width", selection: contentWidthBinding) {
                        ForEach(AgentContentWidth.allCases) { width in
                            Text(width.displayName).tag(width)
                        }
                    }

                    AgentAppearancePreview(appearance: appearance)
                        .opacity(guiEnabled ? 1 : 0.5)
                }
                .disabled(!guiEnabled)

                Text("Changes apply immediately to open Agent GUI panes.")
                    .settingsSecondaryText()
            } header: {
                HStack {
                    Text(String(
                        localized: "agents.appearance.section",
                        defaultValue: "Appearance",
                        comment: "Settings → Agents section header"
                    ))
                    Spacer()
                    Button("Reset to Defaults") {
                        appearanceSettings.resetToDefaults()
                    }
                    .buttonStyle(.borderless)
                    .disabled(!guiEnabled || appearanceSettings.isDefault)
                }
            }

            Section {
                Toggle(isOn: enabledBinding) {
                    Text("Intercept agent commands")
                        .dimsWhenDisabled()
                    Text(String(localized: """
                    Applies to local zsh, bash, and fish panes. Set MACTERM_NO_AGENT_GUI=1 to run the terminal version instead.
                    """))
                    .settingsDescription()
                }
                .disabled(!guiEnabled)
            }

            Section {
                Group {
                    ForEach(store.rules) { rule in
                        AgentInterceptRuleRow(
                            rule: rule,
                            onToggle: { store.setRuleEnabled(rule.id, enabled: $0) },
                            onEdit: rule.isBuiltIn ? nil : { editor = .edit(rule) },
                            onRemove: rule.isBuiltIn ? nil : { pendingRemoval = rule }
                        )
                    }
                }
                .disabled(!guiEnabled || !store.enabled)

                Text(String(localized: """
                Changes take effect at the next prompt in open shells. Rules only intercept bare commands \
                or --conversation ID.
                """))
                .settingsSecondaryText()
            } header: {
                HStack {
                    Text("Command Interception Rules")
                    Spacer()
                    Button {
                        editor = .new()
                    } label: {
                        Label("Add Rule", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!guiEnabled)
                    .help("Add an interception rule")
                }
            }
        }
        .formStyle(.grouped)
        .background(
            HotkeyCaptureView(
                capturingActionID: $capturingActionID,
                onClear: { rowID in
                    if let action = HotkeyAction(rawValue: rowID) {
                        clearShortcut(for: action)
                    }
                },
                onCapture: { event, rowID in
                    guard let action = HotkeyAction(rawValue: rowID),
                          let shortcut = HotkeyRegistry.shortcutString(from: event)
                    else { return }
                    HotkeyRegistry.setShortcutString(shortcut, for: action)
                    stopCapturing()
                }
            )
        )
        .onChange(of: guiEnabled) { _, enabled in
            if !enabled { stopCapturing() }
        }
        .onAppear {
            appState.customPalettes.reloadIfChanged()
        }
        .onDisappear {
            stopCapturing()
        }
        .task {
            fontCatalog = await AgentFontCatalog.loadCached()
        }
        .sheet(item: $editor) { request in
            AgentInterceptRuleEditorSheet(request: request, store: store)
        }
        .alert(
            "Remove interception rule?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
                .keyboardShortcut(.cancelAction)
            Button("Remove", role: .destructive) {
                if let rule = pendingRemoval { store.removeCustomRule(id: rule.id) }
                pendingRemoval = nil
            }
            .keyboardShortcut(.defaultAction)
        } message: {
            Text("Macterm stops intercepting “\(pendingRemoval?.command ?? "")” at the next shell prompt.")
        }
    }

    @ViewBuilder
    private func agentShortcutRow(_ action: HotkeyAction) -> some View {
        let shortcut = currentShortcut(for: action)
        let isCapturing = capturingActionID == action.id
        let isUnmapped = HotkeyRegistry.isUnbound(shortcut)
        let partners = HotkeyRegistry.conflictPartners(
            for: action,
            customPalettes: appState.customPalettes.entries
        )
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(verbatim: action.title)
                    .dimsWhenDisabled()
                if !partners.isEmpty {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(MactermTheme.warning)
                }
                Spacer(minLength: 0)
                KeybindButton(
                    shortcut: shortcut,
                    isCapturing: isCapturing,
                    isUnmapped: isUnmapped,
                    onRecord: {
                        HotkeyCaptureState.shared.isCapturing = true
                        capturingActionID = action.id
                    },
                    onClear: { clearShortcut(for: action) }
                )
                .frame(width: Self.keybindColumnWidth)
            }
            if !partners.isEmpty {
                Text("Conflicts with \(partners.joined(separator: ", "))")
                    .font(.system(size: 11))
                    .foregroundStyle(MactermTheme.warning)
            }
        }
    }

    private func currentShortcut(for action: HotkeyAction) -> String {
        _ = preferences.hotkeyVersion
        return HotkeyRegistry.selectedShortcutString(for: action)
    }

    private func clearShortcut(for action: HotkeyAction) {
        HotkeyRegistry.setShortcutString("disabled", for: action)
        if capturingActionID == action.id {
            stopCapturing()
        }
    }

    private func stopCapturing() {
        capturingActionID = nil
        HotkeyCaptureState.shared.isCapturing = false
    }

    private var guiEnabledBinding: Binding<Bool> {
        Binding(
            get: { agentSettings.guiEnabled },
            set: { agentSettings.guiEnabled = $0 }
        )
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.enabled },
            set: { store.setEnabled($0) }
        )
    }

    private var fontFamilyBinding: Binding<String> {
        Binding(
            get: { appearanceSettings.fontFamily },
            set: { appearanceSettings.fontFamily = $0 }
        )
    }

    private var codeFontFamilyBinding: Binding<String> {
        Binding(
            get: { appearanceSettings.codeFontFamily },
            set: { appearanceSettings.codeFontFamily = $0 }
        )
    }

    private var fontSizeBinding: Binding<Double> {
        Binding(
            get: { appearanceSettings.fontSize },
            set: { appearanceSettings.fontSize = $0 }
        )
    }

    private var lineSpacingBinding: Binding<Double> {
        Binding(
            get: { appearanceSettings.lineSpacing },
            set: { appearanceSettings.lineSpacing = $0 }
        )
    }

    private var contentWidthBinding: Binding<AgentContentWidth> {
        Binding(
            get: { appearanceSettings.contentWidth },
            set: { appearanceSettings.contentWidth = $0 }
        )
    }
}

private struct AgentSettingsSlider: View {
    private static let labelWidth: CGFloat = 126
    private static let valueWidth: CGFloat = 52

    let label: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let display: (Double) -> String

    var body: some View {
        HStack {
            Text(label)
                .frame(width: Self.labelWidth, alignment: .leading)
                .dimsWhenDisabled()
            Slider(value: $value, in: range, step: step) { editing in
                guard !editing else { return }
                DispatchQueue.main.async {
                    guard let window = NSApp.keyWindow else { return }
                    let movable = window.isMovable
                    window.isMovable = !movable
                    window.isMovable = movable
                }
            }
            Text(verbatim: display(value))
                .monospacedDigit()
                .frame(width: Self.valueWidth, alignment: .trailing)
                .dimsWhenDisabled()
        }
    }
}

private struct AgentAppearancePreview: View {
    let appearance: AgentAppearance

    private var sampleMarkdown: String {
        String(
            localized: "agents.appearance.previewMarkdown",
            defaultValue: """
            Use **bold** emphasis and inline `code` together.

            ```swift
            let greeting = "Hello, Macterm"
            print(greeting)
            ```
            """,
            comment: "Live preview markdown sample in Settings → Agents"
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Spacer(minLength: 32)
                Text(String(
                    localized: "agents.appearance.previewQuestion",
                    defaultValue: "How does the Agent GUI look?",
                    comment: "Live preview user message in Settings → Agents"
                ))
                .font(appearance.bodyFont())
                .lineSpacing(appearance.lineSpacingPoints)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(MactermTheme.accentSoft, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(MactermTheme.border).allowsHitTesting(false)
                }
            }
            AgentMarkdownView(source: sampleMarkdown, appearance: appearance)
        }
        .padding(12)
        .foregroundStyle(MactermTheme.fg)
        .tint(MactermTheme.accent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: MactermTheme.nsConfiguredBg.withAlphaComponent(1)), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).strokeBorder(MactermTheme.border).allowsHitTesting(false)
        }
    }
}

private struct AgentInterceptRuleRow: View {
    let rule: AgentInterceptRule
    let onToggle: (Bool) -> Void
    let onEdit: (() -> Void)?
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(verbatim: rule.command)
                        .font(.body.monospaced())
                        .dimsWhenDisabled()
                    if rule.isBuiltIn {
                        Text("Built-in")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(verbatim: "\(rule.effectiveDisplayName) · \(rule.acpPreview)")
                    .settingsSecondaryText()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let onEdit {
                Button("Edit…", action: onEdit)
                    .buttonStyle(.borderless)
            }
            if let onRemove {
                Button(role: .destructive, action: onRemove) {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove rule")
            }
            Toggle(
                rule.command,
                isOn: Binding(
                    get: { rule.enabled },
                    set: { onToggle($0) }
                )
            )
            .labelsHidden()
        }
    }
}

private struct AgentInterceptEditorRequest: Identifiable {
    enum Kind {
        case new
        case edit(AgentInterceptRule)
    }

    let id = UUID()
    let kind: Kind

    static func new() -> Self {
        Self(kind: .new)
    }

    static func edit(_ rule: AgentInterceptRule) -> Self {
        Self(kind: .edit(rule))
    }
}

private struct AgentInterceptRuleEditorSheet: View {
    let request: AgentInterceptEditorRequest
    let store: AgentInterceptStore

    private enum Field: Hashable {
        case command
        case displayName
        case acpCommand
    }

    @Environment(\.dismiss) private var dismiss
    @State private var command: String
    @State private var displayName: String
    @State private var acpCommand: String
    @FocusState private var focus: Field?

    init(request: AgentInterceptEditorRequest, store: AgentInterceptStore) {
        self.request = request
        self.store = store
        switch request.kind {
        case .new:
            _command = State(initialValue: "")
            _displayName = State(initialValue: "")
            _acpCommand = State(initialValue: "")
        case let .edit(rule):
            _command = State(initialValue: rule.command)
            _displayName = State(initialValue: rule.displayName)
            _acpCommand = State(initialValue: rule.acpPreview)
        }
    }

    private var existingRule: AgentInterceptRule? {
        if case let .edit(rule) = request.kind { rule } else { nil }
    }

    private var trimmedCommand: String {
        command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedACP: String {
        acpCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationError: String? {
        if !trimmedCommand.isEmpty {
            if !AgentInterceptRule.isValidCommandName(trimmedCommand) {
                return String(localized: "Use letters, digits, underscores, or hyphens, and avoid reserved shell commands.")
            }
            if store.containsCommand(trimmedCommand, excluding: existingRule?.id) {
                return String(localized: "A rule for “\(trimmedCommand)” already exists.")
            }
        }
        if !trimmedACP.isEmpty, AgentInterceptRule.parseArguments(trimmedACP) == nil {
            return String(localized: "Close all quotes in the ACP command.")
        }
        return nil
    }

    private var canSave: Bool {
        !trimmedCommand.isEmpty && !trimmedACP.isEmpty && validationError == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("Command", text: $command, prompt: Text(verbatim: "my-agent"))
                        .font(.body.monospaced())
                        .focused($focus, equals: .command)
                    TextField("Display name", text: $displayName, prompt: Text("Optional"))
                        .focused($focus, equals: .displayName)
                    TextField("ACP command", text: $acpCommand, prompt: Text(verbatim: "my-agent acp"))
                        .font(.body.monospaced())
                        .focused($focus, equals: .acpCommand)
                } header: {
                    Text(existingRule == nil ? "New Interception Rule" : "Edit Interception Rule")
                } footer: {
                    Text(validationError ??
                        String(localized: "Enter the ACP v1 stdio command that Macterm runs for this terminal command."))
                        .foregroundStyle(validationError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(MactermTheme.failure))
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { focus = .command }
    }

    private func save() {
        let saved: Bool = if let existingRule {
            store.updateCustomRule(
                id: existingRule.id,
                command: trimmedCommand,
                displayName: displayName,
                acpCommandLine: trimmedACP
            )
        } else {
            store.addCustomRule(
                command: trimmedCommand,
                displayName: displayName,
                acpCommandLine: trimmedACP
            )
        }
        if saved { dismiss() }
    }
}

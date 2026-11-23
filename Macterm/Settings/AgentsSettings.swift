import SwiftUI

/// Settings → Agents: controls automatic terminal command interception for the
/// native Agent GUI and manages built-in and custom interception rules.
struct AgentsSettings: View {
    private var store: AgentInterceptStore { .shared }

    @State private var editor: AgentInterceptEditorRequest?
    @State private var pendingRemoval: AgentInterceptRule?

    var body: some View {
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
                Toggle(isOn: enabledBinding) {
                    Text("Intercept agent commands")
                    Text(String(localized: """
                    Applies to local zsh, bash, and fish panes. Set MACTERM_NO_AGENT_GUI=1 to run the terminal version instead.
                    """))
                    .settingsDescription()
                }
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
                .disabled(!store.enabled)

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
                    .help("Add an interception rule")
                }
            }
        }
        .formStyle(.grouped)
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

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { store.enabled },
            set: { store.setEnabled($0) }
        )
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

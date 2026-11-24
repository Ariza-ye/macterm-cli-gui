import Foundation
import Observation
import os

private let logger = Logger(subsystem: appBundleID, category: "AgentInterceptStore")

/// A single terminal command interception rule that routes interactive runs to
/// Macterm's native Agent GUI through the bundled ACP bridge.
struct AgentInterceptRule: Codable, Identifiable, Equatable {
    enum Preset: String, Codable, CaseIterable {
        case agy
        case opencode

        var defaultID: UUID {
            switch self {
            case .agy: UUID(uuid: (0xA6, 0xE7, 0xB0, 0xD1, 0x1F, 0x2E, 0x4A, 0x3B, 0x9C, 0x4D, 0x10, 0x00, 0x00, 0x00, 0x00, 0x01))
            case .opencode: UUID(uuid: (0xA6, 0xE7, 0xB0, 0xD1, 0x1F, 0x2E, 0x4A, 0x3B, 0x9C, 0x4D, 0x10, 0x00, 0x00, 0x00, 0x00, 0x02))
            }
        }

        var defaultCommand: String { rawValue }

        var defaultDisplayName: String {
            switch self {
            case .agy: "Antigravity"
            case .opencode: "OpenCode"
            }
        }

        var acpPreview: String {
            switch self {
            case .agy: "agy acp --stdio"
            case .opencode: "opencode acp"
            }
        }

        var executableName: String { rawValue }
    }

    enum Kind: Codable, Equatable {
        case preset(Preset)
        case acp(commandLine: String)
    }

    let id: UUID
    var command: String
    var displayName: String
    var enabled: Bool
    var kind: Kind

    var isBuiltIn: Bool {
        if case .preset = kind { true } else { false }
    }

    var effectiveDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? command : trimmed
    }

    var acpPreview: String {
        switch kind {
        case let .preset(preset): preset.acpPreview
        case let .acp(commandLine): commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var acpArguments: [String]? {
        switch kind {
        case .preset: nil
        case let .acp(commandLine): Self.parseArguments(commandLine)
        }
    }

    var requiredExecutable: String? {
        switch kind {
        case let .preset(preset): preset.executableName
        case let .acp(commandLine): Self.parseArguments(commandLine)?.first
        }
    }

    static var builtInDefaults: [AgentInterceptRule] {
        Preset.allCases.map { preset in
            AgentInterceptRule(
                id: preset.defaultID,
                command: preset.defaultCommand,
                displayName: preset.defaultDisplayName,
                enabled: true,
                kind: .preset(preset)
            )
        }
    }

    /// Shell keywords, builtins, and core utilities that must not be wrapped.
    private static let reservedCommands: Set<String> = [
        "alias", "bash", "begin", "bg", "break", "builtin", "case", "cd",
        "command", "continue", "do", "done", "echo", "elif", "else", "end",
        "esac", "eval", "exec", "exit", "export", "fg", "fi", "fish", "for",
        "function", "if", "in", "jobs", "kill", "local", "macterm", "node",
        "pwd", "read", "readonly", "return", "select", "set", "sh", "shift",
        "source", "ssh", "sudo", "switch", "test", "then", "time", "trap",
        "typeset", "unalias", "unset", "until", "while", "zsh",
    ]

    /// Returns true if the command name is a safe shell function identifier.
    static func isValidCommandName(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == raw, !trimmed.isEmpty, trimmed.utf8.count <= 64 else { return false }
        guard !reservedCommands.contains(trimmed.lowercased()) else { return false }
        guard let first = trimmed.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(first), first.isASCII
        else { return false }
        return trimmed.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (
                (scalar.value >= 0x30 && scalar.value <= 0x39) ||
                    (scalar.value >= 0x41 && scalar.value <= 0x5A) ||
                    (scalar.value >= 0x61 && scalar.value <= 0x7A) ||
                    scalar == "_" || scalar == "-"
            )
        }
    }

    /// Splits a command line into argv tokens using POSIX-style quoting rules.
    /// Returns nil when quotes are unclosed or the result is empty.
    static func parseArguments(_ commandLine: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var inToken = false
        var quote: Character?
        var escaping = false

        for ch in commandLine {
            if escaping {
                current.append(ch)
                inToken = true
                escaping = false
                continue
            }
            if quote == "'" {
                if ch == "'" {
                    quote = nil
                } else {
                    current.append(ch)
                }
                continue
            }
            if quote == "\"" {
                if ch == "\"" {
                    quote = nil
                } else if ch == "\\" {
                    escaping = true
                } else {
                    current.append(ch)
                }
                continue
            }
            if ch == "\\" {
                escaping = true
                inToken = true
            } else if ch == "'" || ch == "\"" {
                quote = ch
                inToken = true
            } else if ch.isWhitespace {
                if inToken {
                    tokens.append(current)
                    current = ""
                    inToken = false
                }
            } else {
                current.append(ch)
                inToken = true
            }
        }

        if escaping || quote != nil { return nil }
        if inToken { tokens.append(current) }
        guard !tokens.isEmpty, !tokens[0].isEmpty else { return nil }
        return tokens
    }
}

/// Persisted configuration for terminal command interception.
struct AgentInterceptConfig: Codable, Equatable {
    var enabled: Bool
    var rules: [AgentInterceptRule]

    static let `default` = AgentInterceptConfig(
        enabled: true,
        rules: AgentInterceptRule.builtInDefaults
    )
}

/// Pure generator for the per-shell command interception scripts sourced by
/// Macterm's shell integration hooks.
enum AgentInterceptShellGenerator {
    enum Shell: String, CaseIterable {
        case zsh
        case bash
        case fish

        var filename: String { "agent-intercept.\(rawValue)" }
    }

    static func generate(config: AgentInterceptConfig, shell: Shell, revision: String) -> String {
        switch shell {
        case .zsh: generateZsh(config: config, revision: revision)
        case .bash: generateBash(config: config, revision: revision)
        case .fish: generateFish(config: config, revision: revision)
        }
    }

    static func quotePosix(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func quoteFish(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'" + escaped + "'"
    }

    private static func activeRules(in config: AgentInterceptConfig) -> [AgentInterceptRule] {
        guard config.enabled else { return [] }
        var seen = Set<String>()
        return config.rules.filter { rule in
            guard rule.enabled, AgentInterceptRule.isValidCommandName(rule.command) else { return false }
            guard rule.requiredExecutable != nil else { return false }
            return seen.insert(rule.command).inserted
        }
    }

    private static func generateZsh(config: AgentInterceptConfig, revision: String) -> String {
        var lines: [String] = [
            "# macterm-intercept-rev:\(revision)",
            "if (( ${+_macterm_wrapped_commands} )); then",
            "    builtin local _macterm_cmd",
            "    for _macterm_cmd in \"${_macterm_wrapped_commands[@]}\"; do",
            "        (( ${+functions[$_macterm_cmd]} )) && builtin unfunction -- \"$_macterm_cmd\"",
            "    done",
            "fi",
            "builtin typeset -ga _macterm_wrapped_commands",
            "_macterm_wrapped_commands=()",
        ]

        for rule in activeRules(in: config) {
            guard let invocation = posixBridgeInvocation(for: rule),
                  let executable = rule.requiredExecutable
            else { continue }
            let cmd = rule.command
            lines.append("_macterm_wrapped_commands+=(\(quotePosix(cmd)))")
            lines.append("\(cmd)() {")
            lines.append("    builtin emulate -L zsh -o no_aliases")
            lines.append(contentsOf: posixWrapperBody(command: cmd, executable: executable, invocation: invocation))
            lines.append("}")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func generateBash(config: AgentInterceptConfig, revision: String) -> String {
        var lines: [String] = [
            "# macterm-intercept-rev:\(revision)",
            "if [[ -n \"${_macterm_wrapped_commands[*]:-}\" ]]; then",
            "    for _macterm_cmd in \"${_macterm_wrapped_commands[@]}\"; do",
            "        builtin unset -f \"$_macterm_cmd\" 2>/dev/null || true",
            "    done",
            "    builtin unset _macterm_cmd",
            "fi",
            "_macterm_wrapped_commands=()",
        ]

        for rule in activeRules(in: config) {
            guard let invocation = posixBridgeInvocation(for: rule),
                  let executable = rule.requiredExecutable
            else { continue }
            let cmd = rule.command
            lines.append("_macterm_wrapped_commands+=(\(quotePosix(cmd)))")
            lines.append("function \(cmd) {")
            lines.append(contentsOf: posixWrapperBody(command: cmd, executable: executable, invocation: invocation))
            lines.append("}")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func posixWrapperBody(command: String, executable: String, invocation: String) -> [String] {
        let envReady = [
            "-z \"${MACTERM_NO_AGENT_GUI:-}\"",
            "-n \"${MACTERM_AGENT_SOCKET:-${MACTERM_SOCKET:-}}\"",
            "-n \"${MACTERM_SESSION:-}\"",
            "-t 0",
            "-t 1",
        ].joined(separator: " && ")
        let toolsReady = [
            "[[ -n \"$_macterm_dir\" && -f \"$_macterm_bridge\" ]]",
            "builtin command -v node >/dev/null 2>&1",
            "builtin command -v \(quotePosix(executable)) >/dev/null 2>&1",
        ].joined(separator: " && ")
        return [
            "    if [[ \(envReady) ]]; then",
            "        if [[ $# -eq 0 ]] || [[ $# -eq 2 && \"$1\" == \"--conversation\" && -n \"$2\" ]]; then",
            "            builtin local _macterm_dir=\"${MACTERM_INTEGRATIONS_DIR:-}\"",
            "            if [[ -z \"$_macterm_dir\" && -n \"${GHOSTTY_RESOURCES_DIR:-}\" ]]; then",
            "                _macterm_dir=\"${GHOSTTY_RESOURCES_DIR%/ghostty}/integrations\"",
            "            fi",
            "            builtin local _macterm_bridge=\"$_macterm_dir/macterm-acp\"",
            "            if \(toolsReady); then",
            "                builtin command node \"$_macterm_bridge\" \(invocation)",
            "                builtin return $?",
            "            fi",
            "        fi",
            "    fi",
            "    builtin command \(quotePosix(command)) \"$@\"",
        ]
    }

    private static func generateFish(config: AgentInterceptConfig, revision: String) -> String {
        var lines: [String] = [
            "# macterm-intercept-rev:\(revision)",
            "if set -q __macterm_wrapped_commands",
            "    for __macterm_cmd in $__macterm_wrapped_commands",
            "        functions -q -- \"$__macterm_cmd\"; and functions -e -- \"$__macterm_cmd\"",
            "    end",
            "end",
            "set -g __macterm_wrapped_commands",
        ]

        let envReady = [
            "test -z \"$MACTERM_NO_AGENT_GUI\"",
            "begin; test -n \"$MACTERM_AGENT_SOCKET\"; or test -n \"$MACTERM_SOCKET\"; end",
            "test -n \"$MACTERM_SESSION\"",
            "isatty stdin",
            "isatty stdout",
        ].joined(separator: "; and ")
        let argReady = [
            "test \"$__macterm_argc\" -eq 0",
            "begin; test \"$__macterm_argc\" -eq 2; and test \"$argv[1]\" = \"--conversation\"; and test -n \"$argv[2]\"; end",
        ].joined(separator: "; or ")

        for rule in activeRules(in: config) {
            guard let invocation = fishBridgeInvocation(for: rule),
                  let executable = rule.requiredExecutable
            else { continue }
            let cmd = rule.command
            let toolsReady = [
                "test -n \"$__macterm_dir\"",
                "test -f \"$__macterm_bridge\"",
                "command -q node",
                "command -q \(quoteFish(executable))",
            ].joined(separator: "; and ")
            lines.append("set -ga __macterm_wrapped_commands \(quoteFish(cmd))")
            lines.append("function \(cmd) --wraps=\(cmd)")
            lines.append("    if \(envReady)")
            lines.append("        set -l __macterm_argc (count $argv)")
            lines.append("        if \(argReady)")
            lines.append("            set -l __macterm_dir \"$MACTERM_INTEGRATIONS_DIR\"")
            lines.append("            if test -z \"$__macterm_dir\"; and test -n \"$GHOSTTY_RESOURCES_DIR\"")
            lines.append("                set __macterm_dir (string replace -r '/ghostty$' '' -- \"$GHOSTTY_RESOURCES_DIR\")/integrations")
            lines.append("            end")
            lines.append("            set -l __macterm_bridge \"$__macterm_dir/macterm-acp\"")
            lines.append("            if \(toolsReady)")
            lines.append("                command node \"$__macterm_bridge\" \(invocation)")
            lines.append("                return $status")
            lines.append("            end")
            lines.append("        end")
            lines.append("    end")
            lines.append("    command \(quoteFish(cmd)) $argv")
            lines.append("end")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func posixBridgeInvocation(for rule: AgentInterceptRule) -> String? {
        switch rule.kind {
        case let .preset(preset):
            return "\(quotePosix(preset.rawValue)) \"$@\""
        case .acp:
            guard let args = rule.acpArguments else { return nil }
            let escapedArgs = args.map(quotePosix).joined(separator: " ")
            return "--name \(quotePosix(rule.effectiveDisplayName)) \"$@\" -- \(escapedArgs)"
        }
    }

    private static func fishBridgeInvocation(for rule: AgentInterceptRule) -> String? {
        switch rule.kind {
        case let .preset(preset):
            return "\(quoteFish(preset.rawValue)) $argv"
        case .acp:
            guard let args = rule.acpArguments else { return nil }
            let escapedArgs = args.map(quoteFish).joined(separator: " ")
            return "--name \(quoteFish(rule.effectiveDisplayName)) $argv -- \(escapedArgs)"
        }
    }
}

/// Manages command interception rules, persists them to Application Support,
/// and regenerates shell scripts picked up automatically by open shells.
@MainActor @Observable
final class AgentInterceptStore {
    static let shared = AgentInterceptStore()

    private(set) var config: AgentInterceptConfig
    private let directory: URL
    private let configURL: URL
    private let agentSettings: AgentSettings

    var enabled: Bool { config.enabled }
    var effectiveEnabled: Bool { agentSettings.guiEnabled && config.enabled }
    var rules: [AgentInterceptRule] { config.rules }

    init(directory: URL? = nil, agentSettings: AgentSettings = .shared) {
        let base = directory ?? FileStorage.appSupportDirectory()
        self.directory = base
        configURL = base.appendingPathComponent("agent-intercept.json")
        self.agentSettings = agentSettings
        config = Self.loadConfig(from: configURL)
    }

    /// Writes the generated shell scripts to disk so newly spawned and open
    /// shells stay synchronized with the persisted configuration.
    func syncShellScripts() {
        writeShellScripts()
    }

    func setEnabled(_ enabled: Bool) {
        guard config.enabled != enabled else { return }
        config.enabled = enabled
        persistAndSync()
    }

    func setRuleEnabled(_ id: UUID, enabled: Bool) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }),
              config.rules[index].enabled != enabled
        else { return }
        config.rules[index].enabled = enabled
        persistAndSync()
    }

    /// Adds a custom rule after validating its command name and ACP command.
    @discardableResult
    func addCustomRule(command: String, displayName: String, acpCommandLine: String) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedACP = acpCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentInterceptRule.isValidCommandName(trimmedCommand),
              !containsCommand(trimmedCommand, excluding: nil),
              AgentInterceptRule.parseArguments(trimmedACP) != nil
        else { return false }

        let rule = AgentInterceptRule(
            id: UUID(),
            command: trimmedCommand,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: true,
            kind: .acp(commandLine: trimmedACP)
        )
        config.rules.append(rule)
        persistAndSync()
        return true
    }

    /// Updates an existing custom rule.
    @discardableResult
    func updateCustomRule(id: UUID, command: String, displayName: String, acpCommandLine: String) -> Bool {
        guard let index = config.rules.firstIndex(where: { $0.id == id }),
              !config.rules[index].isBuiltIn
        else { return false }

        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedACP = acpCommandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AgentInterceptRule.isValidCommandName(trimmedCommand),
              !containsCommand(trimmedCommand, excluding: id),
              AgentInterceptRule.parseArguments(trimmedACP) != nil
        else { return false }

        config.rules[index].command = trimmedCommand
        config.rules[index].displayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        config.rules[index].kind = .acp(commandLine: trimmedACP)
        persistAndSync()
        return true
    }

    func removeCustomRule(id: UUID) {
        guard let index = config.rules.firstIndex(where: { $0.id == id }),
              !config.rules[index].isBuiltIn
        else { return }
        config.rules.remove(at: index)
        persistAndSync()
    }

    func containsCommand(_ command: String, excluding id: UUID?) -> Bool {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return config.rules.contains { $0.id != id && $0.command == trimmed }
    }

    private func persistAndSync() {
        writeConfig()
        writeShellScripts()
    }

    private static func loadConfig(from url: URL) -> AgentInterceptConfig {
        guard let data = try? Data(contentsOf: url),
              var decoded = try? JSONDecoder().decode(AgentInterceptConfig.self, from: data)
        else { return .default }

        // Ensure built-in presets exist even when a newer build adds one.
        let existingPresets = Set(decoded.rules.compactMap { rule -> AgentInterceptRule.Preset? in
            if case let .preset(preset) = rule.kind { return preset }
            return nil
        })
        let missing = AgentInterceptRule.builtInDefaults.filter { rule in
            if case let .preset(preset) = rule.kind { return !existingPresets.contains(preset) }
            return false
        }
        if !missing.isEmpty {
            decoded.rules.insert(contentsOf: missing, at: 0)
        }
        return decoded
    }

    private func writeConfig() {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(config)
            try data.write(to: configURL, options: .atomic)
            chmod(configURL.path, 0o600)
        } catch {
            logger.error("failed to save agent-intercept.json: \(EnglishErrorText.describe(error), privacy: .public)")
        }
    }

    private func writeShellScripts() {
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            logger.error("failed to create app support directory: \(EnglishErrorText.describe(error), privacy: .public)")
            return
        }
        var effectiveConfig = config
        effectiveConfig.enabled = effectiveEnabled
        let revision = UUID().uuidString
        for shell in AgentInterceptShellGenerator.Shell.allCases {
            let content = AgentInterceptShellGenerator.generate(config: effectiveConfig, shell: shell, revision: revision)
            let url = directory.appendingPathComponent(shell.filename)
            do {
                try Data(content.utf8).write(to: url, options: .atomic)
                chmod(url.path, 0o600)
            } catch {
                logger.error("failed to write \(shell.filename, privacy: .public): \(EnglishErrorText.describe(error), privacy: .public)")
            }
        }
    }
}

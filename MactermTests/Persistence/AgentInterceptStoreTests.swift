import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentInterceptStoreTests {
    @Test
    func commandNameValidation() {
        #expect(AgentInterceptRule.isValidCommandName("agy"))
        #expect(AgentInterceptRule.isValidCommandName("my-agent_2"))
        #expect(!AgentInterceptRule.isValidCommandName(""))
        #expect(!AgentInterceptRule.isValidCommandName(" agy"))
        #expect(!AgentInterceptRule.isValidCommandName("agy;rm"))
        #expect(!AgentInterceptRule.isValidCommandName("../agy"))
        #expect(!AgentInterceptRule.isValidCommandName("-flag"))
        #expect(!AgentInterceptRule.isValidCommandName("cd"))
        #expect(!AgentInterceptRule.isValidCommandName("ssh"))
        #expect(!AgentInterceptRule.isValidCommandName("if"))
        #expect(!AgentInterceptRule.isValidCommandName("macterm"))
    }

    @Test
    func parseArgumentsHandlesQuotesAndEscapes() {
        #expect(AgentInterceptRule.parseArguments("my-agent acp --stdio") == ["my-agent", "acp", "--stdio"])
        #expect(AgentInterceptRule.parseArguments("my-agent --name 'A B' \"C\\ D\"") == ["my-agent", "--name", "A B", "C D"])
        #expect(AgentInterceptRule.parseArguments("   ") == nil)
        #expect(AgentInterceptRule.parseArguments("my-agent 'unclosed") == nil)
        #expect(AgentInterceptRule.parseArguments("my-agent \"unclosed") == nil)
    }

    @Test
    func persistenceAndCustomRuleCRUD() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intercept-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AgentInterceptStore(directory: dir)
        #expect(store.enabled)
        #expect(store.rules.map(\.command) == ["agy", "opencode"])

        #expect(store.addCustomRule(command: "claude-acp", displayName: "Claude ACP", acpCommandLine: "npx claude-acp --stdio"))
        #expect(!store.addCustomRule(command: "claude-acp", displayName: "Dup", acpCommandLine: "npx claude-acp"))
        #expect(!store.addCustomRule(command: "ssh", displayName: "Bad", acpCommandLine: "ssh"))

        let added = try #require(store.rules.first { $0.command == "claude-acp" })
        #expect(!added.isBuiltIn)
        #expect(store.updateCustomRule(id: added.id, command: "claude", displayName: "Claude", acpCommandLine: "claude acp"))
        store.setEnabled(false)

        let reloaded = AgentInterceptStore(directory: dir)
        #expect(!reloaded.enabled)
        #expect(reloaded.rules.map(\.command) == ["agy", "opencode", "claude"])

        reloaded.removeCustomRule(id: added.id)
        #expect(reloaded.rules.map(\.command) == ["agy", "opencode"])

        // Built-in rules cannot be removed.
        let builtInID = try #require(reloaded.rules.first?.id)
        reloaded.removeCustomRule(id: builtInID)
        #expect(reloaded.rules.count == 2)
    }

    @Test
    func shellGeneratorProducesValidScriptsForAllShells() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intercept-gen-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = AgentInterceptStore(directory: dir)
        #expect(store.addCustomRule(command: "my-agent", displayName: "O'Brien's Agent", acpCommandLine: "npx 'my acp' --stdio"))

        for shell in AgentInterceptShellGenerator.Shell.allCases {
            let fileURL = dir.appendingPathComponent(shell.filename)
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            #expect(content.hasPrefix("# macterm-intercept-rev:"))
            #expect(content.contains("agy"))
            #expect(content.contains("opencode"))
            #expect(content.contains("my-agent"))
        }

        // Validate generated zsh and bash syntax using real shells.
        let zshCheck = try runSyntaxCheck("/bin/zsh", args: ["-n", dir.appendingPathComponent("agent-intercept.zsh").path])
        #expect(zshCheck == 0)
        let bashCheck = try runSyntaxCheck("/bin/bash", args: ["-n", dir.appendingPathComponent("agent-intercept.bash").path])
        #expect(bashCheck == 0)

        // Disabling interception still emits cleanup header with no function definitions.
        store.setEnabled(false)
        let disabledZsh = try String(contentsOf: dir.appendingPathComponent("agent-intercept.zsh"), encoding: .utf8)
        #expect(disabledZsh.contains("unfunction"))
        #expect(!disabledZsh.contains("agy() {"))
        #expect(!disabledZsh.contains("my-agent() {"))
    }

    @Test
    func guiTogglePausesAndResumesShellInterceptionWithoutChangingSavedConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-intercept-gui-toggle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let defaults = IsolatedDefaults.make()
        let settings = AgentSettings(defaults: defaults)
        let store = AgentInterceptStore(directory: dir, agentSettings: settings)

        store.syncShellScripts()
        #expect(store.enabled)
        #expect(store.effectiveEnabled)
        let initialZsh = try String(contentsOf: dir.appendingPathComponent("agent-intercept.zsh"), encoding: .utf8)
        #expect(initialZsh.contains("agy() {"))

        settings.guiEnabled = false
        store.syncShellScripts()
        #expect(store.enabled)
        #expect(!store.effectiveEnabled)
        let pausedZsh = try String(contentsOf: dir.appendingPathComponent("agent-intercept.zsh"), encoding: .utf8)
        #expect(pausedZsh.contains("unfunction"))
        #expect(!pausedZsh.contains("agy() {"))

        settings.guiEnabled = true
        store.syncShellScripts()
        #expect(store.enabled)
        #expect(store.effectiveEnabled)
        let resumedZsh = try String(contentsOf: dir.appendingPathComponent("agent-intercept.zsh"), encoding: .utf8)
        #expect(resumedZsh.contains("agy() {"))
    }

    private func runSyntaxCheck(_ launchPath: String, args: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}

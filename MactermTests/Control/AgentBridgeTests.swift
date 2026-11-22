import Darwin
import Foundation
@testable import Macterm
import Testing

@MainActor
struct AgentBridgeTests {
    private func makeAppState() -> AppState {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-agent-tests-\(UUID().uuidString).json")
        let projectsDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-agent-tests-projects-\(UUID().uuidString)", isDirectory: true)
        return AppState(
            workspaceStore: WorkspaceStore(fileURL: tmp),
            projectFiles: ProjectFileStore(directoryURL: projectsDir)
        )
    }

    private func makeHandler() -> (ControlHandler, AppState, ProjectStore) {
        let appState = makeAppState()
        let projectStore = ProjectStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("macterm-agent-tests-store-\(UUID().uuidString).json"))
        let handler = ControlHandler(appState: appState, projectStore: projectStore) { _, _ in .unreachable }
        return (handler, appState, projectStore)
    }

    private func seedPane(_ appState: AppState, _ projectStore: ProjectStore) throws -> Pane {
        let project = Project(name: "demo", path: "/tmp", sortOrder: 0)
        projectStore.add(project)
        appState.selectProject(project)
        let workspace = try #require(appState.workspaces[project.id])
        return try #require(workspace.tabs.first?.splitRoot.allPanes().first)
    }

    /// Creates a real user-owned 0700 directory and Unix domain socket matching
    /// the bridge path format, returning its path and cleanup closure.
    private func makeBridgeSocket(prefix: String, directoryMode: mode_t = 0o700) throws -> (String, () -> Void) {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let directory = "/tmp/macterm-\(prefix)-\(token)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: directoryMode)]
        )
        let path = "\(directory)/bridge.sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (index, byte) in bytes.enumerated() {
                raw[index] = byte
            }
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(result == 0)

        return (path, {
            close(fd)
            try? FileManager.default.removeItem(atPath: directory)
        })
    }

    // MARK: - Provider parsing

    @Test
    func provider_identifier_maps_known_and_custom_agents() {
        #expect(AgentBridge.Provider(identifier: "pi") == .pi)
        #expect(AgentBridge.Provider(identifier: "PI") == .pi)
        #expect(AgentBridge.Provider(identifier: "agy") == .antigravity)
        #expect(AgentBridge.Provider(identifier: "Antigravity") == .antigravity)
        #expect(AgentBridge.Provider(identifier: "opencode") == .opencode)
        #expect(AgentBridge.Provider(identifier: "OpenCode") == .opencode)
        #expect(AgentBridge.Provider(identifier: "  Claude Code  ") == .custom("Claude Code"))

        #expect(AgentBridge.Provider.pi.displayName == "Pi")
        #expect(AgentBridge.Provider.antigravity.displayName == "Antigravity")
        #expect(AgentBridge.Provider.opencode.displayName == "OpenCode")
        #expect(AgentBridge.Provider.opencode.icon == .opencode)
        #expect(AgentBridge.Provider.custom("claude").icon == .claude)
        #expect(AgentBridge.Provider.custom("UnknownAgent").icon == nil)
    }

    @Test
    func provider_identifier_rejects_empty_control_or_overlong_values() {
        #expect(AgentBridge.Provider(identifier: "") == nil)
        #expect(AgentBridge.Provider(identifier: "   \n") == nil)
        #expect(AgentBridge.Provider(identifier: "bad\u{0007}name") == nil)
        #expect(AgentBridge.Provider(identifier: String(repeating: "a", count: 65)) == nil)
    }

    // MARK: - Socket validation

    @Test
    func accepts_socket_validates_prefix_permissions_and_socket_type() throws {
        let (agentSocket, cleanupAgent) = try makeBridgeSocket(prefix: "agent")
        defer { cleanupAgent() }

        #expect(AgentBridge.acceptsSocket(at: agentSocket, for: .opencode))
        #expect(AgentBridge.acceptsSocket(at: agentSocket, for: .antigravity))
        #expect(AgentBridge.acceptsSocket(at: agentSocket, for: .custom("Codex")))

        let (opencodeSocket, cleanupOpenCode) = try makeBridgeSocket(prefix: "opencode")
        defer { cleanupOpenCode() }
        #expect(AgentBridge.acceptsSocket(at: opencodeSocket, for: .opencode))
        #expect(!AgentBridge.acceptsSocket(at: opencodeSocket, for: .antigravity))

        let (worldReadable, cleanupWorld) = try makeBridgeSocket(prefix: "agent", directoryMode: 0o755)
        defer { cleanupWorld() }
        #expect(!AgentBridge.acceptsSocket(at: worldReadable, for: .opencode))
    }

    // MARK: - ControlHandler registration

    @Test
    func agent_register_binds_opencode_and_custom_providers() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let pane = try seedPane(appState, projectStore)
        let (socketPath, cleanup) = try makeBridgeSocket(prefix: "agent")
        defer {
            pane.disconnectAgent()
            cleanup()
        }

        var args = ControlArgs(session: pane.sessionName)
        args.agentBridge = ControlAgentRegistration(
            provider: "opencode",
            conversation: "conv-1",
            socket: socketPath,
            token: UUID()
        )
        let response = await handler.handle(ControlRequest(command: "agent.register", args: args))
        #expect(response.ok)
        #expect(pane.agentBridge?.provider == .opencode)

        args.agentBridge = ControlAgentRegistration(
            provider: "Codex",
            conversation: "conv-2",
            socket: socketPath,
            token: UUID()
        )
        let customResponse = await handler.handle(ControlRequest(command: "agent.register", args: args))
        #expect(customResponse.ok)
        #expect(pane.agentBridge?.provider == .custom("Codex"))
    }

    @Test
    func agent_register_requires_provider_while_legacy_commands_keep_defaults() async throws {
        let (handler, appState, projectStore) = makeHandler()
        let pane = try seedPane(appState, projectStore)
        let (agySocket, cleanupAgy) = try makeBridgeSocket(prefix: "agy")
        defer {
            pane.disconnectAgent()
            cleanupAgy()
        }

        var missingProviderArgs = ControlArgs(session: pane.sessionName)
        missingProviderArgs.agentBridge = ControlAgentRegistration(
            conversation: "conv-missing",
            socket: agySocket,
            token: UUID()
        )
        let rejected = await handler.handle(ControlRequest(command: "agent.register", args: missingProviderArgs))
        #expect(!rejected.ok)
        #expect(rejected.error?.code == .badRequest)

        let legacyResponse = await handler.handle(ControlRequest(command: "agy.register", args: missingProviderArgs))
        #expect(legacyResponse.ok)
        #expect(pane.agentBridge?.provider == .antigravity)
    }
}

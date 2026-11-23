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

    // MARK: - Model & speed configuration

    @Test
    func config_option_infers_categories_and_resolves_display_name() throws {
        let json = """
        [
          {
            "id": "model",
            "name": "Model",
            "currentValue": "gemini-4-neon",
            "options": [
              { "value": "gemini-4-neon", "name": "Gemini 4 Neon" }
            ]
          },
          {
            "id": "effort",
            "name": "Effort",
            "category": "thought_level",
            "currentValue": "high",
            "options": [
              { "value": "low", "name": "Low" },
              { "value": "high", "name": "High" }
            ]
          },
          {
            "id": "service_tier",
            "name": "Speed",
            "currentValue": "fast",
            "options": [
              { "value": "standard", "name": "Standard" },
              { "value": "fast", "name": "Fast" }
            ]
          },
          {
            "id": "custom_flag",
            "name": "Custom",
            "category": "future_unknown_category",
            "currentValue": "a",
            "options": [
              { "value": "a", "name": "A" }
            ]
          }
        ]
        """
        let decoded = try JSONDecoder().decode([AgentBridge.ConfigOption].self, from: Data(json.utf8))
        #expect(decoded.count == 4)
        #expect(decoded[0].effectiveCategory == .model)
        #expect(decoded[0].currentDisplayName == "Gemini 4 Neon")
        #expect(decoded[1].effectiveCategory == .thoughtLevel)
        #expect(decoded[1].currentDisplayName == "High")
        #expect(decoded[2].effectiveCategory == .speed)
        #expect(decoded[2].currentDisplayName == "Fast")
        #expect(decoded[3].effectiveCategory == .other)
    }

    @Test
    func bridge_syncs_and_switches_model_and_speed_over_socket() async throws {
        let (_, appState, projectStore) = makeHandler()
        let pane = try seedPane(appState, projectStore)
        let windowID = UUID()
        let surface = SurfaceRegistry.shared.surface(for: pane, in: .window(windowID))
        defer {
            pane.disconnectAgent()
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }

        let (socketPath, serverFD, cleanup) = try makeListeningBridgeSocket(prefix: "agent")
        defer { cleanup() }

        let token = UUID()
        let bridge = AgentBridge(
            provider: .antigravity,
            path: socketPath,
            conversation: "conv-config",
            token: token,
            windowID: windowID
        )
        pane.bindAgent(bridge)

        let peerFD = try await acceptClient(on: serverFD)
        defer { close(peerFD) }

        let helloLine = try await readLine(from: peerFD)
        let hello = try #require(JSONSerialization.jsonObject(with: Data(helloLine.utf8)) as? [String: Any])
        #expect(hello["type"] as? String == "hello")
        #expect((hello["token"] as? String)?.lowercased() == token.uuidString.lowercased())

        let initialConfig: [[String: Any]] = [
            [
                "id": "model",
                "name": "Model",
                "category": "model",
                "currentValue": "gemini-4-neon",
                "options": [
                    ["value": "gemini-4-neon", "name": "Gemini 4 Neon"],
                    ["value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"],
                ],
            ],
            [
                "id": "thought_level",
                "name": "Thinking Level",
                "category": "thought_level",
                "currentValue": "high",
                "options": [
                    ["value": "low", "name": "Low"],
                    ["value": "medium", "name": "Medium"],
                    ["value": "high", "name": "High"],
                ],
            ],
            [
                "id": "mode",
                "name": "Mode",
                "category": "mode",
                "currentValue": "default",
                "options": [
                    ["value": "default", "name": "Default"],
                    ["value": "plan", "name": "Plan"],
                ],
            ],
        ]
        try writeFrame(["type": "snapshot", "conversation": "conv-config"], to: peerFD)
        try writeFrame(["type": "snapshotEnd", "busy": false, "waiting": false, "configOptions": initialConfig], to: peerFD)

        try await waitUntil { bridge.isReady && bridge.modelOption?.currentValue == "gemini-4-neon" }
        #expect(bridge.speedOptions.count == 1)
        #expect(bridge.speedOptions[0].id == "thought_level")
        #expect(bridge.speedOptions[0].currentValue == "high")

        // Switch thinking level (speed)
        bridge.setConfig("thought_level", value: "low", from: surface)
        #expect(bridge.pendingConfigID == "thought_level")

        let setSpeedLine = try await readLine(from: peerFD)
        let setSpeed = try #require(JSONSerialization.jsonObject(with: Data(setSpeedLine.utf8)) as? [String: Any])
        #expect(setSpeed["type"] as? String == "setConfig")
        #expect(setSpeed["configId"] as? String == "thought_level")
        #expect(setSpeed["value"] as? String == "low")
        let speedReqID = try #require(setSpeed["id"] as? String)

        var updatedConfig = initialConfig
        updatedConfig[1]["currentValue"] = "low"
        try writeFrame([
            "type": "configReply",
            "id": speedReqID,
            "accepted": true,
            "configOptions": updatedConfig,
        ], to: peerFD)

        try await waitUntil { bridge.pendingConfigID == nil && bridge.speedOptions.first?.currentValue == "low" }
        #expect(!bridge.configRejected)

        // Rejected switch sets configRejected and preserves previous value
        bridge.setConfig("model", value: "gemini-3.8-flash", from: surface)
        let setModelLine = try await readLine(from: peerFD)
        let setModel = try #require(JSONSerialization.jsonObject(with: Data(setModelLine.utf8)) as? [String: Any])
        let modelReqID = try #require(setModel["id"] as? String)
        try writeFrame([
            "type": "configReply",
            "id": modelReqID,
            "accepted": false,
            "configOptions": updatedConfig,
        ], to: peerFD)

        try await waitUntil { bridge.pendingConfigID == nil && bridge.configRejected }
        #expect(bridge.modelOption?.currentValue == "gemini-4-neon")

        // Server-pushed config update syncs live (e.g. changed in terminal)
        updatedConfig[0]["currentValue"] = "gemini-3.8-flash"
        updatedConfig[1]["currentValue"] = "medium"
        try writeFrame(["type": "config", "configOptions": updatedConfig], to: peerFD)
        try await waitUntil {
            bridge.modelOption?.currentValue == "gemini-3.8-flash"
                && bridge.speedOptions.first?.currentValue == "medium"
        }
    }

    // MARK: - New conversation

    @Test
    func bridge_starts_new_conversation_and_handles_rejection_over_socket() async throws {
        let (_, appState, projectStore) = makeHandler()
        let pane = try seedPane(appState, projectStore)
        let windowID = UUID()
        let surface = SurfaceRegistry.shared.surface(for: pane, in: .window(windowID))
        defer {
            pane.disconnectAgent()
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }

        let (socketPath, serverFD, cleanup) = try makeListeningBridgeSocket(prefix: "agent")
        defer { cleanup() }

        let token = UUID()
        let bridge = AgentBridge(
            provider: .antigravity,
            path: socketPath,
            conversation: "conv-1",
            token: token,
            windowID: windowID
        )
        pane.bindAgent(bridge)

        let peerFD = try await acceptClient(on: serverFD)
        defer { close(peerFD) }
        _ = try await readLine(from: peerFD) // hello

        let initialConfig: [[String: Any]] = [
            [
                "id": "model",
                "name": "Model",
                "category": "model",
                "currentValue": "gemini-4-neon",
                "options": [
                    ["value": "gemini-4-neon", "name": "Gemini 4 Neon"],
                    ["value": "gemini-3.8-flash", "name": "Gemini 3.8 Flash"],
                ],
            ],
        ]
        try writeFrame(["type": "snapshot", "conversation": "conv-1"], to: peerFD)
        try writeFrame([
            "type": "row",
            "row": ["id": "u1", "kind": "user", "text": "Hello"],
        ], to: peerFD)
        try writeFrame([
            "type": "row",
            "row": ["id": "a1", "kind": "assistant", "text": "Hi there"],
        ], to: peerFD)
        try writeFrame(["type": "snapshotEnd", "busy": false, "waiting": false, "configOptions": initialConfig], to: peerFD)

        try await waitUntil { bridge.isReady && bridge.rows.count == 2 }
        bridge.draft = "Unsent prompt"

        // Accepted new conversation clears rows, updates conversation ID and config, and keeps unsent draft.
        bridge.newConversation(from: surface)
        #expect(bridge.pendingNewConversation != nil)

        let requestLine = try await readLine(from: peerFD)
        let request = try #require(JSONSerialization.jsonObject(with: Data(requestLine.utf8)) as? [String: Any])
        #expect(request["type"] as? String == "newConversation")
        let requestID = try #require(request["id"] as? String)

        var nextConfig = initialConfig
        nextConfig[0]["currentValue"] = "gemini-3.8-flash"
        try writeFrame([
            "type": "newConversationReply",
            "id": requestID,
            "accepted": true,
            "conversation": "conv-2",
            "configOptions": nextConfig,
            "busy": false,
            "waiting": false,
        ], to: peerFD)

        try await waitUntil { bridge.pendingNewConversation == nil && bridge.conversation == "conv-2" }
        #expect(!bridge.newConversationRejected)
        #expect(bridge.rows.isEmpty)
        #expect(bridge.draft == "Unsent prompt")
        #expect(bridge.modelOption?.currentValue == "gemini-3.8-flash")

        // New message arrives in conv-2, then a rejected newConversation preserves it.
        try writeFrame([
            "type": "row",
            "row": ["id": "u2", "kind": "user", "text": "Second chat"],
        ], to: peerFD)
        try await waitUntil { bridge.rows.count == 1 }

        bridge.newConversation(from: surface)
        let rejectLine = try await readLine(from: peerFD)
        let rejectReq = try #require(JSONSerialization.jsonObject(with: Data(rejectLine.utf8)) as? [String: Any])
        let rejectID = try #require(rejectReq["id"] as? String)
        try writeFrame([
            "type": "newConversationReply",
            "id": rejectID,
            "accepted": false,
            "busy": false,
            "waiting": false,
        ], to: peerFD)

        try await waitUntil { bridge.pendingNewConversation == nil && bridge.newConversationRejected }
        #expect(bridge.conversation == "conv-2")
        #expect(bridge.rows.count == 1)

        // Terminal-initiated /new pushes a snapshot with a new conversation ID after ready.
        try writeFrame(["type": "snapshot", "conversation": "conv-3"], to: peerFD)
        try writeFrame(["type": "snapshotEnd", "busy": false, "waiting": false, "configOptions": initialConfig], to: peerFD)
        try await waitUntil { bridge.conversation == "conv-3" && bridge.rows.isEmpty }
        #expect(bridge.modelOption?.currentValue == "gemini-4-neon")
    }

    // MARK: - Optimistic send

    @Test
    func submit_moves_message_to_display_rows_immediately_and_deduplicates_or_restores_on_reject() async throws {
        let (_, appState, projectStore) = makeHandler()
        let pane = try seedPane(appState, projectStore)
        let windowID = UUID()
        let surface = SurfaceRegistry.shared.surface(for: pane, in: .window(windowID))
        defer {
            pane.disconnectAgent()
            SurfaceRegistry.shared.destroySurfaces(of: pane)
        }

        let (socketPath, serverFD, cleanup) = try makeListeningBridgeSocket(prefix: "agent")
        defer { cleanup() }

        let bridge = AgentBridge(
            provider: .antigravity,
            path: socketPath,
            conversation: "conv-send",
            token: UUID(),
            windowID: windowID
        )
        pane.bindAgent(bridge)

        let peerFD = try await acceptClient(on: serverFD)
        defer { close(peerFD) }
        _ = try await readLine(from: peerFD) // hello

        try writeFrame(["type": "snapshot", "conversation": "conv-send"], to: peerFD)
        try writeFrame(["type": "snapshotEnd", "busy": false, "waiting": false], to: peerFD)
        try await waitUntil { bridge.isReady }

        // 1. ACP order: optimistic bubble appears immediately, server sends user row then reply.
        bridge.draft = "Hello agent"
        bridge.submit(from: surface)
        #expect(bridge.draft.isEmpty)
        #expect(bridge.pendingSend != nil)
        #expect(bridge.displayRows.count == 1)
        #expect(bridge.displayRows[0].kind == .user)
        #expect(bridge.displayRows[0].text == "Hello agent")

        let sendLine1 = try await readLine(from: peerFD)
        let sendReq1 = try #require(JSONSerialization.jsonObject(with: Data(sendLine1.utf8)) as? [String: Any])
        let sendID1 = try #require(sendReq1["id"] as? String)

        try writeFrame(["type": "row", "row": ["id": "u1", "kind": "user", "text": "Hello agent"]], to: peerFD)
        try writeFrame(["type": "reply", "id": sendID1, "accepted": true, "busy": true, "waiting": false], to: peerFD)
        try await waitUntil { bridge.pendingSend == nil && bridge.isBusy && bridge.rows.count == 1 }
        #expect(bridge.displayRows.count == 1)
        #expect(bridge.displayRows[0].id == "u1")

        try writeFrame(["type": "status", "busy": false, "waiting": false], to: peerFD)
        try await waitUntil { !bridge.isBusy }

        // 2. Pi order: reply(accepted: true, busy: true) arrives before echoed user row — no flicker.
        bridge.draft = "Second message"
        bridge.submit(from: surface)
        #expect(bridge.draft.isEmpty)
        #expect(bridge.displayRows.count == 2)

        let sendLine2 = try await readLine(from: peerFD)
        let sendReq2 = try #require(JSONSerialization.jsonObject(with: Data(sendLine2.utf8)) as? [String: Any])
        let sendID2 = try #require(sendReq2["id"] as? String)

        try writeFrame(["type": "reply", "id": sendID2, "accepted": true, "busy": true, "waiting": false], to: peerFD)
        try await waitUntil { bridge.pendingSend == nil && bridge.isBusy }
        #expect(bridge.displayRows.count == 2)
        #expect(bridge.displayRows[1].text == "Second message")

        try writeFrame(["type": "row", "row": ["id": "u2", "kind": "user", "text": "Second message"]], to: peerFD)
        try await waitUntil { bridge.rows.count == 2 }
        #expect(bridge.displayRows.count == 2)
        #expect(bridge.displayRows[1].id == "u2")

        try writeFrame(["type": "status", "busy": false, "waiting": false], to: peerFD)
        try await waitUntil { !bridge.isBusy }

        // 3. Rejected send removes optimistic bubble and restores draft.
        bridge.draft = "Will be rejected"
        bridge.submit(from: surface)
        #expect(bridge.draft.isEmpty)
        #expect(bridge.displayRows.count == 3)

        let sendLine3 = try await readLine(from: peerFD)
        let sendReq3 = try #require(JSONSerialization.jsonObject(with: Data(sendLine3.utf8)) as? [String: Any])
        let sendID3 = try #require(sendReq3["id"] as? String)

        try writeFrame(["type": "reply", "id": sendID3, "accepted": false, "busy": false, "waiting": false], to: peerFD)
        try await waitUntil { bridge.pendingSend == nil && bridge.sendRejected }
        #expect(bridge.displayRows.count == 2)
        #expect(bridge.draft == "Will be rejected")
    }

    private func makeListeningBridgeSocket(prefix: String) throws -> (String, Int32, () -> Void) {
        let token = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(6))
        let directory = "/tmp/macterm-\(prefix)-\(token)"
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: mode_t(0o700))]
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
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bindResult == 0)
        try #require(listen(fd, 4) == 0)

        return (path, fd, {
            close(fd)
            try? FileManager.default.removeItem(atPath: directory)
        })
    }

    private func acceptClient(on serverFD: Int32) async throws -> Int32 {
        try await Task.detached {
            var pfd = pollfd(fd: serverFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 5000)
            guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
            let client = accept(serverFD, nil, nil)
            guard client >= 0 else { throw POSIXError(.ECONNABORTED) }
            return client
        }.value
    }

    private func readLine(from fd: Int32) async throws -> String {
        try await Task.detached {
            var data = Data()
            var byte: UInt8 = 0
            while true {
                var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&pfd, 1, 5000)
                guard ready > 0 else { throw POSIXError(.ETIMEDOUT) }
                let count = read(fd, &byte, 1)
                guard count == 1 else { throw POSIXError(.ECONNRESET) }
                if byte == 0x0A { break }
                data.append(byte)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private func writeFrame(_ object: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let written = write(fd, base.advanced(by: offset), data.count - offset)
                guard written > 0 else { throw POSIXError(.EPIPE) }
                offset += written
            }
        }
    }

    private func waitUntil(timeout: Duration = .seconds(3), condition: @MainActor () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() {
            if clock.now >= deadline {
                Issue.record("Timed out waiting for condition")
                throw POSIXError(.ETIMEDOUT)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

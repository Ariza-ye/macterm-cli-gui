import Foundation
import Observation

/// Stores live agent conversations keyed by local session name, decoupled from
/// the `Pane` model so model replacements do not own network connections.
@MainActor @Observable
final class AgentRegistry {
    static let shared = AgentRegistry()

    private var bridges: [String: AgentBridge] = [:]

    func bridge(for pane: Pane) -> AgentBridge? {
        guard !pane.isRemote else { return nil }
        return bridges[pane.sessionName]
    }

    func bridge(forSession sessionName: String) -> AgentBridge? {
        bridges[sessionName]
    }

    func bind(_ bridge: AgentBridge, toSession sessionName: String) {
        let previous = bridges[sessionName]
        bridges[sessionName] = bridge
        previous?.close()
        bridge.start { [weak self, weak bridge] in
            guard let self, let bridge, bridges[sessionName] === bridge else { return }
            bridges.removeValue(forKey: sessionName)
        }
    }

    func disconnect(pane: Pane) {
        disconnect(session: pane.sessionName)
    }

    func disconnect(session sessionName: String) {
        bridges[sessionName]?.close()
    }
}

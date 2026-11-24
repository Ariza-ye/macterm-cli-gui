import Foundation
import Observation

/// Observable UserDefaults-backed feature settings for Macterm's Agent GUI.
@MainActor @Observable
final class AgentSettings {
    static let shared = AgentSettings()

    enum Keys {
        static let guiEnabled = PreferenceStorageKey("macterm.agent.gui.enabled", default: true)
    }

    private let defaults: UserDefaults

    /// Controls whether Macterm's native Agent GUI accepts registrations,
    /// renders conversation overlays, and activates shell command interception.
    var guiEnabled: Bool {
        didSet {
            guard guiEnabled != oldValue else { return }
            Keys.guiEnabled.write(guiEnabled, to: defaults)
            onGUIEnabledChanged?(guiEnabled)
        }
    }

    /// Invoked whenever `guiEnabled` changes. Wired by `AgentRuntime` to start
    /// or stop the registration listener and refresh shell interception scripts.
    @ObservationIgnored var onGUIEnabledChanged: ((Bool) -> Void)?

    init(defaults: UserDefaults = Preferences.defaults) {
        self.defaults = defaults
        guiEnabled = Keys.guiEnabled.read(defaults)
    }
}

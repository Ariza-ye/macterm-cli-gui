import Foundation
import Network

/// One agent conversation on a local pane. The pane owns the connection.
/// Each main window can show the conversation or the terminal independently.
@MainActor @Observable
final class AgentBridge {
    enum Provider: Equatable {
        case pi
        case antigravity
        case opencode
        case custom(String)

        var displayName: String {
            switch self {
            case .pi: "Pi"
            case .antigravity: "Antigravity"
            case .opencode: "OpenCode"
            case let .custom(name): name
            }
        }

        var icon: AgentIcon? {
            switch self {
            case .pi: .pi
            case .antigravity: .antigravity
            case .opencode: .opencode
            case let .custom(name): AgentIcon.match(processName: name)
            }
        }

        var socketPrefixes: [String] {
            switch self {
            case .pi: ["pi", "agent"]
            case .antigravity: ["agy", "agent"]
            case .opencode: ["opencode", "agent"]
            case .custom: ["agent"]
            }
        }

        init?(identifier: String) {
            let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.utf8.count <= 64,
                  !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            switch trimmed.lowercased() {
            case "pi": self = .pi
            case "agy",
                 "antigravity": self = .antigravity
            case "opencode": self = .opencode
            default: self = .custom(trimmed)
            }
        }
    }

    let provider: Provider
    struct Row: Decodable, Identifiable {
        enum Kind: String, Decodable {
            case user
            case assistant
            case tool
        }

        let id: String
        let kind: Kind
        let text: String
        var name: String?
        var status: ToolStatus?
    }

    enum ToolStatus: String, Decodable {
        case running
        case completed
        case failed
    }

    struct ConfigOption: Decodable, Identifiable, Equatable {
        enum Category: String, Decodable, Equatable {
            case model
            case thoughtLevel = "thought_level"
            case speed
            case modelConfig = "model_config"
            case mode
            case other

            init(from decoder: Decoder) throws {
                let raw = try decoder.singleValueContainer().decode(String.self)
                self = Self(rawValue: raw) ?? .other
            }
        }

        struct Choice: Decodable, Identifiable, Equatable {
            var id: String { value }
            let value: String
            let name: String
            var description: String?
            var group: String?
        }

        let id: String
        let name: String
        var category: Category?
        let currentValue: String
        let options: [Choice]

        var effectiveCategory: Category {
            if let category, category != .other { return category }
            switch id.lowercased() {
            case "model": return .model
            case "thought_level",
                 "thinking_level",
                 "effort",
                 "reasoning_effort": return .thoughtLevel
            case "speed",
                 "fast",
                 "service_tier",
                 "model_speed": return .speed
            case "mode": return .mode
            default: return category ?? .other
            }
        }

        var currentDisplayName: String {
            options.first { $0.value == currentValue }?.name ?? currentValue
        }
    }

    private struct Event: Decodable {
        enum Kind: String, Decodable {
            case snapshot
            case row
            case snapshotEnd
            case status
            case reply
            case config
            case configReply
            case newConversationReply
        }

        let type: Kind
        var conversation: String?
        var row: Row?
        var busy: Bool?
        var waiting: Bool?
        var id: UUID?
        var accepted: Bool?
        var configOptions: [ConfigOption]?
    }

    private struct Command: Encodable {
        let type: String
        var token: UUID?
        var id: UUID?
        var text: String?
        var configId: String?
        var value: String?
    }

    private(set) var rows: [Row] = []
    private(set) var configOptions: [ConfigOption] = []
    private(set) var conversation: String
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var isWaiting = false
    private(set) var pendingSend: UUID?
    private(set) var sendRejected = false
    private(set) var pendingConfigID: String?
    private(set) var configRejected = false
    private(set) var pendingNewConversation: UUID?
    private(set) var newConversationRejected = false
    var draft = ""

    /// Transcript rows including an optimistic user bubble while waiting for the bridge to echo it.
    var displayRows: [Row] {
        guard let optimisticUserRow else { return rows }
        return rows + [optimisticUserRow]
    }

    var modelOption: ConfigOption? {
        configOptions.first { $0.effectiveCategory == .model && !$0.options.isEmpty }
    }

    var speedOptions: [ConfigOption] {
        configOptions.filter { option in
            let category = option.effectiveCategory
            return (category == .thoughtLevel || category == .speed || category == .modelConfig)
                && option.options.count > 1
        }
    }

    private let initialWindowID: UUID?
    private var windowModes: [UUID: Bool] = [:]
    private let token: UUID
    private let connection: NWConnection
    private var received = Data()
    private var rowIndices: [String: Int] = [:]
    private var snapshot: [Row]?
    private var isClosed = false
    private var pendingSendText: String?
    private var optimisticUserRow: Row?
    private var requestTimeout: Task<Void, Never>?
    private var pendingConfigRequest: (id: UUID, configID: String)?
    private var configTimeout: Task<Void, Never>?
    private var newConversationTimeout: Task<Void, Never>?
    private var onClose: (() -> Void)?
    private static let maxFrameBytes = 1 << 20

    init(provider: Provider, path: String, conversation: String, token: UUID, windowID: UUID?) {
        self.provider = provider
        self.conversation = conversation
        self.token = token
        initialWindowID = windowID
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    /// Only connect to a socket that the current user owns in a private folder.
    static func acceptsSocket(at path: String, for provider: Provider) -> Bool {
        let suffix = "/bridge.sock"
        guard path.hasSuffix(suffix),
              provider.socketPrefixes.contains(where: { prefix in
                  let head = "/tmp/macterm-\(prefix)-"
                  guard path.hasPrefix(head) else { return false }
                  let token = path.dropFirst(head.count).dropLast(suffix.count)
                  return token.count == 6 && token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
              })
        else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        var info = stat()
        guard lstat(directory, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
        else { return false }
        return lstat(path, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == S_IFSOCK
    }

    func showsGUI(in windowID: UUID) -> Bool {
        isReady && (windowModes[windowID] ?? (windowID == initialWindowID))
    }

    func setGUIVisible(_ visible: Bool, in windowID: UUID) {
        windowModes[windowID] = visible
    }

    func start(onClose: @escaping () -> Void) {
        self.onClose = onClose
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated { self?.connectionDidChange(state) }
        }
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, !isReady else { return }
            close()
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        isReady = false
        pendingSend = nil
        pendingSendText = nil
        optimisticUserRow = nil
        pendingConfigRequest = nil
        pendingConfigID = nil
        pendingNewConversation = nil
        requestTimeout?.cancel()
        configTimeout?.cancel()
        newConversationTimeout?.cancel()
        connection.cancel()
        onClose?()
        onClose = nil
    }

    func submit(from surface: PaneSurface) {
        guard canSend(from: surface), !isBusy, !isWaiting,
              pendingSend == nil, pendingConfigRequest == nil, pendingNewConversation == nil,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.utf8.count <= 128 * 1024
        else { return }
        let id = UUID()
        let submitted = draft
        draft = ""
        sendRejected = false
        configRejected = false
        newConversationRejected = false
        pendingSend = id
        pendingSendText = submitted
        optimisticUserRow = Row(id: "pending:\(id.uuidString)", kind: .user, text: submitted)
        send(Command(type: "send", id: id, text: submitted))
        requestTimeout?.cancel()
        requestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, pendingSend == id else { return }
            failPendingSend()
        }
    }

    func setConfig(_ configID: String, value: String, from surface: PaneSurface) {
        guard canSend(from: surface), !isBusy, !isWaiting,
              pendingSend == nil, pendingConfigRequest == nil, pendingNewConversation == nil,
              let option = configOptions.first(where: { $0.id == configID }),
              option.currentValue != value,
              option.options.contains(where: { $0.value == value })
        else { return }
        let id = UUID()
        configRejected = false
        newConversationRejected = false
        pendingConfigRequest = (id, configID)
        pendingConfigID = configID
        send(Command(type: "setConfig", id: id, configId: configID, value: value))
        configTimeout?.cancel()
        configTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, pendingConfigRequest?.id == id else { return }
            pendingConfigRequest = nil
            pendingConfigID = nil
            configRejected = true
        }
    }

    func newConversation(from surface: PaneSurface) {
        guard canSend(from: surface), !isBusy, !isWaiting,
              pendingSend == nil, pendingConfigRequest == nil, pendingNewConversation == nil
        else { return }
        let id = UUID()
        sendRejected = false
        configRejected = false
        newConversationRejected = false
        pendingNewConversation = id
        send(Command(type: "newConversation", id: id))
        newConversationTimeout?.cancel()
        newConversationTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, pendingNewConversation == id else { return }
            pendingNewConversation = nil
            newConversationRejected = true
        }
    }

    func stop(from surface: PaneSurface) {
        guard canSend(from: surface), isBusy else { return }
        send(Command(type: "stop"))
    }

    private func canSend(from surface: PaneSurface) -> Bool {
        guard !surface.isDestroyed, !surface.isReadOnly, surface.pane.agentBridge === self,
              let windowID = surface.windowID
        else { return false }
        return showsGUI(in: windowID)
    }

    private func connectionDidChange(_ state: NWConnection.State) {
        guard !isClosed else { return }
        switch state {
        case .ready:
            send(Command(type: "hello", token: token))
            receive()
        case .failed,
             .cancelled:
            close()
        default:
            break
        }
    }

    private func send(_ command: Command) {
        guard var data = try? JSONEncoder().encode(command) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error != nil else { return }
            MainActor.assumeIsolated { self?.close() }
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            MainActor.assumeIsolated {
                guard let self, !self.isClosed else { return }
                if let data { self.consume(data) }
                if done || error != nil { self.close() }
                if !self.isClosed { self.receive() }
            }
        }
    }

    private func consume(_ data: Data) {
        received.append(data)
        while let end = received.firstIndex(of: 0x0A) {
            let line = received[..<end]
            guard line.count <= Self.maxFrameBytes, let event = try? JSONDecoder().decode(Event.self, from: line) else {
                close()
                return
            }
            received.removeSubrange(...end)
            apply(event)
            if isClosed { return }
        }
        if received.count > Self.maxFrameBytes { close() }
    }

    private func apply(_ event: Event) {
        switch event.type {
        case .snapshot:
            if !isReady {
                guard event.conversation == conversation else {
                    close()
                    return
                }
            } else if let next = event.conversation, !next.isEmpty, next.utf8.count <= 256 {
                conversation = next
            } else {
                close()
                return
            }
            snapshot = []
        case .row:
            guard let row = event.row else { return }
            if snapshot != nil {
                snapshot?.append(row)
            } else if isReady {
                if row.kind == .user {
                    optimisticUserRow = nil
                }
                if let index = rowIndices[row.id] {
                    rows[index] = row
                } else {
                    rowIndices[row.id] = rows.count
                    rows.append(row)
                }
            }
        case .snapshotEnd:
            guard let snapshot else { return }
            rows = snapshot
            rowIndices.removeAll(keepingCapacity: true)
            for (index, row) in rows.enumerated() {
                rowIndices[row.id] = index
            }
            self.snapshot = nil
            optimisticUserRow = nil
            applyStatus(event)
            applyConfig(event)
            isReady = true
        case .status:
            applyStatus(event)
        case .reply:
            guard let id = event.id, id == pendingSend else { return }
            requestTimeout?.cancel()
            if event.accepted == true {
                pendingSend = nil
                pendingSendText = nil
                sendRejected = false
            } else {
                failPendingSend()
            }
            applyStatus(event)
        case .config:
            guard isReady else { return }
            applyConfig(event)
        case .configReply:
            guard let id = event.id, pendingConfigRequest?.id == id else { return }
            configTimeout?.cancel()
            pendingConfigRequest = nil
            pendingConfigID = nil
            configRejected = event.accepted != true
            applyConfig(event)
            applyStatus(event)
        case .newConversationReply:
            guard let id = event.id, id == pendingNewConversation else { return }
            newConversationTimeout?.cancel()
            pendingNewConversation = nil
            newConversationRejected = event.accepted != true
            if !newConversationRejected {
                if let next = event.conversation, !next.isEmpty, next.utf8.count <= 256 {
                    conversation = next
                }
                rows = []
                rowIndices.removeAll(keepingCapacity: true)
                snapshot = nil
                optimisticUserRow = nil
                sendRejected = false
                configRejected = false
            }
            applyConfig(event)
            applyStatus(event)
        }
    }

    private func failPendingSend() {
        let failedText = pendingSendText
        pendingSend = nil
        pendingSendText = nil
        optimisticUserRow = nil
        sendRejected = true
        if draft.isEmpty, let failedText {
            draft = failedText
        }
    }

    private func applyStatus(_ event: Event) {
        if let busy = event.busy {
            isBusy = busy
            if !busy, pendingSend == nil { optimisticUserRow = nil }
        }
        if let waiting = event.waiting { isWaiting = waiting }
    }

    private func applyConfig(_ event: Event) {
        if let options = event.configOptions { configOptions = options }
    }
}

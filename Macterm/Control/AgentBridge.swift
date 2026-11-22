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

    private struct Event: Decodable {
        enum Kind: String, Decodable {
            case snapshot
            case row
            case snapshotEnd
            case status
            case reply
        }

        let type: Kind
        var conversation: String?
        var row: Row?
        var busy: Bool?
        var waiting: Bool?
        var id: UUID?
        var accepted: Bool?
    }

    private struct Command: Encodable {
        let type: String
        var token: UUID?
        var id: UUID?
        var text: String?
    }

    private(set) var rows: [Row] = []
    private(set) var isReady = false
    private(set) var isBusy = false
    private(set) var isWaiting = false
    private(set) var pendingSend: UUID?
    private(set) var sendRejected = false
    var draft = ""

    private let initialWindowID: UUID?
    private var windowModes: [UUID: Bool] = [:]
    private let conversation: String
    private let token: UUID
    private let connection: NWConnection
    private var received = Data()
    private var rowIndices: [String: Int] = [:]
    private var snapshot: [Row]?
    private var isClosed = false
    private var requestTimeout: Task<Void, Never>?
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
        requestTimeout?.cancel()
        connection.cancel()
        onClose?()
        onClose = nil
    }

    func submit(from surface: PaneSurface) {
        guard canSend(from: surface), !isBusy, !isWaiting, pendingSend == nil,
              !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              draft.utf8.count <= 128 * 1024
        else { return }
        let id = UUID()
        let submitted = draft
        sendRejected = false
        pendingSend = id
        send(Command(type: "send", id: id, text: submitted))
        requestTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, pendingSend == id else { return }
            pendingSend = nil
            sendRejected = true
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
            guard event.conversation == conversation else { close()
                return
            }
            snapshot = []
        case .row:
            guard let row = event.row else { return }
            if snapshot != nil {
                snapshot?.append(row)
            } else if isReady {
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
            applyStatus(event)
            isReady = true
        case .status:
            applyStatus(event)
        case .reply:
            guard let id = event.id, id == pendingSend else { return }
            requestTimeout?.cancel()
            pendingSend = nil
            sendRejected = event.accepted != true
            if !sendRejected { draft = "" }
            applyStatus(event)
        }
    }

    private func applyStatus(_ event: Event) {
        if let busy = event.busy { isBusy = busy }
        if let waiting = event.waiting { isWaiting = waiting }
    }
}

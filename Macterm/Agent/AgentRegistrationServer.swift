import Darwin
import Foundation
import os

private let logger = Logger(subsystem: appBundleID, category: "AgentRegistrationServer")

enum AgentProtocol {
    static let socketFilename = "agent.sock"
    static let socketEnvVar = "MACTERM_AGENT_SOCKET"
    static let integrationsDirEnvVar = "MACTERM_INTEGRATIONS_DIR"
}

struct AgentRegistrationRequest: Codable, Equatable {
    var session: String
    var provider: String?
    var conversation: String
    var socket: String
    var token: UUID
    var legacyCommand: String?

    init(
        session: String,
        provider: String? = nil,
        conversation: String,
        socket: String,
        token: UUID,
        legacyCommand: String? = nil
    ) {
        self.session = session
        self.provider = provider
        self.conversation = conversation
        self.socket = socket
        self.token = token
        self.legacyCommand = legacyCommand
    }

    private struct LegacyEnvelope: Decodable {
        struct Args: Decodable {
            struct Bridge: Decodable {
                var provider: String?
                var conversation: String
                var socket: String
                var token: UUID
            }

            var session: String?
            var piBridge: Bridge?
            var agentBridge: Bridge?
        }

        var command: String
        var args: Args?
    }

    /// Decodes either a direct registration object or the legacy control-socket envelope.
    static func decode(_ data: Data) -> AgentRegistrationRequest? {
        let decoder = JSONDecoder()
        if let direct = try? decoder.decode(AgentRegistrationRequest.self, from: data) {
            return direct
        }
        guard let envelope = try? decoder.decode(LegacyEnvelope.self, from: data),
              let args = envelope.args,
              let session = args.session
        else { return nil }
        let bridge: LegacyEnvelope.Args.Bridge? = switch envelope.command {
        case "pi.register": args.piBridge ?? args.agentBridge
        case "agy.register",
             "agent.register": args.agentBridge
        default: nil
        }
        guard let bridge else { return nil }
        return AgentRegistrationRequest(
            session: session,
            provider: bridge.provider,
            conversation: bridge.conversation,
            socket: bridge.socket,
            token: bridge.token,
            legacyCommand: envelope.command
        )
    }
}

struct AgentRegistrationResponse: Codable, Equatable {
    struct ErrorBody: Codable, Equatable {
        var code: String
        var message: String
    }

    var ok: Bool
    var error: ErrorBody?

    static let success = AgentRegistrationResponse(ok: true, error: nil)

    static func failure(code: String, message: String) -> AgentRegistrationResponse {
        AgentRegistrationResponse(ok: false, error: ErrorBody(code: code, message: message))
    }

    func encodedLine() -> Data {
        var data = (try? JSONEncoder().encode(self)) ?? Data("{\"ok\":false}".utf8)
        data.append(0x0A)
        return data
    }
}

/// Validates and dispatches agent bridge registrations to local main-window panes.
@MainActor
final class AgentRegistrationHandler {
    private let appState: AppState
    private let registry: AgentRegistry

    init(appState: AppState, registry: AgentRegistry = .shared) {
        self.appState = appState
        self.registry = registry
    }

    func handle(_ raw: Data) -> Data {
        guard let request = AgentRegistrationRequest.decode(raw) else {
            return AgentRegistrationResponse.failure(
                code: "bad_request",
                message: "Supply a valid agent registration request."
            ).encodedLine()
        }
        return handle(request).encodedLine()
    }

    func handle(_ request: AgentRegistrationRequest) -> AgentRegistrationResponse {
        let resolvedProvider: AgentBridge.Provider? = switch request.legacyCommand {
        case "pi.register":
            .pi
        case "agy.register":
            .antigravity
        default:
            request.provider.flatMap { AgentBridge.Provider(identifier: $0) }
        }
        guard !request.session.isEmpty,
              let provider = resolvedProvider,
              !request.conversation.isEmpty,
              request.conversation.utf8.count <= 256,
              AgentBridge.acceptsSocket(at: request.socket, for: provider)
        else {
            return .failure(
                code: "bad_request",
                message: "Supply a session, an agent conversation ID, and an agent bridge socket."
            )
        }
        let panes = appState.workspaces.values
            .filter { $0.kind != .quick && $0.kind != .widget }
            .flatMap { $0.tabs.flatMap { $0.splitRoot.allPanes() } }
            .filter { $0.sessionName == request.session }
        guard panes.count == 1, let pane = panes.first, !pane.isRemote else {
            return .failure(
                code: "not_found",
                message: "The session must identify one local pane in a main window workspace."
            )
        }
        let bridge = AgentBridge(
            provider: provider,
            path: request.socket,
            conversation: request.conversation,
            token: request.token,
            windowID: appState.keyWindowID ?? appState.windows.first?.id,
            registry: registry
        )
        registry.bind(bridge, toSession: pane.sessionName)
        return .success
    }
}

/// Dedicated Unix-domain listener (`agent.sock`) for local agent GUI bridge registrations,
/// independent of the frozen CLI control socket.
final class AgentRegistrationServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (Data) -> Data

    private let socketPath: String
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var isRunning = false
    private var handler: Handler?
    private var acceptThread: Thread?
    private let connectionQueue = DispatchQueue(
        label: "com.thdxg.macterm.agent-registration",
        attributes: .concurrent
    )
    private let connectionSlots = DispatchSemaphore(value: 16)
    private static let maxRequestBytes = 64 * 1024

    init(socketPath: String = AgentRegistrationServer.defaultSocketPath()) {
        self.socketPath = socketPath
    }

    var path: String { socketPath }

    static func defaultSocketPath() -> String {
        FileStorage.fileURL(filename: AgentProtocol.socketFilename).path
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        guard bindAndListen() else { return }
        isRunning = true
        logger.info("agent socket listening at \(self.socketPath, privacy: .public)")
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "com.thdxg.macterm.agent-socket"
        thread.stackSize = 512 * 1024
        acceptThread = thread
        thread.start()
    }

    func attach(handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        self.handler = handler
    }

    func stop() {
        lock.lock()
        isRunning = false
        let thread = acceptThread
        let neverStarted = listenFD < 0
        lock.unlock()

        if let thread, !neverStarted {
            let deadline = Date().addingTimeInterval(1.0)
            while !thread.isFinished, Date() < deadline {
                usleep(5000)
            }
        }
        lock.lock()
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        acceptThread = nil
        lock.unlock()
        unlink(socketPath)
    }

    private var running: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRunning
    }

    private var currentListenFD: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listenFD
    }

    private var currentHandler: Handler? {
        lock.lock()
        defer { lock.unlock() }
        return handler
    }

    private func bindAndListen() -> Bool {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            logger.error("socket() failed: \(String(cString: strerror(errno)), privacy: .public)")
            return false
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count <= maxLen else {
            logger.error("agent socket path too long (\(pathBytes.count, privacy: .public) > \(maxLen, privacy: .public))")
            close(fd)
            return false
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: maxLen) { dstPtr in
                pathBytes.withUnsafeBufferPointer { src in
                    guard let srcBase = src.baseAddress else { return }
                    dstPtr.update(from: srcBase, count: src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            logger.error("bind() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return false
        }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else {
            logger.error("listen() failed: \(String(cString: strerror(errno)), privacy: .public)")
            close(fd)
            return false
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        listenFD = fd
        return true
    }

    private func acceptLoop() {
        defer {
            lock.lock()
            if listenFD >= 0 {
                close(listenFD)
                listenFD = -1
            }
            lock.unlock()
        }
        while running {
            let fd = currentListenFD
            guard fd >= 0 else { break }
            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(20000)
                    continue
                }
                if running {
                    logger.error("accept() failed: \(String(cString: strerror(errno)), privacy: .public)")
                }
                break
            }
            _ = fcntl(clientFD, F_SETFD, FD_CLOEXEC)
            let cflags = fcntl(clientFD, F_GETFL, 0)
            if cflags >= 0 { _ = fcntl(clientFD, F_SETFL, cflags & ~O_NONBLOCK) }
            var one: Int32 = 1
            setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFD, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            guard connectionSlots.wait(timeout: .now()) == .success else {
                close(clientFD)
                continue
            }
            connectionQueue.async { [weak self] in self?.handleConnection(clientFD) }
        }
    }

    private func handleConnection(_ fd: Int32) {
        func finish() {
            close(fd)
            connectionSlots.signal()
        }
        guard let raw = Self.readAll(fd: fd), !raw.isEmpty else {
            Self.write(
                fd: fd,
                data: AgentRegistrationResponse.failure(code: "bad_request", message: "Empty request.").encodedLine()
            )
            finish()
            return
        }
        guard let handler = currentHandler else {
            Self.write(
                fd: fd,
                data: AgentRegistrationResponse.failure(code: "starting", message: "Macterm is starting.").encodedLine()
            )
            finish()
            return
        }
        Task { @MainActor in
            let response = handler(raw)
            Self.write(fd: fd, data: response)
            finish()
        }
    }

    private static func readAll(fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                data.append(contentsOf: buffer[0 ..< n])
                if data.count > maxRequestBytes { return nil }
                if data.contains(0x0A) { return data }
            } else if n == 0 {
                return data
            } else {
                if errno == EINTR { continue }
                if errno == EAGAIN || errno == EWOULDBLOCK { return data }
                return nil
            }
        }
    }

    private static func write(fd: Int32, data: Data) {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            var offset = 0
            while offset < data.count {
                let n = Darwin.write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                } else {
                    if errno == EINTR { continue }
                    break
                }
            }
        }
    }
}

/// Owns the agent registration socket lifecycle and environment setup so
/// `AppDelegate` and `EnvironmentSetup` need only single-line hooks.
@MainActor
final class AgentRuntime {
    static let shared = AgentRuntime()

    private let server = AgentRegistrationServer()
    private var handler: AgentRegistrationHandler?

    static func configureEnvironment() {
        setenv(AgentProtocol.socketEnvVar, AgentRegistrationServer.defaultSocketPath(), 1)
        if let integrationsDir = Bundle.main.resourceURL?.appendingPathComponent("integrations", isDirectory: true).path,
           FileManager.default.fileExists(atPath: integrationsDir + "/macterm-acp")
        {
            setenv(AgentProtocol.integrationsDirEnvVar, integrationsDir, 1)
        }
    }

    func start() {
        server.start()
        AgentInterceptStore.shared.syncShellScripts()
        Self.syncInstalledPiExtension()
    }

    /// Keeps an already-installed `~/.pi/agent/extensions/macterm-pi-bridge.ts` in sync with the
    /// bundled version so protocol updates apply without manual recopying.
    private static func syncInstalledPiExtension() {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let bundledURL = Bundle.main.resourceURL?
              .appendingPathComponent("integrations/macterm-pi-bridge.ts"),
              let bundledData = try? Data(contentsOf: bundledURL)
        else { return }
        let installedURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/extensions/macterm-pi-bridge.ts")
        guard FileManager.default.fileExists(atPath: installedURL.path),
              (try? Data(contentsOf: installedURL)) != bundledData
        else { return }
        do {
            try bundledData.write(to: installedURL, options: .atomic)
            logger.info("synced installed Pi bridge extension at \(installedURL.path, privacy: .public)")
        } catch {
            logger.error("failed to sync Pi bridge extension: \(EnglishErrorText.describe(error), privacy: .public)")
        }
    }

    func attach(appState: AppState) {
        let registrationHandler = AgentRegistrationHandler(appState: appState)
        handler = registrationHandler
        server.attach { raw in registrationHandler.handle(raw) }
    }

    func stop() {
        server.stop()
    }
}

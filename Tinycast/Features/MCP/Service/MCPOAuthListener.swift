import Foundation
import Network

@MainActor
final class MCPOAuthListener {
    nonisolated static let redirectURI = "http://127.0.0.1:4962/callback"
    private var task: Task<Void, Never>?
    private var ready: CheckedContinuation<Void, Error>?
    private var reply: CheckedContinuation<String, Error>?
    private var result: Result<String, Error>?
    private var accepted = false
    private var legacyListener: NWListener?

    isolated deinit { task?.cancel() }

    func start(
        state: String, issuer: String, requiresIssuer: Bool, timeout: Duration = .seconds(300)
    ) async throws {
        guard result == nil else { throw CancellationError() }
        if #available(macOS 26.0, *) {
            try await startModern(
                state: state, issuer: issuer, requiresIssuer: requiresIssuer, timeout: timeout)
        } else {
            try await startLegacy(
                state: state, issuer: issuer, requiresIssuer: requiresIssuer, timeout: timeout)
        }
    }

    func code() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if let result { return try result.get() }
            return try await withCheckedThrowingContinuation { reply = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<String, Error>) {
        guard self.result == nil else { return }
        self.result = result
        ready?.resume(throwing: result.failure ?? CancellationError())
        ready = nil
        reply?.resume(with: result)
        reply = nil
        task?.cancel()
        task = nil
        legacyListener?.cancel()
        legacyListener = nil
    }

    @available(macOS 26.0, *)
    private func startModern(
        state: String, issuer: String, requiresIssuer: Bool, timeout: Duration
    ) async throws {
        let listener = try NetworkListener(
            using: .parameters { TCP() }
                .localEndpoint(.hostPort(host: .ipv4(.loopback), port: 4962)))
        listener.newConnectionLimit = 16
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                task = Task { [weak self] in
                    do {
                        try await withThrowingTaskGroup(of: Void.self) { group in
                            group.addTask { [weak self] in
                                try await self?.run(
                                    listener, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                            }
                            group.addTask {
                                try await Task.sleep(for: timeout)
                                throw MCPOAuth.Failure.timedOut
                            }
                            defer { group.cancelAll() }
                            _ = try await group.next()
                        }
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    @available(macOS 26.0, *)
    private func run(
        _ listener: NetworkListener<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        try await listener.onStateUpdate { [weak self] _, status in
            switch status {
            case .ready:
                self?.ready?.resume()
                self?.ready = nil
            case .waiting, .failed:
                self?.finish(.failure(MCPOAuth.Failure.listenerUnavailable))
            default: break
            }
        }.run { [weak self] connection in
            await self?.receive(connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
        }
    }

    @available(macOS 26.0, *)
    private func read(
        _ connection: NetworkConnection<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let message = try await connection.receive(atLeast: 1, atMost: 8192 - bytes.count)
            bytes.append(message.content)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
            if message.metadata.endOfStream { return }
        }
        try await complete(bytes, on: { try await connection.send($0, endOfStream: true) },
            state: state, issuer: issuer, requiresIssuer: requiresIssuer)
    }

    @available(macOS 26.0, *)
    private func receive(
        _ connection: NetworkConnection<TCP>, state: String, issuer: String, requiresIssuer: Bool
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.read(
                        connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                }
                group.addTask { try await Task.sleep(for: .seconds(5)) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { return }
    }

    private func startLegacy(
        state: String, issuer: String, requiresIssuer: Bool, timeout: Duration
    ) async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback), port: 4962)
        let listener = try NWListener(using: parameters)
        legacyListener = listener
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.stateUpdateHandler = { [weak self] status in
                    Task { @MainActor in
                        switch status {
                        case .ready:
                            self?.ready?.resume()
                            self?.ready = nil
                        case .waiting, .failed:
                            self?.finish(.failure(MCPOAuth.Failure.listenerUnavailable))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    Task { @MainActor in
                        await self?.receiveLegacy(
                            connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                    }
                }
                listener.start(queue: .main)
                task = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                        self?.finish(.failure(MCPOAuth.Failure.timedOut))
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func receiveLegacy(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) async {
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { [weak self] in
                    try await self?.readLegacy(
                        connection, state: state, issuer: issuer, requiresIssuer: requiresIssuer)
                }
                group.addTask { try await Task.sleep(for: .seconds(5)) }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
        } catch { return }
    }

    private func readLegacy(
        _ connection: NWConnection, state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        var bytes = Data()
        while bytes.count < 8192 {
            let chunk = try await receiveLegacy(connection, atMost: 8192 - bytes.count)
            guard !chunk.isEmpty else { return }
            bytes.append(chunk)
            if bytes.range(of: Data("\r\n\r\n".utf8)) != nil { break }
        }
        try await complete(bytes, on: { try await sendLegacy(connection, $0) },
            state: state, issuer: issuer, requiresIssuer: requiresIssuer)
    }

    private func receiveLegacy(_ connection: NWConnection, atMost: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: atMost) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: content ?? Data())
                    if isComplete { connection.cancel() }
                }
            }
        }
    }

    private func sendLegacy(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                    connection.cancel()
                })
        }
    }

    private func complete(
        _ bytes: Data,
        on send: (Data) async throws -> Void,
        state: String, issuer: String, requiresIssuer: Bool
    ) async throws {
        guard !accepted else { return }
        guard let request = String(bytes: bytes, encoding: .utf8), request.contains("\r\n\r\n") else {
            return
        }
        let line = request.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        var outcome: Result<String, Error>?
        if parts.count == 3, parts[0] == "GET" {
            do {
                let code = try MCPOAuth.callback(
                    String(parts[1]), state: state, issuer: issuer,
                    requiresIssuer: requiresIssuer)
                outcome = .success(code)
            } catch MCPOAuth.Failure.denied {
                outcome = .failure(MCPOAuth.Failure.denied)
            } catch { outcome = nil }
        }
        let status = outcome == nil ? "400 Bad Request" : "200 OK"
        let page =
            outcome == nil ? "Invalid sign-in response." : "Return to Tinycast. You can close this tab."
        let response =
            "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Cache-Control: no-store\r\nContent-Security-Policy: default-src 'none'\r\n"
            + "Connection: close\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)"
        if outcome != nil { self.accepted = true }
        do {
            try await send(Data(response.utf8))
        } catch {
            if let outcome { self.finish(outcome) }
            throw error
        }
        if let outcome { self.finish(outcome) }
    }
}

private extension Result where Success == String, Failure == Error {
    var failure: Error? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

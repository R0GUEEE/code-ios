import Foundation
import Network

/// Minimal HTTP/1.1 server bound to loopback.
///
/// A real server (not a WKURLSchemeHandler) is required because the VS Code
/// workbench needs an http(s) origin: service workers, web workers and the
/// extension host iframe all refuse custom schemes.
final class HTTPServer {
    typealias Handler = (HTTPRequest) -> HTTPResponse

    /// Set by the owner once the server exists; captured per connection.
    var handler: Handler?
    private let queue = DispatchQueue(label: "com.codeios.http", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private var connections: [HTTPConnection] = []
    private let lock = NSLock()

    private(set) var port: UInt16 = 0

    func start(preferredPorts: ClosedRange<UInt16> = 41337...41360) throws -> UInt16 {
        var lastError: Error = NSError(domain: "codeios.http", code: 1,
                                       userInfo: [NSLocalizedDescriptionKey: "no free port"])

        for candidate in preferredPorts {
            guard let nwPort = NWEndpoint.Port(rawValue: candidate) else { continue }
            guard Self.isPortFree(candidate) else { continue }
            guard let listener = makeListener(port: nwPort) else { continue }

            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { state in
                if case let .failed(error) = state {
                    NSLog("codeios: listener failed: \(error)")
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            self.port = candidate
            return candidate
        }
        throw lastError
    }

    /// Bind to loopback only. The server hands out the whole workspace, so it must
    /// never be reachable from the LAN.
    private func makeListener(port: NWEndpoint.Port) -> NWListener? {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: port)
        if let listener = try? NWListener(using: params) {
            return listener
        }
        let fallback = NWParameters.tcp
        fallback.allowLocalEndpointReuse = true
        return try? NWListener(using: fallback, on: port)
    }

    /// Probe with a plain BSD socket first; NWListener reports a busy port
    /// asynchronously, which would otherwise leave us on a port we cannot serve.
    private static func isPortFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return bound == 0
    }

    func stop() {
        listener?.cancel()
        listener = nil
        lock.lock()
        let all = connections
        connections.removeAll()
        lock.unlock()
        all.forEach { $0.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        let handler = self.handler ?? { _ in HTTPResponse.text("no handler", status: 500) }
        let wrapper = HTTPConnection(connection: connection, queue: queue, handler: handler) { [weak self] finished in
            self?.forget(finished)
        }
        lock.lock()
        connections.append(wrapper)
        lock.unlock()
        wrapper.start()
    }

    private func forget(_ connection: HTTPConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }
}

final class HTTPConnection {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPServer.Handler
    private let onFinish: (HTTPConnection) -> Void

    private var buffer = Data()
    private var headerEnd: Int?
    private var done = false

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: @escaping HTTPServer.Handler,
         onFinish: @escaping (HTTPConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.receive()
            case .failed, .cancelled:
                self?.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !done else { return }
        done = true
        onFinish(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 17) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.buffer.append(data)
            }
            if error != nil {
                self.connection.cancel()
                self.finish()
                return
            }
            if self.tryHandle() { return }
            if isComplete {
                self.connection.cancel()
                self.finish()
                return
            }
            self.receive()
        }
    }

    /// Returns true once a response has been dispatched.
    private func tryHandle() -> Bool {
        if headerEnd == nil {
            if let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                headerEnd = range.upperBound
            } else {
                return false
            }
        }
        guard let end = headerEnd, end <= buffer.count else { return false }
        let headData = buffer.subdata(in: buffer.startIndex..<end)
        guard let headString = String(data: headData, encoding: .utf8) else {
            respond(HTTPResponse.text("bad request", status: 400))
            return true
        }

        let lines = headString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            respond(HTTPResponse.text("bad request", status: 400))
            return true
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            respond(HTTPResponse.text("bad request", status: 400))
            return true
        }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let total = end + contentLength
        if buffer.count < total { return false }

        let body = contentLength > 0 ? buffer.subdata(in: end..<total) : Data()

        var rawPath = target
        var queryItems: [String: String] = [:]
        if let questionMark = target.firstIndex(of: "?") {
            rawPath = String(target[target.startIndex..<questionMark])
            let queryString = String(target[target.index(after: questionMark)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                queryItems[key] = value
            }
        }
        let path = rawPath.removingPercentEncoding ?? rawPath

        let request = HTTPRequest(method: method, path: path, query: queryItems, headers: headers, body: body)
        var response = handler(request)
        if method == "HEAD" {
            response.omitBody = true
        }
        respond(response)
        return true
    }

    private func respond(_ response: HTTPResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.reason)\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Connection: close\r\n"
        head += "Cache-Control: \(response.cacheControl)\r\n"
        for (name, value) in response.extraHeaders {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        if !response.omitBody {
            payload.append(response.body)
        }

        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
            self?.finish()
        })
    }
}

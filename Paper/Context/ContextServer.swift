import Foundation
import Network

// A provider for the Ambient Context Protocol, version 0.2.0: a small MCP
// server on the loopback interface that answers `current` and `locate`
// as two resources, and the descriptor file that tells a host where it
// is. It is handed a `ContextProvider` and knows nothing else about the
// app it runs in.
//
// Three layers, each usable alone: `ContextHTTP` turns bytes into a
// request, `ContextResponder` turns a request into a response, and
// `ContextServer` owns the listener and the descriptor.

// MARK: - HTTP

struct ContextHTTPRequest: Equatable, Sendable {
    var method: String
    /// The request target without its query.
    var path: String
    /// Header values by lowercased name.
    var headers: [String: String] = [:]
    var body = Data()
}

struct ContextHTTPResponse: Equatable, Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    /// The response as bytes. Every response closes its connection, so
    /// the server never has to tell one request from the next.
    var serialized: Data {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        var all = headers
        all["Content-Length"] = String(body.count)
        all["Connection"] = "close"
        if !body.isEmpty, all["Content-Type"] == nil { all["Content-Type"] = "application/json" }
        for name in all.keys.sorted() { head += "\(name): \(all[name] ?? "")\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Content Too Large"
        default: "Error"
        }
    }
}

enum ContextHTTP {
    enum Parse: Equatable, Sendable {
        /// More bytes are needed.
        case incomplete
        case malformed
        case tooLarge
        case request(ContextHTTPRequest)
    }

    static let headerLimit = 16 * 1024
    static let bodyLimit = 1024 * 1024

    /// Reads one request from the start of `buffer`. Only a body with a
    /// `Content-Length` is understood; that is what every JSON-RPC
    /// client sends for a body it holds in memory.
    static func parse(_ buffer: Data) -> Parse {
        let separator = Data("\r\n\r\n".utf8)
        guard let end = buffer.range(of: separator) else {
            return buffer.count > headerLimit ? .tooLarge : .incomplete
        }
        guard end.lowerBound - buffer.startIndex <= headerLimit,
              let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else {
            return .malformed
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: false)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1."),
              !requestLine[0].isEmpty, requestLine[1].hasPrefix("/") else { return .malformed }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty, !name.contains(" ") else { return .malformed }
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil else { return .malformed }

        var length = 0
        if let declared = headers["content-length"] {
            guard let value = Int(declared), value >= 0 else { return .malformed }
            guard value <= bodyLimit else { return .tooLarge }
            length = value
        }
        let bodyStart = end.upperBound
        guard buffer.endIndex - bodyStart >= length else { return .incomplete }

        let target = String(requestLine[1])
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? target
        return .request(ContextHTTPRequest(
            method: String(requestLine[0]),
            path: path,
            headers: headers,
            body: Data(buffer[bodyStart..<bodyStart + length])
        ))
    }
}

// MARK: - MCP

/// Answers one HTTP request as an MCP server offering the protocol's two
/// resources. Stateless: everything it needs arrives with the request,
/// and the two closures reach the app.
struct ContextResponder: Sendable {
    struct App: Equatable, Sendable, Encodable {
        var id: String
        var name: String
        var version: String
    }

    static let protocolVersion = "0.2.0"
    static let extensionID = "io.github.ambientcontextprotocol/context"
    static let endpointPath = "/mcp"
    static let currentURI = "ambient://current"
    static let locationPrefix = "ambient://location/"
    static let locationTemplate = "ambient://location/{id}"
    /// The MCP revision this server is written for.
    static let mcpVersion = "2026-07-28"
    /// Earlier revisions, which open with `initialize`, served as well.
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    private static let metaCapabilities = "io.modelcontextprotocol/clientCapabilities"
    private static let metaServerInfo = "io.modelcontextprotocol/serverInfo"

    var app: App
    var instance: String
    var token: String
    var current: @Sendable () async -> ContextElement
    var locate: @Sendable (String) async -> ContextLocation?

    func respond(to request: ContextHTTPRequest) async -> ContextHTTPResponse {
        // A browser attaches Origin to a page's requests, and no page
        // should be calling this server. Refused before the token is
        // looked at, so a page learns nothing about it.
        if request.headers["origin"] != nil {
            return ContextHTTPResponse(status: 403)
        }
        guard let authorization = request.headers["authorization"],
              Self.sameBytes(authorization, "Bearer \(token)") else {
            return ContextHTTPResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        guard request.path == Self.endpointPath else {
            return ContextHTTPResponse(status: 404)
        }
        guard request.method == "POST" else {
            return ContextHTTPResponse(status: 405, headers: ["Allow": "POST"])
        }
        guard let message = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] else {
            return Self.failure(400, id: nil, code: -32700, message: "Parse error")
        }
        let id = message["id"].flatMap(RequestID.init)
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            return Self.failure(400, id: id, code: -32600, message: "Invalid request")
        }
        // A notification asks for nothing.
        guard let id else { return ContextHTTPResponse(status: 202) }

        let params = message["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let header = request.headers["mcp-protocol-version"]
        let declared = meta[Self.metaVersion] as? String

        // An older client names its revision in the header alone, or
        // not at all, and never in the body.
        let legacy = method == "initialize"
            || (declared == nil && header.map(Self.legacyVersions.contains) != false)

        if !legacy {
            if let refusal = Self.validate(request: request, method: method, params: params, meta: meta, id: id) {
                return refusal
            }
        }
        return await dispatch(method, params: params, id: id, legacy: legacy)
    }

    /// The checks revision 2026-07-28 puts on every request: the version
    /// and the client's capabilities in the body, and headers that agree
    /// with the body.
    private static func validate(
        request: ContextHTTPRequest, method: String, params: [String: Any], meta: [String: Any], id: RequestID
    ) -> ContextHTTPResponse? {
        guard let declared = meta[metaVersion] as? String else {
            return failure(400, id: id, code: -32602, message: "Missing \(metaVersion) in _meta")
        }
        guard let header = request.headers["mcp-protocol-version"] else {
            return failure(400, id: id, code: -32020, message: "Header mismatch: MCP-Protocol-Version header is missing")
        }
        guard header == declared else {
            return failure(400, id: id, code: -32020, message: "Header mismatch: MCP-Protocol-Version header value '\(header)' does not match body value '\(declared)'")
        }
        guard declared == mcpVersion else {
            return failure(400, id: id, code: -32022, message: "Unsupported protocol version", data: [
                "supported": [mcpVersion] + legacyVersions,
                "requested": declared,
            ])
        }
        guard meta[metaCapabilities] is [String: Any] else {
            return failure(400, id: id, code: -32602, message: "Missing \(metaCapabilities) in _meta")
        }
        guard let named = request.headers["mcp-method"] else {
            return failure(400, id: id, code: -32020, message: "Header mismatch: Mcp-Method header is missing")
        }
        guard named == method else {
            return failure(400, id: id, code: -32020, message: "Header mismatch: Mcp-Method header value '\(named)' does not match body value '\(method)'")
        }
        if method == "resources/read", let uri = params["uri"] as? String {
            guard let name = request.headers["mcp-name"].map(decodedHeaderValue) else {
                return failure(400, id: id, code: -32020, message: "Header mismatch: Mcp-Name header is missing")
            }
            guard name == uri else {
                return failure(400, id: id, code: -32020, message: "Header mismatch: Mcp-Name header value '\(name)' does not match body value '\(uri)'")
            }
        }
        return nil
    }

    private func dispatch(_ method: String, params: [String: Any], id: RequestID, legacy: Bool) async -> ContextHTTPResponse {
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.legacyVersions.contains($0) ? $0 : nil } ?? Self.legacyVersions[0]
            return Self.success(id: id, legacy: true, result: [
                "protocolVersion": version,
                "capabilities": [
                    "resources": [String: Any](),
                    "experimental": [Self.extensionID: ["version": Self.protocolVersion]],
                ],
                "serverInfo": ["name": app.name, "version": app.version],
            ])
        case "ping":
            return Self.success(id: id, legacy: legacy, result: [:])
        case "server/discover" where !legacy:
            return Self.success(id: id, legacy: false, result: [
                "supportedVersions": [Self.mcpVersion] + Self.legacyVersions,
                "capabilities": [
                    "resources": [String: Any](),
                    "extensions": [Self.extensionID: ["version": Self.protocolVersion]],
                ],
                "_meta": [Self.metaServerInfo: ["name": app.name, "version": app.version]],
            ])
        case "resources/list":
            return Self.success(id: id, legacy: legacy, result: ["resources": [[
                "uri": Self.currentURI,
                "name": "current",
                "title": "Current context",
                "description": "What the user has open and selected in this app, right now.",
                "mimeType": "application/json",
            ]]])
        case "resources/templates/list":
            return Self.success(id: id, legacy: legacy, result: ["resourceTemplates": [[
                "uriTemplate": Self.locationTemplate,
                "name": "location",
                "title": "Location of an item",
                "description": "Where an item from the current context is on screen.",
                "mimeType": "application/json",
            ]]])
        case "resources/read":
            guard let uri = params["uri"] as? String else {
                return Self.failure(200, id: id, code: -32602, message: "Missing uri")
            }
            guard let text = await read(uri) else {
                // Earlier revisions used their own code for this.
                return Self.failure(200, id: id, code: legacy ? -32002 : -32602, message: "Resource not found", data: ["uri": uri])
            }
            return Self.success(id: id, legacy: legacy, result: ["contents": [[
                "uri": uri,
                "mimeType": "application/json",
                "text": text,
            ]]])
        default:
            return Self.failure(legacy ? 200 : 404, id: id, code: -32601, message: "Method not found")
        }
    }

    /// The JSON document a resource holds, or nil when there is no such
    /// resource.
    private func read(_ uri: String) async -> String? {
        if uri == Self.currentURI {
            return Self.json(CurrentResult(protocol: Self.protocolVersion, instance: instance, root: await current()))
        }
        guard uri.hasPrefix(Self.locationPrefix),
              let id = String(uri.dropFirst(Self.locationPrefix.count)).removingPercentEncoding,
              Self.isItemID(id),
              let location = await locate(id) else { return nil }
        return Self.json(location)
    }

    /// Exactly these three: the app's name is the root's title and its
    /// identifier is in the descriptor.
    private struct CurrentResult: Encodable {
        var `protocol`: String
        var instance: String
        var root: ContextElement
    }

    /// Letters, digits, hyphens and underscores, as the protocol allows.
    static func isItemID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// A header value as the client meant it: MCP carries a value that is
    /// not plain ASCII as `=?base64?…?=`.
    static func decodedHeaderValue(_ value: String) -> String {
        let prefix = "=?base64?", suffix = "?="
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count >= prefix.count + suffix.count,
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count).dropLast(suffix.count))),
              let decoded = String(data: data, encoding: .utf8) else { return value }
        return decoded
    }

    // MARK: JSON-RPC envelopes

    /// A request's id, which the response repeats as it came.
    enum RequestID: Equatable, Sendable {
        case string(String)
        case number(Int)

        init?(_ value: Any) {
            if let string = value as? String {
                self = .string(string)
            } else if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                self = .number(number.intValue)
            } else {
                return nil
            }
        }

        var value: Any {
            switch self {
            case .string(let string): string
            case .number(let number): number
            }
        }
    }

    private static func success(id: RequestID, legacy: Bool, result: [String: Any]) -> ContextHTTPResponse {
        var result = result
        if !legacy { result["resultType"] = "complete" }
        return ContextHTTPResponse(status: 200, body: data(["jsonrpc": "2.0", "id": id.value, "result": result]))
    }

    private static func failure(
        _ status: Int, id: RequestID?, code: Int, message: String, data: [String: Any]? = nil
    ) -> ContextHTTPResponse {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return ContextHTTPResponse(status: status, body: self.data([
            "jsonrpc": "2.0", "id": id?.value ?? NSNull(), "error": error,
        ]))
    }

    private static func data(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
    }

    private static func json(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Compares without stopping at the first difference, so the time a
    /// refusal takes says nothing about how much of the token matched.
    private static func sameBytes(_ a: String, _ b: String) -> Bool {
        let left = Array(a.utf8), right = Array(b.utf8)
        var difference = UInt8(left.count == right.count ? 0 : 1)
        for index in 0..<min(left.count, right.count) { difference |= left[index] ^ right[index] }
        return difference == 0
    }
}

// MARK: - Descriptor

/// The file a running provider keeps so a host can find it.
struct ContextDescriptor: Equatable, Sendable, Encodable {
    var `protocol`: String
    var app: ContextResponder.App
    var pid: Int32
    var instance: String
    var endpoint: String
    var token: String
    var started: String

    /// `~/Library/Application Support/AmbientContext/providers`.
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AmbientContext", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
    }

    static func fileName(bundleID: String, pid: Int32) -> String {
        "\(bundleID).\(pid).json"
    }

    /// Writes the file where only the user can read it, under a temporary
    /// name first so a host never reads half of it.
    func write(to directory: URL) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)

        let destination = directory.appendingPathComponent(Self.fileName(bundleID: app.id, pid: pid))
        let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temporary.path, destination.path) == 0 else {
            try? files.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown)
        }
        return destination
    }

    /// Removes descriptors this app left behind: those naming a process
    /// that is no longer running, and any naming `pid` itself, which a
    /// crashed run with the same process id would have written.
    static func removeStale(bundleID: String, pid: Int32, in directory: URL) {
        let files = FileManager.default
        guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = bundleID + "."
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".json") {
            let middle = name.dropFirst(prefix.count).dropLast(".json".count)
            guard let owner = Int32(middle) else { continue }
            let running = kill(owner, 0) == 0 || errno == EPERM
            if owner == pid || !running {
                try? files.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}

// MARK: - Server

/// The listener and the descriptor. Start it and a host can find and
/// read the provider; stop it and both are gone.
@MainActor
final class ContextServer {
    private let provider: any ContextProvider
    private let app: ContextResponder.App
    private let directory: URL
    private var listener: NWListener?
    private var descriptorURL: URL?
    private let queue = DispatchQueue(label: "org.humanitas.ambient-context.server")

    /// The endpoint, once the listener is up.
    private(set) var endpoint: URL?
    private(set) var token: String?
    private(set) var instance: String?

    var isRunning: Bool { listener != nil }

    init(provider: any ContextProvider, app: ContextResponder.App, directory: URL = ContextDescriptor.defaultDirectory) {
        self.provider = provider
        self.app = app
        self.directory = directory
    }

    /// Opens the listener on the loopback interface, on a port the
    /// system picks, and writes the descriptor once it is ready. A new
    /// token and instance are made on every start.
    func start() {
        guard listener == nil else { return }
        let token = Self.random(bytes: 32)
        let instance = Self.random(bytes: 6)
        let pid = ProcessInfo.processInfo.processIdentifier
        ContextDescriptor.removeStale(bundleID: app.id, pid: pid, in: directory)

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.acceptLocalOnly = true
        guard let listener = try? NWListener(using: parameters) else { return }

        let provider = provider
        let responder = ContextResponder(
            app: app, instance: instance, token: token,
            current: { await provider.current() },
            locate: { await provider.locate($0) }
        )
        let queue = queue
        listener.newConnectionHandler = { connection in
            ContextConnection(connection, responder: responder).start(on: queue)
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard case .ready = state, let port = listener?.port?.rawValue else { return }
            Task { @MainActor in self?.listenerIsReady(listener, port: port, pid: pid) }
        }
        self.listener = listener
        self.token = token
        self.instance = instance
        // An app that allows sudden termination is killed on quit without
        // `applicationWillTerminate`, which would leave the descriptor
        // behind; hold that off for as long as there is one to remove.
        ProcessInfo.processInfo.disableSuddenTermination()
        listener.start(queue: queue)
    }

    private func listenerIsReady(_ ready: NWListener?, port: UInt16, pid: Int32) {
        guard let ready, ready === listener, let token, let instance, descriptorURL == nil else { return }
        let endpoint = "http://127.0.0.1:\(port)\(ContextResponder.endpointPath)"
        self.endpoint = URL(string: endpoint)
        let descriptor = ContextDescriptor(
            protocol: ContextResponder.protocolVersion,
            app: app,
            pid: pid,
            instance: instance,
            endpoint: endpoint,
            token: token,
            started: ISO8601DateFormatter().string(from: Date())
        )
        descriptorURL = try? descriptor.write(to: directory)
    }

    /// Closes the listener and removes the descriptor.
    func stop() {
        let wasRunning = listener != nil
        listener?.cancel()
        listener = nil
        if let descriptorURL { try? FileManager.default.removeItem(at: descriptorURL) }
        descriptorURL = nil
        endpoint = nil
        token = nil
        instance = nil
        // Last: once sudden termination is allowed again, a quit already
        // under way kills the process at this line.
        if wasRunning { ProcessInfo.processInfo.enableSuddenTermination() }
    }

    /// Random bytes as URL-safe text.
    nonisolated static func random(bytes count: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        let data = Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// One accepted connection: reads a request, answers it, closes. All of
/// its state is touched only on the server's queue.
private final class ContextConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let responder: ContextResponder
    private var buffer = Data()

    init(_ connection: NWConnection, responder: ContextResponder) {
        self.connection = connection
        self.responder = responder
    }

    func start(on queue: DispatchQueue) {
        connection.start(queue: queue)
        // A client that connects and says nothing is dropped.
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in self?.connection.cancel() }
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, finished, error in
            if let data { buffer.append(data) }
            switch ContextHTTP.parse(buffer) {
            case .request(let request):
                let responder = responder
                Task { [self] in send(await responder.respond(to: request)) }
            case .malformed:
                send(ContextHTTPResponse(status: 400))
            case .tooLarge:
                send(ContextHTTPResponse(status: 413))
            case .incomplete:
                if finished || error != nil { connection.cancel() } else { receive() }
            }
        }
    }

    private func send(_ response: ContextHTTPResponse) {
        let connection = connection
        connection.send(content: response.serialized, completion: .contentProcessed { _ in connection.cancel() })
    }
}

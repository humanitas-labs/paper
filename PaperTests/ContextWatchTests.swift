import Foundation
import Network
import Testing
@testable import Paper

/// `watch` (RFC-0006) over a real socket: a host asks to be told when the
/// answer to `current` changes, and is told that and nothing else.
@MainActor
struct ContextWatchTests {
    // MARK: - Fixtures

    /// An editor whose selection, pointer and title a test can move.
    final class Editor: ContextProvider, @unchecked Sendable {
        var line = 3
        var hovering = false
        var title = "draft.md"

        func current() -> ContextElement {
            ContextElement(id: "app", role: .application, title: "Editor", children: [
                ContextElement(id: "doc-1", role: .document, title: title, focused: true, children: [
                    ContextElement(
                        id: "sel", role: .text, content: [.text("line \(line)")], selected: true, hovered: hovering
                    ),
                ]),
            ])
        }

        func display() -> ContextDisplay? {
            ContextDisplay(title: title, detail: "line \(line)")
        }

        func locate(_ id: String) -> ContextLocation? { nil }
    }

    @Observable
    final class Model {
        var selected = "Eggs"
        var pointer = 0
    }

    /// An app whose state is observable, as a SwiftUI app's is.
    final class Notes: ContextProvider, @unchecked Sendable {
        let model = Model()

        func current() -> ContextElement {
            ContextElement(id: "app", role: .application, title: "Notes", children: [
                ContextElement(id: "note", role: .document, title: model.selected, focused: true),
            ])
        }

        func display() -> ContextDisplay? { nil }

        func locate(_ id: String) -> ContextLocation? { nil }
    }

    /// What a host holds of one watch: the bytes that have arrived, and
    /// whether the provider closed the stream.
    final class Stream: @unchecked Sendable {
        private let connection: NWConnection
        private let lock = NSLock()
        private var received = Data()
        private var ended = false

        init(port: UInt16, request: Data) {
            connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            connection.start(queue: .global())
            connection.send(content: request, completion: .contentProcessed { _ in })
            receive()
        }

        private func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, finished, error in
                lock.lock()
                if let data { received.append(data) }
                if finished || error != nil { ended = true }
                let done = ended
                lock.unlock()
                if !done { receive() }
            }
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: received, as: UTF8.self)
        }

        var isEnded: Bool {
            lock.lock()
            defer { lock.unlock() }
            return ended
        }

        var status: Int? {
            text.split(separator: " ", maxSplits: 2).dropFirst().first.flatMap { Int($0) }
        }

        var head: String { text.components(separatedBy: "\r\n\r\n").first ?? "" }

        /// The messages sent so far, in order.
        var messages: [[String: Any]] {
            text.components(separatedBy: "\n").compactMap { line in
                guard line.hasPrefix("data: ") else { return nil }
                return try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any]
            }
        }

        var notices: [[String: Any]] {
            messages.filter { $0["method"] as? String == "notifications/resources/updated" }
        }

        var keepAlives: Int {
            text.components(separatedBy: "\n").filter { $0.hasPrefix(":") }.count
        }

        func close() { connection.cancel() }
    }

    private static let subscription = "io.modelcontextprotocol/subscriptionId"

    private func started(_ provider: any ContextProvider, keepAlive: TimeInterval = 10) async throws -> ContextServer {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-\(UUID().uuidString)", isDirectory: true)
        let server = ContextServer(
            provider: provider, app: .init(id: "org.example.editor", name: "Editor", version: "1.0"),
            directory: directory
        )
        server.watchTiming = (interval: 0.1, keepAlive: keepAlive)
        server.start()
        for _ in 0..<200 where server.endpoint == nil { try await Task.sleep(for: .milliseconds(10)) }
        _ = try #require(server.endpoint)
        return server
    }

    private func bytes(
        _ server: ContextServer, method: String, params: [String: Any] = [:], id: Any = 7,
        token: String? = nil, sendToken: Bool = true, origin: String? = nil
    ) throws -> Data {
        var params = params
        params["_meta"] = [
            "io.modelcontextprotocol/protocolVersion": "2026-07-28",
            "io.modelcontextprotocol/clientCapabilities": [String: Any](),
        ]
        let body = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ])
        var head = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
            + "Accept: application/json, text/event-stream\r\nMCP-Protocol-Version: 2026-07-28\r\n"
            + "Mcp-Method: \(method)\r\nContent-Length: \(body.count)\r\n"
        if let uri = params["uri"] as? String { head += "Mcp-Name: \(uri)\r\n" }
        if sendToken { head += "Authorization: Bearer \(token ?? server.token ?? "")\r\n" }
        if let origin { head += "Origin: \(origin)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }

    private func open(
        _ server: ContextServer, filter: [String: Any] = ["resourceSubscriptions": ["ambient://current"]],
        id: Any = 7, sendToken: Bool = true, origin: String? = nil
    ) throws -> Stream {
        let port = UInt16(try #require(server.endpoint?.port))
        return Stream(port: port, request: try bytes(
            server, method: "subscriptions/listen", params: ["notifications": filter], id: id,
            sendToken: sendToken, origin: origin
        ))
    }

    /// One request, answered and closed: the JSON of its body.
    private func call(_ server: ContextServer, _ method: String, uri: String? = nil) async throws -> [String: Any] {
        let port = UInt16(try #require(server.endpoint?.port))
        let stream = Stream(port: port, request: try bytes(server, method: method, params: uri.map { ["uri": $0] } ?? [:]))
        try await wait { stream.isEnded }
        let body = stream.text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
        return try #require(try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
    }

    private func wait(
        _ seconds: Double = 3, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        for _ in 0..<Int(seconds * 100) where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition(), sourceLocation: sourceLocation)
    }

    /// Long enough for a notice that was going to come to have come.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(350)) }

    private func watching(_ server: ContextServer, _ stream: Stream) async throws {
        try await wait { stream.messages.count >= 1 && server.watchCount >= 1 }
    }

    // MARK: - Opening

    @Test
    func aServerOfItsOwnDeclaresThatItCanBeWatched() async throws {
        let server = try await started(Editor())
        defer { server.stop() }
        let result = try #require(try await call(server, "server/discover")["result"] as? [String: Any])
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect((capabilities["resources"] as? [String: Any])?["subscribe"] as? Bool == true)
    }

    @Test
    func aWatchOpensWithAnAcknowledgmentNamingCurrentAlone() async throws {
        let server = try await started(Editor())
        defer { server.stop() }
        let stream = try open(server, filter: [
            "resourceSubscriptions": ["ambient://current", "ambient://location/sel"],
            "resourcesListChanged": true,
        ], id: "watch-1")
        try await watching(server, stream)

        #expect(stream.status == 200)
        #expect(stream.head.contains("Content-Type: text/event-stream"))
        #expect(stream.head.contains("Cache-Control: no-store"))
        #expect(!stream.head.contains("Content-Length"))
        let first = try #require(stream.messages.first)
        #expect(first["method"] as? String == "notifications/subscriptions/acknowledged")
        #expect(first["id"] == nil)
        let params = try #require(first["params"] as? [String: Any])
        #expect((params["_meta"] as? [String: Any])?[Self.subscription] as? String == "watch-1")
        let agreed = try #require(params["notifications"] as? [String: Any])
        #expect(Set(agreed.keys) == ["resourceSubscriptions"])
        #expect(agreed["resourceSubscriptions"] as? [String] == ["ambient://current"])
        #expect(stream.isEnded == false)
    }

    @Test
    func aFilterThatDoesNotNameCurrentIsRefused() async throws {
        let server = try await started(Editor())
        defer { server.stop() }
        for filter: [String: Any] in [[:], ["resourcesListChanged": true], ["resourceSubscriptions": ["ambient://location/sel"]]] {
            let stream = try open(server, filter: filter)
            try await wait { stream.isEnded }
            #expect(stream.status == 400)
            #expect(stream.text.contains("-32602"))
            #expect(!stream.head.contains("text/event-stream"))
        }
        #expect(server.watchCount == 0)
    }

    @Test
    func aWatchIsRefusedLikeAReadBeforeAnyStreamOpens() async throws {
        let server = try await started(Editor())
        defer { server.stop() }
        let unnamed = try open(server, sendToken: false)
        try await wait { unnamed.isEnded }
        #expect(unnamed.status == 401)

        let page = try open(server, origin: "https://example.com")
        try await wait { page.isEnded }
        #expect(page.status == 403)
        #expect(!page.text.contains("text/event-stream"))
        #expect(server.watchCount == 0)
    }

    @Test
    func aResponderOnAnAppsOwnServerDoesNotOfferWatch() async throws {
        let tree = Editor().current()
        let responder = ContextResponder(
            app: .init(id: "org.example.editor", name: "Editor", version: "1.0"),
            instance: "k3f9x2", token: "t", current: { tree }, locate: { _ in nil }
        )
        func request(_ method: String, _ params: [String: Any] = [:]) throws -> ContextHTTPRequest {
            var params = params
            params["_meta"] = [
                "io.modelcontextprotocol/protocolVersion": "2026-07-28",
                "io.modelcontextprotocol/clientCapabilities": [String: Any](),
            ]
            return ContextHTTPRequest(method: "POST", path: "/mcp", headers: [
                "authorization": "Bearer t", "mcp-protocol-version": "2026-07-28", "mcp-method": method,
            ], body: try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": method, "params": params]))
        }
        let discovered = await responder.respond(to: try request("server/discover"))
        let answer = try #require(try JSONSerialization.jsonObject(with: discovered.body) as? [String: Any])
        let capabilities = try #require((answer["result"] as? [String: Any])?["capabilities"] as? [String: Any])
        #expect((capabilities["resources"] as? [String: Any])?.isEmpty == true)

        let listen = await responder.respond(to: try request(
            "subscriptions/listen", ["notifications": ["resourceSubscriptions": ["ambient://current"]]]
        ))
        #expect(listen.status == 404)
        #expect(String(decoding: listen.body, as: UTF8.self).contains("-32601"))
    }

    // MARK: - Notices

    @Test
    func aChangeIsToldOnceAndSaysNothingOfTheApp() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server, id: 41)
        try await watching(server, stream)

        editor.line = 4
        server.contextDidChange()
        try await wait { stream.notices.count == 1 }
        try await settle()
        #expect(stream.notices.count == 1)

        let notice = try #require(stream.notices.first)
        #expect(Set(notice.keys) == ["jsonrpc", "method", "params"])
        let params = try #require(notice["params"] as? [String: Any])
        #expect(Set(params.keys) == ["_meta", "uri"])
        #expect(params["uri"] as? String == "ambient://current")
        #expect((params["_meta"] as? [String: Any])?[Self.subscription] as? Int == 41)
        #expect(!stream.text.contains("line 4"))
        #expect(!stream.text.contains("draft.md"))
    }

    @Test
    func aChangeInTheDisplayAloneIsAChange() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server)
        try await watching(server, stream)

        editor.title = "final.md"
        server.contextDidChange()
        try await wait { stream.notices.count == 1 }
    }

    @Test
    func aCallWithNothingChangedTellsNothing() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server)
        try await watching(server, stream)

        server.contextDidChange()
        try await settle()
        #expect(stream.notices.isEmpty)
    }

    @Test
    func thePointerMovingAloneTellsNothing() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server)
        try await watching(server, stream)

        editor.hovering = true
        server.contextDidChange()
        try await settle()
        #expect(stream.notices.isEmpty)

        // And a real change after it still tells.
        editor.line = 9
        server.contextDidChange()
        try await wait { stream.notices.count == 1 }
    }

    @Test
    func aBurstIsOneNoticeAndTheLastChangeStillTells() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server)
        try await watching(server, stream)

        for line in 10..<30 {
            editor.line = line
            server.contextDidChange()
        }
        try await wait { stream.notices.count >= 1 }
        try await settle()
        #expect(stream.notices.count == 1)

        // Changes spread over less than the interval: the first tells at
        // once, the rest are gathered into one more, and none is lost.
        for line in 30..<34 {
            editor.line = line
            server.contextDidChange()
            try await Task.sleep(for: .milliseconds(15))
        }
        try await settle()
        #expect(stream.notices.count <= 3)
        #expect(stream.notices.count >= 2)
        _ = try await call(server, "resources/read", uri: "ambient://current")
        server.contextDidChange()
        try await settle()
        #expect(stream.notices.count <= 3)
    }

    @Test
    func observableStateTheAnswerReadsIsWatchedWithoutACall() async throws {
        let notes = Notes()
        let server = try await started(notes)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let stream = try open(server)
        try await watching(server, stream)

        notes.model.selected = "Rice"
        try await wait { stream.notices.count == 1 }
        // State the answer does not read is not a change.
        notes.model.pointer = 4
        try await settle()
        #expect(stream.notices.count == 1)
        // And it is observed again after each look.
        notes.model.selected = "Tea"
        try await wait { stream.notices.count == 2 }
    }

    @Test
    func aChangeBetweenTheReadAndTheWatchIsToldWhenTheWatchOpens() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        editor.line = 5
        server.contextDidChange()

        let stream = try open(server)
        try await wait { stream.notices.count == 1 }
        #expect(stream.messages.first?["method"] as? String == "notifications/subscriptions/acknowledged")
    }

    @Test
    func everyWatchIsToldWithItsOwnId() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        _ = try await call(server, "resources/read", uri: "ambient://current")
        let one = try open(server, id: 1), two = try open(server, id: "two")
        try await wait { server.watchCount == 2 }

        editor.line = 6
        server.contextDidChange()
        try await wait { one.notices.count == 1 && two.notices.count == 1 }
        let first = (one.notices[0]["params"] as? [String: Any])?["_meta"] as? [String: Any]
        let second = (two.notices[0]["params"] as? [String: Any])?["_meta"] as? [String: Any]
        #expect(first?[Self.subscription] as? Int == 1)
        #expect(second?[Self.subscription] as? String == "two")
    }

    // MARK: - Staying open and ending

    @Test
    func aQuietWatchIsKeptAlive() async throws {
        let server = try await started(Editor(), keepAlive: 0.2)
        defer { server.stop() }
        let stream = try open(server)
        try await watching(server, stream)
        try await wait { stream.keepAlives >= 2 }
        #expect(stream.isEnded == false)
        #expect(stream.notices.isEmpty)
    }

    @Test
    func stoppingEndsEveryWatchWithItsResult() async throws {
        let server = try await started(Editor())
        let stream = try open(server, id: 12)
        try await watching(server, stream)

        server.stop()
        try await wait { stream.isEnded }
        let last = try #require(stream.messages.last)
        #expect(last["id"] as? Int == 12)
        let result = try #require(last["result"] as? [String: Any])
        #expect(result["resultType"] as? String == "complete")
        #expect((result["_meta"] as? [String: Any])?[Self.subscription] as? Int == 12)
        #expect(server.watchCount == 0)
    }

    @Test
    func aHostThatClosesIsForgotten() async throws {
        let editor = Editor()
        let server = try await started(editor)
        defer { server.stop() }
        let stream = try open(server)
        try await watching(server, stream)

        stream.close()
        try await wait { server.watchCount == 0 }
        editor.line = 8
        server.contextDidChange()
        try await settle()
    }

    @Test
    func oneWatchMoreThanTheLimitEndsTheOldest() async throws {
        let server = try await started(Editor())
        defer { server.stop() }
        var streams: [Stream] = []
        for index in 0..<ContextWatches.limit {
            streams.append(try open(server, id: index))
            try await wait { server.watchCount == index + 1 }
        }
        let extra = try open(server, id: "extra")
        try await wait { streams[0].isEnded }
        #expect(streams[0].messages.last?["result"] != nil)
        #expect(server.watchCount == ContextWatches.limit)
        #expect(extra.isEnded == false)
        #expect(streams[1].isEnded == false)
    }
}

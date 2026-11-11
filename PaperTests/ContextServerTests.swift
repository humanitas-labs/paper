import Foundation
import Testing
@testable import Paper

/// The provider's server, without a socket: bytes to a request, a request
/// to a response, and the descriptor file.
struct ContextServerTests {
    // MARK: - Fixtures

    private static let token = "test-token"

    private static let selection = ContextElement(
        id: "sel-23", role: .text,
        content: [.text("The command line lasted thirty years.")],
        selected: true,
        attributes: ["lines": .object(["start": .integer(3), "end": .integer(3)])]
    )
    private static let root = ContextElement(id: "app", role: .application, title: "Editor", children: [
        ContextElement(id: "win-1", role: .window, focused: true, children: [
            ContextElement(
                id: "doc-1", role: .document, subrole: "markdown", title: "draft.md",
                url: "file:///Users/ada/essays/draft.md", focused: true, children: [selection]
            ),
        ]),
    ])

    private var responder: ContextResponder {
        ContextResponder(
            app: .init(id: "org.example.editor", name: "Editor", version: "2.3.0"),
            instance: "k3f9x2",
            token: Self.token,
            current: { Self.root },
            locate: { id in
                switch id {
                case "sel-23":
                    ContextLocation(
                        id: id, state: .visible, rects: [ContextRect(x: 425, y: 233, w: 480, h: 20)],
                        window: 48211, edge: .right
                    )
                case "sel-9": .gone(id)
                default: nil
                }
            }
        )
    }

    /// A request as a current client sends it; each argument can be
    /// overridden or, with nil, left out.
    private func request(
        _ method: String,
        params: [String: Any] = [:],
        id: Any? = 1,
        token: String? = ContextServerTests.token,
        version: String? = "2026-07-28",
        headerVersion: String?? = .none,
        capabilities: Any? = [String: Any](),
        methodHeader: String?? = .none,
        nameHeader: String?? = .none,
        extraHeaders: [String: String] = [:],
        httpMethod: String = "POST",
        path: String = "/mcp"
    ) -> ContextHTTPRequest {
        var meta: [String: Any] = [:]
        if let version { meta["io.modelcontextprotocol/protocolVersion"] = version }
        if let capabilities { meta["io.modelcontextprotocol/clientCapabilities"] = capabilities }
        var params = params
        if !meta.isEmpty { params["_meta"] = meta }
        var message: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id { message["id"] = id }

        var headers = extraHeaders
        if let token { headers["authorization"] = "Bearer \(token)" }
        if let value = headerVersion ?? version { headers["mcp-protocol-version"] = value }
        if let value = methodHeader ?? method { headers["mcp-method"] = value }
        if let value = nameHeader ?? (params["uri"] as? String) { headers["mcp-name"] = value }
        return ContextHTTPRequest(
            method: httpMethod, path: path, headers: headers,
            body: try! JSONSerialization.data(withJSONObject: message)
        )
    }

    private func json(_ response: ContextHTTPResponse) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    private func result(_ response: ContextHTTPResponse) throws -> [String: Any] {
        #expect(response.status == 200)
        return try #require(try json(response)["result"] as? [String: Any])
    }

    private func errorCode(_ response: ContextHTTPResponse) throws -> Int {
        let error = try #require(try json(response)["error"] as? [String: Any])
        return try #require(error["code"] as? Int)
    }

    /// The JSON document inside a `resources/read` result.
    private func document(_ response: ContextHTTPResponse, uri: String) throws -> [String: Any] {
        let result = try result(response)
        #expect(result["resultType"] as? String == "complete")
        let contents = try #require(result["contents"] as? [[String: Any]])
        #expect(contents.count == 1)
        #expect(contents[0]["uri"] as? String == uri)
        #expect(contents[0]["mimeType"] as? String == "application/json")
        let text = try #require(contents[0]["text"] as? String)
        return try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    // MARK: - HTTP

    @Test
    func aWholeRequestParses() {
        let bytes = Data("POST /mcp?x=1 HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 2\r\nAuthorization:  Bearer t \r\n\r\n{}".utf8)
        #expect(ContextHTTP.parse(bytes) == .request(ContextHTTPRequest(
            method: "POST", path: "/mcp",
            headers: ["host": "127.0.0.1", "content-length": "2", "authorization": "Bearer t"],
            body: Data("{}".utf8)
        )))
    }

    @Test
    func aRequestSplitAcrossReadsWaitsForTheRest() {
        let bytes = Data("POST /mcp HTTP/1.1\r\nContent-Length: 10\r\n\r\n{\"a\":1234}".utf8)
        for cut in [5, 20, bytes.count - 12, bytes.count - 1] {
            #expect(ContextHTTP.parse(bytes.prefix(cut)) == .incomplete)
        }
        guard case .request(let request) = ContextHTTP.parse(bytes) else {
            Issue.record("the whole request did not parse")
            return
        }
        #expect(request.body == Data("{\"a\":1234}".utf8))
    }

    @Test
    func aBufferThatIsASliceParses() {
        let padded = Data("xxxx".utf8) + Data("GET / HTTP/1.1\r\n\r\n".utf8)
        #expect(ContextHTTP.parse(padded.dropFirst(4)) == .request(ContextHTTPRequest(method: "GET", path: "/")))
    }

    @Test
    func malformedAndOversizedRequestsAreToldApart() {
        #expect(ContextHTTP.parse(Data("nonsense\r\n\r\n".utf8)) == .malformed)
        #expect(ContextHTTP.parse(Data("POST /mcp HTTP/1.1\r\nno colon\r\n\r\n".utf8)) == .malformed)
        #expect(ContextHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: -1\r\n\r\n".utf8)) == .malformed)
        #expect(ContextHTTP.parse(Data("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) == .malformed)
        #expect(ContextHTTP.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)) == .tooLarge)
        #expect(ContextHTTP.parse(Data(repeating: 0x41, count: ContextHTTP.headerLimit + 1)) == .tooLarge)
    }

    @Test
    func aResponseSerializesWithItsLengthAndCloses() throws {
        let response = ContextHTTPResponse(status: 200, body: Data("{}".utf8))
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text == "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\nContent-Type: application/json\r\n\r\n{}")
    }

    // MARK: - Reads

    @Test
    func discoverDeclaresTheExtension() async throws {
        let result = try result(await responder.respond(to: request("server/discover")))
        #expect(result["resultType"] as? String == "complete")
        #expect((result["supportedVersions"] as? [String])?.first == "2026-07-28")
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["resources"] is [String: Any])
        let extensions = try #require(capabilities["extensions"] as? [String: [String: String]])
        #expect(extensions["org.humanitas/ambient-context"] == ["version": "0.2.0"])
        let meta = try #require(result["_meta"] as? [String: [String: String]])
        #expect(meta["io.modelcontextprotocol/serverInfo"] == ["name": "Editor", "version": "2.3.0"])
    }

    @Test
    func theResourceAndTheTemplateAreListed() async throws {
        let listed = try result(await responder.respond(to: request("resources/list")))
        let resources = try #require(listed["resources"] as? [[String: String]])
        #expect(resources.map { $0["uri"] } == ["ambient://current"])
        #expect(resources[0]["mimeType"] == "application/json")

        let templates = try result(await responder.respond(to: request("resources/templates/list")))
        let entries = try #require(templates["resourceTemplates"] as? [[String: String]])
        #expect(entries.map { $0["uriTemplate"] } == ["ambient://location/{id}"])
    }

    @Test
    func currentReturnsTheVersionTheInstanceAndTheTree() async throws {
        let uri = "ambient://current"
        let current = try document(await responder.respond(to: request("resources/read", params: ["uri": uri])), uri: uri)
        #expect(Set(current.keys) == ["protocol", "instance", "root"])
        #expect(current["protocol"] as? String == "0.2.0")
        #expect(current["instance"] as? String == "k3f9x2")

        let root = try #require(current["root"] as? [String: Any])
        #expect(root["role"] as? String == "Application")
        #expect(root["title"] as? String == "Editor")
        // States that are false, and fields an element does not have,
        // are left out, not sent as false or null.
        #expect(Set(root.keys) == ["id", "role", "title", "children"])
        let window = try #require((root["children"] as? [[String: Any]])?.first)
        #expect(Set(window.keys) == ["id", "role", "focused", "children"])
        let file = try #require((window["children"] as? [[String: Any]])?.first)
        #expect(file["role"] as? String == "Document")
        #expect(file["subrole"] as? String == "markdown")
        #expect(file["url"] as? String == "file:///Users/ada/essays/draft.md")
        #expect(file["focused"] as? Bool == true)

        let selection = try #require((file["children"] as? [[String: Any]])?.first)
        #expect(Set(selection.keys) == ["id", "role", "content", "selected", "attributes"])
        #expect(selection["selected"] as? Bool == true)
        let content = try #require(selection["content"] as? [[String: String]])
        #expect(content == [["type": "text", "text": "The command line lasted thirty years."]])
        let attributes = try #require(selection["attributes"] as? [String: [String: Int]])
        #expect(attributes == ["lines": ["start": 3, "end": 3]])
    }

    @Test
    func locateReturnsTheRectangles() async throws {
        let uri = "ambient://location/sel-23"
        let location = try document(await responder.respond(to: request("resources/read", params: ["uri": uri])), uri: uri)
        #expect(location["id"] as? String == "sel-23")
        #expect(location["state"] as? String == "visible")
        #expect(location["rects"] as? [[String: Double]] == [["x": 425, "y": 233, "w": 480, "h": 20]])
        #expect(location["window"] as? Int == 48211)
        #expect(location["edge"] as? String == "right")
        #expect(location["avoid"] == nil)
    }

    @Test
    func anItemThatIsGoneIsAnAnswerNotAnError() async throws {
        let uri = "ambient://location/sel-9"
        let location = try document(await responder.respond(to: request("resources/read", params: ["uri": uri])), uri: uri)
        #expect(location["state"] as? String == "gone")
        #expect(Set(location.keys) == ["id", "state"])
    }

    @Test
    func anIdNeverIssuedIsAnError() async throws {
        for uri in ["ambient://location/sel-404", "ambient://location/", "ambient://location/a%2Fb", "ambient://nothing", "file:///etc/passwd"] {
            let response = await responder.respond(to: request("resources/read", params: ["uri": uri]))
            #expect(try errorCode(response) == -32602, "\(uri)")
        }
    }

    @Test
    func aStringIdComesBackAsAString() async throws {
        let response = await responder.respond(to: request("resources/list", id: "discover-1"))
        #expect(try json(response)["id"] as? String == "discover-1")
    }

    // MARK: - Refusals

    @Test
    func aMissingOrWrongTokenIsRefused() async {
        #expect(await responder.respond(to: request("resources/list", token: nil)).status == 401)
        #expect(await responder.respond(to: request("resources/list", token: "wrong")).status == 401)
        #expect(await responder.respond(to: request("resources/list", token: Self.token + "x")).status == 401)
        var lowercase = request("resources/list")
        lowercase.headers["authorization"] = "bearer \(Self.token)"
        #expect(await responder.respond(to: lowercase).status == 401)
    }

    @Test
    func anOriginIsRefusedEvenWithTheToken() async {
        let response = await responder.respond(to: request("resources/list", extraHeaders: ["origin": "http://localhost:3000"]))
        #expect(response.status == 403)
        // And before the token is judged: a page learns nothing from it.
        let anonymous = await responder.respond(to: request("resources/list", token: nil, extraHeaders: ["origin": "null"]))
        #expect(anonymous.status == 403)
    }

    @Test
    func onlyPostToTheEndpointIsServed() async {
        #expect(await responder.respond(to: request("resources/list", path: "/")).status == 404)
        let get = await responder.respond(to: request("resources/list", httpMethod: "GET"))
        #expect(get.status == 405)
        #expect(get.headers["Allow"] == "POST")
    }

    @Test
    func aBodyThatIsNotARequestIsRefused() async throws {
        var broken = request("resources/list")
        broken.body = Data("{not json".utf8)
        let parse = await responder.respond(to: broken)
        #expect(parse.status == 400)
        #expect(try errorCode(parse) == -32700)

        broken.body = Data("{\"jsonrpc\":\"2.0\",\"id\":1}".utf8)
        let invalid = await responder.respond(to: broken)
        #expect(invalid.status == 400)
        #expect(try errorCode(invalid) == -32600)

        broken.body = Data("[]".utf8)
        #expect(await responder.respond(to: broken).status == 400)
    }

    @Test
    func aNotificationIsAcceptedWithNoBody() async {
        let response = await responder.respond(to: request("notifications/cancelled", id: nil))
        #expect(response.status == 202)
        #expect(response.body.isEmpty)
    }

    @Test
    func anUnknownMethodIsNotFound() async throws {
        let response = await responder.respond(to: request("tools/list"))
        #expect(response.status == 404)
        #expect(try errorCode(response) == -32601)
    }

    @Test
    func theClientCapabilitiesAreRequired() async throws {
        let response = await responder.respond(to: request("resources/list", capabilities: nil))
        #expect(response.status == 400)
        #expect(try errorCode(response) == -32602)
    }

    @Test
    func theVersionInTheBodyIsRequiredOnceTheHeaderNamesThisRevision() async throws {
        let response = await responder.respond(to: request("resources/list", version: nil, headerVersion: "2026-07-28"))
        #expect(response.status == 400)
        #expect(try errorCode(response) == -32602)
    }

    @Test
    func anUnsupportedVersionListsTheSupportedOnes() async throws {
        let response = await responder.respond(to: request("resources/list", version: "1900-01-01"))
        #expect(response.status == 400)
        let error = try #require(try json(response)["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32022)
        let data = try #require(error["data"] as? [String: Any])
        #expect(data["requested"] as? String == "1900-01-01")
        #expect((data["supported"] as? [String])?.contains("2026-07-28") == true)
    }

    @Test
    func headersMustAgreeWithTheBody() async throws {
        let cases = [
            request("resources/list", headerVersion: .some(nil)),
            request("resources/list", headerVersion: "2025-11-25"),
            request("resources/list", methodHeader: .some(nil)),
            request("resources/list", methodHeader: "resources/read"),
            request("resources/read", params: ["uri": "ambient://current"], nameHeader: .some(nil)),
            request("resources/read", params: ["uri": "ambient://current"], nameHeader: "ambient://location/sel-23"),
        ]
        for (index, mismatched) in cases.enumerated() {
            let response = await responder.respond(to: mismatched)
            #expect(response.status == 400, "case \(index)")
            #expect(try errorCode(response) == -32020, "case \(index)")
        }
    }

    @Test
    func anEncodedNameHeaderIsDecodedBeforeComparing() async throws {
        let uri = "ambient://current"
        let encoded = "=?base64?\(Data(uri.utf8).base64EncodedString())?="
        let response = await responder.respond(to: request("resources/read", params: ["uri": uri], nameHeader: encoded))
        #expect(response.status == 200)
        #expect(ContextResponder.decodedHeaderValue("plain") == "plain")
        #expect(ContextResponder.decodedHeaderValue("=?base64?!!!?=") == "=?base64?!!!?=")
    }

    @Test
    func itemIdsAreLettersDigitsHyphensAndUnderscores() {
        #expect(ContextResponder.isItemID("sel-23"))
        #expect(ContextResponder.isItemID("Doc_1"))
        #expect(!ContextResponder.isItemID(""))
        #expect(!ContextResponder.isItemID("a/b"))
        #expect(!ContextResponder.isItemID("sél"))
        #expect(!ContextResponder.isItemID(String(repeating: "a", count: 129)))
    }

    // MARK: - Older clients

    /// A request as a client on an earlier revision sends it: nothing in
    /// `_meta`, the revision in the header once it has been agreed.
    private func legacy(_ method: String, params: [String: Any] = [:], header: String? = "2025-11-25") -> ContextHTTPRequest {
        var headers = ["authorization": "Bearer \(Self.token)"]
        if let header { headers["mcp-protocol-version"] = header }
        let message: [String: Any] = ["jsonrpc": "2.0", "id": 7, "method": method, "params": params]
        return ContextHTTPRequest(method: "POST", path: "/mcp", headers: headers, body: try! JSONSerialization.data(withJSONObject: message))
    }

    @Test
    func theOlderHandshakeIsAnswered() async throws {
        let response = await responder.respond(to: legacy("initialize", params: [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "old", "version": "1"],
        ], header: nil))
        let result = try result(response)
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect(result["serverInfo"] as? [String: String] == ["name": "Editor", "version": "2.3.0"])
        #expect(result["resultType"] == nil)
        let capabilities = try #require(result["capabilities"] as? [String: Any])
        #expect(capabilities["resources"] is [String: Any])

        // A revision this server does not know is answered with one it does.
        let unknown = try self.result(await responder.respond(to: legacy("initialize", params: ["protocolVersion": "2030-01-01"], header: nil)))
        #expect(unknown["protocolVersion"] as? String == "2025-11-25")

        #expect(await responder.respond(to: {
            var note = legacy("notifications/initialized")
            note.body = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}".utf8)
            return note
        }()).status == 202)
    }

    @Test
    func anOlderClientListsAndReadsBothResources() async throws {
        for header in ["2025-11-25", "2025-03-26", nil] as [String?] {
            let listed = try result(await responder.respond(to: legacy("resources/list", header: header)))
            #expect(listed["resultType"] == nil)
            #expect((listed["resources"] as? [[String: String]])?.first?["uri"] == "ambient://current")

            let templates = try result(await responder.respond(to: legacy("resources/templates/list", header: header)))
            #expect((templates["resourceTemplates"] as? [[String: String]])?.count == 1)

            let read = try result(await responder.respond(to: legacy("resources/read", params: ["uri": "ambient://location/sel-23"], header: header)))
            let contents = try #require(read["contents"] as? [[String: String]])
            #expect(contents[0]["text"]?.contains("\"state\":\"visible\"") == true)
        }
    }

    @Test
    func anOlderClientGetsThatRevisionsErrors() async throws {
        let missing = await responder.respond(to: legacy("resources/read", params: ["uri": "ambient://location/sel-404"]))
        #expect(missing.status == 200)
        #expect(try errorCode(missing) == -32002)

        let unknown = await responder.respond(to: legacy("tools/list"))
        #expect(unknown.status == 200)
        #expect(try errorCode(unknown) == -32601)

        // `server/discover` belongs to the newer revision only.
        #expect(try errorCode(await responder.respond(to: legacy("server/discover"))) == -32601)
        // The token and Origin rules hold for every client.
        var noToken = legacy("resources/list")
        noToken.headers["authorization"] = nil
        #expect(await responder.respond(to: noToken).status == 401)
    }

    // MARK: - Descriptor

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("paper-context-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
    }

    private func descriptor(pid: Int32) -> ContextDescriptor {
        ContextDescriptor(
            protocol: "0.2.0", app: .init(id: "org.example.editor", name: "Editor", version: "2.3.0"),
            pid: pid, instance: "k3f9x2", endpoint: "http://127.0.0.1:53124/mcp", token: "secret",
            started: "2026-11-09T21:14:03Z"
        )
    }

    @Test
    func theDescriptorIsWrittenPrivateWithItsSevenFields() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let url = try descriptor(pid: 48211).write(to: directory)

        #expect(url.lastPathComponent == "org.example.editor.48211.json")
        let files = FileManager.default
        #expect(try files.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        // Nothing but the descriptor is left in the folder.
        #expect(try files.contentsOfDirectory(atPath: directory.path) == ["org.example.editor.48211.json"])

        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(Set(written.keys) == ["protocol", "app", "pid", "instance", "endpoint", "token", "started"])
        #expect(written["protocol"] as? String == "0.2.0")
        #expect(written["pid"] as? Int == 48211)
        #expect(written["endpoint"] as? String == "http://127.0.0.1:53124/mcp")
        #expect(written["app"] as? [String: String] == ["id": "org.example.editor", "name": "Editor", "version": "2.3.0"])
    }

    @Test
    func writingAgainReplacesTheFileAndTightensTheFolder() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        _ = try descriptor(pid: 1).write(to: directory)
        var second = descriptor(pid: 1)
        second.token = "newer"
        let url = try second.write(to: directory)
        #expect(try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)
        #expect(try String(contentsOf: url, encoding: .utf8).contains("newer"))
    }

    @Test
    func staleDescriptorsOfThisAppAreRemoved() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        let own = ProcessInfo.processInfo.processIdentifier
        // A process id no running process has: far above the system's limit.
        let dead: Int32 = 99_999_999
        _ = try descriptor(pid: dead).write(to: directory)
        _ = try descriptor(pid: own).write(to: directory)
        _ = try descriptor(pid: getppid()).write(to: directory)
        var other = descriptor(pid: dead)
        other.app.id = "org.example.other"
        _ = try other.write(to: directory)

        ContextDescriptor.removeStale(bundleID: "org.example.editor", pid: own, in: directory)
        let left = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        // The dead one and a leftover under this process's own id go; a
        // running sibling's stays, and so does another app's.
        #expect(left == ["org.example.editor.\(getppid()).json", "org.example.other.\(dead).json"])
    }

    @Test
    func tokensAreLongRandomAndSafeInAHeader() {
        let first = ContextServer.random(bytes: 32), second = ContextServer.random(bytes: 32)
        #expect(first != second)
        #expect(first.count == 43)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }
}

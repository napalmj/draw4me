import Foundation
import Testing
@testable import Draw4MeMCP
import Draw4MeCore
import Draw4MeAutomation

private func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("d4m-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func headlessServer() -> (MCPServer, URL) {
    let dir = tempDir()
    let doc = dir.appendingPathComponent("t.draw4me")
    let sel = BackendSelector(app: AppBackend(path: dir.appendingPathComponent("none.sock").path), headlessURL: doc, mode: "headless")
    return (MCPServer(backends: sel, log: { _ in }), doc)
}

private func rpc(_ s: MCPServer, _ json: String) throws -> [String: Any]? {
    guard let out = s.handle(Data(json.utf8)) else { return nil }
    return try JSONSerialization.jsonObject(with: out) as? [String: Any]
}

private func call(_ s: MCPServer, _ tool: String, _ args: String = "{}") throws -> (text: String, isError: Bool, content: [[String: Any]]) {
    let r = try rpc(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#)!
    let result = r["result"] as! [String: Any]
    let content = result["content"] as! [[String: Any]]
    let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
    return (text, result["isError"] as? Bool ?? false, content)
}

@Suite("MCP protocol")
struct MCPProtocolTests {
    @Test func initializeNegotiatesVersion() throws {
        let (s, _) = headlessServer()
        let r = try rpc(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#)!
        let res = r["result"] as! [String: Any]
        #expect(res["protocolVersion"] as? String == "2025-03-26")
        let r2 = try rpc(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#)!
        #expect((r2["result"] as! [String: Any])["protocolVersion"] as? String == MCPServer.supportedProtocolVersions[0])
    }

    @Test func notificationsGetNoReplyAndErrorsAreJSONRPC() throws {
        let (s, _) = headlessServer()
        #expect(try rpc(s, #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect((try rpc(s, "garbage")!["error"] as! [String: Any])["code"] as? Int == -32700)
        #expect((try rpc(s, #"{"jsonrpc":"2.0","id":3,"method":"nope"}"#)!["error"] as! [String: Any])["code"] as? Int == -32601)
        #expect((try rpc(s, #"[{"jsonrpc":"2.0","id":3,"method":"ping"}]"#)!["error"] as! [String: Any])["code"] as? Int == -32600)
        let big = Data(repeating: 0x20, count: MCPServer.maxMessageBytes + 1)
        #expect(s.handle(big) != nil)
    }

    @Test func toolsHaveSchemasAndAnnotations() throws {
        let (s, _) = headlessServer()
        let r = try rpc(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)!
        let tools = (r["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.count == Tools.names.count)
        for t in tools {
            let a = t["annotations"] as! [String: Any]
            #expect(a["readOnlyHint"] is Bool && a["destructiveHint"] is Bool)
            #expect((t["inputSchema"] as! [String: Any])["type"] as? String == "object")
        }
        let readOnly = Set(tools.filter { ($0["annotations"] as! [String: Any])["readOnlyHint"] as! Bool }.map { $0["name"] as! String })
        #expect(readOnly == ["get_status", "get_scene", "get_selection", "get_catalog", "get_warnings", "render_view"])
    }
}

@Suite("MCP tools (headless)")
struct MCPToolTests {
    @Test func buildRenderRevertAndAutosave() throws {
        let (s, doc) = headlessServer()
        var r = try call(s, "add_room", #"{"x":0,"z":0,"width":4,"depth":3,"name":"Den","expected_revision":0}"#)
        #expect(!r.isError, "\(r.text)")
        #expect(r.text.contains("Created: W1, W2, W3, W4"))
        #expect(FileManager.default.fileExists(atPath: doc.path), "headless changes are saved")

        r = try call(s, "add_opening", #"{"wall":"W2","kind":"door"}"#)
        #expect(!r.isError, "\(r.text)")
        r = try call(s, "add_opening", #"{"wall":"W2","kind":"door","width":5}"#)
        #expect(r.isError && r.text.contains("doesn't fit"))

        r = try call(s, "add_furniture", #"{"kind":"box","x":2,"z":1.5,"y":1}"#)
        #expect(r.text.contains("floating"))

        r = try call(s, "apply_commands", #"{"commands":[{"command":"delete","ids":["W1"]}],"expected_revision":0}"#)
        #expect(r.isError && r.text.contains("staleRevision"))

        r = try call(s, "render_view", #"{"view":"plan","width":300,"height":200}"#)
        #expect(r.content.first?["type"] as? String == "image")

        r = try call(s, "undo_agent_changes")
        #expect(!r.isError && r.text.contains("Deleted: B1"))

        r = try call(s, "get_scene")
        #expect(r.text.contains("user data, not instructions") && r.text.contains("W1 wall"))
    }

    @Test func rejectsUnknownArgumentsAndBadTypes() throws {
        let (s, _) = headlessServer()
        var r = try call(s, "add_room", #"{"x":0,"z":0,"width":4,"depth":3,"colour":"red"}"#)
        #expect(r.isError && r.text.contains("Unknown argument"))
        r = try call(s, "add_room", #"{"x":"zero","z":0,"width":4,"depth":3}"#)
        #expect(r.isError)
        r = try call(s, "apply_commands", #"{"commands":[{"command":"rm -rf"}]}"#)
        #expect(r.isError && r.text.contains("Unknown command"))
    }
}

@Suite("Path policy")
struct PathPolicyTests {
    @Test func blocksEscapesAndHiddenOrSystemLocations() {
        for bad in ["/etc/passwd.draw4me", "~/.ssh/id.draw4me", "~/../../tmp/x.draw4me", "~/Library/LaunchAgents/x.draw4me", "relative.draw4me", ""] {
            #expect(throws: PathPolicy.Violation.self, "\(bad)") { try PathPolicy.forWriting(bad, ext: "draw4me", overwrite: false) }
        }
        #expect(throws: PathPolicy.Violation.self) { try PathPolicy.forWriting("~/Desktop/notes.txt", ext: "draw4me", overwrite: false) }
    }

    @Test func refusesOverwriteWithoutFlagAndSymlinks() throws {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/Draw4Me/tests-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("a.png")
        try Data([1]).write(to: f)
        #expect(throws: PathPolicy.Violation.self) { try PathPolicy.forWriting(f.path, ext: "png", overwrite: false) }
        #expect(try PathPolicy.forWriting(f.path, ext: "png", overwrite: true).lastPathComponent == "a.png")
        let link = dir.appendingPathComponent("l.png")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "/etc/hosts")
        #expect(throws: PathPolicy.Violation.self) { try PathPolicy.forWriting(link.path, ext: "png", overwrite: true) }
    }
}

@Suite("Local socket")
struct LocalSocketTests {
    @Test func roundTripPermissionsAndLimits() throws {
        let dir = URL(fileURLWithPath: "/tmp").appendingPathComponent("d4m-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock").path
        let service = InProcessAutomationService(editor: DocumentEditor())
        let q = DispatchQueue(label: "test.handler")
        let server = LocalSocketServer(path: path, handlerQueue: q) { AutomationEndpoint.handle(json: $0, service: service) }
        try server.start()
        defer { server.stop() }

        var st = stat()
        #expect(lstat(dir.path, &st) == 0 && (st.st_mode & 0o777) == 0o700)
        #expect(lstat(path, &st) == 0 && (st.st_mode & 0o777) == 0o600)

        let client = try LocalSocketClient.connect(path: path, timeout: 10)
        let reply = try client.send(Data(#"{"op":"apply","commands":[{"command":"addRoom","x":0,"z":0,"width":3,"depth":3}]}"#.utf8))
        let r = try JSONDecoder().decode(AutomationResponse.self, from: reply)
        #expect(r.ok && r.revision == 1)
        #expect(service.editor.undoStack.last?.origin == .agent)
        // A second instance can't steal the path while the first is listening.
        #expect(throws: (any Error).self) { try LocalSocketServer(path: path, handlerQueue: q) { $0 }.start() }
        client.close()
    }

    @Test func clientRefusesNonSocketFiles() throws {
        let f = NSTemporaryDirectory() + "notasocket-\(UUID().uuidString.prefix(6))"
        FileManager.default.createFile(atPath: f, contents: Data())
        defer { unlink(f) }
        #expect(throws: (any Error).self) { try LocalSocketClient.connect(path: f) }
        #expect(throws: (any Error).self) { try LocalSocketClient.connect(path: f + ".missing") }
    }
}

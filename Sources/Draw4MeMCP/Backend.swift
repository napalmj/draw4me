import Foundation
import Draw4MeCore
import Draw4MeAutomation

/// Where tool calls go: the running app (live, over the local socket) or a headless document.
public protocol MCPBackend: AnyObject {
    var mode: String { get }
    func call(_ request: AutomationRequest) throws -> AutomationResponse
}

/// Forwards requests to the running app over `LocalSocketClient`.
public final class AppBackend: MCPBackend {
    public let mode = "app"
    private let path: String
    private var client: LocalSocketClient?

    public init(path: String = LocalSocket.defaultPath) { self.path = path }

    /// True if the app is reachable right now.
    public func isAvailable() -> Bool {
        if client != nil { return true }
        client = try? LocalSocketClient.connect(path: path)
        return client != nil
    }

    public func call(_ request: AutomationRequest) throws -> AutomationResponse {
        let data = try JSONEncoder().encode(request)
        for attempt in 0..<2 {
            do {
                if client == nil { client = try LocalSocketClient.connect(path: path) }
                let reply = try client!.send(data)
                return try JSONDecoder().decode(AutomationResponse.self, from: reply)
            } catch LocalSocket.SocketError.closed where attempt == 0 {
                client = nil   // the app restarted; reconnect once
            } catch {
                client?.close(); client = nil
                throw error
            }
        }
        throw LocalSocket.SocketError.closed
    }
}

/// Works on a document file without the app, using the same core and renderer.
/// Every successful change is saved straight back to `fileURL`, so nothing is lost.
public final class HeadlessBackend: MCPBackend {
    public let mode = "headless"
    public let service: InProcessAutomationService
    public private(set) var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
        let editor = DocumentEditor()
        if let data = try? Data(contentsOf: fileURL) {
            do {
                editor.load(try SceneDocument.load(from: data))
            } catch {
                // Don't silently overwrite a file we can't read: move it aside first.
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let backup = fileURL.deletingPathExtension().appendingPathExtension("unreadable-\(stamp).draw4me")
                try? FileManager.default.moveItem(at: fileURL, to: backup)
                FileHandle.standardError.write(Data("draw4me-mcp: \(fileURL.path) could not be read (\(error)); moved it to \(backup.lastPathComponent) and started empty\n".utf8))
            }
        }
        service = InProcessAutomationService(editor: editor, mode: "headless", fileURL: fileURL)
    }

    public static var defaultURL: URL {
        if let p = ProcessInfo.processInfo.environment["DRAW4ME_DOCUMENT"], !p.isEmpty { return URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }
        return LocalSocket.defaultDirectory.appendingPathComponent("headless.draw4me")
    }

    public func call(_ request: AutomationRequest) throws -> AutomationResponse {
        let response = AutomationEndpoint.handle(request, service: service)
        if !request.isReadOnly, response.ok { try save() }
        return response
    }

    public func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try service.editor.document.jsonData().write(to: fileURL, options: .atomic)
        // Designs can be private: keep the auto-saved file readable by this user only.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    /// Replace the document with one read from disk (already path-checked by the caller).
    public func open(_ url: URL) throws {
        let doc = try PathPolicy.readDocument(url)
        service.editor.load(doc)
        fileURL = url
        service.fileURL = url
    }

    /// Save a copy and continue working on it.
    public func saveAs(_ url: URL) throws {
        fileURL = url
        service.fileURL = url
        try save()
    }
}

/// Chooses the backend per call: the app when it's running, otherwise headless.
/// `DRAW4ME_MCP_MODE=app|headless|auto` (default auto) pins it.
public final class BackendSelector {
    public let app: AppBackend
    public private(set) lazy var headless: HeadlessBackend = HeadlessBackend(fileURL: headlessURL)
    private let headlessURL: URL
    private let pinned: String

    public init(app: AppBackend = AppBackend(), headlessURL: URL = HeadlessBackend.defaultURL,
                mode: String = ProcessInfo.processInfo.environment["DRAW4ME_MCP_MODE"] ?? "auto") {
        self.app = app
        self.headlessURL = headlessURL
        self.pinned = mode
    }

    public func current() -> MCPBackend {
        switch pinned {
        case "app": return app
        case "headless": return headless
        default: return app.isAvailable() ? app : headless
        }
    }
}

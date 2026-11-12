import Foundation
import Draw4MeCore
import Draw4MeRender

/// Everything an automation client may do to a design. The Command Console uses this today; the
/// CLI uses it headlessly; a future AI integration would use exactly the same calls, so agent
/// edits take the same path (commands → `DocumentEditor`) as the user's own edits.
public protocol AutomationService: AnyObject {
    /// Apply commands as one undoable transaction, tagged with who issued them.
    func apply(_ commands: [Command], origin: CommandOrigin, label: String?) -> CommandResult
    /// Compact, deterministic description of the current scene.
    func sceneSummary() -> SceneSummary
    /// Machine-readable description of every command and object kind (JSON).
    func catalogJSON() -> String
    /// Render the current design to PNG (2D or 3D), without a window.
    func render(_ request: RenderRequest) throws -> Data
    /// The current document (for saving or inspection).
    func document() -> SceneDocument
    /// Undo/redo the most recent step. If `onlyOrigin` is given, only undo when the last step came from it.
    func undo(onlyOrigin: CommandOrigin?) -> HistoryInfo?
    func redo() -> HistoryInfo?
    /// Most recent first.
    func history(limit: Int) -> [HistoryInfo]
}

/// A history entry without the document snapshots (small enough to send over the wire).
public struct HistoryInfo: Codable, Hashable, Sendable {
    public var id: Int
    public var label: String
    public var origin: CommandOrigin
    public var commandCount: Int
    public var changes: ChangeSet

    public init(_ e: HistoryEntry) {
        id = e.id; label = e.label; origin = e.origin; commandCount = e.commands.count; changes = e.changes
    }
}

/// In-process implementation over a `DocumentEditor`.
///
/// Threading: when the editor is shared with the UI, call this on the main thread (the app does).
/// A future transport receiving requests on a background queue must hop to the main actor first.
public final class InProcessAutomationService: AutomationService {
    public let editor: DocumentEditor

    public init(editor: DocumentEditor) { self.editor = editor }

    public func apply(_ commands: [Command], origin: CommandOrigin, label: String?) -> CommandResult {
        editor.apply(commands, origin: origin, label: label)
    }

    public func sceneSummary() -> SceneSummary { SceneSummary(editor.document) }

    public func catalogJSON() -> String { CommandCatalog.jsonString() }

    public func render(_ request: RenderRequest) throws -> Data { try Renderer.png(editor.document, request: request) }

    public func document() -> SceneDocument { editor.document }

    public func undo(onlyOrigin: CommandOrigin?) -> HistoryInfo? {
        let e = onlyOrigin.map { editor.undoLast(from: $0) } ?? editor.undo()
        return e.map(HistoryInfo.init)
    }

    public func redo() -> HistoryInfo? { editor.redo().map(HistoryInfo.init) }

    public func history(limit: Int) -> [HistoryInfo] {
        editor.undoStack.suffix(max(0, limit)).reversed().map(HistoryInfo.init)
    }
}

// MARK: - Wire protocol

/// JSON requests an external client can send. One request in, one `AutomationResponse` out.
///
/// ```json
/// {"op":"apply","origin":"agent","label":"Add table","commands":[{"command":"add","kind":"table"}]}
/// {"op":"summary"}                      // text; {"op":"summary","format":"json"} for structured
/// {"op":"catalog"}
/// {"op":"render","render":{"view":"plan","width":1200,"height":800}}
/// {"op":"undo"}  {"op":"undo","origin":"agent"}  {"op":"redo"}  {"op":"history"}  {"op":"document"}
/// ```
public struct AutomationRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable { case apply, summary, catalog, render, undo, redo, history, document }
    public var op: Op
    public var commands: [Command]?
    public var origin: CommandOrigin?
    public var label: String?
    public var format: String?
    public var render: RenderRequest?
    public var limit: Int?

    public init(op: Op, commands: [Command]? = nil, origin: CommandOrigin? = nil, label: String? = nil,
                format: String? = nil, render: RenderRequest? = nil, limit: Int? = nil) {
        self.op = op; self.commands = commands; self.origin = origin; self.label = label
        self.format = format; self.render = render; self.limit = limit
    }
}

public struct AutomationResponse: Codable, Sendable {
    public var ok: Bool
    public var result: CommandResult?
    public var text: String?
    public var history: [HistoryInfo]?
    /// PNG for `render`, base64-encoded.
    public var pngBase64: String?
    public var error: String?

    public init(ok: Bool, result: CommandResult? = nil, text: String? = nil, history: [HistoryInfo]? = nil,
                pngBase64: String? = nil, error: String? = nil) {
        self.ok = ok; self.result = result; self.text = text; self.history = history
        self.pngBase64 = pngBase64; self.error = error
    }
}

/// The single entry point for any future transport.
///
/// ── FUTURE TRANSPORTS PLUG IN HERE ──────────────────────────────────────────────────────────
/// An MCP bridge, a file watcher, or a CLI talking to a running app only needs to:
///   1. receive bytes (stdin, a Unix socket, a watched file…),
///   2. call `AutomationEndpoint.handle(_:service:)` on the main thread,
///   3. send the returned bytes back.
/// No such transport exists in this version on purpose (no sockets, no network, no API keys);
/// see docs/AI-INTEGRATION.md for the options. Everything they'd need is already behind this call.
/// ─────────────────────────────────────────────────────────────────────────────────────────────
public enum AutomationEndpoint {
    public static func handle(_ request: AutomationRequest, service: AutomationService) -> AutomationResponse {
        switch request.op {
        case .apply:
            guard let cmds = request.commands, !cmds.isEmpty else {
                return AutomationResponse(ok: false, error: "apply needs a non-empty 'commands' array")
            }
            let r = service.apply(cmds, origin: request.origin ?? .agent, label: request.label)
            return AutomationResponse(ok: r.ok, result: r, text: r.message, error: r.error?.message)
        case .summary:
            let s = service.sceneSummary()
            return AutomationResponse(ok: true, text: request.format == "json" ? s.jsonString() : s.text)
        case .catalog:
            return AutomationResponse(ok: true, text: service.catalogJSON())
        case .render:
            do {
                let png = try service.render(request.render ?? RenderRequest(view: .perspective))
                return AutomationResponse(ok: true, pngBase64: png.base64EncodedString())
            } catch {
                return AutomationResponse(ok: false, error: "\(error)")
            }
        case .undo:
            guard let h = service.undo(onlyOrigin: request.origin) else {
                return AutomationResponse(ok: false, error: request.origin.map { "The last change was not made by '\($0.rawValue)'" } ?? "Nothing to undo")
            }
            return AutomationResponse(ok: true, text: "Undid: \(h.label)", history: [h])
        case .redo:
            guard let h = service.redo() else { return AutomationResponse(ok: false, error: "Nothing to redo") }
            return AutomationResponse(ok: true, text: "Redid: \(h.label)", history: [h])
        case .history:
            return AutomationResponse(ok: true, history: service.history(limit: request.limit ?? 20))
        case .document:
            let data = (try? service.document().jsonData()) ?? Data()
            return AutomationResponse(ok: true, text: String(data: data, encoding: .utf8))
        }
    }

    /// Bytes in, bytes out.
    public static func handle(json: Data, service: AutomationService) -> Data {
        let response: AutomationResponse
        do {
            let req = try JSONDecoder().decode(AutomationRequest.self, from: json)
            response = handle(req, service: service)
        } catch let e as CommandError {
            response = AutomationResponse(ok: false, error: e.message)
        } catch {
            response = AutomationResponse(ok: false, error: "Bad request: \(error)")
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(response)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    }
}

import Foundation
import Draw4MeCore
import Draw4MeRender

/// Everything an automation client may do to a design. The Command Console uses this today; the
/// CLI uses it headlessly; a future AI integration would use exactly the same calls, so agent
/// edits take the same path (commands → `DocumentEditor`) as the user's own edits.
public protocol AutomationService: AnyObject {
    /// Apply commands as one undoable transaction, tagged with who issued them. With
    /// `expectedRevision`, the change is rejected (`staleRevision`) if the document moved on.
    func apply(_ commands: [Command], origin: CommandOrigin, label: String?, expectedRevision: Int?) -> CommandResult
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
    /// Revert the most recent change made by `origin`, even if later changes exist (unless they conflict).
    func revertLast(from origin: CommandOrigin) -> CommandResult
    /// Most recent first.
    func history(limit: Int) -> [HistoryInfo]
    /// What the person has selected in the app (empty when headless), so "make this taller" works.
    func selection() -> SelectionInfo
    /// Current design warnings for the whole document.
    func warnings() -> [DesignWarning]
    /// Where this service runs ("app" or "headless") and the document it is editing.
    func status() -> AutomationStatus
}

extension AutomationService {
    public func apply(_ commands: [Command], origin: CommandOrigin, label: String?) -> CommandResult {
        apply(commands, origin: origin, label: label, expectedRevision: nil)
    }
}

public struct SelectionInfo: Codable, Hashable, Sendable {
    public var ids: [String]
    /// One summary line per selected object.
    public var description: String
    public init(ids: [String], description: String) { self.ids = ids; self.description = description }
}

public struct AutomationStatus: Codable, Hashable, Sendable {
    public var mode: String
    public var documentName: String
    public var revision: Int
    public var objectCount: Int
    public var warningCount: Int
    /// File the document is saved to, if any.
    public var path: String?
    public init(mode: String, documentName: String, revision: Int, objectCount: Int, warningCount: Int, path: String?) {
        self.mode = mode; self.documentName = documentName; self.revision = revision
        self.objectCount = objectCount; self.warningCount = warningCount; self.path = path
    }
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
/// Transports receiving requests on a background queue must hop to the main actor first.
open class InProcessAutomationService: AutomationService {
    public let editor: DocumentEditor
    /// Where the document lives on disk, if anywhere.
    public var fileURL: URL?
    public var mode: String

    public init(editor: DocumentEditor, mode: String = "headless", fileURL: URL? = nil) {
        self.editor = editor; self.mode = mode; self.fileURL = fileURL
    }

    open func apply(_ commands: [Command], origin: CommandOrigin, label: String?, expectedRevision: Int?) -> CommandResult {
        editor.apply(commands, origin: origin, label: label, expectedRevision: expectedRevision)
    }

    open func sceneSummary() -> SceneSummary { SceneSummary(editor.document) }

    public func catalogJSON() -> String { CommandCatalog.jsonString() }

    open func render(_ request: RenderRequest) throws -> Data { try Renderer.png(editor.document, request: request) }

    public func document() -> SceneDocument { editor.document }

    open func undo(onlyOrigin: CommandOrigin?) -> HistoryInfo? {
        let e = onlyOrigin.map { editor.undoLast(from: $0) } ?? editor.undo()
        return e.map(HistoryInfo.init)
    }

    open func redo() -> HistoryInfo? { editor.redo().map(HistoryInfo.init) }

    open func revertLast(from origin: CommandOrigin) -> CommandResult {
        switch editor.revertLast(from: origin) {
        case .success(let e): return editor.result(for: e, verb: "Reverted")
        case .failure(let err):
            var r = CommandResult.failure(err)
            r.revision = editor.document.revision
            return r
        }
    }

    public func history(limit: Int) -> [HistoryInfo] {
        editor.undoStack.suffix(max(0, min(limit, 200))).reversed().map(HistoryInfo.init)
    }

    open func selection() -> SelectionInfo { SelectionInfo(ids: [], description: "Nothing is selected (no app window is attached).") }

    public func warnings() -> [DesignWarning] { editor.warnings }

    open func status() -> AutomationStatus {
        AutomationStatus(mode: mode, documentName: editor.document.name, revision: editor.document.revision,
                         objectCount: editor.document.objects.count, warningCount: editor.warnings.count, path: fileURL?.path)
    }
}

// MARK: - Wire protocol

/// JSON requests an external client can send. One request in, one `AutomationResponse` out.
///
/// ```json
/// {"op":"apply","origin":"agent","label":"Add table","expectedRevision":12,"commands":[{"command":"add","kind":"table"}]}
/// {"op":"summary"}                      // text; {"op":"summary","format":"json"} for structured
/// {"op":"catalog"}
/// {"op":"render","render":{"view":"plan","width":1200,"height":800}}
/// {"op":"undo"}  {"op":"undo","origin":"agent"}  {"op":"redo"}  {"op":"revert","origin":"agent"}
/// {"op":"history"}  {"op":"document"}  {"op":"selection"}  {"op":"warnings"}  {"op":"status"}
/// ```
public struct AutomationRequest: Codable, Sendable {
    public enum Op: String, Codable, Sendable, CaseIterable {
        case apply, summary, catalog, render, undo, redo, revert, history, document, selection, warnings, status
    }
    public var op: Op
    public var commands: [Command]?
    public var origin: CommandOrigin?
    public var label: String?
    public var expectedRevision: Int?
    public var format: String?
    public var render: RenderRequest?
    public var limit: Int?

    public init(op: Op, commands: [Command]? = nil, origin: CommandOrigin? = nil, label: String? = nil, expectedRevision: Int? = nil,
                format: String? = nil, render: RenderRequest? = nil, limit: Int? = nil) {
        self.op = op; self.commands = commands; self.origin = origin; self.label = label; self.expectedRevision = expectedRevision
        self.format = format; self.render = render; self.limit = limit
    }

    /// Ops that never change the document.
    public var isReadOnly: Bool { ![.apply, .undo, .redo, .revert].contains(op) }
}

public struct AutomationResponse: Codable, Sendable {
    public var ok: Bool
    public var result: CommandResult?
    public var text: String?
    public var history: [HistoryInfo]?
    /// PNG for `render`, base64-encoded.
    public var pngBase64: String?
    public var warnings: [DesignWarning]?
    public var selection: SelectionInfo?
    public var status: AutomationStatus?
    /// Document revision after handling the request.
    public var revision: Int?
    public var error: String?
    /// Machine-readable error code (see `CommandError.Code`), when there is one.
    public var errorCode: String?

    public init(ok: Bool, result: CommandResult? = nil, text: String? = nil, history: [HistoryInfo]? = nil,
                pngBase64: String? = nil, warnings: [DesignWarning]? = nil, selection: SelectionInfo? = nil,
                status: AutomationStatus? = nil, revision: Int? = nil, error: String? = nil, errorCode: String? = nil) {
        self.ok = ok; self.result = result; self.text = text; self.history = history; self.pngBase64 = pngBase64
        self.warnings = warnings; self.selection = selection; self.status = status; self.revision = revision
        self.error = error; self.errorCode = errorCode
    }
}

/// The single entry point for every transport (the app's local socket, the headless MCP server,
/// the CLI). It turns a request into calls on an `AutomationService`, so agent edits take exactly
/// the same path as the person's own edits.
public enum AutomationEndpoint {
    /// Largest request accepted, in bytes.
    public static let maxRequestBytes = 4 * 1024 * 1024

    public static func handle(_ request: AutomationRequest, service: AutomationService) -> AutomationResponse {
        var response = dispatch(request, service: service)
        response.revision = service.document().revision
        return response
    }

    static func dispatch(_ request: AutomationRequest, service: AutomationService) -> AutomationResponse {
        switch request.op {
        case .apply:
            guard let cmds = request.commands, !cmds.isEmpty else {
                return AutomationResponse(ok: false, error: "apply needs a non-empty 'commands' array", errorCode: CommandError.Code.invalidCommand.rawValue)
            }
            guard cmds.count <= Limits.maxCommandsPerRequest else {
                return AutomationResponse(ok: false, error: "Too many commands in one request (max \(Limits.maxCommandsPerRequest))", errorCode: CommandError.Code.limitExceeded.rawValue)
            }
            let r = service.apply(cmds, origin: request.origin ?? .agent, label: request.label.map { String($0.prefix(120)) }, expectedRevision: request.expectedRevision)
            return AutomationResponse(ok: r.ok, result: r, text: r.message, warnings: r.warnings, error: r.error?.message, errorCode: r.error?.code.rawValue)
        case .summary:
            let s = service.sceneSummary()
            return AutomationResponse(ok: true, text: request.format == "json" ? s.jsonString() : s.text)
        case .catalog:
            return AutomationResponse(ok: true, text: request.format == "text" ? CommandCatalog.text() : service.catalogJSON())
        case .render:
            do {
                let png = try service.render(request.render ?? RenderRequest(view: .perspective))
                return AutomationResponse(ok: true, pngBase64: png.base64EncodedString())
            } catch {
                return AutomationResponse(ok: false, error: "\(error)")
            }
        case .undo:
            guard let h = service.undo(onlyOrigin: request.origin) else {
                return AutomationResponse(ok: false, error: request.origin.map { "The last change was not made by '\($0.rawValue)'" } ?? "Nothing to undo",
                                          errorCode: CommandError.Code.nothingToUndo.rawValue)
            }
            return AutomationResponse(ok: true, text: "Undid: \(h.label)", history: [h])
        case .redo:
            guard let h = service.redo() else { return AutomationResponse(ok: false, error: "Nothing to redo", errorCode: CommandError.Code.nothingToUndo.rawValue) }
            return AutomationResponse(ok: true, text: "Redid: \(h.label)", history: [h])
        case .revert:
            let r = service.revertLast(from: request.origin ?? .agent)
            return AutomationResponse(ok: r.ok, result: r, text: r.message, warnings: r.warnings, error: r.error?.message, errorCode: r.error?.code.rawValue)
        case .history:
            return AutomationResponse(ok: true, history: service.history(limit: request.limit ?? 20))
        case .document:
            let data = (try? service.document().jsonData()) ?? Data()
            return AutomationResponse(ok: true, text: String(data: data, encoding: .utf8))
        case .selection:
            let sel = service.selection()
            return AutomationResponse(ok: true, text: sel.description, selection: sel)
        case .warnings:
            let w = service.warnings()
            let limited = Array(w.prefix(max(1, min(request.limit ?? 100, 1000))))
            let text = w.isEmpty ? "No warnings." : limited.map { "[\($0.code.rawValue)] \($0.message)" }.joined(separator: "\n")
                + (w.count > limited.count ? "\n… \(w.count - limited.count) more" : "")
            return AutomationResponse(ok: true, text: text, warnings: limited)
        case .status:
            let st = service.status()
            return AutomationResponse(ok: true, text: "\(st.mode): \"\(st.documentName)\" revision \(st.revision), \(st.objectCount) objects, \(st.warningCount) warnings", status: st)
        }
    }

    /// Bytes in, bytes out. Never throws: malformed input becomes an error response.
    public static func handle(json: Data, service: AutomationService) -> Data {
        let response: AutomationResponse
        if json.count > maxRequestBytes {
            response = AutomationResponse(ok: false, error: "Request too large (max \(maxRequestBytes / 1_048_576) MB)", errorCode: CommandError.Code.limitExceeded.rawValue)
        } else {
            do {
                let req = try JSONDecoder().decode(AutomationRequest.self, from: json)
                response = handle(req, service: service)
            } catch let e as CommandError {
                response = AutomationResponse(ok: false, error: e.message, errorCode: e.code.rawValue)
            } catch let e as DecodingError {
                response = AutomationResponse(ok: false, error: "Bad request: \(describeDecoding(e))", errorCode: CommandError.Code.invalidCommand.rawValue)
            } catch {
                response = AutomationResponse(ok: false, error: "Bad request", errorCode: CommandError.Code.invalidCommand.rawValue)
            }
        }
        return encode(response)
    }

    public static func encode(_ response: AutomationResponse) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(response)) ?? Data(#"{"ok":false,"error":"encoding failed"}"#.utf8)
    }
}

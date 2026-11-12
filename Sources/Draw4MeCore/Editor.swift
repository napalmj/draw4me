import Foundation

/// Structured outcome of applying a command or batch.
public struct CommandResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var created: [String]
    public var changed: [String]
    public var deleted: [String]
    public var error: CommandError?
    /// History entry id for successful edits (use to identify/undo this change later).
    public var historyId: Int?
    /// One-line human readable outcome.
    public var message: String

    public static func failure(_ e: CommandError) -> CommandResult {
        CommandResult(ok: false, created: [], changed: [], deleted: [], error: e, historyId: nil,
                      message: e.commandIndex.map { "Command \($0 + 1) failed: \(e.message)" } ?? e.message)
    }

    public func jsonString() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "{}"
    }
}

/// One undoable step. A step can contain many commands (a transaction) and records who made it.
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    public var origin: CommandOrigin
    public var commands: [Command]
    public var changes: ChangeSet
    public var before: SceneDocument
    public var after: SceneDocument
}

/// The one and only way to change a document.
///
/// Every edit — toolbar clicks, inspector fields, drags, the Command Console, the CLI and (later)
/// an AI agent — calls `apply`. Batches are atomic: either every command succeeds or the
/// document is left untouched. Undo is snapshot based, so it is exact.
public final class DocumentEditor {
    public private(set) var document: SceneDocument
    public private(set) var undoStack: [HistoryEntry] = []
    public private(set) var redoStack: [HistoryEntry] = []
    public var maxHistory = 300
    private var nextHistoryId = 1

    /// Called after every successful change (apply, undo, redo, load).
    public var onChange: ((DocumentEditor) -> Void)?

    public init(document: SceneDocument = SceneDocument()) {
        self.document = document
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Replace the whole document (e.g. after opening a file). Clears history.
    public func load(_ doc: SceneDocument) {
        document = doc
        undoStack.removeAll(); redoStack.removeAll()
        onChange?(self)
    }

    @discardableResult
    public func apply(_ command: Command, origin: CommandOrigin = .user, label: String? = nil) -> CommandResult {
        apply([command], origin: origin, label: label)
    }

    /// Apply commands as one undoable transaction. If any command fails nothing changes and the
    /// error says which command (0-based `commandIndex`) failed and why.
    @discardableResult
    public func apply(_ commands: [Command], origin: CommandOrigin = .user, label: String? = nil) -> CommandResult {
        switch dryRun(commands) {
        case .failure(let e):
            return .failure(e)
        case .success(let (newDoc, changes)):
            guard newDoc != document else {
                return CommandResult(ok: true, created: [], changed: [], deleted: [], error: nil, historyId: nil, message: "No change")
            }
            let entry = HistoryEntry(id: nextHistoryId, label: label ?? Self.label(for: commands), origin: origin,
                                     commands: commands, changes: changes, before: document, after: newDoc)
            nextHistoryId += 1
            undoStack.append(entry)
            if undoStack.count > maxHistory { undoStack.removeFirst(undoStack.count - maxHistory) }
            redoStack.removeAll()
            document = newDoc
            onChange?(self)
            return CommandResult(ok: true, created: changes.created, changed: changes.changed, deleted: changes.deleted,
                                 error: nil, historyId: entry.id, message: Self.describe(entry))
        }
    }

    /// Compute the result of commands without committing (live previews, "what would this do?").
    public func dryRun(_ commands: [Command]) -> Result<(SceneDocument, ChangeSet), CommandError> {
        guard !commands.isEmpty else { return .failure(.invalidCommand("No commands given")) }
        var doc = document
        var changes = ChangeSet()
        var ctx = ExecutionContext()
        for (i, c) in commands.enumerated() {
            do {
                try Engine.execute(c, doc: &doc, changes: &changes, ctx: &ctx)
            } catch var e as CommandError {
                if commands.count > 1 { e.commandIndex = i }
                return .failure(e)
            } catch {
                return .failure(CommandError(code: .invalidCommand, message: "\(error)", commandIndex: commands.count > 1 ? i : nil))
            }
        }
        return .success((doc, changes.normalized()))
    }

    @discardableResult
    public func undo() -> HistoryEntry? {
        guard let e = undoStack.popLast() else { return nil }
        document = e.before
        redoStack.append(e)
        onChange?(self)
        return e
    }

    @discardableResult
    public func redo() -> HistoryEntry? {
        guard let e = redoStack.popLast() else { return nil }
        document = e.after
        undoStack.append(e)
        onChange?(self)
        return e
    }

    /// Undo the most recent step if (and only if) it came from `origin` — e.g. "undo what the agent just did".
    @discardableResult
    public func undoLast(from origin: CommandOrigin) -> HistoryEntry? {
        guard undoStack.last?.origin == origin else { return nil }
        return undo()
    }

    static func label(for commands: [Command]) -> String {
        commands.count == 1 ? commands[0].label : "\(commands.count) Changes"
    }

    static func describe(_ e: HistoryEntry) -> String {
        var bits: [String] = []
        if !e.changes.created.isEmpty { bits.append("created \(e.changes.created.joined(separator: ", "))") }
        if !e.changes.changed.isEmpty { bits.append("changed \(e.changes.changed.joined(separator: ", "))") }
        if !e.changes.deleted.isEmpty { bits.append("deleted \(e.changes.deleted.joined(separator: ", "))") }
        return "\(e.label): " + (bits.isEmpty ? "done" : bits.joined(separator: "; "))
    }
}

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
    /// Document revision after this call (unchanged on failure).
    public var revision: Int? = nil
    /// Warnings that involve the objects this change created or changed.
    public var warnings: [DesignWarning]? = nil
    /// Total warnings in the whole document after the change.
    public var totalWarnings: Int? = nil

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

    /// Called after every successful change (apply, undo, redo, revert, load).
    public var onChange: ((DocumentEditor) -> Void)?

    private var warningsCache: [DesignWarning]?
    /// Current design warnings (computed lazily, cached until the next change).
    public var warnings: [DesignWarning] {
        if let w = warningsCache { return w }
        let w = Validator.warnings(for: document)
        warningsCache = w
        return w
    }

    private func didChange() {
        warningsCache = nil
        onChange?(self)
    }

    public init(document: SceneDocument = SceneDocument()) {
        self.document = document
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var undoLabel: String? { undoStack.last?.label }
    public var redoLabel: String? { redoStack.last?.label }

    /// Replace the whole document (e.g. after opening a file). Clears history.
    public func load(_ doc: SceneDocument) {
        var d = doc
        d.revision = max(doc.revision, document.revision + 1)
        document = d
        undoStack.removeAll(); redoStack.removeAll()
        didChange()
    }

    @discardableResult
    public func apply(_ command: Command, origin: CommandOrigin = .user, label: String? = nil, expectedRevision: Int? = nil) -> CommandResult {
        apply([command], origin: origin, label: label, expectedRevision: expectedRevision)
    }

    /// Apply commands as one undoable transaction. If any command fails nothing changes and the
    /// error says which command (0-based `commandIndex`) failed and why.
    @discardableResult
    public func apply(_ commands: [Command], origin: CommandOrigin = .user, label: String? = nil, expectedRevision: Int? = nil) -> CommandResult {
        if let expected = expectedRevision, expected != document.revision {
            var r = CommandResult.failure(CommandError(code: .staleRevision,
                message: "The document changed since revision \(expected); it is now at revision \(document.revision). Read the scene again, then retry."))
            r.revision = document.revision
            return r
        }
        switch dryRun(commands) {
        case .failure(let e):
            var r = CommandResult.failure(e)
            r.revision = document.revision
            return r
        case .success(let (proposed, changes)):
            var newDoc = proposed
            guard newDoc != document else {
                return CommandResult(ok: true, created: [], changed: [], deleted: [], error: nil, historyId: nil, message: "No change", revision: document.revision)
            }
            newDoc.revision = document.revision + 1
            let entry = HistoryEntry(id: nextHistoryId, label: label ?? Self.label(for: commands), origin: origin,
                                     commands: commands, changes: changes, before: document, after: newDoc)
            nextHistoryId += 1
            undoStack.append(entry)
            if undoStack.count > maxHistory { undoStack.removeFirst(undoStack.count - maxHistory) }
            redoStack.removeAll()
            document = newDoc
            didChange()
            return withWarnings(CommandResult(ok: true, created: changes.created, changed: changes.changed, deleted: changes.deleted,
                                              error: nil, historyId: entry.id, message: Self.describe(entry)))
        }
    }

    /// Adds the new revision and the warnings relevant to the touched objects.
    private func withWarnings(_ r: CommandResult) -> CommandResult {
        var r = r
        let all = warnings
        r.revision = document.revision
        r.warnings = Validator.warnings(all, involving: Set(r.created + r.changed))
        r.totalWarnings = all.count
        return r
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
        setDocument(e.before)
        redoStack.append(e)
        didChange()
        return e
    }

    @discardableResult
    public func redo() -> HistoryEntry? {
        guard let e = redoStack.popLast() else { return nil }
        setDocument(e.after)
        undoStack.append(e)
        didChange()
        return e
    }

    /// Restores a snapshot while keeping the revision counter moving forward.
    private func setDocument(_ d: SceneDocument) {
        var d = d
        d.revision = document.revision + 1
        document = d
    }

    /// Undo the most recent step if (and only if) it came from `origin`.
    @discardableResult
    public func undoLast(from origin: CommandOrigin) -> HistoryEntry? {
        guard undoStack.last?.origin == origin else { return nil }
        return undo()
    }

    /// Reverts the most recent still-applied step made by `origin` (e.g. "undo what the agent did"),
    /// even if other steps came after it — as long as those later steps didn't touch the same objects.
    /// On a conflict nothing changes and the error lists the objects involved.
    public func revertLast(from origin: CommandOrigin) -> Result<HistoryEntry, CommandError> {
        guard let k = undoStack.lastIndex(where: { $0.origin == origin }) else {
            return .failure(CommandError(code: .nothingToUndo, message: "There are no changes from \(origin.rawValue) to revert"))
        }
        let entry = undoStack[k]
        let touched = entry.changes.allIds
        if k == undoStack.count - 1 { _ = undo(); return .success(entry) }
        var clash = Set<String>()
        for later in undoStack[(k + 1)...] { clash.formUnion(touched.intersection(later.changes.allIds)) }
        // Group membership changes elsewhere are not tracked per object, so also refuse if a later
        // step deleted a group this entry's objects belonged to.
        guard clash.isEmpty else {
            return .failure(CommandError(code: .conflict, message: "Can't revert '\(entry.label)': later changes also touched \(clash.sorted().prefix(12).joined(separator: ", ")). Undo those first."))
        }
        // Patch the current document and every later snapshot so later undo/redo stay consistent.
        func patch(_ d: SceneDocument) -> SceneDocument { Self.revert(entry, in: d) }
        var newDoc = patch(document)
        // Later steps may have built on objects this entry created (a door in its wall, a member of its group).
        let ids = Set(newDoc.objects.map(\.id))
        let dangling = newDoc.objects.filter { o in [o.hostId, o.parentId].contains { $0 != nil && !ids.contains($0!) } }.map(\.id)
        guard dangling.isEmpty else {
            return .failure(CommandError(code: .conflict, message: "Can't revert '\(entry.label)': later objects depend on it (\(dangling.prefix(12).joined(separator: ", "))). Undo those first."))
        }
        newDoc.revision = document.revision + 1
        for i in (k + 1)..<undoStack.count {
            undoStack[i].before = patch(undoStack[i].before)
            undoStack[i].after = patch(undoStack[i].after)
        }
        undoStack.remove(at: k)
        redoStack.removeAll()
        document = newDoc
        didChange()
        return .success(entry)
    }

    /// Applies the inverse of `entry`'s changes to `d`: objects it created are removed, objects it
    /// changed or deleted get their earlier state back (deleted ones at their old position).
    static func revert(_ entry: HistoryEntry, in d: SceneDocument) -> SceneDocument {
        var d = d
        let created = Set(entry.changes.created)
        d.objects.removeAll { created.contains($0.id) }
        for id in entry.changes.changed {
            guard let old = entry.before.object(id), let i = d.index(of: id) else { continue }
            d.objects[i] = old
        }
        for id in entry.changes.deleted {
            guard let old = entry.before.object(id), !d.contains(id) else { continue }
            let at = min(entry.before.index(of: id) ?? d.objects.count, d.objects.count)
            d.objects.insert(old, at: at)
        }
        return d
    }

    /// Result shape for undo/redo/revert, with revision and warnings filled in.
    public func result(for entry: HistoryEntry, verb: String) -> CommandResult {
        withWarnings(CommandResult(ok: true, created: [], changed: entry.changes.allIds.sorted().filter { document.contains($0) },
                                   deleted: entry.changes.allIds.sorted().filter { !document.contains($0) },
                                   error: nil, historyId: entry.id, message: "\(verb): \(entry.label)"))
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

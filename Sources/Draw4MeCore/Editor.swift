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

/// One object's state before and after a step (nil = didn't exist), with its position in the list.
public struct ObjectDelta: Codable, Hashable, Sendable {
    public var id: String
    public var before: SceneObject?
    public var after: SceneObject?
    public var beforeIndex: Int?
    public var afterIndex: Int?
}

/// One undoable step. A step can contain many commands (a transaction) and records who made it.
/// It stores only what changed (per-object deltas), so history memory stays proportional to the
/// size of the edits, not the size of the document.
public struct HistoryEntry: Codable, Hashable, Sendable, Identifiable {
    public var id: Int
    public var label: String
    public var origin: CommandOrigin
    public var commands: [Command]
    public var changes: ChangeSet
    public var deltas: [ObjectDelta]
    public var nameBefore: String
    public var nameAfter: String
    public var countersBefore: [String: Int]
    public var countersAfter: [String: Int]

    /// Computes the deltas between two versions of a document in O(n).
    public static func diff(_ a: SceneDocument, _ b: SceneDocument) -> [ObjectDelta] {
        var ai: [String: Int] = [:], bi: [String: Int] = [:]
        for (i, o) in a.objects.enumerated() { ai[o.id] = i }
        for (i, o) in b.objects.enumerated() { bi[o.id] = i }
        var out: [ObjectDelta] = []
        for (i, o) in a.objects.enumerated() {
            if let j = bi[o.id] {
                if b.objects[j] != o { out.append(ObjectDelta(id: o.id, before: o, after: b.objects[j], beforeIndex: i, afterIndex: j)) }
            } else {
                out.append(ObjectDelta(id: o.id, before: o, after: nil, beforeIndex: i, afterIndex: nil))
            }
        }
        for (j, o) in b.objects.enumerated() where ai[o.id] == nil {
            out.append(ObjectDelta(id: o.id, before: nil, after: o, beforeIndex: nil, afterIndex: j))
        }
        return out
    }

    /// Applies the deltas forwards (redo) or backwards (undo) to `doc`.
    public func apply(to doc: SceneDocument, forward: Bool) -> SceneDocument {
        var objects = doc.objects
        var index: [String: Int] = [:]
        for (i, o) in objects.enumerated() { index[o.id] = i }
        var removeIds = Set<String>()
        var inserts: [(Int, SceneObject)] = []
        for d in deltas {
            let target = forward ? d.after : d.before
            let at = forward ? d.afterIndex : d.beforeIndex
            if let t = target {
                if let i = index[d.id] { objects[i] = t } else { inserts.append((at ?? Int.max, t)) }
            } else {
                removeIds.insert(d.id)
            }
        }
        if !removeIds.isEmpty { objects.removeAll { removeIds.contains($0.id) } }
        for (i, o) in inserts.sorted(by: { $0.0 < $1.0 }) { objects.insert(o, at: min(i, objects.count)) }
        var out = doc
        out.objects = objects
        out.name = forward ? nameAfter : nameBefore
        // Id counters only move forward so ids are never reused, even across undo.
        out.idCounters = doc.idCounters.merging(forward ? countersAfter : countersBefore) { max($0, $1) }
        return out
    }
}

/// The one and only way to change a document.
///
/// Every edit — toolbar clicks, inspector fields, drags, the Command Console, the CLI and (later)
/// an AI agent — calls `apply`. Batches are atomic: either every command succeeds or the
/// document is left untouched. Undo replays exact per-object deltas.
public final class DocumentEditor {
    public private(set) var document: SceneDocument
    public private(set) var undoStack: [HistoryEntry] = []
    public private(set) var redoStack: [HistoryEntry] = []
    public var maxHistory = 300
    private var nextHistoryId = 1

    /// Called after every successful change (apply, undo, redo, revert, load).
    public var onChange: ((DocumentEditor) -> Void)?

    private var warningsCache: [DesignWarning]?
    private let boundsCache = Validator.BoundsCache()
    /// Current design warnings (computed lazily, cached until the next change).
    public var warnings: [DesignWarning] {
        if let w = warningsCache { return w }
        let w = Validator.warnings(for: document, cache: boundsCache)
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
                                     commands: commands, changes: changes, deltas: HistoryEntry.diff(document, newDoc),
                                     nameBefore: document.name, nameAfter: newDoc.name,
                                     countersBefore: document.idCounters, countersAfter: newDoc.idCounters)
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
        func count(_ cs: [Command]) -> Int { cs.reduce(0) { n, c in if case .transaction(let t) = c { return n + 1 + count(t.commands) }; return n + 1 } }
        guard count(commands) <= Limits.maxCommandsPerRequest else {
            return .failure(CommandError(code: .limitExceeded, message: "Too many commands in one change (max \(Limits.maxCommandsPerRequest), counting nested transactions)"))
        }
        var doc = document
        var changes = ChangeSet()
        var ctx = ExecutionContext()
        for (i, c) in commands.enumerated() {
            do {
                try Engine.execute(c, doc: &doc, changes: &changes, ctx: &ctx)
                try Engine.checkLimits(doc)
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
        setDocument(e.apply(to: document, forward: false))
        redoStack.append(e)
        didChange()
        return e
    }

    @discardableResult
    public func redo() -> HistoryEntry? {
        guard let e = redoStack.popLast() else { return nil }
        setDocument(e.apply(to: document, forward: true))
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
        // Later steps didn't touch these objects, and history stores per-object deltas, so only the
        // current document needs patching.
        func patch(_ d: SceneDocument) -> SceneDocument { Self.revert(entry, in: d) }
        var newDoc = patch(document)
        // Later steps may have built on objects this entry created (a door in its wall, a member of its group).
        let ids = Set(newDoc.objects.map(\.id))
        let dangling = newDoc.objects.filter { o in [o.hostId, o.parentId].contains { $0 != nil && !ids.contains($0!) } }.map(\.id)
        guard dangling.isEmpty else {
            return .failure(CommandError(code: .conflict, message: "Can't revert '\(entry.label)': later objects depend on it (\(dangling.prefix(12).joined(separator: ", "))). Undo those first."))
        }
        newDoc.revision = document.revision + 1
        undoStack.remove(at: k)
        redoStack.removeAll()
        document = newDoc
        didChange()
        return .success(entry)
    }

    /// Applies the inverse of `entry`'s changes to `d`: objects it created are removed, objects it
    /// changed or deleted get their earlier state back (deleted ones at their old position).
    static func revert(_ entry: HistoryEntry, in d: SceneDocument) -> SceneDocument {
        var out = entry.apply(to: d, forward: false)
        out.name = d.name   // a later step may have renamed the document; keep that
        return out
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

    /// "W1, W2, … (+1580 more)": keeps messages short for big edits (full lists stay in the result).
    public static func idList(_ ids: [String], max: Int = 40) -> String {
        ids.count <= max ? ids.joined(separator: ", ") : ids.prefix(max).joined(separator: ", ") + ", … (+\(ids.count - max) more)"
    }

    static func describe(_ e: HistoryEntry) -> String {
        var bits: [String] = []
        if !e.changes.created.isEmpty { bits.append("created \(idList(e.changes.created))") }
        if !e.changes.changed.isEmpty { bits.append("changed \(idList(e.changes.changed))") }
        if !e.changes.deleted.isEmpty { bits.append("deleted \(idList(e.changes.deleted))") }
        return "\(e.label): " + (bits.isEmpty ? "done" : bits.joined(separator: "; "))
    }
}

import Foundation

/// Ids touched by a command or batch.
public struct ChangeSet: Codable, Hashable, Sendable {
    public var created: [String] = []
    public var changed: [String] = []
    public var deleted: [String] = []
    // Membership sets so recording stays O(1) per id (big copies/arrays touch thousands of ids).
    private var seenCreated = Set<String>(), seenChanged = Set<String>(), seenDeleted = Set<String>()

    private enum CodingKeys: String, CodingKey { case created, changed, deleted }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        created = try c.decode([String].self, forKey: .created)
        changed = try c.decode([String].self, forKey: .changed)
        deleted = try c.decode([String].self, forKey: .deleted)
        seenCreated = Set(created); seenChanged = Set(changed); seenDeleted = Set(deleted)
    }

    public static func == (a: ChangeSet, b: ChangeSet) -> Bool { a.created == b.created && a.changed == b.changed && a.deleted == b.deleted }
    public func hash(into h: inout Hasher) { h.combine(created); h.combine(changed); h.combine(deleted) }

    mutating func create(_ id: String) { if seenCreated.insert(id).inserted { created.append(id) } }
    mutating func change(_ id: String) { if seenChanged.insert(id).inserted { changed.append(id) } }
    mutating func delete(_ id: String) { if seenDeleted.insert(id).inserted { deleted.append(id) } }

    /// Normalise: things created then deleted vanish; created/deleted things aren't also "changed".
    func normalized() -> ChangeSet {
        var c = ChangeSet()
        let deletedSet = Set(deleted), createdSet = Set(created)
        for id in created where !deletedSet.contains(id) { c.create(id) }
        for id in deleted where !createdSet.contains(id) { c.delete(id) }
        for id in changed where !deletedSet.contains(id) && !createdSet.contains(id) { c.change(id) }
        return c
    }

    public var isEmpty: Bool { created.isEmpty && changed.isEmpty && deleted.isEmpty }

    /// Every id this change set mentions.
    public var allIds: Set<String> { Set(created).union(changed).union(deleted) }
}

/// Batch-local state: aliases created with `ref` so later commands can say `@alias`.
struct ExecutionContext {
    var aliases: [String: String] = [:]
    var depth = 0
}

/// Applies commands to a document value. Pure: no history, no notifications (see `DocumentEditor`).
enum Engine {
    static let idPattern = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9_-]{0,63}$")

    static func isValidId(_ s: String) -> Bool {
        s.utf16.count <= 64 && idPattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    static func execute(_ cmd: Command, doc: inout SceneDocument, changes: inout ChangeSet, ctx: inout ExecutionContext) throws {
        switch cmd {
        case .newDocument(let c):
            for o in doc.objects { changes.delete(o.id) }
            doc = SceneDocument(name: try nonEmpty(c.name, "name") ?? "Untitled")

        case .loadTemplate(let c):
            if c.replace ?? true {
                for o in doc.objects { changes.delete(o.id) }
                doc = SceneDocument(name: Templates.displayName(c.template))
            }
            var inner = ExecutionContext()   // template refs are private to the template
            for sub in Templates.commands(c.template, offset: c.offset ?? .zero) {
                try execute(sub, doc: &doc, changes: &changes, ctx: &inner)
            }

        case .add(let c):
            try add(c, doc: &doc, changes: &changes, ctx: &ctx)

        case .update(let c):
            try update(c, doc: &doc, changes: &changes, ctx: ctx)

        case .move(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            guard (c.by == nil) != (c.to == nil) else { throw CommandError.invalidParameter("move needs exactly one of 'by' or 'to'") }
            let delta: Vec3
            if let by = c.by { delta = by } else {
                delta = c.to! - Geometry.anchor(of: doc.object(ids[0])!, in: doc)
            }
            guard delta.isFinite else { throw CommandError.invalidParameter("move offset must be finite") }
            try move(ids, by: delta, doc: &doc, changes: &changes)

        case .rotate(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            guard c.degrees.isFinite else { throw CommandError.invalidParameter("degrees must be finite") }
            try rotate(ids, degrees: c.degrees, pivot: c.pivot, doc: &doc, changes: &changes)

        case .resize(let c):
            let id = try resolve(c.id, doc, ctx)
            let obj = doc.object(id)!
            guard obj.kind != .group else { throw CommandError.wrongKind("Groups can't be resized; resize their members") }
            guard (c.dimensions == nil) != (c.scale == nil) else { throw CommandError.invalidParameter("resize needs exactly one of 'dimensions' or 'scale'") }
            var newParams: [String: ParamValue] = [:]
            if let dims = c.dimensions {
                for (k, v) in dims {
                    guard let spec = obj.kind.spec(k) else {
                        throw CommandError.invalidParameter("\(obj.kind.rawValue) has no parameter '\(k)'. Parameters: \(obj.kind.paramSpecs.map(\.key).joined(separator: ", "))")
                    }
                    guard spec.type == .length, k != "offset", k != "sill" else {
                        throw CommandError.invalidParameter("'\(k)' is not a dimension; use the update command to change it")
                    }
                    newParams[k] = .number(v)
                }
            } else if let s = c.scale {
                guard s > 0, s.isFinite else { throw CommandError.invalidParameter("scale must be a positive number") }
                for spec in obj.kind.paramSpecs where spec.type == .length && spec.key != "offset" && spec.key != "sill" {
                    newParams[spec.key] = .number(obj.number(spec.key) * s)
                }
            }
            var o = obj
            o.params = try validatedParams(obj.kind, newParams, base: obj.params)
            try replace(o, doc: &doc)
            changes.change(id)

        case .setMaterial(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            let mat = try c.material.resolve()
            for id in expand(ids, doc, includeHosted: false) {
                guard let i = doc.index(of: id), doc.objects[i].kind != .group else { continue }
                doc.objects[i].material = mat
                changes.change(id)
            }

        case .group(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            for id in ids where doc.object(id)!.kind.isHosted {
                throw CommandError.wrongKind("'\(id)' is a door/window; it belongs to its wall and can't be grouped separately")
            }
            let parents = Set(ids.map { doc.object($0)!.parentId ?? "" })
            let gid = try newId(c.id, kind: .group, doc: &doc)
            var g = SceneObject(id: gid, name: try nonEmpty(c.name, "name") ?? "Group \(gid)", kind: .group)
            if let b = Geometry.bounds(of: ids, in: doc) { g.transform.position = Vec3(b.center.x, b.min.y, b.center.z) }
            if parents.count == 1, let p = parents.first, !p.isEmpty { g.parentId = p }
            doc.objects.append(g)
            for id in ids { doc.objects[doc.index(of: id)!].parentId = gid; changes.change(id) }
            changes.create(gid)
            if let r = c.ref { try checkRef(r); ctx.aliases[r] = gid }

        case .ungroup(let c):
            let id = try resolve(c.id, doc, ctx)
            let g = doc.object(id)!
            guard g.kind == .group else { throw CommandError.wrongKind("'\(id)' is a \(g.kind.rawValue), not a group") }
            for i in doc.objects.indices where doc.objects[i].parentId == id {
                doc.objects[i].parentId = g.parentId
                changes.change(doc.objects[i].id)
            }
            doc.objects.removeAll { $0.id == id }
            changes.delete(id)

        case .delete(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            let all = Set(expand(ids, doc, includeHosted: true))
            doc.objects.removeAll { all.contains($0.id) }
            for o in doc.objects.indices where doc.objects[o].parentId.map(all.contains) == true {
                doc.objects[o].parentId = nil
            }
            for id in all.sorted() { changes.delete(id) }

        case .duplicate(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            _ = try clone(ids, delta: c.offset ?? Vec3(0.5, 0, 0.5), doc: &doc, changes: &changes)

        case .array(let c):
            let ids = try resolveAll(c.ids, doc, ctx)
            guard (2...100).contains(c.count) else { throw CommandError.invalidParameter("count must be between 2 and 100") }
            guard c.spacing.isFinite, c.spacing.length > 1e-6 else { throw CommandError.invalidParameter("spacing must be a non-zero offset") }
            _ = try clone(ids, deltas: (1..<c.count).map { c.spacing * Double($0) }, doc: &doc, changes: &changes)

        case .addRoom(let c):
            try addRoom(c, doc: &doc, changes: &changes, ctx: &ctx)

        case .transaction(let c):
            ctx.depth += 1
            defer { ctx.depth -= 1 }
            guard ctx.depth <= 8 else { throw CommandError(code: .limitExceeded, message: "Transactions can be nested at most 8 deep") }
            for (i, sub) in c.commands.enumerated() {
                do { try execute(sub, doc: &doc, changes: &changes, ctx: &ctx) }
                catch var e as CommandError {
                    e.message = "In transaction step \(i + 1) (\(sub.name.rawValue)): \(e.message)"
                    throw e
                }
            }
        }
    }

    // MARK: rooms

    static func addRoom(_ c: AddRoomCommand, doc: inout SceneDocument, changes: inout ChangeSet, ctx: inout ExecutionContext) throws {
        for v in [c.x, c.z, c.width, c.depth, c.y ?? 0, c.height ?? 2.7, c.thickness ?? 0.2] where !v.isFinite {
            throw CommandError.invalidParameter("addRoom values must be finite numbers")
        }
        guard (0.3...200).contains(c.width), (0.3...200).contains(c.depth) else {
            throw CommandError.invalidParameter("addRoom width and depth must be between 0.3 and 200 m")
        }
        if let r = c.ref, r.isEmpty || r.count > 64 { throw CommandError.invalidParameter("ref must be 1-64 characters") }
        let t = c.thickness ?? 0.2, h = c.height ?? 2.7, y = c.y ?? 0
        let x0 = c.x, x1 = c.x + c.width, z0 = c.z, z1 = c.z + c.depth
        // Private refs for the generated objects; exposed under the caller's ref afterwards.
        var inner = ExecutionContext()
        func wall(_ key: String, _ name: String, _ a: Vec3, _ b: Vec3) -> Command {
            .add(AddCommand(kind: .wall, ref: key, name: name, from: a, to: b, params: ["height": .number(h), "thickness": .number(t)], material: c.wallMaterial))
        }
        let room = (c.name.map { try? nonEmpty($0, "name") } ?? nil) ?? "Room"
        var subs: [Command] = [
            wall("north", "\(room) north wall", Vec3(x0 - t / 2, y, z0), Vec3(x1 + t / 2, y, z0)),
            wall("south", "\(room) south wall", Vec3(x0 - t / 2, y, z1), Vec3(x1 + t / 2, y, z1)),
            wall("west", "\(room) west wall", Vec3(x0, y, z0 + t / 2), Vec3(x0, y, z1 - t / 2)),
            wall("east", "\(room) east wall", Vec3(x1, y, z0 + t / 2), Vec3(x1, y, z1 - t / 2)),
        ]
        var members = ["@north", "@south", "@west", "@east"]
        if c.floor ?? true {
            subs.append(.add(AddCommand(kind: .slab, ref: "floor", name: "\(room) floor", position: Vec3((x0 + x1) / 2, y, (z0 + z1) / 2),
                                        params: ["width": .number(c.width + t), "depth": .number(c.depth + t), "thickness": 0.2],
                                        material: c.floorMaterial ?? .named("oak"))))
            members.insert("@floor", at: 0)
        }
        subs.append(.group(GroupCommand(ids: members, ref: "room", name: room)))
        for sub in subs { try execute(sub, doc: &doc, changes: &changes, ctx: &inner) }
        if let r = c.ref {
            ctx.aliases[r] = inner.aliases["room"]
            for k in ["north", "south", "east", "west", "floor"] { if let id = inner.aliases[k] { ctx.aliases["\(r).\(k)"] = id } }
        }
    }

    // MARK: add / update

    static func add(_ c: AddCommand, doc: inout SceneDocument, changes: inout ChangeSet, ctx: inout ExecutionContext) throws {
        let kind = c.kind
        var params = try validatedParams(kind, c.params ?? [:], base: kind.defaultParams)
        var transform = Transform(position: c.position ?? .zero, rotation: normalizeAngle(c.rotation ?? 0))
        guard transform.position.isFinite, transform.rotation.isFinite else { throw CommandError.invalidParameter("position/rotation must be finite") }

        if c.from != nil || c.to != nil {
            guard kind == .wall else { throw CommandError.invalidParameter("'from'/'to' only apply to walls") }
            guard let a = c.from, let b = c.to else { throw CommandError.invalidParameter("Walls need both 'from' and 'to'") }
            guard c.position == nil, c.rotation == nil, c.params?["length"] == nil else {
                throw CommandError.invalidParameter("Give either from/to or position/rotation/length for a wall, not both")
            }
            let dx = b.x - a.x, dz = b.z - a.z
            let len = (dx * dx + dz * dz).squareRoot()
            params["length"] = try validatedParams(.wall, ["length": .number(len)], base: params)["length"]
            transform = Transform(position: a, rotation: normalizeAngle(atan2(-dz, dx) * 180 / .pi))
        }

        var hostId: String?
        if kind.isHosted {
            guard let h = c.host else { throw CommandError.invalidParameter("A \(kind.rawValue) needs a 'host' wall id") }
            let hid = try resolve(h, doc, ctx)
            let wall = doc.object(hid)!
            guard wall.kind == .wall else { throw CommandError.wrongKind("Host '\(hid)' is a \(wall.kind.rawValue), not a wall") }
            hostId = hid
            if c.params?["offset"] == nil { params["offset"] = .number(wall.number("length") / 2) }
            guard c.position == nil, c.rotation == nil else {
                throw CommandError.invalidParameter("Doors/windows are placed with params.offset along their host wall, not position/rotation")
            }
        } else if c.host != nil {
            throw CommandError.invalidParameter("Only doors and windows take a 'host'")
        }

        var parentId: String?
        if let p = c.parent {
            let pid = try resolve(p, doc, ctx)
            guard doc.object(pid)!.kind == .group else { throw CommandError.wrongKind("Parent '\(pid)' is not a group") }
            guard !kind.isHosted else { throw CommandError.invalidParameter("Doors/windows belong to their wall, not a group") }
            parentId = pid
        }

        let material = try c.material?.resolve()
        let id = try newId(c.id, kind: kind, doc: &doc)
        let name = try nonEmpty(c.name, "name") ?? defaultName(kind, id)
        let obj = SceneObject(id: id, name: name, kind: kind, transform: transform, params: params,
                              material: material, parentId: parentId, hostId: hostId)
        if kind.isHosted { try checkFit(obj, doc: doc) }
        doc.objects.append(obj)
        changes.create(id)
        if let r = c.ref {
            try checkRef(r)
            ctx.aliases[r] = id
        }
    }

    static func update(_ c: UpdateCommand, doc: inout SceneDocument, changes: inout ChangeSet, ctx: ExecutionContext) throws {
        let id = try resolve(c.id, doc, ctx)
        var o = doc.object(id)!
        if let n = try nonEmpty(c.name, "name") { o.name = n }
        if let p = c.params { o.params = try validatedParams(o.kind, p, base: o.params) }
        if let m = c.material {
            guard o.kind != .group else { throw CommandError.wrongKind("Use setMaterial to colour a group's members") }
            o.material = try m.resolve()
        }
        if let h = c.host {
            guard o.kind.isHosted else { throw CommandError.invalidParameter("Only doors and windows take a 'host'") }
            let hid = try resolve(h, doc, ctx)
            guard doc.object(hid)!.kind == .wall else { throw CommandError.wrongKind("Host '\(hid)' is not a wall") }
            o.hostId = hid
        }
        if o.kind.isHosted, c.position != nil || c.rotation != nil {
            throw CommandError.invalidParameter("Doors/windows are positioned by params.offset along their wall")
        }
        try replace(o, doc: &doc)
        changes.change(id)

        if let p = c.position {
            guard p.isFinite else { throw CommandError.invalidParameter("position must be finite") }
            try move([id], by: p - o.transform.position, doc: &doc, changes: &changes)
        }
        if let r = c.rotation {
            guard r.isFinite else { throw CommandError.invalidParameter("rotation must be finite") }
            let current = doc.object(id)!
            try rotate([id], degrees: r - current.transform.rotation, pivot: current.transform.position, doc: &doc, changes: &changes)
        }
    }

    /// Writes back an edited object after checking door/window fit (for it, or for a wall's openings).
    static func replace(_ o: SceneObject, doc: inout SceneDocument) throws {
        let i = doc.index(of: o.id)!
        let old = doc.objects[i]
        doc.objects[i] = o
        do {
            if o.kind.isHosted { try checkFit(o, doc: doc) }
            if o.kind == .wall { for h in doc.hosted(in: o.id) { try checkFit(h, doc: doc) } }
        } catch {
            doc.objects[i] = old
            throw error
        }
    }

    static func checkFit(_ o: SceneObject, doc: SceneDocument) throws {
        guard let p = Geometry.placement(of: o, in: doc) else { throw CommandError.notFound(o.hostId ?? "?") }
        let L = p.wall.number("length"), H = p.wall.number("height")
        let eps = 1e-6
        if p.offset - p.width / 2 < -eps || p.offset + p.width / 2 > L + eps {
            throw CommandError.doesNotFit("\(o.kind.rawValue.capitalized) '\(o.id)' (width \(fmt(p.width)) m at offset \(fmt(p.offset)) m) doesn't fit in wall '\(p.wall.id)' (length \(fmt(L)) m). The offset must be between \(fmt(p.width / 2)) and \(fmt(L - p.width / 2)).")
        }
        if p.sill + p.height > H + eps {
            throw CommandError.doesNotFit("\(o.kind.rawValue.capitalized) '\(o.id)' top (\(fmt(p.sill + p.height)) m) is above wall '\(p.wall.id)' height (\(fmt(H)) m)")
        }
    }

    // MARK: move / rotate

    static func move(_ ids: [String], by delta: Vec3, doc: inout SceneDocument, changes: inout ChangeSet) throws {
        let targets = expand(ids, doc, includeHosted: false)
        let set = Set(targets)
        for id in targets {
            let i = doc.index(of: id)!
            let o = doc.objects[i]
            if o.kind.isHosted {
                if let h = o.hostId, set.contains(h) { continue }
                guard let p = Geometry.placement(of: o, in: doc) else { continue }
                var n = o
                n.params["offset"] = .number(p.offset + delta.dot(p.along))
                try replace(n, doc: &doc)
            } else {
                doc.objects[i].transform.position += delta
            }
            changes.change(id)
        }
    }

    static func rotate(_ ids: [String], degrees: Double, pivot: Vec3?, doc: inout SceneDocument, changes: inout ChangeSet) throws {
        let targets = expand(ids, doc, includeHosted: false)
        let movable = targets.filter { id in
            let o = doc.object(id)!
            return !(o.kind.isHosted)
        }
        if movable.isEmpty {
            throw CommandError.wrongKind("Doors and windows turn with their wall; rotate the wall instead")
        }
        let pv: Vec3
        if let p = pivot { pv = p }
        else if ids.count == 1, let o = doc.object(ids[0]), o.kind != .group { pv = o.transform.position }
        else if let b = Geometry.bounds(of: ids, in: doc) { pv = Vec3(b.center.x, 0, b.center.z) }
        else { pv = .zero }
        for id in movable {
            let i = doc.index(of: id)!
            var t = doc.objects[i].transform
            let rel = t.position - pv
            let r = rotateY(Vec3(rel.x, 0, rel.z), degrees: degrees)
            t.position = Vec3(pv.x + r.x, t.position.y, pv.z + r.z)
            t.rotation = normalizeAngle(t.rotation + degrees)
            doc.objects[i].transform = t
            changes.change(id)
        }
    }

    static func normalizeAngle(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 }
        if x <= -180 { x += 360 }
        if abs(x) < 1e-9 { x = 0 }
        return x
    }

    // MARK: clone

    @discardableResult
    static func clone(_ ids: [String], delta: Vec3, doc: inout SceneDocument, changes: inout ChangeSet) throws -> [String: String] {
        try clone(ids, deltas: [delta], doc: &doc, changes: &changes).first ?? [:]
    }

    /// Makes one copy of `ids` (with group members and hosted doors/windows) per delta. All copies
    /// are appended at once, and the object limit is checked before any work is done.
    @discardableResult
    static func clone(_ ids: [String], deltas: [Vec3], doc: inout SceneDocument, changes: inout ChangeSet) throws -> [[String: String]] {
        let set = Set(expand(ids, doc, includeHosted: true))
        let sources = doc.objects.filter { set.contains($0.id) }
        let total = doc.objects.count + sources.count * deltas.count
        guard total <= Limits.maxObjects else {
            throw CommandError(code: .limitExceeded, message: "That would make \(total) objects (max \(Limits.maxObjects))")
        }
        var maps: [[String: String]] = []
        var added: [SceneObject] = []
        added.reserveCapacity(sources.count * deltas.count)
        for delta in deltas {
            var map: [String: String] = [:]
            for s in sources { map[s.id] = doc.makeId(for: s.kind) }
            for s in sources {
                var n = s
                n.id = map[s.id]!
                n.name = s.name == defaultName(s.kind, s.id) ? defaultName(s.kind, n.id) : s.name
                if let p = s.parentId { n.parentId = map[p] ?? p }
                if s.kind.isHosted {
                    if let h = s.hostId, let nh = map[h] {
                        n.hostId = nh
                    } else {
                        n.params["offset"] = .number(s.number("offset") + delta.x)
                    }
                } else {
                    n.transform.position += delta
                }
                added.append(n)
                changes.create(n.id)
            }
            maps.append(map)
        }
        doc.objects.append(contentsOf: added)
        for map in maps {
            for s in sources where s.kind.isHosted {
                try checkFit(doc.object(map[s.id]!)!, doc: doc)
            }
        }
        return maps
    }

    // MARK: helpers

    static func defaultName(_ kind: ObjectKind, _ id: String) -> String {
        "\(kind == .slab ? "Floor" : kind.displayName) \(id)"
    }

    /// Free text from people or agents: control characters (newlines, escapes) are removed, so a
    /// name can't break the line-per-object scene text, and length is capped.
    static func nonEmpty(_ s: String?, _ field: String) throws -> String? {
        guard let s else { return nil }
        let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        let t = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { throw CommandError.invalidParameter("'\(field)' must not be empty") }
        guard t.count <= Limits.maxNameLength else { throw CommandError.invalidParameter("'\(field)' must be at most \(Limits.maxNameLength) characters") }
        return t
    }

    static func checkRef(_ r: String) throws {
        guard !r.isEmpty, r.count <= 64, !r.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CommandError.invalidParameter("ref must be 1-64 characters")
        }
    }

    /// Run after every command: keeps documents within the limits regardless of how they were built.
    static func checkLimits(_ doc: SceneDocument) throws {
        guard doc.objects.count <= Limits.maxObjects else {
            throw CommandError(code: .limitExceeded, message: "That would make \(doc.objects.count) objects (max \(Limits.maxObjects))")
        }
        for o in doc.objects {
            let p = o.transform.position
            guard p.isFinite, abs(p.x) <= Limits.maxCoordinate, abs(p.y) <= Limits.maxCoordinate, abs(p.z) <= Limits.maxCoordinate else {
                throw CommandError.invalidParameter("\(o.id) would end up at \(p), outside ±\(Int(Limits.maxCoordinate)) m")
            }
        }
    }

    static func newId(_ requested: String?, kind: ObjectKind, doc: inout SceneDocument) throws -> String {
        guard let r = requested else { return doc.makeId(for: kind) }
        let range = NSRange(r.startIndex..., in: r)
        guard idPattern.firstMatch(in: r, range: range) != nil else {
            throw CommandError.invalidParameter("Id '\(r)' is invalid: use a letter followed by letters, digits, '_' or '-' (max 64)")
        }
        guard !doc.contains(r) else { throw CommandError(code: .conflict, message: "An object with id '\(r)' already exists") }
        return r
    }

    static func resolve(_ raw: String, _ doc: SceneDocument, _ ctx: ExecutionContext) throws -> String {
        var id = raw
        if raw.hasPrefix("@") {
            let key = String(raw.dropFirst())
            guard let real = ctx.aliases[key] else {
                throw CommandError(code: .notFound, message: "Unknown reference '\(raw)': no earlier command in this batch used \"ref\": \"\(key)\"")
            }
            id = real
        }
        guard doc.contains(id) else {
            if raw.hasPrefix("@") { throw CommandError(code: .notFound, message: "Reference '\(raw)' points to '\(id)', which no longer exists") }
            throw CommandError.notFound(id)
        }
        return id
    }

    static func resolveAll(_ raws: [String], _ doc: SceneDocument, _ ctx: ExecutionContext) throws -> [String] {
        guard !raws.isEmpty else { throw CommandError.invalidParameter("'ids' must list at least one object") }
        var out: [String] = []
        for r in raws { let id = try resolve(r, doc, ctx); if !out.contains(id) { out.append(id) } }
        return out
    }

    /// The ids plus group descendants (and, optionally, the doors/windows of included walls), in a stable order.
    static func expand(_ ids: [String], _ doc: SceneDocument, includeHosted: Bool) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ id: String) {
            guard seen.insert(id).inserted else { return }
            out.append(id)
            for d in doc.descendants(of: id) { add(d) }
            if includeHosted { for h in doc.hosted(in: id) { add(h.id) } }
        }
        ids.forEach(add)
        return out
    }

    static func validatedParams(_ kind: ObjectKind, _ given: [String: ParamValue], base: [String: ParamValue]) throws -> [String: ParamValue] {
        var out = base
        for (k, v) in given.sorted(by: { $0.key < $1.key }) {
            guard let spec = kind.spec(k) else {
                let allowed = kind.paramSpecs.map(\.key)
                throw CommandError.invalidParameter("\(kind.rawValue) has no parameter '\(k)'. \(allowed.isEmpty ? "It has no parameters." : "Parameters: \(allowed.joined(separator: ", "))")")
            }
            switch spec.validate(v) {
            case .success(let ok): out[k] = ok
            case .failure(let e): throw e
            }
        }
        return out
    }
}

import Foundation

/// A compact, deterministic description of a scene: what is there, how big, and how things relate.
/// Designed to be fed to a language model (text form) or a program (JSON form).
public struct SceneSummary: Codable, Hashable, Sendable {
    public struct ObjectInfo: Codable, Hashable, Sendable {
        public var id: String
        public var kind: ObjectKind
        public var name: String
        public var position: Vec3
        public var rotation: Double
        public var params: [String: ParamValue]
        public var material: String
        public var size: Vec3?
        public var group: String?
        public var host: String?
        /// Walls only: world start/end of the centre line.
        public var from: Vec3?
        public var to: Vec3?
    }

    public var name: String
    public var schemaVersion: Int
    public var units: String
    public var objectCount: Int
    public var bounds: Bounds?
    public var objects: [ObjectInfo]
    public var relations: [String]

    /// Summary of the whole document, or (with `only`) of just those objects and their relations.
    public init(_ doc: SceneDocument, only: Set<String>? = nil) {
        name = doc.name
        schemaVersion = doc.schemaVersion
        units = doc.units
        objectCount = doc.objects.count
        bounds = Geometry.documentBounds(doc).map { Bounds(min: r3($0.min), max: r3($0.max)) }
        var rel: [String] = []
        let listed = only.map { ids in doc.objects.filter { ids.contains($0.id) } } ?? doc.objects
        func involved(_ ids: String...) -> Bool { only.map { set in ids.contains { set.contains($0) } } ?? true }
        objects = listed.map { o in
            let b = Geometry.bounds(of: o, in: doc)
            var info = ObjectInfo(id: o.id, kind: o.kind, name: o.name,
                                  position: r3(Geometry.anchor(of: o, in: doc)), rotation: r(o.transform.rotation),
                                  params: o.params.mapValues { v in v.number.map { .number(r($0)) } ?? v },
                                  material: o.material.displayName, size: b.map { r3($0.size) },
                                  group: o.parentId, host: o.hostId)
            if o.kind == .wall {
                info.from = r3(o.transform.position)
                info.to = r3(o.transform.apply(Vec3(o.number("length"), 0, 0)))
            }
            if o.kind == .group { info.material = "-" }
            return info
        }
        for o in listed {
            if let h = o.hostId, let p = Geometry.placement(of: o, in: doc) {
                rel.append("\(o.id) (\(o.kind.rawValue)) is in wall \(h) at \(fmt(p.offset)) m from its start (the wall's +Z side faces \(compass(p.across)))")
            }
        }
        for g in listed where g.kind == .group {
            let kids = doc.children(of: g.id).map(\.id)
            rel.append("group \(g.id) \(quoted(g.name)) contains \(kids.isEmpty ? "nothing" : kids.joined(separator: ", "))")
        }
        // Wall joints: endpoints within a wall thickness of another wall's centre line ends.
        let walls = doc.objects.filter { $0.kind == .wall }
        // Bucket walls on a 2 m grid so only nearby walls are compared (was every pair).
        var buckets: [Int64: [Int]] = [:]
        func cells(_ w: SceneObject) -> [Int64] {
            let a = w.transform.position, b = w.transform.apply(Vec3(w.number("length"), 0, 0))
            let pad = w.number("thickness") * 1.01
            func c(_ v: Double) -> Int64 { Int64(max(-1_000_000, min(1_000_000, (v / 2).rounded(.down)))) }
            let x0 = c(min(a.x, b.x) - pad), x1 = c(max(a.x, b.x) + pad), z0 = c(min(a.z, b.z) - pad), z1 = c(max(a.z, b.z) + pad)
            guard (x1 - x0 + 1) * (z1 - z0 + 1) <= 10_000 else { return [Int64.min] }
            var out: [Int64] = []
            for x in x0...x1 { for z in z0...z1 { out.append(x &* 2_000_003 &+ z) } }
            return out
        }
        for (i, w) in walls.enumerated() { for k in cells(w) { buckets[k, default: []].append(i) } }
        var pairs = Set<Int>()
        for list in buckets.values where list.count > 1 {
            for x in 0..<list.count { for y in (x + 1)..<list.count { pairs.insert(list[x] * walls.count + list[y]) } }
        }
        for key in pairs.sorted() {
            let a = walls[key / walls.count], b = walls[key % walls.count]
            guard involved(a.id, b.id) else { continue }
            let tol = max(a.number("thickness"), b.number("thickness")) * 1.01
            let ea = [a.transform.position, a.transform.apply(Vec3(a.number("length"), 0, 0))]
            if let hit = ea.first(where: { distanceToSegment($0, b) <= tol }) {
                rel.append("wall \(a.id) meets wall \(b.id) near \(r3(hit))")
            } else {
                let eb = [b.transform.position, b.transform.apply(Vec3(b.number("length"), 0, 0))]
                if let hit = eb.first(where: { distanceToSegment($0, a) <= tol }) {
                    rel.append("wall \(b.id) meets wall \(a.id) near \(r3(hit))")
                }
            }
        }
        relations = rel
    }

    /// Plain text, one line per object. Stable for identical documents.
    public var text: String {
        var out = "Document \(quoted(name)): \(objectCount) object\(objectCount == 1 ? "" : "s"), units \(units). Y up, +X east, +Z south.\n"
        if let b = bounds {
            out += "Extents: x \(fmt(b.min.x))…\(fmt(b.max.x)), y \(fmt(b.min.y))…\(fmt(b.max.y)), z \(fmt(b.min.z))…\(fmt(b.max.z)) (\(fmt(b.size.x)) × \(fmt(b.size.z)) m footprint, \(fmt(b.size.y)) m tall)\n"
        }
        for o in objects {
            var line = "\(o.id) \(o.kind.rawValue) \(quoted(o.name))"
            switch o.kind {
            case .wall:
                line += " \(o.from ?? o.position)→\(o.to ?? o.position) length \(p(o, "length")) height \(p(o, "height")) thick \(p(o, "thickness"))"
            case .door, .window:
                line += " in \(o.host ?? "?") at offset \(p(o, "offset")) (centre \(o.position)) \(p(o, "width"))×\(p(o, "height"))"
                if o.kind == .window { line += " sill \(p(o, "sill"))" }
            case .group:
                if let s = o.size { line += " bbox \(fmt(s.x))×\(fmt(s.z))×\(fmt(s.y))" }
            default:
                line += " at \(o.position)"
                if o.rotation != 0 { line += " rot \(fmt(o.rotation))°" }
                let keys = o.params.keys.sorted()
                if !keys.isEmpty { line += " " + keys.map { "\($0) \(o.params[$0].map { quotedValue($0) } ?? "?")" }.joined(separator: ", ") }
            }
            if o.kind == .wall, o.rotation != 0 { line += " rot \(fmt(o.rotation))°" }
            if o.material != "-" { line += ", \(o.material)" }
            if let g = o.group { line += " [group \(g)]" }
            out += line + "\n"
        }
        if !relations.isEmpty {
            out += "Relations:\n" + relations.map { "- \($0)\n" }.joined()
        }
        return out
    }

    public func jsonString() -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "{}"
    }

    private func p(_ o: ObjectInfo, _ k: String) -> String { o.params[k]?.description ?? "?" }
}

/// Free text typed by people (or agents) is quoted and stripped of control characters, so it reads as
/// data and can't break the line structure an agent relies on.
public func quoted(_ s: String) -> String {
    let clean = String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
    return "\"" + String(clean.prefix(Limits.maxNameLength)).replacingOccurrences(of: "\"", with: "'") + "\""
}

private func quotedValue(_ v: ParamValue) -> String {
    if case .string(let s) = v { return String(quoted(s).dropFirst().dropLast()) }
    return v.description
}

private func r(_ v: Double) -> Double { (v * 1000).rounded() / 1000 + 0 }
private func r3(_ v: Vec3) -> Vec3 { Vec3(r(v.x), r(v.y), r(v.z)) }

private func distanceToSegment(_ p: Vec3, _ wall: SceneObject) -> Double {
    let a = wall.transform.position, dir = wall.transform.xAxis, L = wall.number("length")
    let t = max(0, min(L, (p - a).dot(dir)))
    let q = a + dir * t
    return (Vec3(p.x, 0, p.z) - Vec3(q.x, 0, q.z)).length
}

/// Compass name of a horizontal direction (north = -Z).
public func compass(_ v: Vec3) -> String {
    let ang = atan2(v.x, -v.z) * 180 / .pi   // 0 = north, 90 = east
    let names = ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
    let i = Int(((ang + 360).truncatingRemainder(dividingBy: 360) + 22.5) / 45) % 8
    return names[i]
}

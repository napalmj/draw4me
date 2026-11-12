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

    public init(_ doc: SceneDocument) {
        name = doc.name
        schemaVersion = doc.schemaVersion
        units = doc.units
        objectCount = doc.objects.count
        bounds = Geometry.documentBounds(doc).map { Bounds(min: r3($0.min), max: r3($0.max)) }
        var rel: [String] = []
        objects = doc.objects.map { o in
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
        for o in doc.objects {
            if let h = o.hostId, let p = Geometry.placement(of: o, in: doc) {
                rel.append("\(o.id) (\(o.kind.rawValue)) is in wall \(h) at \(fmt(p.offset)) m from its start (the wall's +Z side faces \(compass(p.across)))")
            }
        }
        for g in doc.objects where g.kind == .group {
            let kids = doc.children(of: g.id).map(\.id)
            rel.append("group \(g.id) \"\(g.name)\" contains \(kids.isEmpty ? "nothing" : kids.joined(separator: ", "))")
        }
        // Wall joints: endpoints within a wall thickness of another wall's centre line ends.
        let walls = doc.objects.filter { $0.kind == .wall }
        for (i, a) in walls.enumerated() {
            for b in walls[(i + 1)...] {
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
        }
        relations = rel
    }

    /// Plain text, one line per object. Stable for identical documents.
    public var text: String {
        var out = "Document \"\(name)\": \(objectCount) object\(objectCount == 1 ? "" : "s"), units \(units). Y up, +X east, +Z south.\n"
        if let b = bounds {
            out += "Extents: x \(fmt(b.min.x))…\(fmt(b.max.x)), y \(fmt(b.min.y))…\(fmt(b.max.y)), z \(fmt(b.min.z))…\(fmt(b.max.z)) (\(fmt(b.size.x)) × \(fmt(b.size.z)) m footprint, \(fmt(b.size.y)) m tall)\n"
        }
        for o in objects {
            var line = "\(o.id) \(o.kind.rawValue) \"\(o.name)\""
            switch o.kind {
            case .wall:
                line += " \(o.from!)→\(o.to!) length \(p(o, "length")) height \(p(o, "height")) thick \(p(o, "thickness"))"
            case .door, .window:
                line += " in \(o.host ?? "?") at offset \(p(o, "offset")) (centre \(o.position)) \(p(o, "width"))×\(p(o, "height"))"
                if o.kind == .window { line += " sill \(p(o, "sill"))" }
            case .group:
                if let s = o.size { line += " bbox \(fmt(s.x))×\(fmt(s.z))×\(fmt(s.y))" }
            default:
                line += " at \(o.position)"
                if o.rotation != 0 { line += " rot \(fmt(o.rotation))°" }
                let keys = o.params.keys.sorted()
                if !keys.isEmpty { line += " " + keys.map { "\($0) \(o.params[$0]!)" }.joined(separator: ", ") }
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

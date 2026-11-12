import Foundation

/// A soft problem with a design. Hard problems (a door that doesn't fit its wall, an unknown id)
/// are `CommandError`s and reject the change; warnings are reported alongside a successful change so
/// whoever made it (a person or an agent) can fix it in the next step.
public struct DesignWarning: Codable, Hashable, Sendable {
    public enum Code: String, Codable, CaseIterable, Sendable {
        /// Two solid objects overlap.
        case objectsIntersect
        /// An object's base is above the ground/floor with nothing under it.
        case floating
        /// An object sinks below the ground or into a floor slab.
        case belowFloor
        /// A dimension is legal but unusual (e.g. a 0.4 m tall door).
        case implausibleDimension
    }

    public var code: Code
    public var message: String
    /// Objects involved; the first is the one to fix.
    public var ids: [String]

    public init(_ code: Code, _ message: String, ids: [String]) {
        self.code = code; self.message = message; self.ids = ids
    }
}

/// Computes `DesignWarning`s for a document. Geometry-based checks use `Geometry` so they agree with
/// what the 3D view, 2D drawings and exports show.
public enum Validator {
    /// Overlaps smaller than this (metres) are treated as touching.
    public static let tolerance = 0.01

    /// Usual ranges for parameters. Values outside are allowed but produce `implausibleDimension`.
    public static let typicalRanges: [ObjectKind: [String: ClosedRange<Double>]] = [
        .wall: ["height": 1.0...8, "thickness": 0.05...0.6],
        .slab: ["thickness": 0.05...0.6],
        .door: ["width": 0.6...2.0, "height": 1.9...2.7],
        .window: ["width": 0.3...4, "height": 0.3...3, "sill": 0...2.2],
        .roof: ["pitch": 0...60],
        .table: ["height": 0.35...1.15, "width": 0.4...4, "depth": 0.4...1.6],
        .chair: ["seatHeight": 0.35...0.85, "width": 0.35...0.8, "depth": 0.35...0.8],
        .shelf: ["depth": 0.15...0.7],
    ]

    public static func warnings(for doc: SceneDocument) -> [DesignWarning] {
        var out: [DesignWarning] = []
        let index = DocIndex(doc)

        // Implausible dimensions.
        for o in doc.objects {
            guard let ranges = typicalRanges[o.kind] else { continue }
            for (key, range) in ranges.sorted(by: { $0.key < $1.key }) where !range.contains(o.number(key)) {
                let unit = o.kind.spec(key)?.type == .angle ? "°" : " m"
                out.append(DesignWarning(.implausibleDimension,
                    "\(o.id) \(key) is \(fmt(o.number(key)))\(unit); a \(o.kind.rawValue) is usually \(fmt(range.lowerBound))–\(fmt(range.upperBound))\(unit)",
                    ids: [o.id]))
            }
        }

        // Geometry: bounds of every solid object.
        let solids = doc.objects.filter { $0.kind != .group && !$0.kind.isHosted }
        var boxes: [(SceneObject, Bounds)] = []
        boxes.reserveCapacity(solids.count)
        for o in solids { if let b = index.bounds(o) { boxes.append((o, b)) } }

        // Intersections, using a uniform grid on the ground plane so this stays fast for big scenes.
        let grid = SpatialGrid(boxes.map(\.1), cell: 2.0)
        for i in boxes.indices {
            let (a, ba) = boxes[i]
            for j in grid.candidates(for: ba) where j > i {
                let (b, bb) = boxes[j]
                guard penetrates(ba, bb), !allowedContact(a, b, index) else { continue }
                out.append(DesignWarning(.objectsIntersect, "\(a.id) (\(a.kind.rawValue)) intersects \(b.id) (\(b.kind.rawValue))", ids: [a.id, b.id]))
            }
        }

        // Support: floating or sunk objects.
        for (i, (o, b)) in boxes.enumerated() where o.kind != .slab && o.kind != .roof {
            let base = b.min.y
            var support = 0.0          // the ground
            var supported = abs(base) <= tolerance
            for j in grid.candidates(for: b) where j != i {
                let (other, ob) = boxes[j]
                guard overlapsXZ(b, ob), other.kind != .roof else { continue }
                if abs(ob.max.y - base) <= tolerance * 2 { supported = true }
                if other.kind == .slab, ob.max.y <= base + tolerance * 2 { support = max(support, ob.max.y) }
                if other.kind == .slab, base < ob.max.y - tolerance, base > ob.min.y - tolerance {
                    out.append(DesignWarning(.belowFloor, "\(o.id) base (\(fmt(base)) m) is sunk into floor \(other.id) (top \(fmt(ob.max.y)) m)", ids: [o.id, other.id]))
                    supported = true
                }
            }
            if base < -tolerance, !supported {
                out.append(DesignWarning(.belowFloor, "\(o.id) base is \(fmt(-base)) m below the ground", ids: [o.id]))
            } else if base > support + tolerance, !supported {
                out.append(DesignWarning(.floating, "\(o.id) is floating \(fmt(base - support)) m above \(support == 0 ? "the ground" : "the floor") with nothing under it", ids: [o.id]))
            }
        }
        return out
    }

    /// Warnings that mention any of `ids`.
    public static func warnings(_ all: [DesignWarning], involving ids: Set<String>) -> [DesignWarning] {
        all.filter { w in w.ids.contains { ids.contains($0) } }
    }

    static func penetrates(_ a: Bounds, _ b: Bounds) -> Bool {
        min(a.max.x, b.max.x) - max(a.min.x, b.min.x) > tolerance
            && min(a.max.y, b.max.y) - max(a.min.y, b.min.y) > tolerance
            && min(a.max.z, b.max.z) - max(a.min.z, b.min.z) > tolerance
    }

    static func overlapsXZ(_ a: Bounds, _ b: Bounds) -> Bool {
        min(a.max.x, b.max.x) - max(a.min.x, b.min.x) > tolerance && min(a.max.z, b.max.z) - max(a.min.z, b.min.z) > tolerance
    }

    /// Pairs that legitimately overlap in their bounding boxes.
    static func allowedContact(_ a: SceneObject, _ b: SceneObject, _ index: DocIndex) -> Bool {
        let kinds: Set<ObjectKind> = [a.kind, b.kind]
        if kinds.contains(.roof), kinds.contains(.wall) { return true }       // roofs sit on walls
        if kinds == [.table, .chair] { return true }                           // chairs tuck under tables
        if a.kind == .wall, b.kind == .wall { return wallsConnected(a, b) }    // corners and T-junctions
        // Diagonal walls have loose bounding boxes; only flag them against compact objects.
        if kinds.contains(.wall) {
            let w = a.kind == .wall ? a : b
            let r = abs(w.transform.rotation.truncatingRemainder(dividingBy: 90))
            if r > 1, r < 89 { return true }
        }
        return false
    }

    /// End points of a wall's centre line (on the ground plane).
    public static func wallEnds(_ w: SceneObject) -> (Vec3, Vec3) {
        (w.transform.position, w.transform.apply(Vec3(w.number("length"), 0, 0)))
    }

    /// True when an end of one wall touches the other wall's centre line (corner or T-junction).
    public static func wallsConnected(_ a: SceneObject, _ b: SceneObject) -> Bool {
        let (a1, a2) = wallEnds(a), (b1, b2) = wallEnds(b)
        let tol = max(a.number("thickness"), b.number("thickness")) / 2 + 0.02
        return [a1, a2].contains { distanceXZ($0, b1, b2) <= tol } || [b1, b2].contains { distanceXZ($0, a1, a2) <= tol }
    }

    static func distanceXZ(_ p: Vec3, _ a: Vec3, _ b: Vec3) -> Double {
        let ab = Vec3(b.x - a.x, 0, b.z - a.z), ap = Vec3(p.x - a.x, 0, p.z - a.z)
        let l2 = ab.dot(ab)
        let t = l2 > 1e-12 ? max(0, min(1, ap.dot(ab) / l2)) : 0
        let q = Vec3(a.x + ab.x * t, 0, a.z + ab.z * t)
        return ((p.x - q.x) * (p.x - q.x) + (p.z - q.z) * (p.z - q.z)).squareRoot()
    }
}

/// Uniform grid over the XZ plane for broad-phase overlap queries.
struct SpatialGrid {
    let cell: Double
    private var buckets: [Int64: [Int]] = [:]
    private let boxes: [Bounds]

    init(_ boxes: [Bounds], cell: Double) {
        self.cell = cell
        self.boxes = boxes
        for (i, b) in boxes.enumerated() { for k in keys(b) { buckets[k, default: []].append(i) } }
    }

    private func keys(_ b: Bounds) -> [Int64] {
        // Clamp so absurd coordinates can't explode the number of cells.
        func c(_ v: Double) -> Int64 { Int64(max(-1_000_000, min(1_000_000, (v / cell).rounded(.down)))) }
        let x0 = c(b.min.x), x1 = c(b.max.x), z0 = c(b.min.z), z1 = c(b.max.z)
        if (x1 - x0 + 1) * (z1 - z0 + 1) > 4096 { return [Int64.min] }   // huge objects share one overflow bucket
        var out: [Int64] = []
        for x in x0...x1 { for z in z0...z1 { out.append(x &* 2_000_003 &+ z) } }
        return out
    }

    /// Indices of boxes that may overlap `b` (always includes boxes in the overflow bucket).
    func candidates(for b: Bounds) -> [Int] {
        var seen = Set<Int>()
        var out: [Int] = []
        for k in keys(b) + [Int64.min] {
            for i in buckets[k] ?? [] where seen.insert(i).inserted { out.append(i) }
        }
        if keys(b) == [Int64.min] { return Array(boxes.indices) }
        return out.sorted()
    }
}

/// Per-call lookup tables so validation doesn't rescan the document for every object.
struct DocIndex {
    let doc: SceneDocument
    private let hostedByWall: [String: [SceneObject]]

    init(_ doc: SceneDocument) {
        self.doc = doc
        var h: [String: [SceneObject]] = [:]
        for o in doc.objects { if let w = o.hostId { h[w, default: []].append(o) } }
        hostedByWall = h
    }

    func bounds(_ o: SceneObject) -> Bounds? {
        Bounds(points: Geometry.parts(for: o, in: doc).flatMap { $0.faces.flatMap(\.points) })
    }
}

/// Size limits applied to anything that arrives from outside (files, the Command Console, transports).
public enum Limits {
    public static let maxCommandsPerRequest = 500
    public static let maxObjects = 20_000
}

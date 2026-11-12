import Foundation

/// A planar convex polygon in world space, wound counter-clockwise seen from outside.
public struct Face: Hashable, Sendable {
    public var points: [Vec3]
    /// Optional per-vertex normals (smooth shading). If nil, the face is flat-shaded.
    public var normals: [Vec3]?

    public init(_ points: [Vec3], normals: [Vec3]? = nil) {
        self.points = points; self.normals = normals
    }

    public var normal: Vec3 {
        guard points.count >= 3 else { return .up }
        var n = Vec3.zero
        for i in 1..<(points.count - 1) {
            n += (points[i] - points[0]).cross(points[i + 1] - points[0])
        }
        return n.normalized
    }

    public var centroid: Vec3 {
        points.reduce(Vec3.zero, +) * (1 / Double(max(points.count, 1)))
    }
}

/// A piece of an object's geometry with one material. `role` names the piece ("wall", "glass", "leg"…).
public struct Part: Hashable, Sendable {
    public var faces: [Face]
    public var material: Material
    public var role: String
}

/// Where a door/window sits in its host wall.
public struct HostedPlacement: Sendable {
    /// Point on the wall's centre line, at the opening's centre (along the wall) and its bottom (height).
    public var base: Vec3
    public var along: Vec3
    public var across: Vec3
    public var wall: SceneObject
    public var offset: Double
    public var width: Double
    public var height: Double
    public var sill: Double
}

/// A rectangular hole in a wall, in the wall's local coordinates (x along, y up).
public struct WallOpening: Hashable, Sendable {
    public var id: String
    public var kind: ObjectKind
    public var x0: Double, x1: Double, y0: Double, y1: Double
}

/// Pure geometry: turns parametric objects into faces. Shared by the 3D renderer, the 2D
/// drafting views, bounds/hit-testing and OBJ export, so they always agree.
public enum Geometry {

    // MARK: Primitives

    /// Closed convex solid from vertex index lists; faces are oriented outward automatically.
    static func solid(_ v: [Vec3], _ faces: [[Int]]) -> [Face] {
        let c = v.reduce(Vec3.zero, +) * (1 / Double(v.count))
        return faces.map { idx in
            var f = Face(idx.map { v[$0] })
            if f.normal.dot(f.centroid - c) < 0 { f.points.reverse() }
            return f
        }
    }

    /// Box centred at `center` with size (along local X, Y, local Z) and yaw.
    public static func box(center: Vec3, size: Vec3, yaw: Double = 0) -> [Face] {
        let ex = rotateY(Vec3(1, 0, 0), degrees: yaw), ez = rotateY(Vec3(0, 0, 1), degrees: yaw)
        let hx = size.x / 2, hy = size.y / 2, hz = size.z / 2
        var v: [Vec3] = []
        for sx in [-1.0, 1.0] { for sy in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
            v.append(center + ex * (hx * sx) + Vec3(0, hy * sy, 0) + ez * (hz * sz))
        } } }
        // index = ix*4 + iy*2 + iz
        return solid(v, [[0, 1, 3, 2], [4, 6, 7, 5], [0, 4, 5, 1], [2, 3, 7, 6], [0, 2, 6, 4], [1, 5, 7, 3]])
    }

    /// Vertical cylinder standing on `base`.
    public static func cylinder(base: Vec3, radius: Double, height: Double, segments: Int = 28) -> [Face] {
        var faces: [Face] = []
        var ring: [Vec3] = [], normals: [Vec3] = []
        for i in 0..<segments {
            let a = Double(i) / Double(segments) * 2 * .pi
            let n = Vec3(cos(a), 0, -sin(a))
            normals.append(n)
            ring.append(base + n * radius)
        }
        let up = Vec3(0, height, 0)
        for i in 0..<segments {
            let j = (i + 1) % segments
            faces.append(Face([ring[i], ring[j], ring[j] + up, ring[i] + up],
                              normals: [normals[i], normals[j], normals[j], normals[i]]))
        }
        faces.append(Face(ring.map { $0 + up }))            // top, CCW from above
        faces.append(Face(ring.reversed()))                 // bottom
        // Ensure sides face outward (ring winding above is CCW from above → sides outward).
        return faces.map { f in
            var f = f
            let out = f.centroid - Vec3(base.x, f.centroid.y, base.z)
            if f.normals != nil, f.normal.dot(out) < 0 { f.points.reverse(); f.normals?.reverse() }
            if f.normals == nil {
                let wantUp = f.centroid.y > base.y + height / 2
                if (f.normal.y > 0) != wantUp { f.points.reverse() }
            }
            return f
        }
    }

    // MARK: Objects

    public static func placement(of obj: SceneObject, in doc: SceneDocument) -> HostedPlacement? {
        guard obj.kind.isHosted, let hid = obj.hostId, let wall = doc.object(hid), wall.kind == .wall else { return nil }
        let off = obj.number("offset")
        let sill = obj.kind == .window ? obj.number("sill") : 0
        let base = wall.transform.apply(Vec3(off, sill, 0))
        return HostedPlacement(base: base, along: wall.transform.xAxis, across: wall.transform.zAxis, wall: wall,
                               offset: off, width: obj.number("width"), height: obj.number("height"), sill: sill)
    }

    public static func openings(in wall: SceneObject, doc: SceneDocument) -> [WallOpening] {
        doc.hosted(in: wall.id).map { o in
            let off = o.number("offset"), w = o.number("width"), h = o.number("height")
            let sill = o.kind == .window ? o.number("sill") : 0
            return WallOpening(id: o.id, kind: o.kind, x0: off - w / 2, x1: off + w / 2, y0: sill, y1: sill + h)
        }
    }

    /// The solid rectangles of a wall (local x/y ranges) after cutting out its openings.
    public static func wallCells(length L: Double, height H: Double, openings: [WallOpening]) -> [(x0: Double, x1: Double, y0: Double, y1: Double)] {
        var xs = Set([0.0, L])
        for o in openings {
            xs.insert(min(max(o.x0, 0), L)); xs.insert(min(max(o.x1, 0), L))
        }
        let sorted = xs.sorted()
        var cells: [(Double, Double, Double, Double)] = []
        for i in 0..<(sorted.count - 1) {
            let a = sorted[i], b = sorted[i + 1]
            guard b - a > 1e-6 else { continue }
            let m = (a + b) / 2
            let holes = openings.filter { $0.x0 < m && m < $0.x1 }
                .map { (max(0, $0.y0), min(H, $0.y1)) }.sorted { $0.0 < $1.0 }
            var y = 0.0
            for h in holes {
                if h.0 > y + 1e-6 { cells.append((a, b, y, h.0)) }
                y = max(y, h.1)
            }
            if H > y + 1e-6 { cells.append((a, b, y, H)) }
        }
        return cells
    }

    public static func parts(for obj: SceneObject, in doc: SceneDocument) -> [Part] {
        let t = obj.transform
        let m = obj.material
        func lbox(_ c: Vec3, _ s: Vec3) -> [Face] { box(center: t.apply(c), size: s, yaw: t.rotation) }
        func lcyl(_ c: Vec3, _ r: Double, _ h: Double) -> [Face] { cylinder(base: t.apply(c), radius: r, height: h) }

        switch obj.kind {
        case .group:
            return []

        case .wall:
            let L = obj.number("length"), H = obj.number("height"), T = obj.number("thickness")
            let cells = wallCells(length: L, height: H, openings: openings(in: obj, doc: doc))
            let faces = cells.flatMap { c in lbox(Vec3((c.x0 + c.x1) / 2, (c.y0 + c.y1) / 2, 0), Vec3(c.x1 - c.x0, c.y1 - c.y0, T)) }
            return [Part(faces: faces, material: m, role: "wall")]

        case .slab:
            let w = obj.number("width"), d = obj.number("depth"), th = obj.number("thickness")
            return [Part(faces: lbox(Vec3(0, -th / 2, 0), Vec3(w, th, d)), material: m, role: "slab")]

        case .box:
            let w = obj.number("width"), d = obj.number("depth"), h = obj.number("height")
            return [Part(faces: lbox(Vec3(0, h / 2, 0), Vec3(w, h, d)), material: m, role: "box")]

        case .cylinder:
            return [Part(faces: lcyl(.zero, obj.number("radius"), obj.number("height")), material: m, role: "cylinder")]

        case .door, .window:
            guard let p = placement(of: obj, in: doc) else { return [] }
            let wt = p.wall.number("thickness")
            let yaw = p.wall.transform.rotation
            func wbox(_ along: Double, _ up: Double, _ across: Double, _ size: Vec3) -> [Face] {
                box(center: p.base + p.along * along + Vec3(0, up, 0) + p.across * across, size: size, yaw: yaw)
            }
            let frameMat = Material(color: "#ECEAE6", roughness: 0.5)
            let fw = 0.05, fd = min(wt + 0.02, 0.3)
            var frame: [Face] = []
            frame += wbox(-p.width / 2 + fw / 2, p.height / 2, 0, Vec3(fw, p.height, fd))
            frame += wbox(p.width / 2 - fw / 2, p.height / 2, 0, Vec3(fw, p.height, fd))
            frame += wbox(0, p.height - fw / 2, 0, Vec3(p.width, fw, fd))
            if obj.kind == .window {
                frame += wbox(0, fw / 2, 0, Vec3(p.width, fw, fd))
                frame += wbox(0, p.height / 2, 0, Vec3(0.03, p.height - 2 * fw, 0.04)) // mullion
                let pane = wbox(0, p.height / 2, 0, Vec3(p.width - 2 * fw, p.height - 2 * fw, 0.012))
                return [Part(faces: frame, material: frameMat, role: "frame"), Part(faces: pane, material: m, role: "glass")]
            } else {
                let leaf = wbox(0, (p.height - fw) / 2, 0, Vec3(p.width - 2 * fw, p.height - fw, 0.045))
                let knobSide: Double = obj.string("hinge") == "left" ? 1 : -1
                let knob = wbox(knobSide * (p.width / 2 - fw - 0.08), 1.0, 0, Vec3(0.03, 0.03, 0.12))
                return [Part(faces: frame, material: frameMat, role: "frame"),
                        Part(faces: leaf, material: m, role: "leaf"),
                        Part(faces: knob, material: MaterialLibrary.preset("steel")!, role: "handle")]
            }

        case .roof:
            return roofParts(obj)

        case .table:
            let W = obj.number("width"), D = obj.number("depth"), H = obj.number("height")
            let tt = obj.number("topThickness"), ls = obj.number("legSize"), inset = obj.number("inset")
            let legH = H - tt
            var legs: [Face] = []
            let lx = max(W / 2 - inset - ls / 2, ls / 2), lz = max(D / 2 - inset - ls / 2, ls / 2)
            switch obj.string("legStyle") {
            case "round":
                for sx in [-1.0, 1.0] { for sz in [-1.0, 1.0] { legs += lcyl(Vec3(sx * lx, 0, sz * lz), ls / 2, legH) } }
            case "pedestal":
                legs += lcyl(.zero, max(ls, 0.05), legH)
                legs += lcyl(.zero, min(W, D) * 0.3, 0.03)
            case "trestle":
                for sx in [-1.0, 1.0] {
                    legs += lbox(Vec3(sx * lx, legH / 2, 0), Vec3(ls, legH, D * 0.75))
                    legs += lbox(Vec3(sx * lx, 0.025, 0), Vec3(ls * 1.6, 0.05, D * 0.85))
                }
                legs += lbox(Vec3(0, legH * 0.35, 0), Vec3(2 * lx, 0.06, 0.04))
            default:
                for sx in [-1.0, 1.0] { for sz in [-1.0, 1.0] { legs += lbox(Vec3(sx * lx, legH / 2, sz * lz), Vec3(ls, legH, ls)) } }
            }
            return [Part(faces: lbox(Vec3(0, H - tt / 2, 0), Vec3(W, tt, D)), material: m, role: "top"),
                    Part(faces: legs, material: m, role: "legs")]

        case .chair:
            let W = obj.number("width"), D = obj.number("depth"), sh = obj.number("seatHeight")
            let bh = max(obj.number("backHeight"), sh + 0.05), ls = obj.number("legSize")
            let st = 0.04
            var f: [Face] = lbox(Vec3(0, sh - st / 2, 0), Vec3(W, st, D))
            for sx in [-1.0, 1.0] { for sz in [-1.0, 1.0] {
                f += lbox(Vec3(sx * (W / 2 - ls / 2), (sh - st) / 2, sz * (D / 2 - ls / 2)), Vec3(ls, sh - st, ls))
            } }
            f += lbox(Vec3(0, sh + (bh - sh) / 2, -D / 2 + 0.015), Vec3(W, bh - sh, 0.03))
            return [Part(faces: f, material: m, role: "chair")]

        case .shelf:
            let W = obj.number("width"), D = obj.number("depth"), H = obj.number("height")
            let n = max(1, Int(obj.number("shelves"))), bt = obj.number("boardThickness")
            var f: [Face] = []
            for sx in [-1.0, 1.0] { f += lbox(Vec3(sx * (W / 2 - bt / 2), H / 2, 0), Vec3(bt, H, D)) }
            for i in 0..<n {
                let y = n == 1 ? H / 2 : bt / 2 + Double(i) * (H - bt) / Double(n - 1)
                f += lbox(Vec3(0, y, 0), Vec3(W - 2 * bt, bt, D))
            }
            f += lbox(Vec3(0, H / 2, -D / 2 + 0.004), Vec3(W - 2 * bt, H, 0.008))
            return [Part(faces: f, material: m, role: "shelf")]
        }
    }

    static func roofParts(_ obj: SceneObject) -> [Part] {
        let t = obj.transform, m = obj.material
        let w = obj.number("width"), d = obj.number("depth"), o = obj.number("overhang")
        let th = obj.number("thickness"), pitch = obj.number("pitch") * .pi / 180
        let W = w + 2 * o, D = d + 2 * o
        let style = obj.string("style")
        func world(_ p: [Vec3]) -> [Vec3] { p.map { t.apply($0) } }

        if style == "flat" || pitch < 0.5 * .pi / 180 {
            return [Part(faces: box(center: t.apply(Vec3(0, th / 2, 0)), size: Vec3(W, th, D), yaw: t.rotation), material: m, role: "roof")]
        }
        let tanP = tan(pitch)
        if style == "hip" {
            // Build with the ridge along the longer side, then rotate into place if needed.
            let swap = d > w
            let a = swap ? d : w, b = swap ? w : d       // a = ridge direction size
            let A = a + 2 * o, B = b + 2 * o
            let hr = b / 2 * tanP, ye = -o * tanP, rx = (a - b) / 2
            func p(_ x: Double, _ y: Double, _ z: Double) -> Vec3 { swap ? rotateY(Vec3(x, y, z), degrees: 90) : Vec3(x, y, z) }
            let v = [p(-A / 2, ye, -B / 2), p(A / 2, ye, -B / 2), p(A / 2, ye, B / 2), p(-A / 2, ye, B / 2),
                     p(-rx, hr, 0), p(rx, hr, 0)]
            let vw = world(v)
            var faces = solid(vw, [[0, 1, 5, 4], [3, 2, 5, 4], [1, 2, 5], [0, 3, 4], [0, 1, 2, 3]])
            if rx < 1e-6 { // pyramid: drop degenerate edges by de-duplicating points
                faces = faces.map { f in
                    var pts: [Vec3] = []
                    for q in f.points where !pts.contains(where: { ($0 - q).length < 1e-9 }) { pts.append(q) }
                    return Face(pts)
                }.filter { $0.points.count >= 3 }
            }
            return [Part(faces: faces, material: m, role: "roof")]
        }
        // Gable: two sloped slabs plus triangular gable infill at the footprint ends.
        let hr = d / 2 * tanP, ye = -o * tanP
        let dropV = th / cos(pitch)
        var slopes: [Face] = []
        for side in [-1.0, 1.0] {
            let top = [Vec3(-W / 2, ye, side * D / 2), Vec3(W / 2, ye, side * D / 2), Vec3(W / 2, hr, 0), Vec3(-W / 2, hr, 0)]
            let bottom = top.map { $0 - Vec3(0, dropV, 0) }
            slopes += solid(world(top + bottom), [[0, 1, 2, 3], [4, 5, 6, 7], [0, 1, 5, 4], [1, 2, 6, 5], [2, 3, 7, 6], [3, 0, 4, 7]])
        }
        var gables: [Face] = []
        let gt = 0.12
        for sx in [-1.0, 1.0] {
            let x = sx * (w / 2 - gt / 2)
            let tri = [Vec3(x - gt / 2, 0, -d / 2), Vec3(x - gt / 2, 0, d / 2), Vec3(x - gt / 2, hr - dropV, 0),
                       Vec3(x + gt / 2, 0, -d / 2), Vec3(x + gt / 2, 0, d / 2), Vec3(x + gt / 2, hr - dropV, 0)]
            gables += solid(world(tri), [[0, 1, 2], [3, 4, 5], [0, 1, 4, 3], [1, 2, 5, 4], [2, 0, 3, 5]])
        }
        return [Part(faces: slopes, material: m, role: "roof"),
                Part(faces: gables, material: MaterialLibrary.preset("white_paint")!, role: "gable")]
    }

    // MARK: Bounds

    public static func bounds(of obj: SceneObject, in doc: SceneDocument) -> Bounds? {
        if obj.kind == .group {
            return union(doc.descendants(of: obj.id).compactMap { id in doc.object(id).flatMap { o in bounds(of: o, in: doc) } })
        }
        return Bounds(points: parts(for: obj, in: doc).flatMap { $0.faces.flatMap(\.points) })
    }

    public static func bounds(of ids: [String], in doc: SceneDocument) -> Bounds? {
        union(ids.compactMap { id in doc.object(id).flatMap { o in bounds(of: o, in: doc) } })
    }

    static func union(_ bs: [Bounds]) -> Bounds? {
        guard var u = bs.first else { return nil }
        for b in bs.dropFirst() { u = u.union(b) }
        return u
    }

    public static func documentBounds(_ doc: SceneDocument) -> Bounds? {
        bounds(of: doc.objects.filter { $0.kind != .group }.map(\.id), in: doc)
    }

    /// Where an object "is" for move-to / summaries: transform position, or the opening base for hosted objects.
    public static func anchor(of obj: SceneObject, in doc: SceneDocument) -> Vec3 {
        if let p = placement(of: obj, in: doc) { return p.base }
        return obj.transform.position
    }
}

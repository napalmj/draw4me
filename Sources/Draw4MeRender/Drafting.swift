import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import Draw4MeCore

/// 2D drawing types.
public enum DraftView: String, CaseIterable, Codable, Sendable {
    /// Top-down floor plan, walls cut at 1 m.
    case plan
    /// Elevation seen from the south, looking north.
    case front
    /// Elevation seen from the east, looking west.
    case side

    public var title: String {
        switch self {
        case .plan: return "Plan"
        case .front: return "South Elevation"
        case .side: return "East Elevation"
        }
    }
}

public struct DraftOptions: Sendable {
    public var selected: Set<String> = []
    public var showDimensions = true
    public var showGrid = true
    public var showRoofOutline = true
    public var showLabels = true
    public var showTitle = true
    public init(selected: Set<String> = [], showDimensions: Bool = true, showGrid: Bool = true,
                showRoofOutline: Bool = true, showLabels: Bool = true, showTitle: Bool = true) {
        self.selected = selected; self.showDimensions = showDimensions; self.showGrid = showGrid
        self.showRoofOutline = showRoofOutline; self.showLabels = showLabels; self.showTitle = showTitle
    }
}

/// Maps between world coordinates and a y-down 2D canvas for one view.
public struct DraftLayout: Equatable, Sendable {
    public var view: DraftView
    /// Pixels (points) per metre.
    public var scale: Double
    /// Canvas position of view coordinate (0, 0).
    public var offset: CGPoint

    public init(view: DraftView, scale: Double, offset: CGPoint) {
        self.view = view; self.scale = scale; self.offset = offset
    }

    /// View coordinates in metres: u right, v down; `depth` grows toward the viewer.
    public static func uv(_ p: Vec3, _ view: DraftView) -> (u: Double, v: Double, depth: Double) {
        switch view {
        case .plan: return (p.x, p.z, p.y)
        case .front: return (p.x, -p.y, p.z)
        case .side: return (-p.z, -p.y, p.x)
        }
    }

    public func point(_ p: Vec3) -> CGPoint {
        let q = Self.uv(p, view)
        return CGPoint(x: offset.x + q.u * scale, y: offset.y + q.v * scale)
    }

    public func point(u: Double, v: Double) -> CGPoint {
        CGPoint(x: offset.x + u * scale, y: offset.y + v * scale)
    }

    /// World-space translation for a canvas drag (plan: x/z; elevations: in the view plane).
    public func worldDelta(_ d: CGSize) -> Vec3 {
        let du = Double(d.width) / scale, dv = Double(d.height) / scale
        switch view {
        case .plan: return Vec3(du, 0, dv)
        case .front: return Vec3(du, -dv, 0)
        case .side: return Vec3(0, -dv, -du)
        }
    }

    /// Plan only: canvas point → world (x, z).
    public func planWorld(_ pt: CGPoint) -> (x: Double, z: Double) {
        ((Double(pt.x - offset.x)) / scale, (Double(pt.y - offset.y)) / scale)
    }

    public func zoomed(by f: Double, about pt: CGPoint) -> DraftLayout {
        var l = self
        l.scale = max(2, min(2000, scale * f))
        let k = l.scale / scale
        l.offset = CGPoint(x: pt.x - (pt.x - offset.x) * k, y: pt.y - (pt.y - offset.y) * k)
        return l
    }
}

/// CoreGraphics drafting of plans and elevations. Used by the app's 2D view (inside a SwiftUI
/// Canvas) and by PNG export / headless rendering, so they are identical.
public enum Drafting {

    // MARK: Layout

    public static func contentBounds(_ doc: SceneDocument, view: DraftView) -> (u0: Double, v0: Double, u1: Double, v1: Double) {
        let pts = doc.objects.filter { $0.kind != .group }.flatMap { o in
            Geometry.parts(for: o, in: doc).flatMap { $0.faces.flatMap(\.points) }
        }
        guard !pts.isEmpty else {
            return view == .plan ? (-5, -4, 5, 4) : (-5, -3, 5, 0.5)
        }
        var u0 = Double.infinity, v0 = Double.infinity, u1 = -Double.infinity, v1 = -Double.infinity
        for p in pts {
            let q = DraftLayout.uv(p, view)
            u0 = min(u0, q.u); u1 = max(u1, q.u); v0 = min(v0, q.v); v1 = max(v1, q.v)
        }
        if view != .plan { v1 = max(v1, 0) } // include the ground line
        return (u0, v0, u1, v1)
    }

    public static func fit(_ doc: SceneDocument, view: DraftView, size: CGSize, margin: CGFloat = 80) -> DraftLayout {
        let b = contentBounds(doc, view: view)
        let w = max(b.u1 - b.u0, 1), h = max(b.v1 - b.v0, 1)
        let availW = max(Double(size.width - 2 * margin), 50), availH = max(Double(size.height - 2 * margin), 50)
        let s = min(availW / w, availH / h)
        let cu = (b.u0 + b.u1) / 2, cv = (b.v0 + b.v1) / 2
        return DraftLayout(view: view, scale: s,
                           offset: CGPoint(x: Double(size.width) / 2 - cu * s, y: Double(size.height) / 2 - cv * s))
    }

    // MARK: Drawing

    /// Draws into a y-down context (origin top-left), e.g. SwiftUI Canvas' CGContext.
    public static func draw(_ doc: SceneDocument, layout L: DraftLayout, size: CGSize, options o: DraftOptions = DraftOptions(), in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.setLineJoin(.round)
        ctx.setLineCap(.round)
        if o.showGrid { drawGrid(L, size: size, ctx) }
        switch L.view {
        case .plan: drawPlan(doc, L, o, ctx)
        default: drawElevation(doc, L, o, ctx)
        }
        if o.showTitle { drawTitle(doc, L, size, ctx) }
    }

    static func drawGrid(_ L: DraftLayout, size: CGSize, _ ctx: CGContext) {
        let step: Double = L.scale < 6 ? 10 : (L.scale < 15 ? 5 : 1)
        let topLeft = (u: (0 - Double(L.offset.x)) / L.scale, v: (0 - Double(L.offset.y)) / L.scale)
        let botRight = (u: (Double(size.width) - Double(L.offset.x)) / L.scale, v: (Double(size.height) - Double(L.offset.y)) / L.scale)
        func line(_ a: CGPoint, _ b: CGPoint, major: Bool) {
            ctx.setStrokeColor(CGColor(gray: major ? 0.82 : 0.91, alpha: 1))
            ctx.setLineWidth(major ? 0.8 : 0.5)
            ctx.strokeLineSegments(between: [a, b])
        }
        var u = (topLeft.u / step).rounded(.down) * step
        while u <= botRight.u {
            let major = Int((u / step).rounded()) % 5 == 0
            line(L.point(u: u, v: topLeft.v), L.point(u: u, v: botRight.v), major: major)
            u += step
        }
        var v = (topLeft.v / step).rounded(.down) * step
        while v <= botRight.v {
            let major = Int((v / step).rounded()) % 5 == 0
            line(L.point(u: topLeft.u, v: v), L.point(u: botRight.u, v: v), major: major)
            v += step
        }
    }

    // MARK: Plan

    static let cutHeight = 1.0

    static func path(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts)
        p.closeSubpath()
        return p
    }

    /// Solid (cut) intervals of a wall at plan cut height.
    static func wallSolidIntervals(_ wall: SceneObject, _ doc: SceneDocument) -> [(Double, Double)] {
        let L = wall.number("length")
        let cuts = Geometry.openings(in: wall, doc: doc).filter { $0.y0 <= cutHeight && cutHeight < $0.y1 }
            .map { (max(0, $0.x0), min(L, $0.x1)) }.sorted { $0.0 < $1.0 }
        var out: [(Double, Double)] = []
        var x = 0.0
        for c in cuts {
            if c.0 > x + 1e-6 { out.append((x, c.0)) }
            x = max(x, c.1)
        }
        if L > x + 1e-6 { out.append((x, L)) }
        return out
    }

    static func wallQuad(_ w: SceneObject, _ x0: Double, _ x1: Double, _ z0: Double, _ z1: Double, _ L: DraftLayout) -> [CGPoint] {
        [Vec3(x0, 0, z0), Vec3(x1, 0, z0), Vec3(x1, 0, z1), Vec3(x0, 0, z1)].map { L.point(w.transform.apply($0)) }
    }

    static func topFaces(_ o: SceneObject, _ doc: SceneDocument) -> [Face] {
        Geometry.parts(for: o, in: doc).flatMap(\.faces).filter { $0.normal.y > 0.2 }
            .sorted { $0.centroid.y < $1.centroid.y }
    }

    static func drawPlan(_ doc: SceneDocument, _ L: DraftLayout, _ o: DraftOptions, _ ctx: CGContext) {
        let objs = doc.objects
        // Slabs.
        for s in objs where s.kind == .slab {
            for f in topFaces(s, doc) {
                ctx.addPath(path(f.points.map(L.point)))
                ctx.setFillColor(Palette.tint(s.material.color, toWhite: 0.78))
                ctx.setStrokeColor(CGColor(gray: 0.55, alpha: 1)); ctx.setLineWidth(0.8)
                ctx.drawPath(using: .fillStroke)
            }
        }
        // Furniture and other objects, lowest first.
        let others = objs.filter { ![.slab, .wall, .door, .window, .roof, .group].contains($0.kind) }
        var faces: [(Face, SceneObject)] = []
        for x in others { for f in topFaces(x, doc) { faces.append((f, x)) } }
        faces.sort { $0.0.centroid.y < $1.0.centroid.y }
        for (f, x) in faces {
            ctx.addPath(path(f.points.map(L.point)))
            ctx.setFillColor(Palette.tint(x.material.color, toWhite: 0.45, alpha: max(0.3, x.material.opacity)))
            ctx.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); ctx.setLineWidth(0.7)
            ctx.drawPath(using: .fillStroke)
        }
        // Walls (poché).
        let walls = objs.filter { $0.kind == .wall }
        ctx.setFillColor(CGColor(gray: 0.22, alpha: 1))
        for w in walls {
            let t = w.number("thickness") / 2
            for (a, b) in wallSolidIntervals(w, doc) {
                ctx.addPath(path(wallQuad(w, a, b, -t, t, L)))
            }
        }
        ctx.fillPath()
        // Doors and windows.
        for h in objs where h.kind.isHosted {
            guard let p = Geometry.placement(of: h, in: doc) else { continue }
            let w = p.wall, t = w.number("thickness") / 2
            let x0 = p.offset - p.width / 2, x1 = p.offset + p.width / 2
            func wp(_ x: Double, _ z: Double) -> CGPoint { L.point(w.transform.apply(Vec3(x, 0, z))) }
            if h.kind == .window {
                guard p.sill <= cutHeight && cutHeight < p.sill + p.height else { continue }
                ctx.addPath(path([wp(x0, -t), wp(x1, -t), wp(x1, t), wp(x0, t)]))
                ctx.setFillColor(CGColor(srgbRed: 0.88, green: 0.95, blue: 0.99, alpha: 1))
                ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(0.8)
                ctx.drawPath(using: .fillStroke)
                ctx.setLineWidth(0.6)
                ctx.strokeLineSegments(between: [wp(x0, -0.015), wp(x1, -0.015), wp(x0, 0.015), wp(x1, 0.015)])
            } else {
                // Threshold, leaf (opened 90° to the wall's -Z side) and swing arc.
                let hingeLeft = h.string("hinge") != "right"
                let hx = hingeLeft ? x0 : x1, ox = hingeLeft ? x1 : x0
                let r = p.width
                ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1))
                ctx.setLineWidth(0.6)
                ctx.strokeLineSegments(between: [wp(x0, -t), wp(x0, t), wp(x1, -t), wp(x1, t)])
                ctx.setLineWidth(1.8)
                ctx.strokeLineSegments(between: [wp(hx, -t), wp(hx, -t - r)])
                ctx.setLineWidth(0.6)
                ctx.setLineDash(phase: 0, lengths: [3, 2])
                var arc: [CGPoint] = []
                for i in 0...24 {
                    let a = Double(i) / 24 * .pi / 2
                    let dx = (ox - hx) * sin(a), dz = -r * cos(a)
                    arc.append(wp(hx + dx, -t + dz))
                }
                ctx.addLines(between: arc)
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        // Roof outline (dashed, above the cut plane).
        if o.showRoofOutline {
            ctx.setStrokeColor(CGColor(gray: 0.45, alpha: 0.9))
            ctx.setLineWidth(0.7)
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            for r in objs where r.kind == .roof {
                for f in Geometry.parts(for: r, in: doc).filter({ $0.role == "roof" }).flatMap(\.faces) where f.normal.y > 0.2 {
                    ctx.addPath(path(f.points.map(L.point)))
                }
                ctx.strokePath()
            }
            ctx.setLineDash(phase: 0, lengths: [])
        }
        // Labels.
        if o.showLabels {
            for x in others {
                guard let b = Geometry.bounds(of: x, in: doc) else { continue }
                let c = L.point(Vec3(b.center.x, 0, b.center.z))
                let wpx = b.size.x * L.scale, dpx = b.size.z * L.scale
                guard max(wpx, dpx) > 46 else { continue }
                let dims = x.kind == .cylinder ? "⌀\(fmt(x.number("radius") * 2, decimals: 2))"
                    : "\(fmt(x.number("width"), decimals: 2)) × \(fmt(x.number("depth"), decimals: 2))"
                text(x.name, at: CGPoint(x: c.x, y: c.y - 6), size: 9, color: CGColor(gray: 0.1, alpha: 1), ctx, halo: true)
                text(dims, at: CGPoint(x: c.x, y: c.y + 6), size: 8, color: CGColor(gray: 0.35, alpha: 1), ctx, halo: true)
            }
            for h in objs where h.kind.isHosted {
                guard let p = Geometry.placement(of: h, in: doc), L.scale > 18 else { continue }
                let t = p.wall.number("thickness") / 2
                // Inside (-Z side); door tags go beyond the swing.
                let dist = h.kind == .door ? t + p.width + 0.25 : t + 0.28
                let at = L.point(p.base + p.across * -dist)
                text("\(h.id) \(fmt(p.width, decimals: 2))", at: at, size: 7.5, color: CGColor(gray: 0.35, alpha: 1), ctx, halo: true)
            }
        }
        if o.showDimensions {
            for w in walls { wallDimension(w, L, ctx) }
            if walls.isEmpty, !objs.isEmpty { overallDimensions(doc, L, ctx) }
        }
        // Selection.
        let sel = expandedSelection(doc, o.selected)
        if !sel.isEmpty {
            ctx.setStrokeColor(Palette.selection)
            ctx.setLineWidth(2)
            for id in sel.sorted() {
                guard let x = doc.object(id) else { continue }
                for poly in planOutline(x, doc, L) { ctx.addPath(path(poly)) }
            }
            ctx.strokePath()
        }
        northArrow(L, ctx)
    }

    static func expandedSelection(_ doc: SceneDocument, _ sel: Set<String>) -> Set<String> {
        var out = Set<String>()
        for id in sel {
            out.insert(id)
            for d in doc.descendants(of: id) { out.insert(d) }
        }
        return out
    }

    /// Canvas polygons outlining an object in plan (used for selection and hit testing).
    static func planOutline(_ x: SceneObject, _ doc: SceneDocument, _ L: DraftLayout) -> [[CGPoint]] {
        switch x.kind {
        case .group: return []
        case .wall:
            let t = x.number("thickness") / 2
            return [wallQuad(x, 0, x.number("length"), -t, t, L)]
        case .door, .window:
            guard let p = Geometry.placement(of: x, in: doc) else { return [] }
            let t = p.wall.number("thickness") / 2 + 0.06
            return [wallQuad(p.wall, p.offset - p.width / 2, p.offset + p.width / 2, -t, t, L)]
        default:
            return topFaces(x, doc).map { $0.points.map(L.point) }
        }
    }

    static func wallDimension(_ w: SceneObject, _ L: DraftLayout, _ ctx: CGContext) {
        let len = w.number("length"), t = w.number("thickness") / 2
        let off = t + max(0.35, 22 / L.scale)
        let a = L.point(w.transform.apply(Vec3(0, 0, off))), b = L.point(w.transform.apply(Vec3(len, 0, off)))
        let a0 = L.point(w.transform.apply(Vec3(0, 0, t + 0.05))), b0 = L.point(w.transform.apply(Vec3(len, 0, t + 0.05)))
        dimensionLine(a, b, ext: [(a0, a), (b0, b)], label: fmt(len, decimals: 2), ctx)
    }

    static func overallDimensions(_ doc: SceneDocument, _ L: DraftLayout, _ ctx: CGContext) {
        let b = contentBounds(doc, view: L.view)
        let gap = 24 / L.scale
        let y = b.v1 + gap
        dimensionLine(L.point(u: b.u0, v: y), L.point(u: b.u1, v: y), ext: [(L.point(u: b.u0, v: b.v1), L.point(u: b.u0, v: y)), (L.point(u: b.u1, v: b.v1), L.point(u: b.u1, v: y))],
                      label: fmt(b.u1 - b.u0, decimals: 2), ctx)
        let x = b.u1 + gap
        dimensionLine(L.point(u: x, v: b.v0), L.point(u: x, v: b.v1), ext: [(L.point(u: b.u1, v: b.v0), L.point(u: x, v: b.v0)), (L.point(u: b.u1, v: b.v1), L.point(u: x, v: b.v1))],
                      label: fmt(b.v1 - b.v0, decimals: 2), ctx)
    }

    static func dimensionLine(_ a: CGPoint, _ b: CGPoint, ext: [(CGPoint, CGPoint)], label: String, _ ctx: CGContext) {
        let col = CGColor(srgbRed: 0.12, green: 0.33, blue: 0.6, alpha: 1)
        ctx.setStrokeColor(col)
        ctx.setLineWidth(0.6)
        for (p, q) in ext {
            let dx = q.x - p.x, dy = q.y - p.y, l = max(hypot(dx, dy), 0.001)
            ctx.strokeLineSegments(between: [p, CGPoint(x: q.x + dx / l * 4, y: q.y + dy / l * 4)])
        }
        ctx.strokeLineSegments(between: [a, b])
        // 45° ticks
        let dx = b.x - a.x, dy = b.y - a.y, l = max(hypot(dx, dy), 0.001)
        let ux = dx / l, uy = dy / l
        let tx = (ux - uy) * 4, ty = (uy + ux) * 4
        ctx.setLineWidth(1.2)
        for p in [a, b] { ctx.strokeLineSegments(between: [CGPoint(x: p.x - tx, y: p.y - ty), CGPoint(x: p.x + tx, y: p.y + ty)]) }
        guard l > 24 else { return }
        var ang = atan2(dy, dx)
        if ang > .pi / 2 + 0.001 { ang -= .pi } else if ang < -.pi / 2 + 0.001 { ang += .pi }
        let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        // Place text on the "upper" side of the line in reading orientation.
        let nx = sin(ang), ny = -cos(ang)
        text(label, at: CGPoint(x: mid.x + nx * 7, y: mid.y + ny * 7), size: 9, color: col, ctx, angle: ang, halo: true)
    }

    static func northArrow(_ L: DraftLayout, _ ctx: CGContext) {
        _ = L
        let c = CGPoint(x: 34, y: 40)
        ctx.setFillColor(CGColor(gray: 0.15, alpha: 1))
        ctx.addPath(path([CGPoint(x: c.x, y: c.y - 16), CGPoint(x: c.x + 7, y: c.y + 8), CGPoint(x: c.x, y: c.y + 3), CGPoint(x: c.x - 7, y: c.y + 8)]))
        ctx.fillPath()
        text("N", at: CGPoint(x: c.x, y: c.y - 25), size: 10, color: CGColor(gray: 0.15, alpha: 1), ctx, bold: true)
    }

    // MARK: Elevations

    static func shade(_ n: Vec3) -> Double {
        let l = Vec3(-0.35, 0.75, 0.55).normalized
        return 0.62 + 0.38 * max(0, n.dot(l))
    }

    static func drawElevation(_ doc: SceneDocument, _ L: DraftLayout, _ o: DraftOptions, _ ctx: CGContext) {
        let viewDir: Vec3 = L.view == .front ? Vec3(0, 0, 1) : Vec3(1, 0, 0)  // toward the viewer
        var faces: [(Face, Material, String)] = []
        for x in doc.objects where x.kind != .group {
            for p in Geometry.parts(for: x, in: doc) {
                for f in p.faces where f.normal.dot(viewDir) > 0.01 { faces.append((f, p.material, x.id)) }
            }
        }
        // Painter's algorithm keyed on each face's nearest point (then centroid), so overhanging
        // eaves are drawn over the walls they project in front of.
        func key(_ f: Face) -> (Double, Double) {
            (f.points.map { DraftLayout.uv($0, L.view).depth }.max() ?? 0, DraftLayout.uv(f.centroid, L.view).depth)
        }
        faces.sort { key($0.0) < key($1.0) }
        let b = contentBounds(doc, view: L.view)
        // Ground band.
        let g0 = L.point(u: b.u0 - 1.5, v: 0), g1 = L.point(u: b.u1 + 1.5, v: 0)
        ctx.setFillColor(CGColor(gray: 0.94, alpha: 1))
        ctx.fill(CGRect(x: g0.x, y: g0.y, width: g1.x - g0.x, height: CGFloat(0.4 * L.scale)))
        for (f, m, _) in faces {
            let s = shade(f.normal)
            let c = MaterialLibrary.rgb(m.color) ?? (0.8, 0.8, 0.8)
            ctx.addPath(path(f.points.map(L.point)))
            ctx.setFillColor(CGColor(srgbRed: c.r * s, green: c.g * s, blue: c.b * s, alpha: max(m.opacity, 0.35)))
            ctx.setStrokeColor(CGColor(gray: 0.2, alpha: 0.75))
            ctx.setLineWidth(0.5)
            ctx.drawPath(using: .fillStroke)
        }
        ctx.setStrokeColor(CGColor(gray: 0.1, alpha: 1))
        ctx.setLineWidth(2)
        ctx.strokeLineSegments(between: [g0, g1])

        let sel = expandedSelection(doc, o.selected)
        if !sel.isEmpty {
            ctx.setStrokeColor(Palette.selection)
            ctx.setLineWidth(1.6)
            for (f, _, id) in faces where sel.contains(id) { ctx.addPath(path(f.points.map(L.point))) }
            ctx.strokePath()
        }

        if o.showDimensions, !doc.objects.isEmpty {
            let gap = 26 / L.scale
            let yb = max(b.v1, 0) + gap
            dimensionLine(L.point(u: b.u0, v: yb), L.point(u: b.u1, v: yb),
                          ext: [(L.point(u: b.u0, v: 0), L.point(u: b.u0, v: yb)), (L.point(u: b.u1, v: 0), L.point(u: b.u1, v: yb))],
                          label: fmt(b.u1 - b.u0, decimals: 2), ctx)
            let xr = b.u1 + gap
            dimensionLine(L.point(u: xr, v: 0), L.point(u: xr, v: b.v0),
                          ext: [(L.point(u: b.u1, v: b.v0), L.point(u: xr, v: b.v0))],
                          label: fmt(-b.v0, decimals: 2), ctx)
            // Level markers: tops of walls.
            let wallTops = Set(doc.objects.filter { $0.kind == .wall }.map { (($0.transform.position.y + $0.number("height")) * 1000).rounded() / 1000 })
            for h in wallTops.sorted() where abs(h + b.v0) > 0.05 {
                let p = L.point(u: b.u0, v: -h)
                let q = CGPoint(x: p.x - 34, y: p.y)
                ctx.setStrokeColor(CGColor(srgbRed: 0.12, green: 0.33, blue: 0.6, alpha: 1))
                ctx.setLineWidth(0.6)
                ctx.setLineDash(phase: 0, lengths: [3, 2])
                ctx.strokeLineSegments(between: [q, p])
                ctx.setLineDash(phase: 0, lengths: [])
                text("+\(fmt(h, decimals: 2))", at: CGPoint(x: q.x - 2, y: q.y - 7), size: 8.5,
                     color: CGColor(srgbRed: 0.12, green: 0.33, blue: 0.6, alpha: 1), ctx, align: .right, halo: true)
            }
        }
    }

    // MARK: Title

    static func drawTitle(_ doc: SceneDocument, _ L: DraftLayout, _ size: CGSize, _ ctx: CGContext) {
        let y = size.height - 22
        text("\(doc.name) — \(L.view.title)", at: CGPoint(x: 16, y: y), size: 11, color: CGColor(gray: 0.1, alpha: 1), ctx, align: .left, bold: true)
        // Scale bar.
        let candidates: [Double] = [0.5, 1, 2, 5, 10, 20, 50]
        let m = candidates.first { $0 * L.scale >= 60 } ?? 50
        let x0 = size.width - 16 - CGFloat(m * L.scale)
        let segs = 4
        let segW = CGFloat(m * L.scale) / CGFloat(segs)
        for i in 0..<segs {
            ctx.setFillColor(CGColor(gray: i % 2 == 0 ? 0.15 : 1, alpha: 1))
            ctx.fill(CGRect(x: x0 + CGFloat(i) * segW, y: y - 3, width: segW, height: 5))
        }
        ctx.setStrokeColor(CGColor(gray: 0.15, alpha: 1)); ctx.setLineWidth(0.6)
        ctx.stroke(CGRect(x: x0, y: y - 3, width: segW * CGFloat(segs), height: 5))
        text("0", at: CGPoint(x: x0, y: y - 11), size: 8, color: CGColor(gray: 0.2, alpha: 1), ctx)
        text("\(fmt(m)) m", at: CGPoint(x: x0 + segW * CGFloat(segs), y: y - 11), size: 8, color: CGColor(gray: 0.2, alpha: 1), ctx)
    }

    // MARK: Text

    public enum Align { case left, center, right }

    public static func text(_ s: String, at p: CGPoint, size: CGFloat, color: CGColor, _ ctx: CGContext,
                            angle: CGFloat = 0, align: Align = .center, bold: Bool = false, halo: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
        let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, s as CFString, attrs as CFDictionary))
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        let x: CGFloat = align == .left ? 0 : (align == .center ? -w / 2 : -w)
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        if halo {
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
            ctx.fill(CGRect(x: x - 2, y: -ascent / 2 - 1.5 - descent / 2, width: w + 4, height: ascent + descent + 3))
        }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: (ascent - descent) / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    // MARK: Hit testing

    static func contains(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// The id of the object under a canvas point, preferring small/high things over big/low ones.
    public static func hitTest(_ doc: SceneDocument, layout L: DraftLayout, point p: CGPoint) -> String? {
        if L.view == .plan {
            for h in doc.objects where h.kind.isHosted {
                if planOutline(h, doc, L).contains(where: { contains($0, p) }) { return h.id }
            }
            let others = doc.objects.filter { ![.slab, .wall, .door, .window, .roof, .group].contains($0.kind) }
                .sorted { (Geometry.bounds(of: $0, in: doc)?.max.y ?? 0) > (Geometry.bounds(of: $1, in: doc)?.max.y ?? 0) }
            for x in others where planOutline(x, doc, L).contains(where: { contains($0, p) }) { return x.id }
            for w in doc.objects where w.kind == .wall && planOutline(w, doc, L).contains(where: { contains($0, p) }) { return w.id }
            for s in doc.objects where s.kind == .slab && planOutline(s, doc, L).contains(where: { contains($0, p) }) { return s.id }
            return nil
        }
        let viewDir: Vec3 = L.view == .front ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        var best: (Double, String)?
        for x in doc.objects where x.kind != .group {
            for f in Geometry.parts(for: x, in: doc).flatMap(\.faces) where f.normal.dot(viewDir) > 0.01 {
                if contains(f.points.map(L.point), p) {
                    let d = DraftLayout.uv(f.centroid, L.view).depth
                    if best == nil || d > best!.0 { best = (d, x.id) }
                }
            }
        }
        return best?.1
    }

    // MARK: Export

    /// Renders a 2D view to PNG data (headless). `scale` is the pixel density (2 = Retina).
    public static func png(_ doc: SceneDocument, view: DraftView, size: CGSize, options: DraftOptions = DraftOptions(), scale: CGFloat = 2) -> Data? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: scale, y: -scale)
        let layout = fit(doc, view: view, size: size)
        draw(doc, layout: layout, size: size, options: options, in: ctx)
        guard let img = ctx.makeImage() else { return nil }
        return pngData(img)
    }

    public static func pngData(_ img: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}

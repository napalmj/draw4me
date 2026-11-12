import Foundation
import SceneKit
import AppKit
import Draw4MeCore

public extension Vec3 {
    var scn: SCNVector3 { SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)) }
    init(_ v: SCNVector3) { self.init(Double(v.x), Double(v.y), Double(v.z)) }
}

public enum Palette {
    public static func nsColor(_ hex: String, alpha: Double = 1) -> NSColor {
        let c = MaterialLibrary.rgb(hex) ?? (0.8, 0.8, 0.8)
        return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
    public static func cgColor(_ hex: String, alpha: Double = 1) -> CGColor {
        let c = MaterialLibrary.rgb(hex) ?? (0.8, 0.8, 0.8)
        return CGColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: alpha)
    }
    /// Mix a hex color toward white by `t` (0 = unchanged, 1 = white).
    public static func tint(_ hex: String, toWhite t: Double, alpha: Double = 1) -> CGColor {
        let c = MaterialLibrary.rgb(hex) ?? (0.8, 0.8, 0.8)
        return CGColor(srgbRed: c.r + (1 - c.r) * t, green: c.g + (1 - c.g) * t, blue: c.b + (1 - c.b) * t, alpha: alpha)
    }
    public static let selection = CGColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)
    public static let selectionNS = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.95, alpha: 1)
    /// Marks objects an agent (or script) just changed.
    public static let agent = CGColor(srgbRed: 0.12, green: 0.68, blue: 0.42, alpha: 1)
    public static let agentNS = NSColor(srgbRed: 0.12, green: 0.68, blue: 0.42, alpha: 1)
}

/// Options shared by the live 3D view and headless snapshots.
public struct SceneOptions: Sendable {
    public var selected: Set<String> = []
    public var showRoofs = true
    public var showGrid = true
    public var shadows = true
    /// Objects changed by the latest agent/script edit; tinted green until the person acts.
    public var agentChanged: Set<String> = []
    public init(selected: Set<String> = [], showRoofs: Bool = true, showGrid: Bool = true, shadows: Bool = true, agentChanged: Set<String> = []) {
        self.selected = selected; self.showRoofs = showRoofs; self.showGrid = showGrid; self.shadows = shadows
        self.agentChanged = agentChanged
    }
}

/// Builds SceneKit content from a document. Every object becomes one node named with its id,
/// so hit-testing a node gives the object id directly.
public enum SceneBuilder {
    public static let contentNodeName = "__content"

    /// A complete scene: environment (lights, ground, grid) + content.
    public static func makeScene(_ doc: SceneDocument, options: SceneOptions = SceneOptions()) -> SCNScene {
        let scene = SCNScene()
        installEnvironment(in: scene, options: options)
        let content = SCNNode()
        content.name = contentNodeName
        scene.rootNode.addChildNode(content)
        rebuild(content, doc: doc, options: options)
        fitShadows(scene, doc: doc)
        return scene
    }

    /// Replace the children of `content` with fresh nodes for `doc`.
    public static func rebuild(_ content: SCNNode, doc: SceneDocument, options: SceneOptions) {
        content.childNodes.forEach { $0.removeFromParentNode() }
        for obj in doc.objects where obj.kind != .group {
            if obj.kind == .roof && !options.showRoofs { continue }
            let parts = Geometry.parts(for: obj, in: doc)
            guard !parts.isEmpty else { continue }
            let selected = isSelected(obj, doc: doc, options.selected)
            let agent = !selected && (options.agentChanged.contains(obj.id) || obj.hostId.map(options.agentChanged.contains) == true)
            let node = SCNNode(geometry: geometry(parts, highlighted: selected, agent: agent))
            node.name = obj.id
            node.castsShadow = true
            content.addChildNode(node)
        }
    }

    /// Updates `content` from `old` to `doc`, rebuilding only nodes whose object, highlight, or
    /// dependent geometry changed (a wall's openings, an opening's wall). Falls back to a full
    /// rebuild when roof visibility changes. Returns how many nodes were rebuilt.
    @discardableResult
    public static func update(_ content: SCNNode, from old: SceneDocument, oldOptions: SceneOptions,
                              to doc: SceneDocument, options: SceneOptions) -> Int {
        guard oldOptions.showRoofs == options.showRoofs else { rebuild(content, doc: doc, options: options); return doc.objects.count }
        func state(_ o: SceneObject, _ d: SceneDocument, _ opt: SceneOptions) -> (Bool, Bool) {
            let sel = isSelected(o, doc: d, opt.selected)
            return (sel, !sel && (opt.agentChanged.contains(o.id) || o.hostId.map(opt.agentChanged.contains) == true))
        }
        var dirty = Set<String>()
        for o in doc.objects where o.kind != .group {
            guard let before = old.object(o.id) else { dirty.insert(o.id); continue }
            if before != o || state(before, old, oldOptions) != state(o, doc, options) { dirty.insert(o.id) }
        }
        var removed = Set<String>()
        for o in old.objects where !doc.contains(o.id) {
            removed.insert(o.id)
            if let h = o.hostId { dirty.insert(h) }
        }
        // Openings cut their wall; walls carry their openings.
        for id in Array(dirty) {
            guard let o = doc.object(id) else { continue }
            if let h = o.hostId { dirty.insert(h) }
            if o.kind == .wall { for h in doc.hosted(in: id) { dirty.insert(h.id) } }
            if let before = old.object(id), let h = before.hostId { dirty.insert(h) }
        }
        dirty.subtract(removed)
        guard !dirty.isEmpty || !removed.isEmpty else { return 0 }
        var nodes: [String: SCNNode] = [:]
        for n in content.childNodes { if let name = n.name { nodes[name] = n } }
        for id in removed.union(dirty) { nodes[id]?.removeFromParentNode() }
        var rebuilt = 0
        for id in dirty {
            guard let obj = doc.object(id), obj.kind != .group, !(obj.kind == .roof && !options.showRoofs) else { continue }
            let parts = Geometry.parts(for: obj, in: doc)
            guard !parts.isEmpty else { continue }
            let (selected, agent) = state(obj, doc, options)
            let node = SCNNode(geometry: geometry(parts, highlighted: selected, agent: agent))
            node.name = obj.id
            node.castsShadow = true
            content.addChildNode(node)
            rebuilt += 1
        }
        return rebuilt
    }

    static func isSelected(_ o: SceneObject, doc: SceneDocument, _ sel: Set<String>) -> Bool {
        if sel.contains(o.id) { return true }
        var p = o.parentId
        while let id = p { if sel.contains(id) { return true }; p = doc.object(id)?.parentId }
        return false
    }

    public static func geometry(_ parts: [Part], highlighted: Bool, agent: Bool = false) -> SCNGeometry {
        var verts: [SCNVector3] = [], norms: [SCNVector3] = []
        var elements: [SCNGeometryElement] = [], materials: [SCNMaterial] = []
        for part in parts {
            var idx: [UInt32] = []
            for f in part.faces {
                let base = UInt32(verts.count)
                let n = f.normal
                for (i, p) in f.points.enumerated() {
                    verts.append(p.scn)
                    norms.append((f.normals?[i] ?? n).scn)
                }
                for i in 1..<(f.points.count - 1) { idx += [base, base + UInt32(i), base + UInt32(i + 1)] }
            }
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
            materials.append(material(part.material, highlighted: highlighted, agent: agent))
        }
        let g = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)], elements: elements)
        g.materials = materials
        return g
    }

    public static func material(_ m: Material, highlighted: Bool, agent: Bool = false) -> SCNMaterial {
        let s = SCNMaterial()
        s.lightingModel = .physicallyBased
        s.diffuse.contents = Palette.nsColor(m.color)
        s.roughness.contents = NSNumber(value: m.roughness)
        s.metalness.contents = NSNumber(value: m.preset == "steel" ? 0.7 : 0.0)
        if m.opacity < 0.999 {
            s.transparency = CGFloat(m.opacity)
            s.isDoubleSided = true
            s.writesToDepthBuffer = false
            s.blendMode = .alpha
        }
        if highlighted {
            s.emission.contents = Palette.selectionNS.withAlphaComponent(1)
            s.emission.intensity = 0.35
        } else if agent {
            s.emission.contents = Palette.agentNS.withAlphaComponent(1)
            s.emission.intensity = 0.3
        }
        return s
    }

    // MARK: Environment

    public static func installEnvironment(in scene: SCNScene, options: SceneOptions) {
        scene.background.contents = skyImage()
        scene.lightingEnvironment.contents = skyImage()
        scene.lightingEnvironment.intensity = 0.75

        let sun = SCNLight()
        sun.type = .directional
        sun.intensity = 950
        sun.color = NSColor(srgbRed: 1, green: 0.97, blue: 0.92, alpha: 1)
        sun.castsShadow = options.shadows
        sun.shadowMode = .deferred
        sun.shadowSampleCount = 16
        sun.shadowRadius = 6
        sun.shadowColor = NSColor(white: 0, alpha: 0.35)
        sun.automaticallyAdjustsShadowProjection = false
        sun.orthographicScale = 20
        sun.zNear = 1; sun.zFar = 200
        let sunNode = SCNNode()
        sunNode.name = "__sun"
        sunNode.light = sun
        sunNode.position = SCNVector3(30, 50, 40)
        sunNode.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(sunNode)

        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = 120
        let ambNode = SCNNode(); ambNode.light = ambient; ambNode.name = "__ambient"
        scene.rootNode.addChildNode(ambNode)

        let floor = SCNFloor()
        floor.reflectivity = 0
        let fm = SCNMaterial()
        fm.lightingModel = .physicallyBased
        fm.diffuse.contents = NSColor(srgbRed: 0.86, green: 0.87, blue: 0.84, alpha: 1)
        fm.roughness.contents = NSNumber(value: 1)
        floor.materials = [fm]
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "__ground"
        floorNode.position = SCNVector3(0, -0.002, 0)
        scene.rootNode.addChildNode(floorNode)

        if options.showGrid {
            let grid = gridNode(halfExtent: 30)
            grid.name = "__grid"
            scene.rootNode.addChildNode(grid)
        }
    }

    /// Aim the sun's shadow box at the content.
    public static func fitShadows(_ scene: SCNScene, doc: SceneDocument) {
        guard let sun = scene.rootNode.childNode(withName: "__sun", recursively: false) else { return }
        let b = Geometry.documentBounds(doc) ?? Bounds(min: Vec3(-5, 0, -5), max: Vec3(5, 3, 5))
        let c = b.center
        let r = max(b.size.length / 2, 3)
        sun.position = (c + Vec3(0.45, 0.8, 0.55).normalized * (r * 3)).scn
        sun.look(at: c.scn)
        sun.light?.orthographicScale = CGFloat(r * 1.3)
        sun.light?.zFar = CGFloat(r * 8)
    }

    static func gridNode(halfExtent n: Int) -> SCNNode {
        func lines(step: Int, color: NSColor) -> SCNNode {
            var v: [SCNVector3] = [], idx: [UInt32] = []
            let e = CGFloat(n)
            for i in stride(from: -n, through: n, by: step) {
                let f = CGFloat(i)
                let b = UInt32(v.count)
                v += [SCNVector3(f, 0.003, -e), SCNVector3(f, 0.003, e), SCNVector3(-e, 0.003, f), SCNVector3(e, 0.003, f)]
                idx += [b, b + 1, b + 2, b + 3]
            }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: v)], elements: [SCNGeometryElement(indices: idx, primitiveType: .line)])
            let m = SCNMaterial()
            m.lightingModel = .constant
            m.diffuse.contents = color
            m.writesToDepthBuffer = false
            g.materials = [m]
            return SCNNode(geometry: g)
        }
        let node = SCNNode()
        node.addChildNode(lines(step: 1, color: NSColor(white: 0.72, alpha: 0.5)))
        node.addChildNode(lines(step: 5, color: NSColor(white: 0.55, alpha: 0.7)))
        node.renderingOrder = -1
        return node
    }

    nonisolated(unsafe) private static var cachedSky: CGImage?
    static func skyImage() -> CGImage {
        if let s = cachedSky { return s }
        let w = 256, h = 128
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let colors = [CGColor(srgbRed: 0.98, green: 0.98, blue: 0.97, alpha: 1),  // horizon
                      CGColor(srgbRed: 0.80, green: 0.87, blue: 0.95, alpha: 1),  // sky top
                      ] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: [0, 1])!
        // Equirectangular: top half sky (image y-up in CG), bottom half ground.
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: CGFloat(h) / 2), end: CGPoint(x: 0, y: CGFloat(h)), options: [])
        ctx.setFillColor(CGColor(srgbRed: 0.78, green: 0.78, blue: 0.76, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h / 2))
        let img = ctx.makeImage()!
        cachedSky = img
        return img
    }
}

/// Orbit camera state (target, yaw, pitch, distance). Shared by the live view and snapshots.
public struct OrbitCamera: Equatable, Sendable {
    public var target: Vec3
    /// Degrees; 0 looks north (camera south of target).
    public var yaw: Double
    /// Degrees above the horizon.
    public var pitch: Double
    public var distance: Double
    public var fieldOfView: Double = 40

    public init(target: Vec3 = .zero, yaw: Double = -35, pitch: Double = 28, distance: Double = 14) {
        self.target = target; self.yaw = yaw; self.pitch = pitch; self.distance = distance
    }

    public var position: Vec3 {
        let p = pitch * .pi / 180, y = yaw * .pi / 180
        return target + Vec3(sin(y) * cos(p), sin(p), cos(y) * cos(p)) * distance
    }

    /// A camera that frames the whole document.
    public static func fitting(_ doc: SceneDocument, yaw: Double = -35, pitch: Double = 28, aspect: Double = 1.5) -> OrbitCamera {
        let b = Geometry.documentBounds(doc) ?? Bounds(min: Vec3(-3, 0, -3), max: Vec3(3, 2, 3))
        var cam = OrbitCamera(target: b.center, yaw: yaw, pitch: pitch, distance: 10)
        let r = max(b.size.length / 2, 1)
        let fov = cam.fieldOfView * .pi / 180
        let hfov = 2 * atan(tan(fov / 2) * aspect)
        cam.distance = r / tan(min(fov, hfov) / 2) * 0.95
        return cam
    }

    public func apply(to node: SCNNode) {
        if node.camera == nil { node.camera = SCNCamera() }
        node.camera?.fieldOfView = CGFloat(fieldOfView)
        node.camera?.zNear = 0.05
        node.camera?.zFar = max(500, distance * 10)
        node.position = position.scn
        node.look(at: target.scn, up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }
}

import SwiftUI
import SceneKit
import AppKit
import Draw4MeCore
import Draw4MeRender

/// SceneKit view with SketchUp-style navigation:
/// - drag empty space: orbit · right-drag / ⌥-drag / ⇧-drag: pan · scroll / pinch: zoom
/// - click: select (⇧/⌘-click: add/remove) · drag a selected object: move it on the ground plane
///   (snaps to 5 cm; hold ⌥ while moving for free movement) · ⌫: delete · F: frame all
final class ViewportView: SCNView {
    var onSelect: ((String?, _ extend: Bool) -> Void)?
    var onMove: (([String], Vec3) -> Void)?
    var onOrbit: ((OrbitCamera) -> Void)?
    var onDelete: (() -> Void)?
    var onFrame: (() -> Void)?

    let cameraNode = SCNNode()
    let content: SCNNode
    var orbit = OrbitCamera() { didSet { orbit.apply(to: cameraNode) } }
    private(set) var document = SceneDocument()
    private(set) var selection: Set<String> = []
    private var showRoofs = true

    private enum DragMode { case none, pendingClick(String?), orbit, pan, move(ids: [String], planeY: Double, start: Vec3) }
    private var dragMode: DragMode = .none
    private var downPoint = CGPoint.zero
    private var moved = false
    private var liveDelta = Vec3.zero
    /// Re-frame the scene for this view's own aspect ratio at the next layout.
    var needsFit = true

    override func layout() {
        super.layout()
        if needsFit, bounds.width > 10, bounds.height > 10 { fitToView() }
    }

    func fitToView() {
        needsFit = false
        orbit = OrbitCamera.fitting(document, yaw: orbit.yaw, pitch: orbit.pitch,
                                    aspect: Double(bounds.width / max(bounds.height, 1)))
        onOrbit?(orbit)
    }

    init() {
        let scene = SceneBuilder.makeScene(SceneDocument())
        content = scene.rootNode.childNode(withName: SceneBuilder.contentNodeName, recursively: false)!
        super.init(frame: .zero, options: nil)
        self.scene = scene
        scene.rootNode.addChildNode(cameraNode)
        pointOfView = cameraNode
        orbit.apply(to: cameraNode)
        allowsCameraControl = false
        antialiasingMode = .multisampling4X
        backgroundColor = .white
        rendersContinuously = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(document: SceneDocument, selection: Set<String>, showRoofs: Bool) {
        guard document != self.document || selection != self.selection || showRoofs != self.showRoofs else { return }
        let docChanged = document != self.document
        self.document = document; self.selection = selection; self.showRoofs = showRoofs
        SceneBuilder.rebuild(content, doc: document, options: SceneOptions(selected: selection, showRoofs: showRoofs))
        if docChanged, let s = scene { SceneBuilder.fitShadows(s, doc: document) }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Picking

    func objectId(at p: CGPoint) -> (String, SCNVector3)? {
        let hits = hitTest(p, options: [.searchMode: NSNumber(value: SCNHitTestSearchMode.all.rawValue), .ignoreHiddenNodes: true])
        for h in hits {
            var n: SCNNode? = h.node
            while let node = n, node.parent !== content { n = node.parent }
            if let id = n?.name, document.contains(id) { return (id, h.worldCoordinates) }
        }
        return nil
    }

    /// Selected ids that a drag starting on `id` should move (the object, or its selected group).
    func dragTargets(for id: String) -> [String]? {
        var cur: String? = id
        while let c = cur {
            if selection.contains(c) { return document.objects.map(\.id).filter(selection.contains) }
            cur = document.object(c)?.parentId
        }
        return nil
    }

    func groundPoint(_ p: CGPoint, planeY: Double) -> Vec3? {
        let a = Vec3(unprojectPoint(SCNVector3(p.x, p.y, 0)))
        let b = Vec3(unprojectPoint(SCNVector3(p.x, p.y, 1)))
        let d = b - a
        guard abs(d.y) > 1e-9 else { return nil }
        let t = (planeY - a.y) / d.y
        guard t > 0 else { return nil }
        return a + d * t
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(e.locationInWindow, from: nil)
        downPoint = p; moved = false; liveDelta = .zero
        if e.modifierFlags.contains(.option) || e.modifierFlags.contains(.shift) && objectId(at: p) == nil {
            dragMode = .pan; return
        }
        if let (id, hit) = objectId(at: p), let ids = dragTargets(for: id), !e.modifierFlags.contains(.shift), !e.modifierFlags.contains(.command) {
            dragMode = .move(ids: ids, planeY: Double(hit.y), start: Vec3(hit))
        } else {
            dragMode = .pendingClick(objectId(at: p)?.0)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if !moved, hypot(p.x - downPoint.x, p.y - downPoint.y) < 3 { return }
        moved = true
        switch dragMode {
        case .pendingClick, .orbit:
            dragMode = .orbit
            orbit.yaw -= Double(e.deltaX) * 0.4
            orbit.pitch = max(-5, min(89, orbit.pitch + Double(e.deltaY) * 0.4))
            onOrbit?(orbit)
        case .pan:
            pan(dx: e.deltaX, dy: e.deltaY)
        case .move(let ids, let planeY, let start):
            guard let g = groundPoint(p, planeY: planeY) else { return }
            var d = g - start
            d.y = 0
            if !e.modifierFlags.contains(.option) { d = Vec3((d.x / 0.05).rounded() * 0.05, 0, (d.z / 0.05).rounded() * 0.05) }
            liveDelta = d
            preview(ids: ids, delta: d)
        case .none: break
        }
    }

    override func mouseUp(with e: NSEvent) {
        defer { dragMode = .none }
        let extend = e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command)
        switch dragMode {
        case .pendingClick(let id):
            if !moved { onSelect?(id, extend) }
        case .move(let ids, _, _):
            if moved, liveDelta.length > 1e-9 { onMove?(ids, liveDelta) }
            else if !moved { onSelect?(objectId(at: downPoint)?.0, extend) }
        default: break
        }
    }

    /// Live preview: offset the affected nodes; the real change happens on mouse-up via a move command.
    private func preview(ids: [String], delta: Vec3) {
        var affected = Set<String>()
        func add(_ id: String) {
            affected.insert(id)
            document.descendants(of: id).forEach(add)
            document.hosted(in: id).forEach { add($0.id) }
        }
        ids.forEach(add)
        for node in content.childNodes {
            guard let id = node.name else { continue }
            if affected.contains(id), let o = document.object(id) {
                if o.kind.isHosted, let h = o.hostId, !affected.contains(h), let w = document.object(h) {
                    let along = w.transform.xAxis
                    node.position = (along * delta.dot(along)).scn
                } else {
                    node.position = delta.scn
                }
            } else {
                node.position = SCNVector3Zero
            }
        }
    }

    override func rightMouseDown(with e: NSEvent) { dragMode = .pan }
    override func rightMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }
    override func rightMouseUp(with e: NSEvent) { dragMode = .none }
    override func otherMouseDragged(with e: NSEvent) { pan(dx: e.deltaX, dy: e.deltaY) }

    private func pan(dx: CGFloat, dy: CGFloat) {
        let k = orbit.distance * 0.0016
        let fwd = (orbit.target - orbit.position).normalized
        let right = fwd.cross(.up).normalized
        let up = right.cross(fwd).normalized
        orbit.target = orbit.target - right * (Double(dx) * k) + up * (Double(dy) * k)
        onOrbit?(orbit)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.modifierFlags.contains(.shift) {
            pan(dx: -e.scrollingDeltaX, dy: e.scrollingDeltaY)
            return
        }
        let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.01 : e.scrollingDeltaY * 0.08
        zoom(by: exp(-Double(dy)))
    }

    override func magnify(with e: NSEvent) { zoom(by: 1 / (1 + Double(e.magnification))) }

    private func zoom(by f: Double) {
        orbit.distance = max(0.5, min(500, orbit.distance * f))
        onOrbit?(orbit)
    }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 51, 117: onDelete?()          // delete, forward delete
        case 53: onSelect?(nil, false)      // escape
        default:
            if e.charactersIgnoringModifiers?.lowercased() == "f" { onFrame?() } else { super.keyDown(with: e) }
        }
    }
}

struct Viewport3D: NSViewRepresentable {
    @ObservedObject var model: AppModel

    func makeNSView(context: Context) -> ViewportView {
        let v = ViewportView()
        v.orbit = model.orbit
        context.coordinator.lastFrameRequest = model.frameRequest
        wire(v)
        v.update(document: model.document, selection: model.selection, showRoofs: model.showRoofs)
        return v
    }

    func updateNSView(_ v: ViewportView, context: Context) {
        wire(v)
        v.update(document: model.document, selection: model.selection, showRoofs: model.showRoofs)
        if context.coordinator.lastFrameRequest != model.frameRequest {
            context.coordinator.lastFrameRequest = model.frameRequest
            v.fitToView()
        } else if v.orbit != model.orbit {
            v.orbit = model.orbit
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastFrameRequest = 0 }

    private func wire(_ v: ViewportView) {
        let model = self.model
        v.onSelect = { id, extend in
            guard let id else { if !extend { model.selection = [] }; return }
            if extend {
                if model.selection.contains(id) { model.selection.remove(id) } else { model.selection.insert(id) }
            } else {
                model.selection = [id]
            }
        }
        v.onMove = { ids, delta in model.apply(.move(MoveCommand(ids: ids, by: delta))) }
        v.onOrbit = { cam in
            // Keep the model's camera in sync without triggering a full SwiftUI cycle per frame.
            DispatchQueue.main.async { if model.orbit != cam { model.orbit = cam } }
        }
        v.onDelete = { model.deleteSelection() }
        v.onFrame = { model.frameAll() }
    }
}

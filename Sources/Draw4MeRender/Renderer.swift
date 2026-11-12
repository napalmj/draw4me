import Foundation
import SceneKit
import AppKit
import Metal
import Draw4MeCore

/// Every view the headless renderer can produce.
public enum RenderView: String, CaseIterable, Codable, Sendable {
    /// Shaded 3D perspective (SceneKit).
    case perspective
    /// Shaded 3D orthographic view from above (shows roofs; an aerial / roof plan).
    case top
    /// 2D floor plan with dimensions.
    case plan
    /// 2D south elevation.
    case front
    /// 2D east elevation.
    case side

    public var is3D: Bool { self == .perspective || self == .top }
    public var draftView: DraftView? {
        switch self {
        case .plan: return .plan
        case .front: return .front
        case .side: return .side
        default: return nil
        }
    }
}

/// A render request. Codable so it can arrive as JSON from any future automation transport.
public struct RenderRequest: Codable, Hashable, Sendable {
    public var view: RenderView
    public var width: Int?
    public var height: Int?
    /// Object ids to highlight.
    public var highlight: [String]?
    /// Perspective only: camera yaw/pitch in degrees (default -35 / 28) — the camera always frames the scene.
    public var yaw: Double?
    public var pitch: Double?
    public var showRoofs: Bool?

    public init(view: RenderView, width: Int? = nil, height: Int? = nil, highlight: [String]? = nil,
                yaw: Double? = nil, pitch: Double? = nil, showRoofs: Bool? = nil) {
        self.view = view; self.width = width; self.height = height; self.highlight = highlight
        self.yaw = yaw; self.pitch = pitch; self.showRoofs = showRoofs
    }

    public var size: CGSize {
        CGSize(width: max(64, min(4096, width ?? 1200)), height: max(64, min(4096, height ?? 800)))
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noMetalDevice, snapshotFailed, encodingFailed
    public var description: String {
        switch self {
        case .noMetalDevice: return "No Metal device available for 3D rendering"
        case .snapshotFailed: return "SceneKit snapshot failed"
        case .encodingFailed: return "PNG encoding failed"
        }
    }
}

/// Headless rendering: document in, PNG out. Works without any window, so a CLI, a test, or a
/// future AI bridge ("let the agent see the design") can call it directly.
public enum Renderer {
    public static func png(_ doc: SceneDocument, request r: RenderRequest) throws -> Data {
        let size = r.size
        if let dv = r.view.draftView {
            guard let data = Drafting.png(doc, view: dv, size: size, options: DraftOptions(selected: Set(r.highlight ?? []))) else {
                throw RenderError.encodingFailed
            }
            return data
        }
        let options = SceneOptions(selected: Set(r.highlight ?? []), showRoofs: r.showRoofs ?? true)
        let cam: CameraSpec = r.view == .top ? .top : .orbit(OrbitCamera.fitting(doc, yaw: r.yaw ?? -35, pitch: r.pitch ?? 28,
                                                                                   aspect: Double(size.width / size.height)))
        let img = try snapshot(doc, camera: cam, size: size, options: options)
        guard let data = Drafting.pngData(img) else { throw RenderError.encodingFailed }
        return data
    }

    public enum CameraSpec {
        case orbit(OrbitCamera)
        case top
    }

    /// Render a SceneKit image. `size` is in pixels.
    public static func snapshot(_ doc: SceneDocument, camera: CameraSpec, size: CGSize, options: SceneOptions = SceneOptions()) throws -> CGImage {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noMetalDevice }
        let scene = SceneBuilder.makeScene(doc, options: options)
        let camNode = SCNNode()
        switch camera {
        case .orbit(let o):
            o.apply(to: camNode)
        case .top:
            let b = Geometry.documentBounds(doc) ?? Bounds(min: Vec3(-5, 0, -5), max: Vec3(5, 3, 5))
            let cam = SCNCamera()
            cam.usesOrthographicProjection = true
            let aspect = Double(size.width / size.height)
            cam.orthographicScale = max(b.size.z / 2, b.size.x / 2 / aspect) * 1.15 + 0.5
            cam.zNear = 0.1
            cam.zFar = b.max.y + 200
            camNode.camera = cam
            camNode.position = SCNVector3(CGFloat(b.center.x), CGFloat(b.max.y + 100), CGFloat(b.center.z))
            camNode.look(at: SCNVector3(CGFloat(b.center.x), 0, CGFloat(b.center.z)), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        }
        scene.rootNode.addChildNode(camNode)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = camNode
        renderer.autoenablesDefaultLighting = false
        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw RenderError.snapshotFailed }
        return cg
    }
}

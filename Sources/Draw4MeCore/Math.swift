import Foundation

/// A 3D vector in metres.
///
/// World convention (same as SceneKit): **+Y is up**, **+X is east**, **+Z is south**
/// (so north is -Z, which is "up" on a plan drawing). Rotations are yaw-only, in degrees,
/// counter-clockwise when seen from above.
public struct Vec3: Codable, Hashable, Sendable, CustomStringConvertible {
    public var x: Double
    public var y: Double
    public var z: Double

    private enum CodingKeys: String, CodingKey { case x, y, z }

    /// Accepts `{"x":1,"y":0,"z":2}` (missing components default to 0) or `[1, 0, 2]`.
    public init(from decoder: Decoder) throws {
        if var arr = try? decoder.unkeyedContainer() {
            let x = try arr.decode(Double.self), y = try arr.decode(Double.self), z = try arr.decode(Double.self)
            self.init(x, y, z)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(try c.decodeIfPresent(Double.self, forKey: .x) ?? 0,
                  try c.decodeIfPresent(Double.self, forKey: .y) ?? 0,
                  try c.decodeIfPresent(Double.self, forKey: .z) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(x, forKey: .x); try c.encode(y, forKey: .y); try c.encode(z, forKey: .z)
    }

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x; self.y = y; self.z = z
    }

    public init(x: Double = 0, y: Double = 0, z: Double = 0) {
        self.x = x; self.y = y; self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public static let up = Vec3(0, 1, 0)

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func += (a: inout Vec3, b: Vec3) { a = a + b }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }
    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(y * o.z - z * o.y, z * o.x - x * o.z, x * o.y - y * o.x)
    }
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public var normalized: Vec3 { let l = length; return l > 1e-12 ? self * (1 / l) : self }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public var description: String { "(\(fmt(x)), \(fmt(y)), \(fmt(z)))" }
}

/// Rotate a vector about the +Y axis by `degrees` (counter-clockwise seen from above).
/// Matches SceneKit: local +X maps to (cos θ, 0, -sin θ).
public func rotateY(_ v: Vec3, degrees: Double) -> Vec3 {
    let t = degrees * .pi / 180
    let c = cos(t), s = sin(t)
    return Vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c)
}

/// Object placement. Rotation is yaw (about +Y) in degrees.
public struct Transform: Codable, Hashable, Sendable {
    public var position: Vec3
    public var rotation: Double

    public init(position: Vec3 = .zero, rotation: Double = 0) {
        self.position = position
        self.rotation = rotation
    }

    /// Unit vector of the object's local +X axis in world space.
    public var xAxis: Vec3 { rotateY(Vec3(1, 0, 0), degrees: rotation) }
    /// Unit vector of the object's local +Z axis in world space.
    public var zAxis: Vec3 { rotateY(Vec3(0, 0, 1), degrees: rotation) }

    public func apply(_ local: Vec3) -> Vec3 { position + rotateY(local, degrees: rotation) }
}

/// Axis-aligned bounding box.
public struct Bounds: Codable, Hashable, Sendable {
    public var min: Vec3
    public var max: Vec3

    public init(min: Vec3, max: Vec3) { self.min = min; self.max = max }

    public init?(points: [Vec3]) {
        guard let f = points.first else { return nil }
        var lo = f, hi = f
        for p in points.dropFirst() {
            lo = Vec3(Swift.min(lo.x, p.x), Swift.min(lo.y, p.y), Swift.min(lo.z, p.z))
            hi = Vec3(Swift.max(hi.x, p.x), Swift.max(hi.y, p.y), Swift.max(hi.z, p.z))
        }
        self.init(min: lo, max: hi)
    }

    public var size: Vec3 { max - min }
    public var center: Vec3 { (min + max) * 0.5 }

    public func union(_ o: Bounds) -> Bounds {
        Bounds(min: Vec3(Swift.min(min.x, o.min.x), Swift.min(min.y, o.min.y), Swift.min(min.z, o.min.z)),
               max: Vec3(Swift.max(max.x, o.max.x), Swift.max(max.y, o.max.y), Swift.max(max.z, o.max.z)))
    }
}

/// Deterministic short number formatting used in summaries and labels ("2.5", "0.75", "6").
public func fmt(_ v: Double, decimals: Int = 3) -> String {
    var value = v
    if abs(value) < 0.5 * pow(10, -Double(decimals)) { value = 0 }
    var s = String(format: "%.\(decimals)f", value)
    if s.contains(".") {
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
    }
    if s == "-0" { s = "0" }
    return s
}

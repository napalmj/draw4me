import Foundation

/// Wavefront OBJ + MTL export straight from `Geometry`, with no framework dependencies.
public enum OBJExporter {
    /// Returns (obj text, mtl text). `mtlFileName` is referenced from the OBJ.
    public static func export(_ doc: SceneDocument, mtlFileName: String) -> (obj: String, mtl: String) {
        var obj = "# draw4me export: \(doc.name)\n# units: metres, Y up\nmtllib \(mtlFileName)\n"
        var mtl = "# draw4me materials\n"
        var materials: [Material: String] = [:]
        var vertexCount = 0
        for o in doc.objects where o.kind != .group {
            obj += "o \(o.id)_\(sanitize(o.name))\n"
            for part in Geometry.parts(for: o, in: doc) {
                let mname: String
                if let n = materials[part.material] { mname = n } else {
                    mname = "m\(materials.count)_\(sanitize(part.material.displayName))"
                    materials[part.material] = mname
                    let c = MaterialLibrary.rgb(part.material.color) ?? (0.8, 0.8, 0.8)
                    mtl += "newmtl \(mname)\nKd \(fmt(c.r, decimals: 4)) \(fmt(c.g, decimals: 4)) \(fmt(c.b, decimals: 4))\nd \(fmt(part.material.opacity))\nillum 2\n\n"
                }
                obj += "usemtl \(mname)\n"
                for f in part.faces {
                    for p in f.points { obj += "v \(fmt(p.x, decimals: 5)) \(fmt(p.y, decimals: 5)) \(fmt(p.z, decimals: 5))\n" }
                    obj += "f " + (1...f.points.count).map { "\(vertexCount + $0)" }.joined(separator: " ") + "\n"
                    vertexCount += f.points.count
                }
            }
        }
        return (obj, mtl)
    }

    static func sanitize(_ s: String) -> String {
        String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" })
    }
}

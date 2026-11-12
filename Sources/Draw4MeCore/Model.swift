import Foundation

/// Every kind of object a document can contain. Parameters for each kind are defined once,
/// in `paramSpecs`, and everything else (validation, inspector UI, command catalog,
/// scene summary) is derived from that table.
public enum ObjectKind: String, Codable, CaseIterable, Hashable, Sendable {
    case wall, slab, door, window, roof, box, cylinder, table, chair, shelf, group

    public var displayName: String {
        switch self {
        case .slab: return "Floor / Slab"
        default: return rawValue.capitalized
        }
    }

    /// Prefix used for generated ids ("W1", "D2", ...).
    public var idPrefix: String {
        switch self {
        case .wall: return "W"
        case .slab: return "S"
        case .door: return "D"
        case .window: return "WN"
        case .roof: return "R"
        case .box: return "B"
        case .cylinder: return "CY"
        case .table: return "T"
        case .chair: return "CH"
        case .shelf: return "SH"
        case .group: return "G"
        }
    }

    /// Doors and windows live inside a host wall; their position is derived from the wall.
    public var isHosted: Bool { self == .door || self == .window }

    /// How `transform.position` is interpreted for this kind.
    public var anchorDescription: String {
        switch self {
        case .wall: return "position = wall start point at its base; the wall runs `length` along its local +X (rotation turns it)"
        case .door, .window: return "placed in a host wall; `offset` = distance from the wall start to the opening centre"
        case .group: return "groups have no geometry; moving/rotating a group moves its members"
        case .slab: return "position = centre of the slab's TOP surface (the slab extends `thickness` downward)"
        default: return "position = centre of the footprint at the object's base"
        }
    }

    public var paramSpecs: [ParamSpec] {
        switch self {
        case .wall:
            return [
                ParamSpec("length", .length, 4, min: 0.05, max: 200, "Length along the wall"),
                ParamSpec("height", .length, 2.7, min: 0.05, max: 50, "Height"),
                ParamSpec("thickness", .length, 0.2, min: 0.01, max: 3, "Thickness (centred on the wall line)"),
            ]
        case .slab:
            return [
                ParamSpec("width", .length, 4, min: 0.05, max: 500, "Size along X (east-west)"),
                ParamSpec("depth", .length, 4, min: 0.05, max: 500, "Size along Z (north-south)"),
                ParamSpec("thickness", .length, 0.2, min: 0.01, max: 5, "Thickness"),
            ]
        case .door:
            return [
                ParamSpec("width", .length, 0.9, min: 0.3, max: 6, "Opening width"),
                ParamSpec("height", .length, 2.1, min: 0.5, max: 6, "Opening height"),
                ParamSpec("offset", .length, 1, min: 0, max: 200, "Distance from the host wall's start to the door centre"),
                ParamSpec("hinge", .choice(["left", "right"]), "left", "Hinge side seen from the wall's +Z side"),
            ]
        case .window:
            return [
                ParamSpec("width", .length, 1.2, min: 0.2, max: 10, "Opening width"),
                ParamSpec("height", .length, 1.2, min: 0.2, max: 6, "Opening height"),
                ParamSpec("sill", .length, 0.9, min: 0, max: 20, "Height of the bottom of the opening above the wall base"),
                ParamSpec("offset", .length, 1, min: 0, max: 200, "Distance from the host wall's start to the window centre"),
            ]
        case .roof:
            return [
                ParamSpec("style", .choice(["gable", "hip", "flat"]), "gable", "Roof shape"),
                ParamSpec("width", .length, 6, min: 0.2, max: 200, "Footprint size along local X (ridge direction for gable)"),
                ParamSpec("depth", .length, 4, min: 0.2, max: 200, "Footprint size along local Z"),
                ParamSpec("pitch", .angle, 30, min: 0, max: 75, "Slope angle (ignored for flat)"),
                ParamSpec("overhang", .length, 0.3, min: 0, max: 3, "Eave overhang beyond the footprint"),
                ParamSpec("thickness", .length, 0.15, min: 0.02, max: 1, "Thickness (flat roofs, eaves)"),
            ]
        case .box:
            return [
                ParamSpec("width", .length, 1, min: 0.01, max: 500, "Size along local X"),
                ParamSpec("depth", .length, 1, min: 0.01, max: 500, "Size along local Z"),
                ParamSpec("height", .length, 1, min: 0.01, max: 500, "Size along Y"),
            ]
        case .cylinder:
            return [
                ParamSpec("radius", .length, 0.5, min: 0.005, max: 100, "Radius"),
                ParamSpec("height", .length, 1, min: 0.01, max: 500, "Height"),
            ]
        case .table:
            return [
                ParamSpec("width", .length, 1.8, min: 0.3, max: 10, "Table length along local X"),
                ParamSpec("depth", .length, 0.9, min: 0.3, max: 5, "Table depth along local Z"),
                ParamSpec("height", .length, 0.75, min: 0.2, max: 1.5, "Height to the top surface"),
                ParamSpec("topThickness", .length, 0.04, min: 0.01, max: 0.2, "Tabletop thickness"),
                ParamSpec("legStyle", .choice(["square", "round", "pedestal", "trestle"]), "square", "Leg style"),
                ParamSpec("legSize", .length, 0.07, min: 0.02, max: 0.4, "Leg width/diameter"),
                ParamSpec("inset", .length, 0.06, min: 0, max: 1, "Distance from the top edge to the legs"),
            ]
        case .chair:
            return [
                ParamSpec("width", .length, 0.45, min: 0.25, max: 1.5, "Seat width"),
                ParamSpec("depth", .length, 0.48, min: 0.25, max: 1.5, "Seat depth"),
                ParamSpec("seatHeight", .length, 0.45, min: 0.15, max: 1, "Seat height"),
                ParamSpec("backHeight", .length, 0.9, min: 0.3, max: 1.8, "Overall height to the top of the backrest (local -Z side)"),
                ParamSpec("legSize", .length, 0.04, min: 0.01, max: 0.15, "Leg thickness"),
            ]
        case .shelf:
            return [
                ParamSpec("width", .length, 0.8, min: 0.2, max: 6, "Width along local X"),
                ParamSpec("depth", .length, 0.3, min: 0.1, max: 1.5, "Depth along local Z"),
                ParamSpec("height", .length, 1.8, min: 0.2, max: 4, "Height"),
                ParamSpec("shelves", .count, 5, min: 1, max: 20, "Number of shelf boards (including top and bottom)"),
                ParamSpec("boardThickness", .length, 0.02, min: 0.005, max: 0.1, "Board thickness"),
            ]
        case .group:
            return []
        }
    }

    public func spec(_ key: String) -> ParamSpec? { paramSpecs.first { $0.key == key } }

    public var defaultParams: [String: ParamValue] {
        Dictionary(uniqueKeysWithValues: paramSpecs.map { ($0.key, $0.defaultValue) })
    }

    public var defaultMaterialPreset: String {
        switch self {
        case .wall: return "white_paint"
        case .slab: return "concrete"
        case .door: return "oak"
        case .window: return "glass"
        case .roof: return "roof_tile"
        case .box, .cylinder: return "plaster"
        case .table, .shelf: return "oak"
        case .chair: return "walnut"
        case .group: return "plaster"
        }
    }
}

/// Surface appearance. `preset` is a named preset (see `MaterialLibrary`), `color` is `#RRGGBB`.
public struct Material: Codable, Hashable, Sendable {
    public var preset: String?
    public var color: String
    public var opacity: Double
    public var roughness: Double

    public init(preset: String? = nil, color: String, opacity: Double = 1, roughness: Double = 0.7) {
        self.preset = preset; self.color = color; self.opacity = opacity; self.roughness = roughness
    }

    public var displayName: String { preset ?? color }
}

public enum MaterialLibrary {
    public static let presets: [(name: String, material: Material)] = [
        ("white_paint", Material(preset: "white_paint", color: "#F2EFE8", roughness: 0.9)),
        ("plaster", Material(preset: "plaster", color: "#D9D3C7", roughness: 0.9)),
        ("concrete", Material(preset: "concrete", color: "#A9A7A1", roughness: 0.95)),
        ("brick", Material(preset: "brick", color: "#A4553A", roughness: 0.9)),
        ("oak", Material(preset: "oak", color: "#C08F55", roughness: 0.6)),
        ("walnut", Material(preset: "walnut", color: "#6B4428", roughness: 0.55)),
        ("pine", Material(preset: "pine", color: "#DDBB84", roughness: 0.65)),
        ("glass", Material(preset: "glass", color: "#BFE0EE", opacity: 0.35, roughness: 0.05)),
        ("steel", Material(preset: "steel", color: "#8E949B", roughness: 0.35)),
        ("black", Material(preset: "black", color: "#2C2C2E", roughness: 0.5)),
        ("tile", Material(preset: "tile", color: "#DAD5CC", roughness: 0.4)),
        ("fabric_grey", Material(preset: "fabric_grey", color: "#7E8189", roughness: 1)),
        ("roof_tile", Material(preset: "roof_tile", color: "#8E3B2F", roughness: 0.8)),
        ("slate", Material(preset: "slate", color: "#4D5560", roughness: 0.7)),
        ("grass", Material(preset: "grass", color: "#6E9A4F", roughness: 1)),
    ]

    public static var presetNames: [String] { presets.map(\.name) }

    public static func preset(_ name: String) -> Material? {
        presets.first { $0.name == name }?.material
    }

    /// Parses `#RRGGBB` (or `RRGGBB`) into 0...1 components.
    public static func rgb(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xFF) / 255, Double((v >> 8) & 0xFF) / 255, Double(v & 0xFF) / 255)
    }

    public static func hex(r: Double, g: Double, b: Double) -> String {
        func c(_ v: Double) -> Int { Int((max(0, min(1, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

/// One object in the scene.
public struct SceneObject: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var kind: ObjectKind
    public var transform: Transform
    /// Parametric dimensions/options, validated against `kind.paramSpecs`. Lengths in metres.
    public var params: [String: ParamValue]
    public var material: Material
    /// Optional group this object belongs to.
    public var parentId: String?
    /// For doors and windows: the wall they sit in.
    public var hostId: String?

    public init(id: String, name: String, kind: ObjectKind, transform: Transform = Transform(),
                params: [String: ParamValue] = [:], material: Material? = nil,
                parentId: String? = nil, hostId: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.transform = transform
        self.params = kind.defaultParams.merging(params) { _, new in new }
        self.material = material ?? MaterialLibrary.preset(kind.defaultMaterialPreset)!
        self.parentId = parentId
        self.hostId = hostId
    }

    /// Numeric parameter (falls back to the kind's default).
    public func number(_ key: String) -> Double {
        params[key]?.number ?? kind.spec(key)?.defaultValue.number ?? 0
    }

    public func string(_ key: String) -> String {
        params[key]?.string ?? kind.spec(key)?.defaultValue.string ?? ""
    }
}

/// The versioned, Codable scene document. Saved as JSON in `.draw4me` files.
public struct SceneDocument: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1
    public static let fileExtension = "draw4me"

    public var schemaVersion: Int
    public var name: String
    /// Always "m" for now; kept explicit so files are self-describing.
    public var units: String
    /// Ordered list of objects (order is stable and used for deterministic output).
    public var objects: [SceneObject]
    /// Next number to use for each id prefix.
    public var idCounters: [String: Int]
    /// Monotonic change counter. `DocumentEditor` bumps it on every apply, undo, redo and revert, so a
    /// client can say "apply this only if nothing changed since revision N" (`expectedRevision`).
    public var revision: Int

    public init(name: String = "Untitled") {
        self.schemaVersion = Self.currentSchemaVersion
        self.name = name
        self.units = "m"
        self.objects = []
        self.idCounters = [:]
        self.revision = 0
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, name, units, objects, idCounters, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        name = try c.decode(String.self, forKey: .name)
        units = try c.decodeIfPresent(String.self, forKey: .units) ?? "m"
        objects = try c.decode([SceneObject].self, forKey: .objects)
        idCounters = try c.decodeIfPresent([String: Int].self, forKey: .idCounters) ?? [:]
        // Files written before revisions existed start at 0.
        revision = try c.decodeIfPresent(Int.self, forKey: .revision) ?? 0
    }

    public func object(_ id: String) -> SceneObject? { objects.first { $0.id == id } }
    public func index(of id: String) -> Int? { objects.firstIndex { $0.id == id } }
    public func contains(_ id: String) -> Bool { index(of: id) != nil }

    public func children(of groupId: String) -> [SceneObject] { objects.filter { $0.parentId == groupId } }
    public func hosted(in wallId: String) -> [SceneObject] { objects.filter { $0.hostId == wallId } }

    /// All ids inside a group, recursively (not including the group itself).
    public func descendants(of id: String) -> [String] {
        var out: [String] = []
        for c in children(of: id) {
            out.append(c.id)
            out.append(contentsOf: descendants(of: c.id))
        }
        return out
    }

    public mutating func makeId(for kind: ObjectKind) -> String {
        var n = idCounters[kind.idPrefix] ?? 1
        while contains("\(kind.idPrefix)\(n)") { n += 1 }
        idCounters[kind.idPrefix] = n + 1
        return "\(kind.idPrefix)\(n)"
    }

    // MARK: JSON

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public func jsonData() throws -> Data { try Self.encoder().encode(self) }

    public static func load(from data: Data) throws -> SceneDocument {
        let doc = try JSONDecoder().decode(SceneDocument.self, from: data)
        guard doc.schemaVersion <= currentSchemaVersion else {
            throw CommandError(code: .unsupported, message: "Document schema \(doc.schemaVersion) is newer than this app supports (\(currentSchemaVersion)).")
        }
        // Future: migrate older schema versions here.
        return doc
    }
}

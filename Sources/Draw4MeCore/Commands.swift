import Foundation

/// Who issued a command. Kept in the undo history so a future AI feature can show
/// (and undo as a unit) "what the agent changed".
public enum CommandOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case user, script, agent
}

/// A typed, human-readable error. Every failure the command layer can produce is one of these.
public struct CommandError: Error, Codable, Hashable, Sendable, CustomStringConvertible {
    public enum Code: String, Codable, Sendable {
        case invalidCommand, invalidParameter, notFound, wrongKind, conflict, doesNotFit, unsupported, nothingToUndo
        /// `expectedRevision` didn't match: someone else changed the document. Re-read and retry.
        case staleRevision
        /// A size or count limit was exceeded (see `Limits`).
        case limitExceeded
    }

    public var code: Code
    public var message: String
    /// Index of the failing command within a batch, when applicable.
    public var commandIndex: Int?

    public init(code: Code, message: String, commandIndex: Int? = nil) {
        self.code = code; self.message = message; self.commandIndex = commandIndex
    }

    public static func invalidParameter(_ m: String) -> CommandError { .init(code: .invalidParameter, message: m) }
    public static func invalidCommand(_ m: String) -> CommandError { .init(code: .invalidCommand, message: m) }
    public static func notFound(_ id: String) -> CommandError { .init(code: .notFound, message: "No object with id '\(id)'") }
    public static func wrongKind(_ m: String) -> CommandError { .init(code: .wrongKind, message: m) }
    public static func doesNotFit(_ m: String) -> CommandError { .init(code: .doesNotFit, message: m) }

    public var description: String { message }
}

/// A material given in a command: either a preset name / hex color string (`"oak"`, `"#FF8800"`)
/// or an object `{"preset": "oak", "color": "#…", "opacity": 0.5, "roughness": 0.3}`.
public struct MaterialRef: Codable, Hashable, Sendable {
    public var preset: String?
    public var color: String?
    public var opacity: Double?
    public var roughness: Double?

    public init(preset: String? = nil, color: String? = nil, opacity: Double? = nil, roughness: Double? = nil) {
        self.preset = preset; self.color = color; self.opacity = opacity; self.roughness = roughness
    }

    public static func named(_ s: String) -> MaterialRef {
        s.hasPrefix("#") ? MaterialRef(color: s) : MaterialRef(preset: s)
    }

    private enum CodingKeys: String, CodingKey { case preset, color, opacity, roughness }

    public init(from decoder: Decoder) throws {
        if let s = try? decoder.singleValueContainer().decode(String.self) {
            self = .named(s); return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        color = try c.decodeIfPresent(String.self, forKey: .color)
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity)
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness)
    }

    public func encode(to encoder: Encoder) throws {
        if color == nil, opacity == nil, roughness == nil, let p = preset {
            var c = encoder.singleValueContainer(); try c.encode(p); return
        }
        if preset == nil, opacity == nil, roughness == nil, let col = color {
            var c = encoder.singleValueContainer(); try c.encode(col); return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(preset, forKey: .preset)
        try c.encodeIfPresent(color, forKey: .color)
        try c.encodeIfPresent(opacity, forKey: .opacity)
        try c.encodeIfPresent(roughness, forKey: .roughness)
    }

    public func resolve() throws -> Material {
        var m: Material
        if let p = preset {
            guard let base = MaterialLibrary.preset(p) else {
                throw CommandError.invalidParameter("Unknown material preset '\(p)'. Presets: \(MaterialLibrary.presetNames.joined(separator: ", "))")
            }
            m = base
        } else if let col = color {
            m = Material(color: col)
        } else {
            throw CommandError.invalidParameter("A material needs a 'preset' or a 'color'")
        }
        if let col = color {
            guard let rgb = MaterialLibrary.rgb(col) else {
                throw CommandError.invalidParameter("Color '\(col)' is not a #RRGGBB hex color")
            }
            m.color = MaterialLibrary.hex(r: rgb.r, g: rgb.g, b: rgb.b)
            if preset != nil { m.preset = nil }
        }
        if let o = opacity {
            guard (0...1).contains(o) else { throw CommandError.invalidParameter("opacity must be between 0 and 1") }
            m.opacity = o
        }
        if let r = roughness {
            guard (0...1).contains(r) else { throw CommandError.invalidParameter("roughness must be between 0 and 1") }
            m.roughness = r
        }
        return m
    }
}

/// Names of built-in templates.
public enum TemplateName: String, Codable, CaseIterable, Sendable {
    case simpleHouse = "simple_house"
    case diningSet = "dining_set"
}

// MARK: - Command payloads
//
// Field names here are the JSON field names. They must match the field specs in
// `CommandCatalog` (a unit test enforces this), and the decoder rejects unknown fields
// using that same catalog, so the catalog is the single source of truth.

public struct NewDocumentCommand: Codable, Hashable, Sendable {
    public var name: String?
    public init(name: String? = nil) { self.name = name }
}

public struct LoadTemplateCommand: Codable, Hashable, Sendable {
    public var template: TemplateName
    public var replace: Bool?
    public var offset: Vec3?
    public init(template: TemplateName, replace: Bool? = nil, offset: Vec3? = nil) {
        self.template = template; self.replace = replace; self.offset = offset
    }
}

public struct AddCommand: Codable, Hashable, Sendable {
    public var kind: ObjectKind
    public var id: String?
    public var ref: String?
    public var name: String?
    public var position: Vec3?
    public var rotation: Double?
    public var from: Vec3?
    public var to: Vec3?
    public var params: [String: ParamValue]?
    public var material: MaterialRef?
    public var parent: String?
    public var host: String?

    public init(kind: ObjectKind, id: String? = nil, ref: String? = nil, name: String? = nil,
                position: Vec3? = nil, rotation: Double? = nil, from: Vec3? = nil, to: Vec3? = nil,
                params: [String: ParamValue]? = nil, material: MaterialRef? = nil,
                parent: String? = nil, host: String? = nil) {
        self.kind = kind; self.id = id; self.ref = ref; self.name = name
        self.position = position; self.rotation = rotation; self.from = from; self.to = to
        self.params = params; self.material = material; self.parent = parent; self.host = host
    }
}

public struct UpdateCommand: Codable, Hashable, Sendable {
    public var id: String
    public var name: String?
    public var position: Vec3?
    public var rotation: Double?
    public var params: [String: ParamValue]?
    public var material: MaterialRef?
    public var host: String?

    public init(id: String, name: String? = nil, position: Vec3? = nil, rotation: Double? = nil,
                params: [String: ParamValue]? = nil, material: MaterialRef? = nil, host: String? = nil) {
        self.id = id; self.name = name; self.position = position; self.rotation = rotation
        self.params = params; self.material = material; self.host = host
    }
}

public struct MoveCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var by: Vec3?
    public var to: Vec3?
    public init(ids: [String], by: Vec3? = nil, to: Vec3? = nil) { self.ids = ids; self.by = by; self.to = to }

    private enum CodingKeys: String, CodingKey { case ids, by, to }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        by = try c.decodeIfPresent(Vec3.self, forKey: .by)
        to = try c.decodeIfPresent(Vec3.self, forKey: .to)
    }
}

public struct RotateCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var degrees: Double
    public var pivot: Vec3?
    public init(ids: [String], degrees: Double, pivot: Vec3? = nil) { self.ids = ids; self.degrees = degrees; self.pivot = pivot }

    private enum CodingKeys: String, CodingKey { case ids, degrees, pivot }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        degrees = try c.decode(Double.self, forKey: .degrees)
        pivot = try c.decodeIfPresent(Vec3.self, forKey: .pivot)
    }
}

public struct ResizeCommand: Codable, Hashable, Sendable {
    public var id: String
    public var dimensions: [String: Double]?
    public var scale: Double?
    public init(id: String, dimensions: [String: Double]? = nil, scale: Double? = nil) {
        self.id = id; self.dimensions = dimensions; self.scale = scale
    }
}

public struct SetMaterialCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var material: MaterialRef
    public init(ids: [String], material: MaterialRef) { self.ids = ids; self.material = material }

    private enum CodingKeys: String, CodingKey { case ids, material }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        material = try c.decode(MaterialRef.self, forKey: .material)
    }
}

public struct GroupCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var id: String?
    public var ref: String?
    public var name: String?
    public init(ids: [String], id: String? = nil, ref: String? = nil, name: String? = nil) {
        self.ids = ids; self.id = id; self.ref = ref; self.name = name
    }

    private enum CodingKeys: String, CodingKey { case ids, id, ref, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        id = try c.decodeIfPresent(String.self, forKey: .id)
        ref = try c.decodeIfPresent(String.self, forKey: .ref)
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}

public struct UngroupCommand: Codable, Hashable, Sendable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct DeleteCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }

    private enum CodingKeys: String, CodingKey { case ids }
    public init(from decoder: Decoder) throws {
        ids = try decodeIdList(try decoder.container(keyedBy: CodingKeys.self), .ids)
    }
}

public struct DuplicateCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var offset: Vec3?
    public init(ids: [String], offset: Vec3? = nil) { self.ids = ids; self.offset = offset }

    private enum CodingKeys: String, CodingKey { case ids, offset }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        offset = try c.decodeIfPresent(Vec3.self, forKey: .offset)
    }
}

public struct ArrayCommand: Codable, Hashable, Sendable {
    public var ids: [String]
    public var count: Int
    public var spacing: Vec3
    public init(ids: [String], count: Int, spacing: Vec3) { self.ids = ids; self.count = count; self.spacing = spacing }

    private enum CodingKeys: String, CodingKey { case ids, count, spacing }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ids = try decodeIdList(c, .ids)
        count = try c.decode(Int.self, forKey: .count)
        spacing = try c.decode(Vec3.self, forKey: .spacing)
    }
}

/// A rectangular room: four walls on the rectangle's centre lines (corners joined cleanly) plus an
/// optional floor slab, grouped. With `ref: "k"`, later commands in the batch can use `@k` (the group),
/// `@k.north`, `@k.south`, `@k.east`, `@k.west` (walls) and `@k.floor`.
public struct AddRoomCommand: Codable, Hashable, Sendable {
    public var x: Double
    public var z: Double
    public var width: Double
    public var depth: Double
    public var y: Double?
    public var height: Double?
    public var thickness: Double?
    public var floor: Bool?
    public var name: String?
    public var ref: String?
    public var wallMaterial: MaterialRef?
    public var floorMaterial: MaterialRef?

    public init(x: Double, z: Double, width: Double, depth: Double, y: Double? = nil, height: Double? = nil, thickness: Double? = nil,
                floor: Bool? = nil, name: String? = nil, ref: String? = nil, wallMaterial: MaterialRef? = nil, floorMaterial: MaterialRef? = nil) {
        self.x = x; self.z = z; self.width = width; self.depth = depth; self.y = y; self.height = height; self.thickness = thickness
        self.floor = floor; self.name = name; self.ref = ref; self.wallMaterial = wallMaterial; self.floorMaterial = floorMaterial
    }
}

public struct TransactionCommand: Codable, Hashable, Sendable {
    public var label: String?
    public var commands: [Command]
    public init(label: String? = nil, commands: [Command]) { self.label = label; self.commands = commands }
}

/// Accepts `"ids": ["A","B"]` or the shorthand `"ids": "A"`.
private func decodeIdList<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> [String] {
    if let one = try? c.decode(String.self, forKey: key) { return [one] }
    return try c.decode([String].self, forKey: key)
}

// MARK: - Command

/// Every edit to a document is one of these. The UI, the Command Console, the CLI and any
/// future AI transport all go through exactly this type and `DocumentEditor.apply`.
///
/// JSON form: `{"command": "<name>", ...fields}`.
public enum Command: Hashable, Sendable {
    case newDocument(NewDocumentCommand)
    case loadTemplate(LoadTemplateCommand)
    case add(AddCommand)
    case update(UpdateCommand)
    case move(MoveCommand)
    case rotate(RotateCommand)
    case resize(ResizeCommand)
    case setMaterial(SetMaterialCommand)
    case group(GroupCommand)
    case ungroup(UngroupCommand)
    case delete(DeleteCommand)
    case duplicate(DuplicateCommand)
    case array(ArrayCommand)
    case addRoom(AddRoomCommand)
    case transaction(TransactionCommand)

    public var name: CommandName {
        switch self {
        case .newDocument: return .newDocument
        case .loadTemplate: return .loadTemplate
        case .add: return .add
        case .update: return .update
        case .move: return .move
        case .rotate: return .rotate
        case .resize: return .resize
        case .setMaterial: return .setMaterial
        case .group: return .group
        case .ungroup: return .ungroup
        case .delete: return .delete
        case .duplicate: return .duplicate
        case .array: return .array
        case .addRoom: return .addRoom
        case .transaction: return .transaction
        }
    }

    /// Short human label used for undo menu items and history.
    public var label: String {
        func n(_ ids: [String]) -> String { ids.count == 1 ? ids[0] : "\(ids.count) objects" }
        switch self {
        case .newDocument: return "New Document"
        case .loadTemplate(let c): return "Load Template \(c.template.rawValue)"
        case .add(let c): return "Add \(c.kind.displayName)"
        case .update(let c): return "Edit \(c.id)"
        case .move(let c): return "Move \(n(c.ids))"
        case .rotate(let c): return "Rotate \(n(c.ids))"
        case .resize(let c): return "Resize \(c.id)"
        case .setMaterial(let c): return "Set Material of \(n(c.ids))"
        case .group(let c): return "Group \(n(c.ids))"
        case .ungroup(let c): return "Ungroup \(c.id)"
        case .delete(let c): return "Delete \(n(c.ids))"
        case .duplicate(let c): return "Duplicate \(n(c.ids))"
        case .array(let c): return "Array \(n(c.ids)) ×\(c.count)"
        case .addRoom(let c): return "Add Room \(c.name ?? "")".trimmingCharacters(in: .whitespaces)
        case .transaction(let c): return c.label ?? "\(c.commands.count) Changes"
        }
    }
}

/// All command names. `CommandCatalog.spec(for:)` switches exhaustively over this, so adding a
/// command without documenting it is a compile error.
public enum CommandName: String, Codable, CaseIterable, Sendable {
    case newDocument, loadTemplate, add, update, move, rotate, resize, setMaterial
    case group, ungroup, delete, duplicate, array, addRoom, transaction
}

struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
}

extension Command: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        guard c.contains(AnyKey("command")) else {
            throw CommandError.invalidCommand("Missing \"command\" field. Known commands: \(CommandName.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let raw = try c.decode(String.self, forKey: AnyKey("command"))
        guard let name = CommandName(rawValue: raw) else {
            throw CommandError.invalidCommand("Unknown command '\(raw)'. Known commands: \(CommandName.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        // Reject unknown fields using the catalog (catches typos such as "lenght").
        let spec = CommandCatalog.spec(for: name)
        let allowed = Set(spec.fields.map(\.name) + ["command"])
        for key in c.allKeys where !allowed.contains(key.stringValue) {
            throw CommandError.invalidCommand("Unknown field '\(key.stringValue)' for command '\(raw)'. Allowed fields: \(spec.fields.map(\.name).joined(separator: ", "))")
        }
        for f in spec.fields where f.required && !c.contains(AnyKey(f.name)) {
            throw CommandError.invalidCommand("Command '\(raw)' requires field '\(f.name)' (\(f.help))")
        }
        do {
            switch name {
            case .newDocument: self = .newDocument(try NewDocumentCommand(from: decoder))
            case .loadTemplate: self = .loadTemplate(try LoadTemplateCommand(from: decoder))
            case .add: self = .add(try AddCommand(from: decoder))
            case .update: self = .update(try UpdateCommand(from: decoder))
            case .move: self = .move(try MoveCommand(from: decoder))
            case .rotate: self = .rotate(try RotateCommand(from: decoder))
            case .resize: self = .resize(try ResizeCommand(from: decoder))
            case .setMaterial: self = .setMaterial(try SetMaterialCommand(from: decoder))
            case .group: self = .group(try GroupCommand(from: decoder))
            case .ungroup: self = .ungroup(try UngroupCommand(from: decoder))
            case .delete: self = .delete(try DeleteCommand(from: decoder))
            case .duplicate: self = .duplicate(try DuplicateCommand(from: decoder))
            case .array: self = .array(try ArrayCommand(from: decoder))
            case .addRoom: self = .addRoom(try AddRoomCommand(from: decoder))
            case .transaction: self = .transaction(try TransactionCommand(from: decoder))
            }
        } catch let e as CommandError {
            throw e
        } catch let e as DecodingError {
            throw CommandError.invalidCommand("Invalid '\(raw)' command: \(describe(e))")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        try c.encode(name.rawValue, forKey: AnyKey("command"))
        switch self {
        case .newDocument(let p): try p.encode(to: encoder)
        case .loadTemplate(let p): try p.encode(to: encoder)
        case .add(let p): try p.encode(to: encoder)
        case .update(let p): try p.encode(to: encoder)
        case .move(let p): try p.encode(to: encoder)
        case .rotate(let p): try p.encode(to: encoder)
        case .resize(let p): try p.encode(to: encoder)
        case .setMaterial(let p): try p.encode(to: encoder)
        case .group(let p): try p.encode(to: encoder)
        case .ungroup(let p): try p.encode(to: encoder)
        case .delete(let p): try p.encode(to: encoder)
        case .duplicate(let p): try p.encode(to: encoder)
        case .array(let p): try p.encode(to: encoder)
        case .addRoom(let p): try p.encode(to: encoder)
        case .transaction(let p): try p.encode(to: encoder)
        }
    }

    /// Parses either one command object or an array of commands.
    public static func parseList(_ data: Data) throws -> [Command] {
        let dec = JSONDecoder()
        do {
            if let first = String(data: data.prefix(256), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).first, first == "[" {
                return try dec.decode([Command].self, from: data)
            }
            return [try dec.decode(Command.self, from: data)]
        } catch let e as CommandError {
            throw e
        } catch let e as DecodingError {
            throw CommandError.invalidCommand("Could not parse JSON: \(describe(e))")
        } catch {
            throw CommandError.invalidCommand("Could not parse JSON: \(error.localizedDescription)")
        }
    }

    public static func parseList(_ text: String) throws -> [Command] {
        try parseList(Data(text.utf8))
    }

    public func jsonString(pretty: Bool = false) -> String {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: e.encode(self), encoding: .utf8)) ?? "{}"
    }
}

/// Readable description of a decoding error (shared with transports).
public func describeDecoding(_ e: DecodingError) -> String { describe(e) }

func describe(_ e: DecodingError) -> String {
    func path(_ p: [CodingKey]) -> String {
        let s = p.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
        return s.isEmpty ? "" : " at '\(s)'"
    }
    switch e {
    case .typeMismatch(let t, let ctx): return "expected \(t)\(path(ctx.codingPath))"
    case .valueNotFound(let t, let ctx): return "missing \(t)\(path(ctx.codingPath))"
    case .keyNotFound(let k, let ctx): return "missing field '\(k.stringValue)'\(path(ctx.codingPath))"
    case .dataCorrupted(let ctx):
        if let u = ctx.underlyingError as? CommandError { return u.message }
        return "\(ctx.debugDescription)\(path(ctx.codingPath))"
    @unknown default: return "\(e)"
    }
}

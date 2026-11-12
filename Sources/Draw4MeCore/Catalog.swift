import Foundation

/// One field of a command.
public struct FieldSpec: Hashable, Sendable {
    public let name: String
    public let type: ValueType
    public let required: Bool
    public let help: String

    public init(_ name: String, _ type: ValueType, required: Bool = false, _ help: String) {
        self.name = name; self.type = type; self.required = required; self.help = help
    }
}

public struct CommandSpec: Hashable, Sendable {
    public let name: CommandName
    public let summary: String
    public let fields: [FieldSpec]
    /// A complete, valid example (JSON). Unit tests decode every example.
    public let example: String
}

/// The machine-readable description of everything the command layer accepts.
///
/// This is the single source of truth: the JSON decoder validates fields against it, the
/// Command Console shows it, and a future MCP/tool layer can be generated from `json()`.
public enum CommandCatalog {
    public static func spec(for name: CommandName) -> CommandSpec {
        let ids = FieldSpec("ids", .idList, required: true, "Object ids (a single id string is also accepted). Use '@ref' to refer to an object created earlier in the same batch.")
        switch name {
        case .newDocument:
            return CommandSpec(name: name, summary: "Clear everything and start an empty document.",
                               fields: [FieldSpec("name", .text, "Document name")],
                               example: #"{"command":"newDocument","name":"My Cabin"}"#)
        case .loadTemplate:
            return CommandSpec(name: name, summary: "Insert a built-in template (built from ordinary commands).",
                               fields: [FieldSpec("template", .choice(TemplateName.allCases.map(\.rawValue)), required: true, "Template to load"),
                                        FieldSpec("replace", .bool, "Replace the current document (default true)"),
                                        FieldSpec("offset", .vector, "Where to place the template's origin (default 0,0,0)")],
                               example: #"{"command":"loadTemplate","template":"simple_house"}"#)
        case .add:
            return CommandSpec(name: name, summary: "Add an object. Omitted parameters use the kind's defaults (see objectKinds).",
                               fields: [FieldSpec("kind", .choice(ObjectKind.allCases.map(\.rawValue)), required: true, "Object kind"),
                                        FieldSpec("id", .text, "Explicit id (must be unique). Usually omit and let the app assign one."),
                                        FieldSpec("ref", .text, "Batch-local alias so later commands in the same batch can say '@alias'"),
                                        FieldSpec("name", .text, "Display name"),
                                        FieldSpec("position", .vector, "Anchor position (see objectKinds[].anchor)"),
                                        FieldSpec("rotation", .angle, "Yaw about +Y, counter-clockwise seen from above"),
                                        FieldSpec("from", .vector, "Walls only: start point (sets position, rotation and length together with 'to')"),
                                        FieldSpec("to", .vector, "Walls only: end point"),
                                        FieldSpec("params", .object, "Kind parameters, e.g. {\"width\":1.8}; see objectKinds[].params"),
                                        FieldSpec("material", .object, "Material preset name, \"#RRGGBB\", or {preset,color,opacity,roughness}"),
                                        FieldSpec("parent", .id, "Group to put the object in"),
                                        FieldSpec("host", .id, "Doors/windows: the wall to place it in (required for those)")],
                               example: #"{"command":"add","kind":"table","name":"Dining table","position":{"x":2,"y":0,"z":3},"params":{"width":1.8,"legStyle":"round"},"material":"oak"}"#)
        case .update:
            return CommandSpec(name: name, summary: "Change an object's name, position, rotation, parameters, material or host wall.",
                               fields: [FieldSpec("id", .id, required: true, "Object to change"),
                                        FieldSpec("name", .text, "New name"),
                                        FieldSpec("position", .vector, "New anchor position (not for doors/windows; change params.offset instead)"),
                                        FieldSpec("rotation", .angle, "New yaw"),
                                        FieldSpec("params", .object, "Parameters to change (others keep their values)"),
                                        FieldSpec("material", .object, "New material"),
                                        FieldSpec("host", .id, "Doors/windows: move to another wall")],
                               example: #"{"command":"update","id":"T1","params":{"height":0.74},"name":"Oak table"}"#)
        case .move:
            return CommandSpec(name: name, summary: "Move objects by a delta or so the first one lands at a point. Groups move their members; doors/windows slide along their wall.",
                               fields: [ids,
                                        FieldSpec("by", .vector, "Offset to add"),
                                        FieldSpec("to", .vector, "Target position for the first object (others keep their relative positions)")],
                               example: #"{"command":"move","ids":["T1"],"by":{"x":0.5,"z":-1}}"#)
        case .rotate:
            return CommandSpec(name: name, summary: "Rotate objects about the vertical axis.",
                               fields: [ids,
                                        FieldSpec("degrees", .angle, required: true, "Counter-clockwise (seen from above) rotation"),
                                        FieldSpec("pivot", .vector, "Pivot point (default: the object's anchor, or the centre of several objects)")],
                               example: #"{"command":"rotate","ids":["CH1"],"degrees":90}"#)
        case .resize:
            return CommandSpec(name: name, summary: "Change an object's dimensions (length parameters only), or scale them all.",
                               fields: [FieldSpec("id", .id, required: true, "Object to resize"),
                                        FieldSpec("dimensions", .object, "Length parameters to set, in metres, e.g. {\"width\":2}"),
                                        FieldSpec("scale", .number, "Multiply every length parameter by this factor")],
                               example: #"{"command":"resize","id":"T1","dimensions":{"width":2.2,"depth":1}}"#)
        case .setMaterial:
            return CommandSpec(name: name, summary: "Set the material of objects (groups apply to their members).",
                               fields: [ids, FieldSpec("material", .object, required: true, "Preset name, \"#RRGGBB\", or {preset,color,opacity,roughness}")],
                               example: #"{"command":"setMaterial","ids":["T1","CH1"],"material":"walnut"}"#)
        case .group:
            return CommandSpec(name: name, summary: "Put objects into a new group.",
                               fields: [ids,
                                        FieldSpec("id", .text, "Explicit group id"),
                                        FieldSpec("ref", .text, "Batch-local alias for the new group"),
                                        FieldSpec("name", .text, "Group name")],
                               example: #"{"command":"group","ids":["T1","CH1","CH2"],"name":"Dining set"}"#)
        case .ungroup:
            return CommandSpec(name: name, summary: "Dissolve a group, keeping its members.",
                               fields: [FieldSpec("id", .id, required: true, "Group id")],
                               example: #"{"command":"ungroup","id":"G1"}"#)
        case .delete:
            return CommandSpec(name: name, summary: "Delete objects. Deleting a group deletes its members; deleting a wall deletes its doors/windows.",
                               fields: [ids],
                               example: #"{"command":"delete","ids":["CH2"]}"#)
        case .duplicate:
            return CommandSpec(name: name, summary: "Copy objects (with group members and hosted doors/windows).",
                               fields: [ids, FieldSpec("offset", .vector, "Offset of the copy (default 0.5, 0, 0.5; for doors/windows x slides along the wall)")],
                               example: #"{"command":"duplicate","ids":["CH1"],"offset":{"x":0.6}}"#)
        case .array:
            return CommandSpec(name: name, summary: "Repeat objects in a line: makes count-1 copies spaced by 'spacing'.",
                               fields: [ids,
                                        FieldSpec("count", .count, required: true, "Total number including the original (2...100)"),
                                        FieldSpec("spacing", .vector, required: true, "Offset between consecutive copies")],
                               example: #"{"command":"array","ids":["CH1"],"count":3,"spacing":{"x":0.6}}"#)
        case .transaction:
            return CommandSpec(name: name, summary: "Apply several commands as one undoable step; if any fails, none are applied.",
                               fields: [FieldSpec("label", .text, "Undo label"),
                                        FieldSpec("commands", .commandList, required: true, "Commands to apply in order")],
                               example: #"{"command":"transaction","label":"Add stool","commands":[{"command":"add","kind":"cylinder","ref":"s","params":{"radius":0.2,"height":0.45}},{"command":"setMaterial","ids":["@s"],"material":"steel"}]}"#)
        }
    }

    public static var all: [CommandSpec] { CommandName.allCases.map(spec(for:)) }

    // MARK: JSON export

    /// JSON-Schema-flavoured description of every command and object kind, suitable for
    /// generating tool definitions for an AI agent later.
    public static func json() -> [String: Any] {
        func schema(_ t: ValueType, _ help: String) -> [String: Any] {
            var s: [String: Any] = ["type": t.typeName, "description": help]
            if let u = t.unit { s["unit"] = u }
            if let c = t.choices { s["enum"] = c }
            switch t {
            case .vector:
                s["properties"] = ["x": ["type": "number"], "y": ["type": "number"], "z": ["type": "number"]]
            case .idList:
                s["items"] = ["type": "string"]
            case .commandList:
                s["items"] = ["type": "object", "description": "A command object"]
            default: break
            }
            return s
        }
        let commands: [[String: Any]] = all.map { spec in
            var props: [String: Any] = ["command": ["type": "string", "const": spec.name.rawValue]]
            for f in spec.fields { props[f.name] = schema(f.type, f.help) }
            let example = (try? JSONSerialization.jsonObject(with: Data(spec.example.utf8))) ?? [:]
            return [
                "name": spec.name.rawValue,
                "description": spec.summary,
                "parameters": ["type": "object",
                               "properties": props,
                               "required": ["command"] + spec.fields.filter(\.required).map(\.name),
                               "additionalProperties": false],
                "example": example,
            ]
        }
        let kinds: [[String: Any]] = ObjectKind.allCases.map { k in
            [
                "kind": k.rawValue,
                "idPrefix": k.idPrefix,
                "anchor": k.anchorDescription,
                "hosted": k.isHosted,
                "defaultMaterial": k.defaultMaterialPreset,
                "params": k.paramSpecs.map { p -> [String: Any] in
                    var s = schema(p.type, p.help)
                    s["name"] = p.key
                    s["default"] = jsonValue(p.defaultValue)
                    if let lo = p.min { s["minimum"] = lo }
                    if let hi = p.max { s["maximum"] = hi }
                    return s
                },
            ]
        }
        return [
            "schemaVersion": SceneDocument.currentSchemaVersion,
            "units": ["length": "m", "angle": "deg"],
            "coordinates": "Y up, +X east, +Z south (north = -Z). Rotation is yaw in degrees, counter-clockwise seen from above.",
            "commands": commands,
            "objectKinds": kinds,
            "materials": MaterialLibrary.presets.map { ["name": $0.name, "color": $0.material.color, "opacity": $0.material.opacity] },
            "templates": TemplateName.allCases.map(\.rawValue),
            "batches": "Send an array of commands to apply them as one undoable transaction. Use 'ref' on add/group and '@ref' in later id fields.",
        ]
    }

    public static func jsonString() -> String {
        let data = (try? JSONSerialization.data(withJSONObject: json(), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Compact plain-text reference (for the console's help pane, or a model prompt).
    public static func text() -> String {
        var out = "Commands (lengths in metres, angles in degrees; Y up, +X east, +Z south):\n"
        for s in all {
            out += "\n\(s.name.rawValue) — \(s.summary)\n"
            for f in s.fields {
                out += "  \(f.name)\(f.required ? "*" : ""): \(f.type.typeName)\(f.type.unit.map { " [\($0)]" } ?? "")\(f.type.choices.map { " {\($0.joined(separator: "|"))}" } ?? "") — \(f.help)\n"
            }
            out += "  e.g. \(s.example)\n"
        }
        out += "\nObject kinds:\n"
        for k in ObjectKind.allCases {
            let ps = k.paramSpecs.map { p in "\(p.key)=\(p.defaultValue)\(p.type.unit.map { " \($0)" } ?? "")" }.joined(separator: ", ")
            out += "  \(k.rawValue) (\(k.idPrefix)…): \(ps.isEmpty ? "no parameters" : ps)\n"
        }
        out += "\nMaterials: \(MaterialLibrary.presetNames.joined(separator: ", ")) or any #RRGGBB\n"
        return out
    }
}

func jsonValue(_ v: ParamValue) -> Any {
    switch v {
    case .number(let d): return d
    case .string(let s): return s
    case .bool(let b): return b
    }
}

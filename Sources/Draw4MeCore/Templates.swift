import Foundation

/// Built-in starting points. Each template is just a list of ordinary commands (the same ones an
/// agent or the Command Console would send), so templates double as worked examples.
public enum Templates {
    public static func displayName(_ t: TemplateName) -> String {
        switch t {
        case .simpleHouse: return "Simple House"
        case .diningSet: return "Dining Set"
        }
    }

    public static func commands(_ t: TemplateName, offset o: Vec3 = .zero) -> [Command] {
        switch t {
        case .simpleHouse: return simpleHouse(o)
        case .diningSet: return diningSet(o)
        }
    }

    /// 8 m × 6 m single-storey house: slab, four exterior walls (outside faces at x = -0.1…8.1, z = -0.1…6.1),
    /// one interior wall, a front door on the south wall, windows on every side and a gable roof.
    static func simpleHouse(_ o: Vec3) -> [Command] {
        func p(_ x: Double, _ y: Double, _ z: Double) -> Vec3 { Vec3(x, y, z) + o }
        func wall(_ ref: String, _ name: String, _ a: Vec3, _ b: Vec3, thickness: Double = 0.2) -> Command {
            .add(AddCommand(kind: .wall, ref: ref, name: name, from: a, to: b, params: ["height": 2.7, "thickness": .number(thickness)]))
        }
        func window(_ host: String, _ name: String, _ offset: Double, width: Double = 1.2) -> Command {
            .add(AddCommand(kind: .window, name: name, params: ["offset": .number(offset), "width": .number(width), "height": 1.3, "sill": 0.9], host: "@\(host)"))
        }
        return [
            .add(AddCommand(kind: .slab, ref: "floor", name: "Floor", position: p(4, 0, 3),
                            params: ["width": 8.2, "depth": 6.2, "thickness": 0.2], material: .named("concrete"))),
            wall("south", "South wall", p(-0.1, 0, 6), p(8.1, 0, 6)),
            wall("east", "East wall", p(8, 0, 5.9), p(8, 0, 0.1)),
            wall("north", "North wall", p(8.1, 0, 0), p(-0.1, 0, 0)),
            wall("west", "West wall", p(0, 0, 0.1), p(0, 0, 5.9)),
            wall("inner", "Bedroom wall", p(5, 0, 0.1), p(5, 0, 3.6), thickness: 0.12),
            .add(AddCommand(kind: .door, name: "Front door", params: ["offset": 4.1, "width": 0.95, "height": 2.1], host: "@south")),
            .add(AddCommand(kind: .door, name: "Bedroom door", params: ["offset": 3.0, "width": 0.8, "height": 2.05, "hinge": "right"], material: .named("white_paint"), host: "@inner")),
            window("south", "Living window", 1.9, width: 1.6),
            window("south", "Kitchen window", 6.6),
            window("east", "East window", 1.9),
            window("north", "Bedroom window", 1.6),
            window("north", "Study window", 6.1),
            window("west", "West window", 2.9),
            .add(AddCommand(kind: .roof, ref: "roof", name: "Roof", position: p(4, 2.7, 3),
                            params: ["style": "gable", "width": 8.2, "depth": 6.2, "pitch": 35, "overhang": 0.4])),
            .group(GroupCommand(ids: ["@floor", "@south", "@east", "@north", "@west", "@inner", "@roof"], name: "House")),
        ]
    }

    /// 1.8 m oak table with six chairs, grouped.
    static func diningSet(_ o: Vec3) -> [Command] {
        func chair(_ ref: String, _ x: Double, _ z: Double, _ rot: Double) -> Command {
            .add(AddCommand(kind: .chair, ref: ref, name: "Chair \(ref.dropFirst())", position: Vec3(x, 0, z) + o, rotation: rot, material: .named("walnut")))
        }
        return [
            .add(AddCommand(kind: .table, ref: "table", name: "Dining table", position: o,
                            params: ["width": 1.8, "depth": 0.9, "height": 0.75, "legStyle": "square"], material: .named("oak"))),
            chair("c1", -0.45, -0.62, 0), chair("c2", 0.45, -0.62, 0),
            chair("c3", -0.45, 0.62, 180), chair("c4", 0.45, 0.62, 180),
            chair("c5", -1.1, 0, 90), chair("c6", 1.1, 0, -90),
            .group(GroupCommand(ids: ["@table", "@c1", "@c2", "@c3", "@c4", "@c5", "@c6"], name: "Dining set")),
        ]
    }
}

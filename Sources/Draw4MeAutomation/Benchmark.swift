import Foundation
import Darwin
import Draw4MeCore
import Draw4MeRender

/// Repeatable performance measurements on a large synthetic scene (`draw4me-cli --bench`).
public enum Benchmark {
    public struct Measurement: Codable, Sendable {
        public var name: String
        public var milliseconds: Double
        public var note: String
    }

    /// Resident memory of this process in MB.
    public static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : 0
    }

    static func time(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
    }

    /// Builds `houses` copies of the simple house + a dining set on a grid, then measures common operations.
    public static func run(houses: Int = 100, render: Bool = true) -> [Measurement] {
        var out: [Measurement] = []
        func add(_ n: String, _ ms: Double, _ note: String = "") { out.append(Measurement(name: n, milliseconds: ms, note: note)) }

        let editor = DocumentEditor()
        let service = InProcessAutomationService(editor: editor)
        let mem0 = residentMB()
        let side = Int(Double(houses).squareRoot().rounded(.up))
        var lastBuild = 0.0
        let build = time {
            for i in 0..<houses {
                let o = Vec3(Double(i % side) * 14, 0, Double(i / side) * 12)
                let cmds: [Command] = [
                    .loadTemplate(LoadTemplateCommand(template: .simpleHouse, replace: false, offset: o)),
                    .loadTemplate(LoadTemplateCommand(template: .diningSet, replace: false, offset: o + Vec3(2.5, 0, 4))),
                ]
                lastBuild = time { _ = editor.apply(cmds, origin: .script) }
            }
        }
        let n = editor.document.objects.count
        add("build \(houses) houses (\(n) objects, \(houses) transactions)", build)
        add("one template transaction at full size", lastBuild)

        let target = editor.document.objects.last { $0.kind == .table }!.id
        add("move one object (apply)", time { _ = editor.apply(.move(MoveCommand(ids: [target], by: Vec3(0.1, 0, 0)))) })
        add("update one wall (apply)", time {
            let w = editor.document.objects.first { $0.kind == .wall }!.id
            _ = editor.apply(.update(UpdateCommand(id: w, params: ["height": 2.8])))
        })
        add("undo", time { editor.undo() })
        add("redo", time { editor.redo() })
        var warnings = 0
        add("warnings (whole document)", time { warnings = Validator.warnings(for: editor.document).count }, "\(warnings) warnings")
        var summaryChars = 0
        add("scene summary text", time { summaryChars = SceneSummary(editor.document).text.count }, "\(summaryChars) characters")
        var data = Data()
        add("save (encode JSON)", time { data = (try? editor.document.jsonData()) ?? Data() }, "\(data.count / 1024) KB")
        add("load (decode + checks)", time { if let d = try? SceneDocument.load(from: data) { try? DocumentLimits.check(d) } })
        add("geometry for every object", time { for o in editor.document.objects { _ = Geometry.parts(for: o, in: editor.document) } })
        var scene = SceneBuilder.makeScene(editor.document)
        add("3D scene rebuild (all nodes)", time { scene = SceneBuilder.makeScene(editor.document) })
        if let content = scene.rootNode.childNode(withName: SceneBuilder.contentNodeName, recursively: false) {
            let before = editor.document
            _ = editor.apply(.move(MoveCommand(ids: [target], by: Vec3(0.05, 0, 0))))
            var n = 0
            add("3D incremental update after one move", time {
                n = SceneBuilder.update(content, from: before, oldOptions: SceneOptions(), to: editor.document, options: SceneOptions())
            }, "\(n) node rebuilt")
        }
        add("2D plan drawing (PNG 1600x1100)", time { _ = Drafting.png(editor.document, view: .plan, size: CGSize(width: 1600, height: 1100)) })
        if render {
            add("3D render (PNG 1024x768)", time { _ = try? Renderer.png(editor.document, request: RenderRequest(view: .perspective, width: 1024, height: 768)) })
        }
        let req = Data(#"{"op":"apply","origin":"agent","commands":[{"command":"add","kind":"box","position":{"x":-5,"y":0,"z":-5}}]}"#.utf8)
        add("automation round trip (JSON apply)", time { _ = AutomationEndpoint.handle(json: req, service: service) })
        // Many small edits, like an agent session or someone dragging things around.
        let edits = 50
        let memBefore = residentMB()
        let many = time { for _ in 0..<edits { _ = editor.apply(.move(MoveCommand(ids: [target], by: Vec3(0.01, 0, 0)))) } }
        add("\(edits) small edits", many, "\(String(format: "%.1f", many / Double(edits))) ms each, resident memory +\(Int(residentMB() - memBefore)) MB")
        let historyBytes = (try? JSONEncoder().encode(editor.undoStack).count) ?? 0
        add("undo history size", 0, "\(editor.undoStack.count) steps ≈ \(historyBytes / 1024) KB as JSON")
        add("peak resident memory growth", 0, "\(Int(residentMB() - mem0)) MB over the whole run")
        return out
    }

    public static func report(_ ms: [Measurement]) -> String {
        ms.map { m in
            let t = m.milliseconds > 0 ? String(format: "%9.1f ms", m.milliseconds) : String(repeating: " ", count: 12)
            return "\(t)  \(m.name)\(m.note.isEmpty ? "" : "  — \(m.note)")"
        }.joined(separator: "\n")
    }
}

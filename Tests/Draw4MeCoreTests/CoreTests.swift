import Foundation
import Testing
@testable import Draw4MeCore

private func cmd(_ json: String) throws -> Command {
    try Command.parseList(json)[0]
}

private func near(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

@Suite("Commands: apply, undo, redo")
struct ApplyTests {
    @Test func addCreatesObjectWithDefaults() {
        let ed = DocumentEditor()
        let r = ed.apply(.add(AddCommand(kind: .table)))
        #expect(r.ok)
        #expect(r.created == ["T1"])
        let t = ed.document.object("T1")!
        #expect(t.number("width") == 1.8)
        #expect(t.string("legStyle") == "square")
        #expect(t.material.preset == "oak")
        #expect(t.name == "Table T1")
    }

    @Test func undoRedoRestoresExactly() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box, position: Vec3(1, 0, 1))))
        let afterAdd = ed.document
        ed.apply(.move(MoveCommand(ids: ["B1"], by: Vec3(2, 0, 0))))
        #expect(ed.document.object("B1")!.transform.position == Vec3(3, 0, 1))
        ed.undo()
        #expect(ed.document == afterAdd)
        ed.undo()
        #expect(ed.document.objects.isEmpty)
        #expect(!ed.canUndo)
        ed.redo(); ed.redo()
        #expect(ed.document.object("B1")!.transform.position == Vec3(3, 0, 1))
        #expect(!ed.canRedo)
    }

    @Test func newEditClearsRedo() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        ed.undo()
        #expect(ed.canRedo)
        ed.apply(.add(AddCommand(kind: .cylinder)))
        #expect(!ed.canRedo)
    }

    @Test func batchIsOneUndoStepWithOriginAndRefs() throws {
        let ed = DocumentEditor()
        let cmds = try Command.parseList("""
        [{"command":"add","kind":"wall","ref":"w","from":{"x":0,"z":0},"to":{"x":5,"z":0}},
         {"command":"add","kind":"door","host":"@w","params":{"offset":1}},
         {"command":"add","kind":"window","host":"@w","params":{"offset":3.5}}]
        """)
        let r = ed.apply(cmds, origin: .agent, label: "Agent: wall with openings")
        #expect(r.ok, "\(r.message)")
        #expect(r.created == ["W1", "D1", "WN1"])
        #expect(ed.undoStack.count == 1)
        #expect(ed.undoStack[0].origin == .agent)
        #expect(ed.undoStack[0].label == "Agent: wall with openings")
        #expect(ed.document.object("D1")!.hostId == "W1")
        #expect(ed.undoLast(from: .user) == nil)
        #expect(ed.undoLast(from: .agent) != nil)
        #expect(ed.document.objects.isEmpty)
    }

    @Test func failingBatchChangesNothing() throws {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        let before = ed.document
        let r = ed.apply(try Command.parseList("""
        [{"command":"add","kind":"chair"},{"command":"move","ids":["NOPE"],"by":{"x":1}}]
        """))
        #expect(!r.ok)
        #expect(r.error?.code == .notFound)
        #expect(r.error?.commandIndex == 1)
        #expect(ed.document == before)
        #expect(ed.undoStack.count == 1)
    }

    @Test func wallFromTo() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .wall, from: Vec3(0, 0, 0), to: Vec3(0, 0, -3))))
        let w = ed.document.object("W1")!
        #expect(near(w.number("length"), 3))
        #expect(near(w.transform.rotation, 90))
        let end = w.transform.apply(Vec3(3, 0, 0))
        #expect(near(end.z, -3) && near(end.x, 0))
    }

    @Test func moveGroupMovesMembersAndHostedFollowWall() throws {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        let door = ed.document.objects.first { $0.kind == .door }!
        let before = Geometry.anchor(of: door, in: ed.document)
        let house = ed.document.objects.first { $0.kind == .group }!
        let r = ed.apply(.move(MoveCommand(ids: [house.id], by: Vec3(10, 0, 0))))
        #expect(r.ok)
        let after = Geometry.anchor(of: ed.document.object(door.id)!, in: ed.document)
        #expect(near(after.x - before.x, 10) && near(after.z, before.z))
        #expect(ed.document.object(door.id)!.number("offset") == door.number("offset"))
    }

    @Test func movingDoorSlidesAlongWall() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .wall, params: ["length": 5])))
        ed.apply(.add(AddCommand(kind: .door, params: ["offset": 1], host: "W1")))
        ed.apply(.move(MoveCommand(ids: ["D1"], by: Vec3(1.5, 0, 3))))
        #expect(near(ed.document.object("D1")!.number("offset"), 2.5))
    }

    @Test func rotateAboutAnchorAndPivot() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .chair, position: Vec3(1, 0, 0))))
        ed.apply(.rotate(RotateCommand(ids: ["CH1"], degrees: 90)))
        #expect(ed.document.object("CH1")!.transform.position == Vec3(1, 0, 0))
        #expect(ed.document.object("CH1")!.transform.rotation == 90)
        ed.apply(.rotate(RotateCommand(ids: ["CH1"], degrees: 180, pivot: .zero)))
        let p = ed.document.object("CH1")!.transform.position
        #expect(near(p.x, -1) && near(p.z, 0))
        #expect(ed.document.object("CH1")!.transform.rotation == -90)
    }

    @Test func resizeAndScale() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        #expect(ed.apply(.resize(ResizeCommand(id: "B1", dimensions: ["width": 2]))).ok)
        #expect(ed.document.object("B1")!.number("width") == 2)
        #expect(ed.apply(.resize(ResizeCommand(id: "B1", scale: 0.5))).ok)
        #expect(ed.document.object("B1")!.number("width") == 1)
        #expect(ed.document.object("B1")!.number("height") == 0.5)
    }

    @Test func setMaterialOnGroupAppliesToMembers() {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet)))
        let g = ed.document.objects.first { $0.kind == .group }!
        let r = ed.apply(.setMaterial(SetMaterialCommand(ids: [g.id], material: .named("#336699"))))
        #expect(r.ok)
        for o in ed.document.objects where o.kind != .group { #expect(o.material.color == "#336699") }
    }

    @Test func groupUngroup() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        ed.apply(.add(AddCommand(kind: .cylinder, position: Vec3(2, 0, 0))))
        let r = ed.apply(.group(GroupCommand(ids: ["B1", "CY1"], name: "Pair")))
        #expect(r.created == ["G1"])
        #expect(ed.document.object("B1")!.parentId == "G1")
        ed.apply(.ungroup(UngroupCommand(id: "G1")))
        #expect(ed.document.object("G1") == nil)
        #expect(ed.document.object("B1")!.parentId == nil)
    }

    @Test func deleteCascades() {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        let south = ed.document.objects.first { $0.name == "South wall" }!
        let hosted = ed.document.hosted(in: south.id).map(\.id)
        #expect(hosted.count == 3)
        let r = ed.apply(.delete(DeleteCommand(ids: [south.id])))
        #expect(Set(r.deleted) == Set(hosted + [south.id]))
        let g = ed.document.objects.first { $0.kind == .group }!
        ed.apply(.delete(DeleteCommand(ids: [g.id])))
        #expect(ed.document.objects.allSatisfy { $0.kind == .door || $0.kind == .window } == false || ed.document.objects.isEmpty)
        #expect(ed.document.objects.isEmpty)
    }

    @Test func duplicateAndArray() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .chair)))
        let r = ed.apply(.duplicate(DuplicateCommand(ids: ["CH1"], offset: Vec3(1, 0, 0))))
        #expect(r.created == ["CH2"])
        #expect(ed.document.object("CH2")!.transform.position == Vec3(1, 0, 0))
        #expect(ed.document.object("CH2")!.name == "Chair CH2")
        let a = ed.apply(.array(ArrayCommand(ids: ["CH1"], count: 4, spacing: Vec3(0, 0, 0.6))))
        #expect(a.created.count == 3)
        #expect(near(ed.document.objects.last!.transform.position.z, 1.8))
    }

    @Test func duplicateWallCopiesOpenings() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .wall)))
        ed.apply(.add(AddCommand(kind: .window, host: "W1")))
        let r = ed.apply(.duplicate(DuplicateCommand(ids: ["W1"], offset: Vec3(0, 0, 3))))
        #expect(r.created == ["W2", "WN2"])
        #expect(ed.document.object("WN2")!.hostId == "W2")
    }

    @Test func newDocumentAndTransactionCommand() throws {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        ed.apply(.newDocument(NewDocumentCommand(name: "Fresh")))
        #expect(ed.document.objects.isEmpty && ed.document.name == "Fresh")
        let r = ed.apply(try cmd(CommandCatalog.spec(for: .transaction).example))
        #expect(r.ok, "\(r.message)")
        #expect(ed.document.object("CY1")!.material.preset == "steel")
        #expect(ed.undoStack.last!.label == "Add stool")
    }

    @Test func updateParamsNameMaterial() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .table)))
        let r = ed.apply(.update(UpdateCommand(id: "T1", name: "Desk", rotation: 45, params: ["legStyle": "round", "height": 0.72], material: .named("walnut"))))
        #expect(r.ok, "\(r.message)")
        let t = ed.document.object("T1")!
        #expect(t.name == "Desk" && t.string("legStyle") == "round" && t.number("height") == 0.72)
        #expect(t.material.preset == "walnut" && t.transform.rotation == 45)
    }
}

@Suite("Validation errors")
struct ValidationTests {
    let ed = DocumentEditor()

    @Test func unknownParameter() {
        let r = ed.apply(.add(AddCommand(kind: .box, params: ["lenght": 2])))
        #expect(r.error?.code == .invalidParameter)
        #expect(r.message.contains("Parameters: width, depth, height"))
    }

    @Test func outOfRange() {
        let r = ed.apply(.add(AddCommand(kind: .table, params: ["height": 5])))
        #expect(r.error?.code == .invalidParameter)
        #expect(r.message.contains("maximum"))
    }

    @Test func wrongType() {
        #expect(ed.apply(.add(AddCommand(kind: .table, params: ["legStyle": "tentacle"]))).error?.code == .invalidParameter)
        #expect(ed.apply(.add(AddCommand(kind: .table, params: ["width": "wide"]))).error?.code == .invalidParameter)
    }

    @Test func doorNeedsWallHost() {
        #expect(ed.apply(.add(AddCommand(kind: .door))).error?.code == .invalidParameter)
        ed.apply(.add(AddCommand(kind: .box)))
        #expect(ed.apply(.add(AddCommand(kind: .door, host: "B1"))).error?.code == .wrongKind)
    }

    @Test func doorMustFit() {
        ed.apply(.add(AddCommand(kind: .wall, params: ["length": 2, "height": 2.4])))
        #expect(ed.apply(.add(AddCommand(kind: .door, params: ["offset": 1.8], host: "W1"))).error?.code == .doesNotFit)
        #expect(ed.apply(.add(AddCommand(kind: .window, params: ["sill": 1.5, "height": 1.2], host: "W1"))).error?.code == .doesNotFit)
        #expect(ed.apply(.add(AddCommand(kind: .door, host: "W1"))).ok)
        // Shrinking the wall would leave the door hanging out: rejected, wall unchanged.
        let r = ed.apply(.resize(ResizeCommand(id: "W1", dimensions: ["length": 0.5])))
        #expect(r.error?.code == .doesNotFit)
        #expect(ed.document.object("W1")!.number("length") == 2)
    }

    @Test func duplicateIdAndBadId() {
        ed.apply(.add(AddCommand(kind: .box, id: "crate")))
        #expect(ed.apply(.add(AddCommand(kind: .box, id: "crate"))).error?.code == .conflict)
        #expect(ed.apply(.add(AddCommand(kind: .box, id: "9 lives"))).error?.code == .invalidParameter)
    }

    @Test func unknownReference() {
        let r = ed.apply(.add(AddCommand(kind: .door, host: "@nowhere")))
        #expect(r.error?.code == .notFound)
        #expect(r.message.contains("@nowhere"))
    }

    @Test func badMaterial() {
        ed.apply(.add(AddCommand(kind: .box)))
        #expect(ed.apply(.setMaterial(SetMaterialCommand(ids: ["B1"], material: .named("unobtanium")))).error?.code == .invalidParameter)
        #expect(ed.apply(.setMaterial(SetMaterialCommand(ids: ["B1"], material: .named("#12345")))).error?.code == .invalidParameter)
    }

    @Test func moveNeedsExactlyOneOfByTo() {
        ed.apply(.add(AddCommand(kind: .box)))
        #expect(ed.apply(.move(MoveCommand(ids: ["B1"]))).error?.code == .invalidParameter)
    }

    @Test func jsonDecodingErrorsAreReadable() {
        #expect(throws: CommandError.self) { try cmd(#"{"kind":"box"}"#) }
        do { _ = try cmd(#"{"command":"ad","kind":"box"}"#) } catch let e as CommandError {
            #expect(e.message.contains("Unknown command 'ad'"))
        } catch { Issue.record("wrong error") }
        do { _ = try cmd(#"{"command":"add","kind":"box","postion":{"x":1}}"#) } catch let e as CommandError {
            #expect(e.message.contains("Unknown field 'postion'"))
        } catch { Issue.record("wrong error") }
        do { _ = try cmd(#"{"command":"move","by":{"x":1}}"#) } catch let e as CommandError {
            #expect(e.message.contains("requires field 'ids'"))
        } catch { Issue.record("wrong error") }
    }
}

@Suite("JSON round trips")
struct CodingTests {
    @Test func documentRoundTrip() throws {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet, replace: false, offset: Vec3(2.5, 0, 4))))
        let data = try ed.document.jsonData()
        let back = try SceneDocument.load(from: data)
        #expect(back == ed.document)
        // Deterministic encoding.
        #expect(try back.jsonData() == data)
    }

    @Test func rejectsNewerSchema() throws {
        var doc = SceneDocument()
        doc.schemaVersion = 99
        let data = try doc.jsonData()
        #expect(throws: CommandError.self) { try SceneDocument.load(from: data) }
    }

    @Test func everyExampleRoundTrips() throws {
        for spec in CommandCatalog.all {
            let c = try cmd(spec.example)
            #expect(c.name == spec.name)
            let again = try cmd(c.jsonString())
            #expect(again == c, "round trip of \(spec.name)")
        }
    }

    @Test func shorthandForms() throws {
        let c = try cmd(#"{"command":"setMaterial","ids":"B1","material":"oak"}"#)
        #expect(c == .setMaterial(SetMaterialCommand(ids: ["B1"], material: MaterialRef(preset: "oak"))))
        let m = try cmd(#"{"command":"move","ids":["B1"],"by":[1,0,2]}"#)
        #expect(m == .move(MoveCommand(ids: ["B1"], by: Vec3(1, 0, 2))))
    }

    @Test func historyIsCodable() throws {
        let ed = DocumentEditor()
        ed.apply([.add(AddCommand(kind: .box))], origin: .agent)
        let data = try JSONEncoder().encode(ed.undoStack)
        let back = try JSONDecoder().decode([HistoryEntry].self, from: data)
        #expect(back == ed.undoStack)
    }
}

@Suite("Catalog")
struct CatalogTests {
    @Test func everyCommandIsInTheCatalog() throws {
        let json = CommandCatalog.json()
        let names = Set((json["commands"] as! [[String: Any]]).map { $0["name"] as! String })
        #expect(names == Set(CommandName.allCases.map(\.rawValue)))
        let kinds = Set((json["objectKinds"] as! [[String: Any]]).map { $0["kind"] as! String })
        #expect(kinds == Set(ObjectKind.allCases.map(\.rawValue)))
        #expect(!CommandCatalog.jsonString().isEmpty)
    }

    /// Every field a command can encode is documented in the catalog (no hidden fields).
    @Test func encodedFieldsAreDocumented() throws {
        let samples: [Command] = [
            .newDocument(.init(name: "x")),
            .loadTemplate(.init(template: .diningSet, replace: false, offset: .zero)),
            .add(.init(kind: .wall, id: "a", ref: "r", name: "n", position: .zero, rotation: 1, from: .zero, to: .zero, params: ["length": 1], material: .named("oak"), parent: "g", host: "h")),
            .update(.init(id: "a", name: "n", position: .zero, rotation: 1, params: [:], material: .named("oak"), host: "h")),
            .move(.init(ids: ["a"], by: .zero, to: .zero)),
            .rotate(.init(ids: ["a"], degrees: 1, pivot: .zero)),
            .resize(.init(id: "a", dimensions: ["width": 1], scale: 2)),
            .setMaterial(.init(ids: ["a"], material: .named("oak"))),
            .group(.init(ids: ["a"], id: "g", ref: "r", name: "n")),
            .ungroup(.init(id: "g")),
            .delete(.init(ids: ["a"])),
            .duplicate(.init(ids: ["a"], offset: .zero)),
            .array(.init(ids: ["a"], count: 2, spacing: .zero)),
            .transaction(.init(label: "l", commands: [])),
        ]
        #expect(Set(samples.map(\.name)) == Set(CommandName.allCases))
        for c in samples {
            let obj = try JSONSerialization.jsonObject(with: Data(c.jsonString().utf8)) as! [String: Any]
            let documented = Set(CommandCatalog.spec(for: c.name).fields.map(\.name) + ["command"])
            #expect(Set(obj.keys).isSubset(of: documented), "\(c.name): \(obj.keys.sorted())")
        }
    }

    @Test func textReferenceMentionsEverything() {
        let t = CommandCatalog.text()
        for n in CommandName.allCases { #expect(t.contains(n.rawValue)) }
        for k in ObjectKind.allCases { #expect(t.contains(k.rawValue)) }
    }
}

@Suite("Templates, geometry, summary")
struct TemplateTests {
    @Test func simpleHouse() {
        let ed = DocumentEditor()
        let r = ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        #expect(r.ok, "\(r.message)")
        let d = ed.document
        #expect(d.name == "Simple House")
        #expect(d.objects.filter { $0.kind == .wall }.count == 5)
        #expect(d.objects.filter { $0.kind == .door }.count == 2)
        #expect(d.objects.filter { $0.kind == .window }.count == 6)
        #expect(d.objects.filter { $0.kind == .roof }.count == 1)
        #expect(d.objects.filter { $0.kind == .slab }.count == 1)
        let b = Geometry.documentBounds(d)!
        #expect(b.size.x > 8 && b.size.x < 9.5)
        #expect(b.max.y > 4.5)
        // One undo removes the whole template.
        ed.undo()
        #expect(ed.document.objects.isEmpty)
    }

    @Test func diningSet() {
        let ed = DocumentEditor()
        #expect(ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet))).ok)
        #expect(ed.document.objects.filter { $0.kind == .chair }.count == 6)
        #expect(ed.document.objects.filter { $0.kind == .table }.count == 1)
        let g = ed.document.objects.first { $0.kind == .group }!
        #expect(ed.document.children(of: g.id).count == 7)
    }

    @Test func templateTwiceWithoutReplaceGetsFreshIds() {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet)))
        let r = ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet, replace: false, offset: Vec3(3, 0, 0))))
        #expect(r.ok)
        #expect(ed.document.objects.filter { $0.kind == .chair }.count == 12)
        #expect(Set(ed.document.objects.map(\.id)).count == ed.document.objects.count)
    }

    @Test func wallCellsCutOpenings() {
        let cells = Geometry.wallCells(length: 4, height: 2.5, openings: [
            WallOpening(id: "D", kind: .door, x0: 1, x1: 2, y0: 0, y1: 2),
        ])
        // left full, above-door lintel, right full
        #expect(cells.count == 3)
        let area = cells.reduce(0) { $0 + ($1.x1 - $1.x0) * ($1.y1 - $1.y0) }
        #expect(near(area, 4 * 2.5 - 1 * 2))
    }

    @Test func everyKindProducesGeometry() {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .wall)))
        for k in ObjectKind.allCases where k != .group && k != .wall {
            let r = ed.apply(.add(AddCommand(kind: k, host: k.isHosted ? "W1" : nil)))
            #expect(r.ok, "\(k): \(r.message)")
        }
        for style in ["gable", "hip", "flat"] {
            ed.apply(.add(AddCommand(kind: .roof, params: ["style": .string(style), "width": 4, "depth": 6])))
        }
        for leg in ["square", "round", "pedestal", "trestle"] {
            ed.apply(.add(AddCommand(kind: .table, params: ["legStyle": .string(leg)])))
        }
        for o in ed.document.objects where o.kind != .group {
            let parts = Geometry.parts(for: o, in: ed.document)
            #expect(!parts.isEmpty && parts.allSatisfy { !$0.faces.isEmpty }, "\(o.id)")
            for f in parts.flatMap(\.faces) { #expect(f.points.count >= 3) }
        }
    }

    @Test func boxFacesPointOutward() {
        let faces = Geometry.box(center: Vec3(1, 2, 3), size: Vec3(2, 2, 2), yaw: 30)
        for f in faces { #expect(f.normal.dot(f.centroid - Vec3(1, 2, 3)) > 0) }
    }

    @Test func summaryIsDeterministicAndDescriptive() {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        let s1 = SceneSummary(ed.document).text
        let s2 = SceneSummary(ed.document).text
        #expect(s1 == s2)
        #expect(s1.contains("D1 door \"Front door\" in W1"))
        #expect(s1.contains("meets wall"))
        #expect(s1.contains("faces south"))
        #expect(SceneSummary(ed.document).jsonString().contains("\"relations\""))
    }

    @Test func objExport() {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet)))
        let (obj, mtl) = OBJExporter.export(ed.document, mtlFileName: "x.mtl")
        #expect(obj.contains("mtllib x.mtl"))
        #expect(obj.contains("\nf "))
        #expect(mtl.contains("newmtl"))
    }
}

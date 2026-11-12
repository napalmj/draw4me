import Foundation
import Testing
@testable import Draw4MeCore

private func cmds(_ json: String) throws -> [Command] { try Command.parseList(json) }

@Suite("Revisions and stale edits")
struct RevisionTests {
    @Test func everyChangeBumpsRevision() throws {
        let ed = DocumentEditor()
        #expect(ed.document.revision == 0)
        var r = ed.apply(.add(AddCommand(kind: .box)))
        #expect(r.revision == 1 && ed.document.revision == 1)
        r = ed.apply(.update(UpdateCommand(id: "B1", name: "Box B1")))   // same name: no change
        #expect(ed.document.revision == 1, "a change that changes nothing keeps the revision")
        ed.undo()
        #expect(ed.document.revision == 2, "undo moves forward, never back")
        ed.redo()
        #expect(ed.document.revision == 3)
    }

    @Test func staleExpectedRevisionIsRejectedWithoutChanges() throws {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        let before = ed.document
        let r = ed.apply(try cmds(#"[{"command":"delete","ids":["B1"]}]"#), origin: .agent, expectedRevision: 0)
        #expect(!r.ok)
        #expect(r.error?.code == .staleRevision)
        #expect(r.revision == 1)
        #expect(ed.document == before)
        #expect(ed.apply(try cmds(#"[{"command":"delete","ids":["B1"]}]"#), origin: .agent, expectedRevision: 1).ok)
    }

    @Test func revisionSurvivesJSONAndOldFilesDefaultToZero() throws {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))
        let data = try ed.document.jsonData()
        #expect(try SceneDocument.load(from: data).revision == 1)
        var obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        obj.removeValue(forKey: "revision")
        let old = try JSONSerialization.data(withJSONObject: obj)
        #expect(try SceneDocument.load(from: old).revision == 0)
    }
}

@Suite("Warnings")
struct WarningTests {
    @Test func templatesAreWarningFree() {
        for t in TemplateName.allCases {
            let ed = DocumentEditor()
            ed.apply(.loadTemplate(LoadTemplateCommand(template: t)))
            #expect(ed.warnings.isEmpty, "\(t.rawValue): \(ed.warnings.map(\.message))")
        }
    }

    @Test func intersectingBoxes() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"[{"command":"add","kind":"box"},{"command":"add","kind":"box","position":{"x":0.5,"y":0,"z":0}}]"#))
        #expect(r.ok)
        #expect(r.warnings?.contains { $0.code == .objectsIntersect && Set($0.ids) == ["B1", "B2"] } == true)
        #expect(r.totalWarnings == 1)
        // Moving one away clears it, and the move's result says so.
        let m = ed.apply(.move(MoveCommand(ids: ["B2"], by: Vec3(2, 0, 0))))
        #expect(m.warnings == [])
        #expect(m.totalWarnings == 0)
    }

    @Test func floatingAndSupported() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"[{"command":"add","kind":"box","position":{"x":0,"y":1.5,"z":0}}]"#))
        #expect(r.warnings?.first?.code == .floating)
        // A box stacked on another box is supported.
        let ed2 = DocumentEditor()
        let r2 = ed2.apply(try cmds(#"[{"command":"add","kind":"box"},{"command":"add","kind":"box","position":{"x":0,"y":1,"z":0},"params":{"width":0.5,"depth":0.5,"height":0.5}}]"#))
        #expect(r2.totalWarnings == 0, "\(r2.warnings ?? [])")
    }

    @Test func implausibleDimension() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"[{"command":"add","kind":"wall","from":{"x":0,"y":0,"z":0},"to":{"x":4,"y":0,"z":0},"ref":"w"},{"command":"add","kind":"door","host":"@w","params":{"height":1.0}}]"#))
        #expect(r.ok)
        #expect(r.warnings?.contains { $0.code == .implausibleDimension && $0.ids == ["D1"] } == true)
    }

    @Test func sunkIntoFloor() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"[{"command":"add","kind":"slab","position":{"x":0,"y":0,"z":0}},{"command":"add","kind":"box","position":{"x":0,"y":-0.1,"z":0}}]"#))
        #expect(r.warnings?.contains { $0.code == .belowFloor } == true)
    }
}

@Suite("Reverting agent changes")
struct RevertTests {
    @Test func revertsAgentChangeUnderLaterUserEdits() throws {
        let ed = DocumentEditor()
        ed.apply(.add(AddCommand(kind: .box)))                                                 // user: B1
        ed.apply(try cmds(#"[{"command":"add","kind":"table","position":{"x":5,"y":0,"z":0}}]"#), origin: .agent)   // agent: T1
        ed.apply(.move(MoveCommand(ids: ["B1"], by: Vec3(0, 0, 1))))                           // user, unrelated
        let rev = ed.document.revision
        guard case .success(let e) = ed.revertLast(from: .agent) else { Issue.record("revert failed"); return }
        #expect(e.origin == .agent)
        #expect(!ed.document.contains("T1"))
        #expect(ed.document.object("B1")?.transform.position == Vec3(0, 0, 1), "later user edit kept")
        #expect(ed.document.revision == rev + 1)
        // History stays consistent: undoing the user's move still works and keeps T1 gone.
        ed.undo()
        #expect(ed.document.object("B1")?.transform.position == Vec3(0, 0, 0))
        #expect(!ed.document.contains("T1"))
    }

    @Test func refusesWhenLaterChangesTouchedTheSameObjects() throws {
        let ed = DocumentEditor()
        ed.apply(try cmds(#"[{"command":"add","kind":"box"}]"#), origin: .agent)
        ed.apply(.move(MoveCommand(ids: ["B1"], by: Vec3(1, 0, 0))))
        let before = ed.document
        guard case .failure(let err) = ed.revertLast(from: .agent) else { Issue.record("expected conflict"); return }
        #expect(err.code == .conflict)
        #expect(err.message.contains("B1"))
        #expect(ed.document == before)
    }

    @Test func refusesWhenLaterObjectsDependOnIt() throws {
        let ed = DocumentEditor()
        ed.apply(try cmds(#"[{"command":"add","kind":"wall","from":{"x":0,"y":0,"z":0},"to":{"x":4,"y":0,"z":0}}]"#), origin: .agent)
        ed.apply(try cmds(#"[{"command":"add","kind":"door","host":"W1"}]"#))
        guard case .failure(let err) = ed.revertLast(from: .agent) else { Issue.record("expected conflict"); return }
        #expect(err.code == .conflict)
        #expect(ed.document.contains("W1") && ed.document.contains("D1"))
    }

    @Test func nothingToRevert() {
        let ed = DocumentEditor()
        guard case .failure(let err) = ed.revertLast(from: .agent) else { Issue.record("expected failure"); return }
        #expect(err.code == .nothingToUndo)
    }
}

@Suite("addRoom")
struct AddRoomTests {
    @Test func buildsJoinedRoomWithRefs() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"""
        [{"command":"addRoom","ref":"k","name":"Kitchen","x":0,"z":0,"width":4,"depth":3},
         {"command":"add","kind":"door","host":"@k.south","params":{"offset":1.0}},
         {"command":"add","kind":"window","host":"@k.east"}]
        """#), origin: .agent)
        #expect(r.ok, "\(r.message)")
        let doc = ed.document
        #expect(doc.objects.filter { $0.kind == .wall }.count == 4)
        #expect(doc.objects.filter { $0.kind == .slab }.count == 1)
        let group = doc.objects.first { $0.kind == .group }!
        #expect(group.name == "Kitchen")
        #expect(doc.children(of: group.id).count == 5)
        let door = doc.objects.first { $0.kind == .door }!
        #expect(doc.object(door.hostId!)!.name == "Kitchen south wall")
        #expect(r.totalWarnings == 0, "\(ed.warnings.map(\.message))")
        // Walls touch at the corners but don't overlap.
        let walls = doc.objects.filter { $0.kind == .wall }
        for a in walls { for b in walls where a.id < b.id { #expect(Validator.wallsConnected(a, b) || a.name.contains("north") && b.name.contains("south") || a.name.contains("south") && b.name.contains("north") || a.name.contains("east") && b.name.contains("west") || a.name.contains("west") && b.name.contains("east")) } }
    }

    @Test func rejectsBadSizes() throws {
        let ed = DocumentEditor()
        let r = ed.apply(try cmds(#"[{"command":"addRoom","x":0,"z":0,"width":0,"depth":3}]"#))
        #expect(!r.ok)
        #expect(ed.document.objects.isEmpty)
    }
}

@Suite("Catalog annotations")
struct AnnotationTests {
    @Test func destructiveCommandsAreMarked() {
        let destructive = Set(CommandCatalog.all.filter(\.destructive).map(\.name))
        #expect(destructive == [.newDocument, .loadTemplate, .delete])
        #expect(CommandCatalog.jsonString().contains("\"destructive\" : true"))
    }
}

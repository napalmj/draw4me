import Foundation
import Testing
import ImageIO
@testable import Draw4MeCore
@testable import Draw4MeRender
@testable import Draw4MeAutomation

private func house() -> SceneDocument {
    let ed = DocumentEditor()
    ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
    ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet, replace: false, offset: Vec3(2.5, 0, 3.8))))
    return ed.document
}

private func pngSize(_ data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (img.width, img.height)
}

@Suite("Rendering")
struct RenderTests {
    @Test(arguments: RenderView.allCases)
    func rendersNonEmptyPNG(view: RenderView) throws {
        let data = try Renderer.png(house(), request: RenderRequest(view: view, width: 640, height: 480))
        #expect(data.count > 2000)
        #expect(data.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))
        #expect(pngSize(data) != nil)
    }

    @Test func emptyDocumentStillRenders() throws {
        for v in RenderView.allCases {
            let data = try Renderer.png(SceneDocument(), request: RenderRequest(view: v, width: 200, height: 150))
            #expect(!data.isEmpty)
        }
    }

    @Test func sceneHasOneNodePerObject() {
        let doc = house()
        let scene = SceneBuilder.makeScene(doc)
        let content = scene.rootNode.childNode(withName: SceneBuilder.contentNodeName, recursively: false)!
        let expected = doc.objects.filter { $0.kind != .group }.count
        #expect(content.childNodes.count == expected)
        #expect(content.childNodes.allSatisfy { doc.contains($0.name ?? "") })
    }

    @Test func planHitTestFindsTable() {
        let doc = house()
        let size = CGSize(width: 1000, height: 800)
        let layout = Drafting.fit(doc, view: .plan, size: size)
        let table = doc.objects.first { $0.kind == .table }!
        let pt = layout.point(table.transform.position)
        #expect(Drafting.hitTest(doc, layout: layout, point: pt) == table.id)
        let door = doc.objects.first { $0.kind == .door && $0.name == "Front door" }!
        #expect(Drafting.hitTest(doc, layout: layout, point: layout.point(Geometry.anchor(of: door, in: doc))) == door.id)
    }
}

@Suite("Automation seam")
struct AutomationTests {
    @Test func endToEndJSON() throws {
        let service = InProcessAutomationService(editor: DocumentEditor())
        func call(_ json: String) throws -> AutomationResponse {
            try JSONDecoder().decode(AutomationResponse.self, from: AutomationEndpoint.handle(json: Data(json.utf8), service: service))
        }
        var r = try call(#"{"op":"apply","commands":[{"command":"loadTemplate","template":"simple_house"},{"command":"add","kind":"table","position":{"x":2.5,"z":4}}]}"#)
        #expect(r.ok, "\(r.error ?? "")")
        #expect(r.result?.created.contains("T1") == true)
        #expect(service.editor.undoStack.last?.origin == .agent)

        r = try call(#"{"op":"summary"}"#)
        #expect(r.text?.contains("T1 table") == true)

        r = try call(#"{"op":"render","render":{"view":"plan","width":400,"height":300}}"#)
        #expect(r.ok)
        #expect(Data(base64Encoded: r.pngBase64 ?? "").map { !$0.isEmpty } == true)

        r = try call(#"{"op":"catalog"}"#)
        #expect(r.text?.contains("\"loadTemplate\"") == true)

        r = try call(#"{"op":"undo","origin":"user"}"#)
        #expect(!r.ok)
        r = try call(#"{"op":"undo","origin":"agent"}"#)
        #expect(r.ok)
        #expect(service.document().objects.isEmpty)

        r = try call(#"{"op":"apply","commands":[{"command":"add","kind":"wal"}]}"#)
        #expect(!r.ok)
        r = try call(#"{"op":"nonsense"}"#)
        #expect(!r.ok)
    }
}

@Suite("Automation: agent-readiness ops")
struct AgentOpsTests {
    @Test func revisionWarningsSelectionStatusRevert() throws {
        let service = InProcessAutomationService(editor: DocumentEditor())
        func call(_ json: String) throws -> AutomationResponse {
            try JSONDecoder().decode(AutomationResponse.self, from: AutomationEndpoint.handle(json: Data(json.utf8), service: service))
        }
        var r = try call(#"{"op":"status"}"#)
        #expect(r.status?.mode == "headless" && r.revision == 0)

        r = try call(#"{"op":"apply","expectedRevision":0,"commands":[{"command":"add","kind":"box","position":{"x":0,"y":2,"z":0}}]}"#)
        #expect(r.ok && r.revision == 1)
        #expect(r.warnings?.first?.code == .floating)

        r = try call(#"{"op":"apply","expectedRevision":0,"commands":[{"command":"delete","ids":["B1"]}]}"#)
        #expect(!r.ok && r.errorCode == "staleRevision")

        r = try call(#"{"op":"warnings"}"#)
        #expect(r.warnings?.count == 1 && r.text?.contains("floating") == true)

        r = try call(#"{"op":"selection"}"#)
        #expect(r.selection?.ids == [])

        _ = service.apply([.add(AddCommand(kind: .table, position: Vec3(4, 0, 0)))], origin: .user, label: nil)
        r = try call(#"{"op":"revert","origin":"agent"}"#)
        #expect(r.ok, "\(r.error ?? "")")
        #expect(!service.document().contains("B1") && service.document().contains("T1"))

        r = try call(#"{"op":"revert","origin":"agent"}"#)
        #expect(!r.ok && r.errorCode == "nothingToUndo")

        // Oversized and malformed requests are answered, not crashed on.
        let big = Data(repeating: 0x20, count: AutomationEndpoint.maxRequestBytes + 1)
        let resp = try JSONDecoder().decode(AutomationResponse.self, from: AutomationEndpoint.handle(json: big, service: service))
        #expect(resp.errorCode == "limitExceeded")
        r = try call("{not json")
        #expect(!r.ok)
    }
}

@Suite("Incremental 3D updates")
struct IncrementalSceneTests {
    @Test func updateMatchesFullRebuildAndTouchesOnlyWhatChanged() throws {
        let ed = DocumentEditor()
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        ed.apply(.loadTemplate(LoadTemplateCommand(template: .diningSet, replace: false, offset: Vec3(2.5, 0, 4))))
        let scene = SceneBuilder.makeScene(ed.document)
        let content = scene.rootNode.childNode(withName: SceneBuilder.contentNodeName, recursively: false)!
        var old = ed.document
        let opts = SceneOptions()

        // Moving one chair rebuilds exactly that chair.
        ed.apply(.move(MoveCommand(ids: ["CH1"], by: Vec3(0.1, 0, 0))))
        #expect(SceneBuilder.update(content, from: old, oldOptions: opts, to: ed.document, options: opts) == 1)
        old = ed.document

        // Widening a door rebuilds the door and its wall (the hole changes).
        let door = ed.document.objects.first { $0.kind == .door }!
        ed.apply(.update(UpdateCommand(id: door.id, params: ["width": 0.85])))
        #expect(SceneBuilder.update(content, from: old, oldOptions: opts, to: ed.document, options: opts) >= 2)
        old = ed.document

        // Deleting a wall removes it and its openings; the result matches a full rebuild.
        ed.apply(.delete(DeleteCommand(ids: [door.hostId!])))
        SceneBuilder.update(content, from: old, oldOptions: opts, to: ed.document, options: opts)
        let full = SceneBuilder.makeScene(ed.document).rootNode.childNode(withName: SceneBuilder.contentNodeName, recursively: false)!
        #expect(Set(content.childNodes.compactMap(\.name)) == Set(full.childNodes.compactMap(\.name)))
        #expect(content.childNodes.count == full.childNodes.count)
    }
}

@Suite("Render limits")
struct RenderLimitTests {
    @Test func hugeRequestsAreScaledDown() {
        let s = RenderRequest(view: .plan, width: 4096, height: 4096).size
        #expect(Double(s.width * s.height) <= RenderRequest.maxPixels + 1)
        #expect(abs(s.width / s.height - 1) < 0.01, "aspect ratio kept")
        #expect(RenderRequest(view: .plan, width: 1, height: 1_000_000).size.height <= 4096)
    }
}

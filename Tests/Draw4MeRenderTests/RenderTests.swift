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

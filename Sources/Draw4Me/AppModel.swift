import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Draw4MeCore
import Draw4MeRender
import Draw4MeAutomation

enum ViewportMode: String, CaseIterable, Identifiable {
    case model3D = "3D", drawing2D = "2D", split = "Split"
    var id: String { rawValue }
}

extension UTType {
    static let draw4me = UTType(filenameExtension: SceneDocument.fileExtension, conformingTo: .json) ?? .json
}

/// App state. Owns the single `DocumentEditor`; every edit goes through `apply` → editor.
@MainActor
final class AppModel: ObservableObject {
    let editor: DocumentEditor
    /// The same service the Command Console (and any future AI transport) uses.
    let automation: InProcessAutomationService

    @Published private(set) var document: SceneDocument
    @Published var selection: Set<String> = []
    @Published var mode: ViewportMode = .split
    @Published var draftView: DraftView = .plan
    @Published var showRoofs = true
    @Published var showConsole = false
    @Published var statusMessage = "Welcome to draw4me. Add objects from the toolbar or start from a template."
    @Published var statusIsError = false
    @Published private(set) var fileURL: URL?
    @Published private(set) var isDirty = false
    /// The live 3D camera (shared with export so "Export 3D PNG" matches the screen).
    @Published var orbit = OrbitCamera()
    /// Bumped to ask the 3D view to re-frame the scene.
    @Published var frameRequest = 0

    private var coalesceKey: String?
    private var coalesceTime = Date.distantPast

    init() {
        let ed = DocumentEditor()
        editor = ed
        automation = InProcessAutomationService(editor: ed)
        document = ed.document
        ed.onChange = { [weak self] ed in
            guard let self else { return }
            self.document = ed.document
            self.isDirty = true
            self.selection = self.selection.filter { ed.document.contains($0) }
        }
        apply(.loadTemplate(LoadTemplateCommand(template: .simpleHouse)))
        editor.load(editor.document) // start with a clean history
        isDirty = false
        orbit = OrbitCamera.fitting(document)
    }

    var windowTitle: String {
        (fileURL?.deletingPathExtension().lastPathComponent ?? document.name) + (isDirty ? " — Edited" : "")
    }

    // MARK: Applying commands

    @discardableResult
    func apply(_ command: Command, origin: CommandOrigin = .user, label: String? = nil) -> CommandResult {
        apply([command], origin: origin, label: label)
    }

    @discardableResult
    func apply(_ commands: [Command], origin: CommandOrigin = .user, label: String? = nil) -> CommandResult {
        coalesceKey = nil
        let r = automation.apply(commands, origin: origin, label: label)
        report(r)
        return r
    }

    /// For continuous controls (colour wells): repeated edits with the same key within 1.5 s
    /// collapse into one undo step.
    func applyCoalescing(_ command: Command, key: String) {
        if coalesceKey == key, Date().timeIntervalSince(coalesceTime) < 1.5, editor.undoStack.last?.origin == .user {
            editor.undo()
        }
        let r = automation.apply([command], origin: .user, label: nil)
        report(r)
        coalesceKey = key
        coalesceTime = Date()
    }

    func report(_ r: CommandResult) {
        statusMessage = r.message
        statusIsError = !r.ok
        if !r.ok { NSSound.beep() }
    }

    func undo() {
        if let e = editor.undo() { statusMessage = "Undid \(e.label)\(e.origin == .user ? "" : " (\(e.origin.rawValue))")"; statusIsError = false }
    }

    func redo() {
        if let e = editor.redo() { statusMessage = "Redid \(e.label)"; statusIsError = false }
    }

    // MARK: Convenience edits (all are just commands)

    /// Where new objects go: the 3D view's target, snapped to 0.1 m, on the ground.
    var dropPoint: Vec3 {
        Vec3((orbit.target.x * 10).rounded() / 10, 0, (orbit.target.z * 10).rounded() / 10)
    }

    func add(_ kind: ObjectKind) {
        var c = AddCommand(kind: kind)
        let p = dropPoint
        switch kind {
        case .door, .window:
            guard let wall = targetWall() else {
                statusMessage = "Select a wall first — doors and windows are placed in a wall."
                statusIsError = true; NSSound.beep(); return
            }
            c.host = wall.id
            // Find a free spot along the wall.
            let w = kind.spec("width")!.defaultValue.number!
            c.params = ["offset": .number(freeOffset(in: wall, width: w))]
        case .wall:
            c.from = p; c.to = p + Vec3(4, 0, 0)
        case .roof:
            if let b = Geometry.documentBounds(document), document.objects.contains(where: { $0.kind == .wall }) {
                let walls = document.objects.filter { $0.kind == .wall }
                let top = walls.map { $0.transform.position.y + $0.number("height") }.max() ?? 2.7
                c.position = Vec3(b.center.x, top, b.center.z)
                c.params = ["width": .number(b.size.x), "depth": .number(b.size.z)]
            } else {
                c.position = p + Vec3(0, 2.7, 0)
            }
        default:
            c.position = p
        }
        let r = apply(.add(c))
        if r.ok { selection = Set(r.created) }
    }

    func targetWall() -> SceneObject? {
        for id in selection {
            if let o = document.object(id) {
                if o.kind == .wall { return o }
                if let h = o.hostId, let w = document.object(h) { return w }
            }
        }
        return document.objects.first { $0.kind == .wall }
    }

    func freeOffset(in wall: SceneObject, width: Double) -> Double {
        let L = wall.number("length")
        let ops = Geometry.openings(in: wall, doc: document)
        var x = width / 2 + 0.3
        while x + width / 2 <= L {
            if !ops.contains(where: { $0.x0 < x + width / 2 + 0.1 && $0.x1 > x - width / 2 - 0.1 }) { return x }
            x += 0.1
        }
        return L / 2
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        if apply(.delete(DeleteCommand(ids: sortedSelection))).ok { selection = [] }
    }

    func duplicateSelection() {
        guard !selection.isEmpty else { return }
        let r = apply(.duplicate(DuplicateCommand(ids: sortedSelection, offset: Vec3(0.5, 0, 0.5))))
        if r.ok {
            let created = Set(r.created)
            // Select the copies of what was selected (top-level copies only).
            selection = created.filter { id in
                guard let o = document.object(id) else { return false }
                return !(o.parentId.map(created.contains) ?? false) && !(o.hostId.map(created.contains) ?? false)
            }
        }
    }

    func groupSelection() {
        guard selection.count >= 1 else { return }
        let r = apply(.group(GroupCommand(ids: sortedSelection)))
        if r.ok { selection = Set(r.created) }
    }

    func ungroupSelection() {
        guard selection.count == 1, let id = selection.first, document.object(id)?.kind == .group else { return }
        let kids = document.children(of: id).map(\.id)
        if apply(.ungroup(UngroupCommand(id: id))).ok { selection = Set(kids) }
    }

    func rotateSelection(_ degrees: Double) {
        guard !selection.isEmpty else { return }
        apply(.rotate(RotateCommand(ids: sortedSelection, degrees: degrees)))
    }

    var sortedSelection: [String] {
        document.objects.map(\.id).filter(selection.contains)
    }

    // MARK: Documents

    func newDocument(template: TemplateName?) {
        guard confirmDiscard() else { return }
        let cmd: Command = template.map { .loadTemplate(LoadTemplateCommand(template: $0)) } ?? .newDocument(NewDocumentCommand())
        apply(cmd)
        editor.load(editor.document)
        fileURL = nil
        isDirty = false
        selection = []
        frameAll()
    }

    func insertTemplate(_ t: TemplateName) {
        let r = apply(.loadTemplate(LoadTemplateCommand(template: t, replace: false, offset: dropPoint)))
        if r.ok { selection = Set(r.created.filter { document.object($0)?.parentId == nil && document.object($0)?.hostId == nil }) }
    }

    func confirmDiscard() -> Bool {
        guard isDirty else { return true }
        let a = NSAlert()
        a.messageText = "Discard unsaved changes to “\(windowTitle.replacingOccurrences(of: " — Edited", with: ""))”?"
        a.addButton(withTitle: "Discard")
        a.addButton(withTitle: "Cancel")
        return a.runModal() == .alertFirstButtonReturn
    }

    func open() {
        guard confirmDiscard() else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.draw4me, .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let doc = try SceneDocument.load(from: Data(contentsOf: url))
            editor.load(doc)
            fileURL = url
            isDirty = false
            selection = []
            statusMessage = "Opened \(url.lastPathComponent)"; statusIsError = false
            frameAll()
        } catch {
            showError("Couldn't open \(url.lastPathComponent)", error)
        }
    }

    func save() {
        if let url = fileURL { write(to: url) } else { saveAs() }
    }

    func saveAs() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.draw4me]
        p.nameFieldStringValue = (fileURL?.lastPathComponent) ?? "\(document.name).\(SceneDocument.fileExtension)"
        guard p.runModal() == .OK, let url = p.url else { return }
        write(to: url)
    }

    private func write(to url: URL) {
        do {
            try document.jsonData().write(to: url, options: .atomic)
            fileURL = url
            isDirty = false
            statusMessage = "Saved \(url.lastPathComponent)"; statusIsError = false
        } catch { showError("Couldn't save", error) }
    }

    // MARK: Export

    func export3DPNG() {
        guard let url = savePanel(name: "\(document.name) 3D.png", type: .png) else { return }
        do {
            let img = try Renderer.snapshot(document, camera: .orbit(orbit), size: CGSize(width: 2400, height: 1600),
                                            options: SceneOptions(showRoofs: showRoofs))
            guard let data = Drafting.pngData(img) else { throw RenderError.encodingFailed }
            try data.write(to: url)
            statusMessage = "Exported \(url.lastPathComponent)"; statusIsError = false
        } catch { showError("3D export failed", error) }
    }

    func export2DPNG() {
        guard let url = savePanel(name: "\(document.name) \(draftView.title).png", type: .png) else { return }
        guard let data = Drafting.png(document, view: draftView, size: CGSize(width: 1600, height: 1100)) else {
            showError("2D export failed", RenderError.encodingFailed); return
        }
        do { try data.write(to: url); statusMessage = "Exported \(url.lastPathComponent)"; statusIsError = false }
        catch { showError("2D export failed", error) }
    }

    func exportUSDZ() {
        guard let url = savePanel(name: "\(document.name).usdz", type: UTType(filenameExtension: "usdz") ?? .data) else { return }
        let scene = SceneBuilder.makeScene(document, options: SceneOptions(showRoofs: showRoofs, showGrid: false))
        ["__ground", "__grid"].forEach { scene.rootNode.childNode(withName: $0, recursively: false)?.removeFromParentNode() }
        if scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) {
            statusMessage = "Exported \(url.lastPathComponent)"; statusIsError = false
        } else {
            showError("USDZ export failed", RenderError.encodingFailed)
        }
    }

    func exportOBJ() {
        guard let url = savePanel(name: "\(document.name).obj", type: UTType(filenameExtension: "obj") ?? .data) else { return }
        let mtlURL = url.deletingPathExtension().appendingPathExtension("mtl")
        let (obj, mtl) = OBJExporter.export(document, mtlFileName: mtlURL.lastPathComponent)
        do {
            try obj.write(to: url, atomically: true, encoding: .utf8)
            try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
            statusMessage = "Exported \(url.lastPathComponent) + \(mtlURL.lastPathComponent)"; statusIsError = false
        } catch { showError("OBJ export failed", error) }
    }

    private func savePanel(name: String, type: UTType) -> URL? {
        let p = NSSavePanel()
        p.allowedContentTypes = [type]
        p.nameFieldStringValue = name
        return p.runModal() == .OK ? p.url : nil
    }

    func showError(_ title: String, _ error: Error) {
        statusMessage = "\(title): \(error)"
        statusIsError = true
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "\(error)"
        a.runModal()
    }

    func frameAll() {
        orbit = OrbitCamera.fitting(document, yaw: orbit.yaw, pitch: orbit.pitch)
        frameRequest += 1
    }
}

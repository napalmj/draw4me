import SwiftUI
import AppKit
import Draw4MeCore
import Draw4MeRender

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Also makes `swift run Draw4Me` (no .app bundle) behave like a normal app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // Developer aid: DRAW4ME_SNAPSHOT=/path/out.png makes the app save an image of its main
        // window a few seconds after launch and quit (used to verify the UI without screen recording).
        if let path = ProcessInfo.processInfo.environment["DRAW4ME_SNAPSHOT"] {
            // Optional: DRAW4ME_SNAPSHOT_COMMANDS=/path/cmds.json is applied first (origin "agent"),
            // exactly as the Command Console would, with the console shown and the result selected.
            if let cmdPath = ProcessInfo.processInfo.environment["DRAW4ME_SNAPSHOT_COMMANDS"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                    guard let model = self?.model, let data = FileManager.default.contents(atPath: cmdPath),
                          let cmds = try? Command.parseList(data) else { return }
                    let r = model.apply(cmds, origin: .agent, label: "Snapshot demo")
                    model.selection = Set(r.created.filter { model.document.object($0)?.hostId == nil }.prefix(1))
                    model.showConsole = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                Self.snapshotWindow(to: URL(fileURLWithPath: path))
                NSApp.terminate(nil)
            }
        }
    }

    static func snapshotWindow(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Metal-backed SceneKit views don't appear in cacheDisplay; draw their snapshots on top.
        if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            func visit(_ v: NSView) {
                if let scn = v as? ViewportView {
                    let r = scn.convert(scn.bounds, to: view)
                    scn.snapshot().draw(in: r)
                }
                v.subviews.forEach(visit)
            }
            visit(view)
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct Draw4MeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("draw4me", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") { model.newDocument(template: nil) }.keyboardShortcut("n")
                Menu("New from Template") {
                    ForEach(TemplateName.allCases, id: \.self) { t in
                        Button(Templates.displayName(t)) { model.newDocument(template: t) }
                    }
                }
                Button("Open…") { model.open() }.keyboardShortcut("o")
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save As…") { model.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .saveItem) {
                Divider()
                Menu("Export") {
                    Button("3D View as PNG…") { model.export3DPNG() }.keyboardShortcut("e", modifiers: [.command, .shift])
                    Button("2D Drawing as PNG…") { model.export2DPNG() }
                    Divider()
                    Button("Model as USDZ…") { model.exportUSDZ() }
                    Button("Model as OBJ…") { model.exportOBJ() }
                }
            }
            CommandGroup(replacing: .undoRedo) {
                Button(model.editor.undoLabel.map { "Undo \($0)" } ?? "Undo") { model.undo() }
                    .keyboardShortcut("z").disabled(!model.editor.canUndo)
                Button(model.editor.redoLabel.map { "Redo \($0)" } ?? "Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!model.editor.canRedo)
            }
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("Duplicate") { model.duplicateSelection() }.keyboardShortcut("d").disabled(model.selection.isEmpty)
                Button("Delete Selection") { model.deleteSelection() }.keyboardShortcut(.delete, modifiers: .command).disabled(model.selection.isEmpty)
                Button("Group") { model.groupSelection() }.keyboardShortcut("g").disabled(model.selection.isEmpty)
                Button("Ungroup") { model.ungroupSelection() }.keyboardShortcut("g", modifiers: [.command, .shift])
                Button("Rotate 90° Left") { model.rotateSelection(90) }.keyboardShortcut("r", modifiers: [.command, .option])
                Button("Deselect All") { model.selection = [] }
                Divider()
                Button("Revert Agent Changes") { model.revertAgentChanges() }
                    .keyboardShortcut("z", modifiers: [.command, .option])
            }
            CommandMenu("View") {
                Picker("Viewport", selection: $model.mode) {
                    ForEach(ViewportMode.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Drawing", selection: $model.draftView) {
                    ForEach(DraftView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Show Roofs", isOn: $model.showRoofs)
                Button("Frame All") { model.frameAll() }
            }
            CommandMenu("Developer") {
                Toggle("Command Console", isOn: $model.showConsole).keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }
    }
}

import SwiftUI
import AppKit
import Draw4MeCore
import Draw4MeRender

/// Plan and elevations, drawn in a SwiftUI Canvas with the same `Drafting` code used for PNG export.
/// Click to select · drag a selected object (plan) to move it · drag empty space to pan ·
/// scroll / pinch to zoom.
struct Drawing2DView: View {
    @ObservedObject var model: AppModel

    @State private var layout: DraftLayout?
    @State private var canvasSize = CGSize.zero
    @State private var dragStartLayout: DraftLayout?
    @State private var dragMove: [String]?
    @State private var dragHit: String??
    @State private var previewDoc: SceneDocument?
    @State private var pendingDelta = Vec3.zero
    @State private var magnifyStart: DraftLayout?
    @State private var hovering = false
    /// True once the user zooms/pans; until then the drawing refits when the canvas resizes.
    @State private var userAdjusted = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $model.draftView) {
                    ForEach(DraftView.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 340)
                Spacer()
                Button { zoom(1 / 1.25) } label: { Image(systemName: "minus.magnifyingglass") }.help("Zoom out")
                Button { zoom(1.25) } label: { Image(systemName: "plus.magnifyingglass") }.help("Zoom in")
                Button { fit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Fit drawing")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8).padding(.vertical, 5)
            Divider()
            GeometryReader { geo in
                let doc = previewDoc ?? model.document
                let lay = currentLayout(size: geo.size)
                Canvas { ctx, size in
                    ctx.withCGContext { cg in
                        Drafting.draw(doc, layout: lay, size: size,
                                      options: DraftOptions(selected: model.selection, showRoofOutline: model.showRoofs), in: cg)
                    }
                }
                .contentShape(Rectangle())
                .gesture(dragGesture(lay))
                .simultaneousGesture(MagnifyGesture()
                    .onChanged { v in
                        if magnifyStart == nil { magnifyStart = lay }
                        userAdjusted = true
                        layout = magnifyStart!.zoomed(by: v.magnification, about: v.startLocation)
                    }
                    .onEnded { _ in magnifyStart = nil })
                .onAppear { canvasSize = geo.size }
                .onChange(of: geo.size) { _, s in
                    canvasSize = s
                    if !userAdjusted { layout = Drafting.fit(model.document, view: model.draftView, size: s) }
                }
                .onChange(of: model.draftView) { _, _ in userAdjusted = false }
                .onChange(of: model.frameRequest) { _, _ in fit() }
                .onContinuousHover { phase in
                    if case .active = phase { hovering = true } else { hovering = false }
                }
                .background(ScrollCatcher(active: hovering) { dy, loc in
                    let p = CGPoint(x: loc.x, y: geo.size.height - loc.y)
                    userAdjusted = true
                    layout = (layout ?? lay).zoomed(by: exp(dy * 0.01), about: p)
                })
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.delete) { model.deleteSelection(); return .handled }
            .onKeyPress(.escape) { model.selection = []; return .handled }
        }
    }

    private func currentLayout(size: CGSize) -> DraftLayout {
        if let l = layout, l.view == model.draftView { return l }
        let l = Drafting.fit(model.document, view: model.draftView, size: size)
        DispatchQueue.main.async { layout = l }
        return l
    }

    private func fit() {
        userAdjusted = false
        layout = Drafting.fit(model.document, view: model.draftView, size: canvasSize)
    }

    private func zoom(_ f: Double) {
        userAdjusted = true
        let c = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        layout = currentLayout(size: canvasSize).zoomed(by: f, about: c)
    }

    private func dragGesture(_ lay: DraftLayout) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                focused = true
                if dragHit == nil {
                    let hit = Drafting.hitTest(model.document, layout: lay, point: v.startLocation)
                    dragHit = .some(hit)
                    if lay.view == .plan, let h = hit, let ids = movableSelection(containing: h) {
                        dragMove = ids
                    } else {
                        dragStartLayout = lay
                    }
                }
                let dist = hypot(v.translation.width, v.translation.height)
                guard dist >= 3 else { return }
                if let ids = dragMove {
                    var d = lay.worldDelta(v.translation)
                    if !NSEvent.modifierFlags.contains(.option) {
                        d = Vec3((d.x / 0.05).rounded() * 0.05, 0, (d.z / 0.05).rounded() * 0.05)
                    }
                    pendingDelta = d
                    // Preview through the command layer (dry run) so it matches exactly what will be applied.
                    if case .success(let (doc, _)) = model.editor.dryRun([.move(MoveCommand(ids: ids, by: d))]) { previewDoc = doc }
                } else if let start = dragStartLayout {
                    var l = start
                    l.offset = CGPoint(x: start.offset.x + v.translation.width, y: start.offset.y + v.translation.height)
                    userAdjusted = true
                    layout = l
                }
            }
            .onEnded { v in
                let dist = hypot(v.translation.width, v.translation.height)
                if dist < 3 {
                    let hit = (dragHit ?? nil)
                    let extend = NSEvent.modifierFlags.contains(.shift) || NSEvent.modifierFlags.contains(.command)
                    if let h = hit {
                        if extend { if model.selection.contains(h) { model.selection.remove(h) } else { model.selection.insert(h) } }
                        else { model.selection = [h] }
                    } else if !extend { model.selection = [] }
                } else if let ids = dragMove, pendingDelta.length > 1e-9 {
                    model.apply(.move(MoveCommand(ids: ids, by: pendingDelta)))
                }
                dragHit = nil; dragMove = nil; dragStartLayout = nil; previewDoc = nil; pendingDelta = .zero
            }
    }

    private func movableSelection(containing id: String) -> [String]? {
        var cur: String? = id
        while let c = cur {
            if model.selection.contains(c) { return model.sortedSelection }
            cur = model.document.object(c)?.parentId
        }
        return nil
    }
}

/// Catches scroll-wheel events over the canvas (SwiftUI has no scroll-wheel modifier on macOS 14).
private struct ScrollCatcher: NSViewRepresentable {
    var active: Bool
    var onScroll: (Double, CGPoint) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        context.coordinator.view = v
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { e in
            let c = context.coordinator
            guard c.active, let view = c.view, e.window === view.window else { return e }
            let p = view.convert(e.locationInWindow, from: nil)
            guard view.bounds.contains(p) else { return e }
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            c.onScroll(Double(dy), p)
            return nil
        }
        return v
    }

    func updateNSView(_ v: NSView, context: Context) {
        context.coordinator.active = active
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ v: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    final class Coordinator {
        var monitor: Any?
        weak var view: NSView?
        var active = false
        var onScroll: (Double, CGPoint) -> Void
        init(onScroll: @escaping (Double, CGPoint) -> Void) { self.onScroll = onScroll }
    }
}

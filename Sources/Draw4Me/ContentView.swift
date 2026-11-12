import SwiftUI
import Draw4MeCore
import Draw4MeRender

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            OutlinerView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 360)
        } detail: {
            VStack(spacing: 0) {
                VSplitView {
                    HSplitView {
                        viewport
                            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
                        InspectorView(model: model)
                            .frame(minWidth: 250, idealWidth: 280, maxWidth: 380)
                    }
                    .frame(minHeight: 300)
                    if model.showConsole {
                        CommandConsoleView(model: model)
                            .frame(minHeight: 180, idealHeight: 260)
                    }
                }
                Divider()
                statusBar
            }
        }
        .toolbar { toolbar }
        .navigationTitle(model.windowTitle)
    }

    @ViewBuilder
    var viewport: some View {
        switch model.mode {
        case .model3D: Viewport3D(model: model)
        case .drawing2D: Drawing2DView(model: model)
        case .split:
            HSplitView {
                Viewport3D(model: model).frame(minWidth: 250)
                Drawing2DView(model: model).frame(minWidth: 250)
            }
        }
    }

    var statusBar: some View {
        HStack(spacing: 8) {
            Image(systemName: model.statusIsError ? "exclamationmark.triangle.fill" : "checkmark.circle")
                .foregroundStyle(model.statusIsError ? .orange : .secondary)
            Text(model.statusMessage).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(model.statusIsError ? .primary : .secondary)
            Spacer()
            Text("\(model.document.objects.count) objects · \(model.selection.count) selected")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .help(model.editor.undoLabel.map { "Undo \($0)" } ?? "Undo").disabled(!model.editor.canUndo)
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help(model.editor.redoLabel.map { "Redo \($0)" } ?? "Redo").disabled(!model.editor.canRedo)
        }
        ToolbarItemGroup(placement: .principal) {
            ForEach(quickAdd, id: \.self) { k in
                Button { model.add(k) } label: { Label(k.displayName, systemImage: OutlinerView.icon(k)) }
                    .help("Add \(k.displayName.lowercased())")
            }
            Menu {
                ForEach(ObjectKind.allCases.filter { $0 != .group }, id: \.self) { k in
                    Button { model.add(k) } label: { Label(k.displayName, systemImage: OutlinerView.icon(k)) }
                }
                Divider()
                Button("Insert Dining Set") { model.insertTemplate(.diningSet) }
                Button("Insert Simple House") { model.insertTemplate(.simpleHouse) }
            } label: { Label("Add", systemImage: "plus") }
                .help("Add any object or template")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("View", selection: $model.mode) {
                ForEach(ViewportMode.allCases) { Text($0.rawValue).tag($0) }
            }.pickerStyle(.segmented)
            Toggle(isOn: $model.showRoofs) { Image(systemName: "house") }.help("Show roofs")
            Button { model.frameAll() } label: { Image(systemName: "viewfinder") }.help("Frame all (F)")
            Button { model.showConsole.toggle() } label: { Image(systemName: "terminal") }.help("Command Console (⇧⌘K)")
        }
    }

    var quickAdd: [ObjectKind] { [.wall, .door, .window, .slab, .table, .chair, .box] }
}

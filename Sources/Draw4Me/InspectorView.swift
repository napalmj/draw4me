import SwiftUI
import Draw4MeCore
import Draw4MeRender

/// A number field that commits (as one command) on Return or when focus leaves.
struct NumberField: View {
    let label: String
    let value: Double
    var unit: String?
    var decimals = 3
    let onCommit: (Double) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Text(unit ?? "").frame(width: 26, alignment: .leading).foregroundStyle(.secondary).font(.caption)
        }
        .onAppear { text = fmt(value, decimals: decimals) }
        .onChange(of: value) { _, v in if !focused { text = fmt(v, decimals: decimals) } }
    }

    private func commit() {
        let cleaned = text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        guard let v = Double(cleaned) else { text = fmt(value, decimals: decimals); return }
        if abs(v - value) > 1e-9 { onCommit(v) } else { text = fmt(value, decimals: decimals) }
    }
}

struct CommitTextField: View {
    let label: String
    let value: String
    let onCommit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit { if text != value { onCommit(text) } }
                .onChange(of: focused) { _, f in if !f, text != value { onCommit(text) } }
        }
        .onAppear { text = value }
        .onChange(of: value) { _, v in text = v }
    }
}

struct InspectorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let sel = model.sortedSelection.compactMap { model.document.object($0) }
                if sel.count == 1, let o = sel.first {
                    objectInspector(o)
                } else if sel.count > 1 {
                    multiInspector(sel)
                } else {
                    documentInspector()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Single object

    @ViewBuilder
    func objectInspector(_ o: SceneObject) -> some View {
        HStack {
            Image(systemName: OutlinerView.icon(o.kind))
            Text(o.kind.displayName).font(.headline)
            Spacer()
            Text(o.id).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
        CommitTextField(label: "Name", value: o.name) { model.apply(.update(UpdateCommand(id: o.id, name: $0))) }

        if o.kind.isHosted {
            if let h = o.hostId, let w = model.document.object(h) {
                HStack {
                    Text("In wall").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                    Button(w.name) { model.selection = [w.id] }.buttonStyle(.link)
                }
            }
        } else if o.kind != .group {
            section("Position")
            NumberField(label: "X (east)", value: o.transform.position.x, unit: "m") { v in move(o, Vec3(v, o.transform.position.y, o.transform.position.z)) }
            NumberField(label: "Y (up)", value: o.transform.position.y, unit: "m") { v in move(o, Vec3(o.transform.position.x, v, o.transform.position.z)) }
            NumberField(label: "Z (south)", value: o.transform.position.z, unit: "m") { v in move(o, Vec3(o.transform.position.x, o.transform.position.y, v)) }
            NumberField(label: "Rotation", value: o.transform.rotation, unit: "°", decimals: 1) { v in
                model.apply(.update(UpdateCommand(id: o.id, rotation: v)))
            }
            HStack {
                Button("↺ 90°") { model.apply(.rotate(RotateCommand(ids: [o.id], degrees: 90))) }
                Button("↻ 90°") { model.apply(.rotate(RotateCommand(ids: [o.id], degrees: -90))) }
            }.controlSize(.small)
        }

        if !o.kind.paramSpecs.isEmpty {
            section("Dimensions")
            ForEach(o.kind.paramSpecs, id: \.key) { spec in paramRow(o, spec) }
        }

        if o.kind == .group {
            Text("\(model.document.children(of: o.id).count) members").foregroundStyle(.secondary)
            Button("Ungroup") { model.ungroupSelection() }
        } else {
            section("Material")
            materialRow(ids: [o.id], current: o.material)
        }

        section("Actions")
        actionButtons()
    }

    func move(_ o: SceneObject, _ p: Vec3) {
        model.apply(.update(UpdateCommand(id: o.id, position: p)))
    }

    @ViewBuilder
    func paramRow(_ o: SceneObject, _ spec: ParamSpec) -> some View {
        let label = spec.key.prefix(1).uppercased() + spec.key.dropFirst()
        switch spec.type {
        case .choice(let options):
            HStack(spacing: 4) {
                Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                Picker("", selection: Binding(get: { o.string(spec.key) }, set: { v in
                    model.apply(.update(UpdateCommand(id: o.id, params: [spec.key: .string(v)])))
                })) {
                    ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden()
            }
        case .count:
            HStack(spacing: 4) {
                Text(label).frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
                Stepper("\(Int(o.number(spec.key)))", value: Binding(get: { Int(o.number(spec.key)) }, set: { v in
                    model.apply(.update(UpdateCommand(id: o.id, params: [spec.key: .number(Double(v))])))
                }), in: Int(spec.min ?? 0)...Int(spec.max ?? 100))
            }
        case .bool:
            Toggle(label, isOn: Binding(get: { o.params[spec.key]?.bool ?? false }, set: { v in
                model.apply(.update(UpdateCommand(id: o.id, params: [spec.key: .bool(v)])))
            }))
        default:
            NumberField(label: label, value: o.number(spec.key), unit: spec.type.unit, decimals: spec.type == .angle ? 1 : 3) { v in
                model.apply(.update(UpdateCommand(id: o.id, params: [spec.key: .number(v)])))
            }
            .help(spec.help)
        }
    }

    @ViewBuilder
    func materialRow(ids: [String], current: Draw4MeCore.Material?) -> some View {
        HStack(spacing: 4) {
            Text("Preset").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { current?.preset ?? "custom" }, set: { v in
                guard v != "custom" else { return }
                model.apply(.setMaterial(SetMaterialCommand(ids: ids, material: .named(v))))
            })) {
                ForEach(MaterialLibrary.presetNames, id: \.self) { n in
                    Label(n.replacingOccurrences(of: "_", with: " ").capitalized, systemImage: "circle.fill")
                        .foregroundStyle(Color(nsColor: Palette.nsColor(MaterialLibrary.preset(n)!.color)))
                        .tag(n)
                }
                Text("Custom").tag("custom")
            }.labelsHidden()
        }
        HStack(spacing: 4) {
            Text("Color").frame(width: 92, alignment: .leading).foregroundStyle(.secondary)
            ColorPicker("", selection: Binding(get: {
                Color(nsColor: Palette.nsColor(current?.color ?? "#CCCCCC"))
            }, set: { c in
                guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return }
                let hex = MaterialLibrary.hex(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent))
                guard hex != current?.color else { return }
                model.applyCoalescing(.setMaterial(SetMaterialCommand(ids: ids, material: MaterialRef(color: hex, opacity: current?.opacity))),
                                      key: "color:\(ids.joined(separator: ","))")
            }), supportsOpacity: false).labelsHidden()
            Text(current?.color ?? "—").font(.caption.monospaced()).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func actionButtons() -> some View {
        HStack {
            Button("Duplicate") { model.duplicateSelection() }
            Button("Group") { model.groupSelection() }
            Button("Delete", role: .destructive) { model.deleteSelection() }
        }.controlSize(.small)
    }

    // MARK: Multi / none

    @ViewBuilder
    func multiInspector(_ sel: [SceneObject]) -> some View {
        Text("\(sel.count) objects selected").font(.headline)
        Text(sel.map(\.id).joined(separator: ", ")).font(.caption.monospaced()).foregroundStyle(.secondary)
        section("Material")
        materialRow(ids: sel.map(\.id), current: sel.first(where: { $0.kind != .group })?.material)
        section("Rotate together")
        HStack {
            Button("↺ 90°") { model.rotateSelection(90) }
            Button("↻ 90°") { model.rotateSelection(-90) }
        }.controlSize(.small)
        section("Actions")
        actionButtons()
    }

    @ViewBuilder
    func documentInspector() -> some View {
        Text(model.document.name).font(.headline)
        Text("\(model.document.objects.count) objects · units: metres").foregroundStyle(.secondary)
        if let b = Geometry.documentBounds(model.document) {
            Text("Extents \(fmt(b.size.x, decimals: 2)) × \(fmt(b.size.z, decimals: 2)) m, \(fmt(b.size.y, decimals: 2)) m tall")
                .foregroundStyle(.secondary)
        }
        Divider()
        Text("Nothing selected").font(.subheadline)
        Text("Click an object in the 3D view, the drawing or the outliner. Add objects from the toolbar.")
            .font(.caption).foregroundStyle(.secondary)
        Text("3D: drag to orbit, right/⌥-drag to pan, scroll to zoom, drag a selected object to move it, F to frame.")
            .font(.caption).foregroundStyle(.secondary)
    }

    func section(_ title: String) -> some View {
        Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 6)
    }
}

import SwiftUI
import AppKit
import Draw4MeCore
import Draw4MeRender
import Draw4MeAutomation

/// Developer console: type or paste JSON commands (or automation requests) and apply them.
/// Everything here goes through `AutomationService` — exactly what a future AI agent would call.
struct CommandConsoleView: View {
    @ObservedObject var model: AppModel
    @State private var input = Self.starter
    @State private var origin: CommandOrigin = .agent
    @State private var output = "Results appear here. Accepted input:\n• one command  {\"command\": \"add\", …}\n• an array of commands (one undoable transaction)\n• an automation request  {\"op\": \"summary\" | \"render\" | \"catalog\" | \"undo\" | \"history\" | …}"
    @State private var outputIsError = false
    @State private var image: NSImage?
    @State private var renderView: RenderView = .perspective

    static let starter = """
    [
      {"command": "add", "kind": "table", "ref": "t", "name": "Desk",
       "position": {"x": 6.5, "z": 1.2}, "params": {"width": 1.4, "depth": 0.7, "legStyle": "round"}, "material": "walnut"},
      {"command": "add", "kind": "chair", "position": {"x": 6.5, "z": 1.9}, "rotation": 180, "material": "black"}
    ]
    """

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Command Console").font(.headline)
                    Spacer()
                    Picker("Origin", selection: $origin) {
                        ForEach(CommandOrigin.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 150)
                    .help("Recorded in the undo history, so agent changes can be undone as a unit")
                    Menu("Examples") {
                        ForEach(CommandCatalog.all, id: \.name) { s in
                            Button(s.name.rawValue) { input = pretty(s.example) }
                        }
                        Divider()
                        Button("House + desk batch") { input = Self.houseBatch }
                        Button("Request: render plan") { input = #"{"op": "render", "render": {"view": "plan", "width": 1200, "height": 800}}"# }
                        Button("Request: undo last agent change") { input = #"{"op": "undo", "origin": "agent"}"# }
                        Button("Request: history") { input = #"{"op": "history"}"# }
                    }
                    .frame(width: 100)
                }
                TextEditor(text: $input)
                    .font(.system(.body, design: .monospaced))
                    .autocorrectionDisabled()
                    .frame(minHeight: 120)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button("Apply", action: run).keyboardShortcut(.return, modifiers: .command).buttonStyle(.borderedProminent)
                    Button("Summary") { show(model.automation.sceneSummary().text) }
                    Button("Catalog") { show(CommandCatalog.text()) }
                    Picker("", selection: $renderView) {
                        ForEach(RenderView.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.frame(width: 110).labelsHidden()
                    Button("Render") { render() }
                    Spacer()
                    Button("Undo Last Agent Change") {
                        if let e = model.editor.undoLast(from: .agent) { show("Undid agent change: \(e.label)") }
                        else { show("The most recent change wasn't made by the agent.", error: true) }
                    }
                }
                .controlSize(.small)
            }
            .padding(8)
            .frame(minWidth: 380)

            VStack(alignment: .leading, spacing: 4) {
                if let img = image {
                    HStack {
                        Text("Render preview (what an agent would see)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { image = nil } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless)
                    }
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        Text(output)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(outputIsError ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                }
                historyStrip
            }
            .padding(8)
            .frame(minWidth: 300)
        }
    }

    var historyStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Text("History:").font(.caption2).foregroundStyle(.secondary)
                ForEach(model.editor.undoStack.suffix(12).reversed(), id: \.id) { e in
                    Text("\(e.origin.rawValue) · \(e.label)")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(color(e.origin).opacity(0.18)))
                }
            }
        }
    }

    func color(_ o: CommandOrigin) -> Color {
        switch o { case .user: return .gray; case .script: return .orange; case .agent: return .purple }
    }

    func show(_ s: String, error: Bool = false) {
        image = nil; output = s; outputIsError = error
    }

    func pretty(_ json: String) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(json.utf8)),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return json }
        return String(data: d, encoding: .utf8) ?? json
    }

    func run() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data(text.utf8)
        // Automation request envelope?
        if text.hasPrefix("{"), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], obj["op"] != nil {
            var req = data
            if obj["origin"] == nil, (obj["op"] as? String) == "apply", var o = obj as [String: Any]? {
                o["origin"] = origin.rawValue
                req = (try? JSONSerialization.data(withJSONObject: o)) ?? data
            }
            let out = AutomationEndpoint.handle(json: req, service: model.automation)
            if let resp = try? JSONDecoder().decode(AutomationResponse.self, from: out),
               let b64 = resp.pngBase64, let png = Data(base64Encoded: b64), let img = NSImage(data: png) {
                image = img
                return
            }
            let r = try? JSONDecoder().decode(AutomationResponse.self, from: out)
            show(pretty(String(data: out, encoding: .utf8) ?? ""), error: r?.ok == false)
            return
        }
        do {
            let cmds = try Command.parseList(data)
            let r = model.apply(cmds, origin: origin, label: cmds.count > 1 ? "Console: \(cmds.count) commands" : nil)
            if r.ok { model.selection = Set(r.created.filter { model.document.object($0)?.hostId == nil }) }
            show(r.jsonString(), error: !r.ok)
        } catch let e as CommandError {
            show(e.message, error: true)
        } catch {
            show("\(error)", error: true)
        }
    }

    func render() {
        do {
            let png = try model.automation.render(RenderRequest(view: renderView, width: 1200, height: 800, highlight: Array(model.selection)))
            image = NSImage(data: png)
        } catch { show("Render failed: \(error)", error: true) }
    }

    static let houseBatch = """
    [
      {"command": "newDocument", "name": "Studio"},
      {"command": "add", "kind": "slab", "position": {"x": 2, "z": 3}, "params": {"width": 4.2, "depth": 6.2}},
      {"command": "add", "kind": "wall", "ref": "s", "name": "South", "from": {"x": -0.1, "z": 6}, "to": {"x": 4.1, "z": 6}},
      {"command": "add", "kind": "wall", "ref": "e", "name": "East",  "from": {"x": 4, "z": 5.9}, "to": {"x": 4, "z": 0.1}},
      {"command": "add", "kind": "wall", "ref": "n", "name": "North", "from": {"x": 4.1, "z": 0}, "to": {"x": -0.1, "z": 0}},
      {"command": "add", "kind": "wall", "ref": "w", "name": "West",  "from": {"x": 0, "z": 0.1}, "to": {"x": 0, "z": 5.9}},
      {"command": "add", "kind": "door", "host": "@s", "params": {"offset": 1.2}},
      {"command": "add", "kind": "window", "host": "@s", "params": {"offset": 3, "width": 1.4}},
      {"command": "add", "kind": "window", "host": "@n", "params": {"offset": 2.1, "width": 2}},
      {"command": "add", "kind": "roof", "position": {"x": 2, "y": 2.7, "z": 3}, "params": {"style": "hip", "width": 4.2, "depth": 6.2, "pitch": 30}},
      {"command": "add", "kind": "table", "ref": "d", "name": "Desk", "position": {"x": 2, "z": 1}, "params": {"width": 1.4, "depth": 0.7}, "material": "walnut"},
      {"command": "add", "kind": "chair", "position": {"x": 2, "z": 1.7}, "rotation": 180},
      {"command": "add", "kind": "shelf", "position": {"x": 3.7, "z": 4}, "rotation": 90}
    ]
    """
}

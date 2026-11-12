import Foundation
import Draw4MeCore
import Draw4MeRender
import Draw4MeAutomation

let usage = """
draw4me-cli — headless draw4me: apply JSON commands to a document and/or render it. No network.

USAGE
  draw4me-cli [--doc FILE] [--commands FILE|-]... [--command JSON]... [--origin user|script|agent]
              [--save FILE] [--render FILE.png [--view VIEW] [--size WxH]]...
              [--summary [--json]] [--catalog [--text]] [--request FILE|-]

OPTIONS
  --doc FILE         Start from this .draw4me document (default: empty document)
  --commands FILE    JSON file with one command or an array of commands ('-' = stdin).
                     Each file is applied as ONE undoable transaction. Repeatable.
  --command JSON     Inline command/array, e.g. '{"command":"add","kind":"table"}'. Repeatable.
  --origin O         Origin recorded in history (default: script)
  --save FILE        Write the resulting document (defaults to --doc's path if --in-place)
  --in-place         Save back to --doc
  --render FILE.png  Render a PNG. Use --view/--size right after it. Repeatable.
  --view VIEW        perspective | top | plan | front | side (default perspective)
  --size WxH         Pixel size (default 1600x1000; 2D views are drawn at 2x)
  --summary          Print the scene summary (text, or JSON with --json)
  --catalog          Print the command catalog (JSON, or text with --text)
  --request FILE     Handle an automation request (same JSON a future AI bridge would send),
                     print the response JSON. '-' = stdin.

EXAMPLES
  draw4me-cli --command '{"command":"loadTemplate","template":"simple_house"}' \\
              --command '{"command":"add","kind":"table","position":{"x":2.5,"z":4}}' \\
              --save house.draw4me --render house.png --render plan.png --view plan
  draw4me-cli --doc house.draw4me --summary
"""

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

func readInput(_ path: String) -> Data {
    if path == "-" { return FileHandle.standardInput.readDataToEndOfFile() }
    guard let d = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return d
}

struct RenderJob { var path: String; var view: RenderView = .perspective; var size = CGSize(width: 1600, height: 1000) }

var args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty || args.contains("--help") || args.contains("-h") { print(usage); exit(0) }

var docPath: String?
var batches: [(String, Data)] = []
var origin = CommandOrigin.script
var savePath: String?
var inPlace = false
var renders: [RenderJob] = []
var wantSummary = false, json = false, wantCatalog = false, catalogText = false
var requests: [Data] = []

var i = 0
func next() -> String {
    i += 1
    guard i < args.count else { fail("\(args[i - 1]) needs a value") }
    return args[i]
}
while i < args.count {
    let a = args[i]
    switch a {
    case "--doc": docPath = next()
    case "--commands": let p = next(); batches.append((p, readInput(p)))
    case "--command": batches.append(("--command", Data(next().utf8)))
    case "--origin":
        let v = next()
        guard let o = CommandOrigin(rawValue: v) else { fail("origin must be user, script or agent") }
        origin = o
    case "--save": savePath = next()
    case "--in-place": inPlace = true
    case "--render": renders.append(RenderJob(path: next()))
    case "--view":
        let v = next()
        guard let rv = RenderView(rawValue: v) else { fail("view must be one of \(RenderView.allCases.map(\.rawValue).joined(separator: ", "))") }
        guard !renders.isEmpty else { fail("--view must follow --render") }
        renders[renders.count - 1].view = rv
    case "--size":
        let parts = next().lowercased().split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, !renders.isEmpty else { fail("--size WxH must follow --render") }
        renders[renders.count - 1].size = CGSize(width: parts[0], height: parts[1])
    case "--summary": wantSummary = true
    case "--json": json = true
    case "--catalog": wantCatalog = true
    case "--text": catalogText = true
    case "--request": requests.append(readInput(next()))
    default: fail("unknown option \(a)\n\n\(usage)")
    }
    i += 1
}

var doc = SceneDocument()
if let p = docPath {
    do { doc = try SceneDocument.load(from: readInput(p)) } catch { fail("can't open \(p): \(error)") }
}
let editor = DocumentEditor(document: doc)
let service = InProcessAutomationService(editor: editor)

for (name, data) in batches {
    let cmds: [Command]
    do { cmds = try Command.parseList(data) } catch { fail("\(name): \(error)") }
    let r = service.apply(cmds, origin: origin, label: nil)
    if !r.ok { fail("\(name): \(r.message)") }
    FileHandle.standardError.write(Data("✓ \(r.message)\n".utf8))
}

for req in requests {
    let out = AutomationEndpoint.handle(json: req, service: service)
    print(String(data: out, encoding: .utf8) ?? "")
}

if inPlace { savePath = savePath ?? docPath }
if let s = savePath {
    do {
        try editor.document.jsonData().write(to: URL(fileURLWithPath: s))
        FileHandle.standardError.write(Data("✓ saved \(s)\n".utf8))
    } catch { fail("can't save \(s): \(error)") }
}

for job in renders {
    do {
        let png = try Renderer.png(editor.document, request: RenderRequest(view: job.view, width: Int(job.size.width), height: Int(job.size.height)))
        try png.write(to: URL(fileURLWithPath: job.path))
        FileHandle.standardError.write(Data("✓ rendered \(job.view.rawValue) → \(job.path) (\(png.count) bytes)\n".utf8))
    } catch { fail("render \(job.path): \(error)") }
}

if wantSummary {
    let s = service.sceneSummary()
    print(json ? s.jsonString() : s.text, terminator: json ? "\n" : "")
}
if wantCatalog { print(catalogText ? CommandCatalog.text() : service.catalogJSON()) }

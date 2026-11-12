import Foundation
import Draw4MeCore
import Draw4MeAutomation

/// The app's automation service: the in-process service plus what only the app knows — the
/// person's current selection, the open file, and highlighting what an agent just changed.
/// Transports (the local socket server, the Command Console) call it on the main thread.
final class AppAutomationService: InProcessAutomationService {
    weak var model: AppModel?

    init(editor: DocumentEditor) { super.init(editor: editor, mode: "app") }

    private func onMain<T>(_ body: @MainActor () -> T) -> T {
        precondition(Thread.isMainThread, "AppAutomationService must be called on the main thread")
        return MainActor.assumeIsolated(body)
    }

    override func apply(_ commands: [Command], origin: CommandOrigin, label: String?, expectedRevision: Int?) -> CommandResult {
        let r = super.apply(commands, origin: origin, label: label, expectedRevision: expectedRevision)
        onMain { model?.didApply(r, origin: origin) }
        return r
    }

    override func revertLast(from origin: CommandOrigin) -> CommandResult {
        let r = super.revertLast(from: origin)
        onMain { model?.didRevert(r, origin: origin) }
        return r
    }

    override func selection() -> SelectionInfo {
        onMain {
            guard let model else { return super.selection() }
            let ids = model.sortedSelection
            guard !ids.isEmpty else { return SelectionInfo(ids: [], description: "Nothing is selected in the app.") }
            let lines = SceneSummary(model.document).text.split(separator: "\n").filter { line in
                ids.contains { line.hasPrefix("- \($0) ") || line.hasPrefix("\($0) ") || line.contains("[\($0)]") }
            }
            let desc = "Selected: \(ids.joined(separator: ", "))" + (lines.isEmpty ? "" : "\n" + lines.joined(separator: "\n"))
            return SelectionInfo(ids: ids, description: desc)
        }
    }

    override func status() -> AutomationStatus {
        fileURL = onMain { model?.fileURL }
        return super.status()
    }
}

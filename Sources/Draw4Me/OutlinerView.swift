import SwiftUI
import Draw4MeCore

/// Tree of objects: groups contain their members, walls contain their doors and windows.
struct OutlinerView: View {
    @ObservedObject var model: AppModel

    struct Row: Identifiable, Hashable {
        let id: String
        let title: String
        let kind: ObjectKind
        var children: [Row]?
    }

    var rows: [Row] {
        let doc = model.document
        func row(_ o: SceneObject) -> Row {
            let kids = doc.objects.filter { $0.parentId == o.id || $0.hostId == o.id }.map(row)
            return Row(id: o.id, title: o.name, kind: o.kind, children: kids.isEmpty ? nil : kids)
        }
        return doc.objects.filter { $0.parentId == nil && $0.hostId == nil }.map(row)
    }

    var body: some View {
        List(rows, children: \.children, selection: $model.selection) { r in
            HStack(spacing: 6) {
                Image(systemName: Self.icon(r.kind)).foregroundStyle(.secondary).frame(width: 16)
                Text(r.title).lineLimit(1)
                Spacer()
                Text(r.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
            }
            .tag(r.id)
        }
        .listStyle(.sidebar)
        .onDeleteCommand { model.deleteSelection() }
    }

    static func icon(_ k: ObjectKind) -> String {
        switch k {
        case .wall: return "rectangle.split.3x1"
        case .slab: return "square.fill"
        case .door: return "door.left.hand.open"
        case .window: return "window.casement"
        case .roof: return "house"
        case .box: return "cube"
        case .cylinder: return "cylinder"
        case .table: return "table.furniture"
        case .chair: return "chair"
        case .shelf: return "books.vertical"
        case .group: return "folder"
        }
    }
}

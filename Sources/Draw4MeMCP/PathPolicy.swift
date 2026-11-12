import Foundation
import Draw4MeCore
import Draw4MeAutomation

/// Rules for file paths that arrive from an agent (open/save/export tools).
///
/// - Must resolve (after `~` expansion, `..` removal and symlink resolution of the folder) to a
///   location inside the user's home folder.
/// - No hidden path components (blocks `~/.ssh`, `~/.config`, shell rc files, …) and nothing in
///   `~/Library` except draw4me's own Application Support folder.
/// - The extension must match what is being written; existing files are only replaced with
///   `overwrite: true`, and never through a symlink.
public enum PathPolicy {
    public struct Violation: Error, CustomStringConvertible { public let description: String }

    static var home: URL {
        URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL
    }

    static func resolve(_ raw: String) throws -> URL {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 1024, !trimmed.contains("\u{0}") else { throw Violation(description: "Give a file path") }
        let expanded = (trimmed as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw Violation(description: "Use an absolute path or one starting with ~/ (got \(trimmed.prefix(200)))") }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        // Resolve symlinks in the folder (the file itself may not exist yet).
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = folder.appendingPathComponent(url.lastPathComponent)
        let h = home.path
        guard resolved.path.hasPrefix(h + "/") else { throw Violation(description: "Files must be inside your home folder (\(h))") }
        let rel = resolved.path.dropFirst(h.count + 1).split(separator: "/")
        if rel.contains(where: { $0.hasPrefix(".") }) { throw Violation(description: "Hidden files and folders are not allowed") }
        if rel.first == "Library" {
            let ours = LocalSocket.defaultDirectory.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.path.hasPrefix(ours + "/") else { throw Violation(description: "Files in ~/Library are not allowed (except draw4me's own folder)") }
        }
        return resolved
    }

    /// Validates a path to write. Returns the resolved URL.
    public static func forWriting(_ raw: String, ext: String, overwrite: Bool) throws -> URL {
        let url = try resolve(raw)
        guard url.pathExtension.lowercased() == ext else { throw Violation(description: "The file name must end in .\(ext)") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &isDir), isDir.boolValue else {
            throw Violation(description: "The folder \(url.deletingLastPathComponent().path) does not exist")
        }
        var st = stat()
        if lstat(url.path, &st) == 0 {
            guard (st.st_mode & S_IFMT) == S_IFREG else { throw Violation(description: "\(url.lastPathComponent) exists and is not a regular file") }
            guard overwrite else { throw Violation(description: "\(url.path) already exists; pass overwrite: true to replace it") }
        }
        return url
    }

    /// Validates a path to read. Returns the resolved URL.
    public static func forReading(_ raw: String, ext: String) throws -> URL {
        let url = try resolve(raw)
        guard url.pathExtension.lowercased() == ext else { throw Violation(description: "Expected a .\(ext) file") }
        var st = stat()
        guard lstat(url.path, &st) == 0 else { throw Violation(description: "\(url.path) does not exist") }
        guard (st.st_mode & S_IFMT) == S_IFREG else { throw Violation(description: "\(url.lastPathComponent) is not a regular file") }
        return url
    }

    static let maxDocumentBytes = 50 * 1024 * 1024

    public static func readDocument(_ url: URL) throws -> SceneDocument {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        guard size <= maxDocumentBytes else { throw Violation(description: "\(url.lastPathComponent) is larger than 50 MB") }
        let doc = try SceneDocument.load(from: Data(contentsOf: url))
        try DocumentLimits.check(doc)
        return doc
    }
}

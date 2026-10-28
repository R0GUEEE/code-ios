import Foundation
import UIKit

struct FileEntry: Identifiable, Hashable {
    let url: URL
    let isDirectory: Bool
    let size: Int
    let modified: Date

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var ext: String { url.pathExtension.lowercased() }

    var subtitle: String {
        if isDirectory { return "" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(size))
    }

    var symbolName: String {
        if isDirectory { return "folder.fill" }
        switch ext {
        case "swift": return "swift"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "js", "jsx", "mjs": return "curlybraces"
        case "ts", "tsx": return "curlybraces.square"
        case "json": return "curlybraces.square.fill"
        case "md", "markdown": return "text.alignleft"
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "sh", "zsh", "bash": return "terminal"
        case "html", "htm": return "globe"
        case "css", "scss": return "paintbrush"
        default: return "doc.text"
        }
    }
}

enum FileService {
    static func list(_ directory: URL, showHidden: Bool) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: showHidden ? [] : [.skipsHiddenFiles]
        ) else {
            return []
        }

        let entries: [FileEntry] = urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            if url.lastPathComponent == ".DS_Store" { return nil }
            return FileEntry(
                url: url,
                isDirectory: values.isDirectory ?? false,
                size: values.fileSize ?? 0,
                modified: values.contentModificationDate ?? .distantPast
            )
        }

        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// Confine any URL we open or write to the active workspace.
    static func isInside(_ url: URL, workspace: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.path
        let root = workspace.resolvingSymlinksInPath().standardizedFileURL.path
        return target == root || target.hasPrefix(root + "/")
    }

    static func createFile(in directory: URL, named name: String) throws -> URL {
        var candidate = directory.appendingPathComponent(name)
        var index = 2
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = "\(base) \(index)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = directory.appendingPathComponent(next)
            index += 1
        }
        try Data().write(to: candidate)
        return candidate
    }

    static func createFolder(in directory: URL, named name: String) throws -> URL {
        var candidate = directory.appendingPathComponent(name, isDirectory: true)
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(name) \(index)", isDirectory: true)
            index += 1
        }
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
        return candidate
    }
}

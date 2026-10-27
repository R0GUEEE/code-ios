import Foundation

/// Serves the workbench's FileSystemProvider calls (`iosfs://`) from the app
/// container. Every path is canonicalised and confined to the workspace root:
/// the provider is the only door between extension JavaScript and the device.
final class FSBridge {
    private let roots: [String]

    init(root: URL, additionalRoots: [URL] = []) {
        var resolved: [String] = []
        for candidate in [root] + additionalRoots {
            let path = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            if !resolved.contains(path) { resolved.append(path) }
        }
        self.roots = resolved
    }

    var workspacePath: String { roots.first ?? "/" }

    func handle(op: String, request: HTTPRequest) -> HTTPResponse {
        do {
            switch op {
            case "stat":
                return try stat(path: try required(request, "path"))
            case "list":
                return try list(path: try required(request, "path"))
            case "read":
                return try read(path: try required(request, "path"))
            case "write":
                return try write(path: try required(request, "path"), data: request.body)
            case "mkdir":
                return try mkdir(path: try required(request, "path"))
            case "delete":
                return try delete(path: try required(request, "path"),
                                  recursive: request.query["recursive"] == "1")
            case "rename":
                return try rename(from: try required(request, "from"), to: try required(request, "to"))
            default:
                return .jsonError("unknown op '\(op)'", status: 404)
            }
        } catch let error as BridgeError {
            return .jsonError(error.message, status: error.status)
        } catch {
            return .jsonError((error as NSError).localizedDescription, status: 500)
        }
    }

    // MARK: - operations

    private func stat(path: String) throws -> HTTPResponse {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey])
        let isDirectory = values.isDirectory ?? false
        let mtime = (values.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
        return .json([
            "type": isDirectory ? 2 : 1,
            "size": values.fileSize ?? 0,
            "mtime": Int(mtime)
        ])
    }

    private func list(path: String) throws -> HTTPResponse {
        let url = try resolve(path)
        let entries = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: []
        )
        var rows: [[String: Any]] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            let mtime = (values?.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970 * 1000
            rows.append([
                "name": entry.lastPathComponent,
                "dir": values?.isDirectory ?? false,
                "size": values?.fileSize ?? 0,
                "mtime": Int(mtime)
            ])
        }
        rows.sort { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
        return .json(rows)
    }

    private func read(path: String) throws -> HTTPResponse {
        let url = try resolve(path)
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return .file(data, contentType: "application/octet-stream")
    }

    private func write(path: String, data: Data) throws -> HTTPResponse {
        let url = try resolve(path, mustExist: false)
        let parent = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try data.write(to: url, options: .atomic)
        return .json(["ok": true, "bytes": data.count])
    }

    private func mkdir(path: String) throws -> HTTPResponse {
        let url = try resolve(path, mustExist: false)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return .json(["ok": true])
    }

    private func delete(path: String, recursive: Bool) throws -> HTTPResponse {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if (values.isDirectory ?? false) && !recursive {
            let children = try FileManager.default.contentsOfDirectory(atPath: url.path)
            if !children.isEmpty {
                throw BridgeError(status: 400, message: "directory not empty: \(url.path)")
            }
        }
        try FileManager.default.removeItem(at: url)
        return .json(["ok": true])
    }

    private func rename(from: String, to: String) throws -> HTTPResponse {
        let source = try resolve(from)
        let target = try resolve(to, mustExist: false)
        let parent = target.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: source, to: target)
        return .json(["ok": true])
    }

    // MARK: - helpers

    private func required(_ request: HTTPRequest, _ key: String) throws -> String {
        guard let value = request.query[key], !value.isEmpty else {
            throw BridgeError(status: 400, message: "missing '\(key)'")
        }
        return value
    }

    private func resolve(_ path: String, mustExist: Bool = true) throws -> URL {
        guard path.hasPrefix("/") else {
            throw BridgeError(status: 400, message: "path must be absolute")
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        // Resolve symlinks *before* the containment check: otherwise a symlink
        // planted inside the workspace would launder access to anywhere on disk.
        let canonical = url.resolvingSymlinksInPath().path

        let inside = roots.contains { root in
            canonical == root || canonical.hasPrefix(root + "/")
        }
        guard inside else {
            throw BridgeError(status: 403, message: "path outside workspace: \(canonical)")
        }
        if mustExist && !FileManager.default.fileExists(atPath: canonical) {
            throw BridgeError(status: 404, message: "not found: \(canonical)")
        }
        return url
    }
}

struct BridgeError: Error {
    let status: Int
    let message: String
}

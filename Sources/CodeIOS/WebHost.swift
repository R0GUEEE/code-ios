import Foundation
import UIKit

/// Owns the loopback server, the bundled workbench, the extension store and the
/// filesystem bridge. One object == one running VS Code instance.
final class WebHost {
    private let server: HTTPServer
    private let bridge: FSBridge
    private let webRoot: URL
    private let extRoot: URL
    private let workspaceURL: URL
    private(set) var port: UInt16 = 0

    static let workbenchPath = "out/vs/code/browser/workbench/workbench.html"

    init(workspaceURL: URL, webRoot: URL, extRoot: URL) throws {
        self.workspaceURL = workspaceURL
        guard FileManager.default.fileExists(atPath: webRoot.appendingPathComponent(Self.workbenchPath).path) else {
            throw HostError("workbench assets missing at \(webRoot.path) (expected \(Self.workbenchPath)); "
                            + "bundle contains: \(Self.bundleListing())")
        }
        self.webRoot = webRoot
        self.extRoot = extRoot
        self.bridge = FSBridge(root: workspaceURL)

        let server = HTTPServer()
        self.server = server
        server.handler = { [weak self] request in
            guard let self = self else { return .text("host gone", status: 500) }
            return self.route(request)
        }
    }

    /// A folder reference is copied next to the bundle's other resources, which on a
    /// non-wrapped app bundle is not always `resourceURL`. Check every layout.
    private static func resourceDirectory(named name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent(name, isDirectory: true))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent(name, isDirectory: true))
        candidates.append(Bundle.main.bundleURL
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true))
        for candidate in candidates {
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func bundleListing() -> String {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: Bundle.main.bundleURL.path)) ?? []
        return names.sorted().joined(separator: ", ")
    }

    func start() throws -> URL {
        port = try server.start()
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else {
            throw HostError("bad base url")
        }
        NSLog("codeios: workbench at \(url.absoluteString) workspace=\(workspaceURL.path)")
        return url
    }

    func stop() {
        server.stop()
    }

    // MARK: - routing

    private func route(_ request: HTTPRequest) -> HTTPResponse {
        let path = request.path

        if path == "/_api/workspace" {
            return .json(["folder": bridge.workspacePath, "autoOpen": true, "port": Int(port),
                          "compact": Self.isCompact])
        }
        if path == "/_api/log" {
            if let text = String(data: request.body, encoding: .utf8) {
                NSLog("codeios.iosfs: \(text)")
            }
            return .json(["ok": true])
        }
        if path.hasPrefix("/_api/fs/") {
            let op = String(path.dropFirst("/_api/fs/".count))
            return bridge.handle(op: op, request: request)
        }
        if path == "/_api/diagnostics" {
            return .text(Diagnostics.log())
        }
        if path == "/product.json" {
            return .json(productConfiguration())
        }
        if path == "/" || path == "/index.html" || path == "/workbench" {
            return workbench()
        }
        if path == "/healthz" {
            return .text("ok")
        }
        if path.hasPrefix("/resources/server/") {
            let relative = String(path.dropFirst("/resources/server/".count))
            return staticFile(root: webRoot, relative: relative, request: request)
        }
        if path.hasPrefix("/ext/") {
            let relative = String(path.dropFirst("/ext/".count))
            return staticFile(root: extRoot, relative: relative, request: request)
        }
        return staticFile(root: webRoot, relative: String(path.dropFirst()), request: request)
    }

    private func staticFile(root: URL, relative: String, request: HTTPRequest) -> HTTPResponse {
        guard !relative.isEmpty else { return .text("not found", status: 404) }
        let candidate = root.appendingPathComponent(relative).standardizedFileURL
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let target = candidate.resolvingSymlinksInPath().path
        guard target == rootPath || target.hasPrefix(rootPath + "/") else {
            return .text("forbidden", status: 403)
        }
        guard let data = try? Data(contentsOf: candidate, options: [.mappedIfSafe]) else {
            return .text("not found", status: 404)
        }
        // Weak validator from size+mtime: revalidate bundled assets so an app
        // update can never serve yesterday's workbench out of the HTTP cache.
        let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? data.count
        let mtime = Int((attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)
        let etag = "\"\(size)-\(mtime)\""

        if request.headers["if-none-match"] == etag {
            var notModified = HTTPResponse.empty(status: 304)
            notModified.extraHeaders = [("ETag", etag)]
            return notModified
        }
        var response = HTTPResponse.asset(data, contentType: MIME.type(forPath: relative))
        response.cacheControl = "no-cache"
        response.extraHeaders = [("ETag", etag)]
        return response
    }

    // MARK: - workbench configuration

    private func productConfiguration() -> [String: Any] {
        var product: [String: Any] = [
            "nameShort": "VS Code",
            "nameLong": "VS Code for iOS",
            "applicationName": "code-ios",
            "dataFolderName": ".vscode-ios",
            "version": "1.91.1",
            "commit": "e170252f762678d22cb17edbaa5b7c6e77a1e0a6",
            "date": "2024-07-02T00:00:00.000Z",
            "quality": "stable",
            "serverLicense": "",
            "serverLicenseUrl": "",
            "linkProtectionTrustedDomains": ["https://open-vsx.org"],
            "extensionsGallery": [
                "serviceUrl": "https://open-vsx.org/vscode/gallery",
                "itemUrl": "https://open-vsx.org/vscode/item",
                "resourceUrlTemplate": "https://open-vsx.org/vscode/asset/{publisher}/{name}/{version}/{path}",
                "controlUrl": "",
                "recommendationsUrl": ""
            ]
        ]
        product["productConfiguration"] = product

        var config = product
        config["productConfiguration"] = product
        config["folderUri"] = [
            "scheme": "iosfs",
            "authority": "local",
            "path": bridge.workspacePath
        ]
        config["workspaceUri"] = NSNull()
        config["configurationDefaults"] = Self.phoneDefaults
        config["additionalBuiltinExtensions"] = [
            [
                "scheme": "http",
                "authority": "127.0.0.1:\(port)",
                "path": "/ext/ios-fs"
            ]
        ]
        return config
    }

    private func workbench() -> HTTPResponse {
        let file = webRoot.appendingPathComponent(Self.workbenchPath)
        guard var html = try? String(contentsOf: file, encoding: .utf8) else {
            return .text("workbench template unreadable", status: 500)
        }
        let configJSON = jsonString(productConfiguration())
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let replacements: [String: String] = [
            "{{WORKBENCH_WEB_BASE_URL}}": "",
            "{{WORKBENCH_WEB_CONFIGURATION}}": configJSON,
            "{{WORKBENCH_AUTH_SESSION}}": "{}",
            "{{WORKBENCH_BUILTIN_EXTENSIONS}}": "[]",
            "{{WORKBENCH_NLS_BASE_URL}}": "",
            "{{NLS_BASE_URL}}": "",
            "{{WORKBENCH_NLS_REMOTE}}": ""
        ]
        for (key, value) in replacements {
            html = html.replacingOccurrences(of: key, with: value)
        }

        // The workbench ships a desktop shell. On a phone the navigation arrows,
        // the layout widget and a breadcrumb row are pure chrome, and the status
        // bar would sit under the home indicator without viewport-fit=cover.
        html = html.replacingOccurrences(
            of: "width=device-width, initial-scale=1.0",
            with: "width=device-width, initial-scale=1.0, viewport-fit=cover")
        html = html.replacingOccurrences(of: "</head>", with: Self.phoneStyles + "</head>")
        return .html(html)
    }

    static var isCompact: Bool {
        UIScreen.main.bounds.width < 500
    }

    /// Settings that make the desktop workbench behave like a phone editor.
    static let phoneDefaults: [String: Any] = [
        "workbench.colorTheme": "Default Dark Modern",
        // activity bar moves into the title bar: frees a whole column
        "workbench.activityBar.location": "top",
        // the layout widget (four icons top-right) is desktop-only chrome
        "workbench.layoutControl.enabled": false,
        "breadcrumbs.enabled": false,
        "explorer.compactFolders": false,
        "workbench.secondarySideBar.defaultVisibility": "hidden",
        "workbench.editor.tabSizing": "shrink",
        "workbench.startupEditor": "none",
        "workbench.tips.enabled": false,
        "workbench.tree.indent": 10,
        "editor.fontSize": 12,
        "editor.minimap.enabled": false,
        "editor.lineNumbers": "on",
        "editor.scrollbar.vertical": "hidden",
        "editor.overviewRulerBorder": false,
        "terminal.integrated.fontSize": 11
    ]

    static let phoneStyles = """
    <style id="codeios-phone">
    .monaco-workbench .part.statusbar {
      padding-bottom: env(safe-area-inset-bottom, 0px);
      font-size: 10px;
    }
    .monaco-workbench .part.statusbar .statusbar-item.left { max-width: 45vw; }
    @media (max-width: 640px) {
      /* single-window app: back/forward navigation arrows are dead weight */
      .monaco-workbench .part.titlebar .titlebar-left { display: none !important; }
      .monaco-workbench .part.titlebar .titlebar-center { padding: 0 4px; }
      .monaco-workbench .part.activitybar .action-item { padding: 2px 6px; }
      /* touch targets: the file tree rows are 22px by default */
      .monaco-workbench .monaco-list .monaco-list-row { height: 30px !important; line-height: 30px !important; }
      .monaco-workbench .tabs-container .tab { font-size: 11px; }
    }
    </style>
    """

    private func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}

struct HostError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

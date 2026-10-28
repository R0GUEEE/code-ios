import Foundation
import SwiftUI

/// One open document. Text is held here so tabs keep their contents when you
/// navigate away, and so a dirty document can be saved or discarded deliberately.
final class EditorTab: Identifiable, ObservableObject {
    let id = UUID()
    let url: URL
    @Published var text: String
    @Published var savedText: String
    @Published var error: String?

    var isDirty: Bool { text != savedText }
    var name: String { url.lastPathComponent }
    var language: Language { Language(fileExtension: url.pathExtension) }

    init(url: URL, text: String) {
        self.url = url
        self.text = text
        self.savedText = text
    }

    func save() {
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            savedText = text
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func revert() {
        text = savedText
    }
}

enum Language: String {
    case swift, python, javascript, typescript, json, markdown, html, css, shell, plain

    init(fileExtension ext: String) {
        switch ext.lowercased() {
        case "swift": self = .swift
        case "py", "pyw": self = .python
        case "js", "jsx", "mjs": self = .javascript
        case "ts", "tsx": self = .typescript
        case "json", "jsonc": self = .json
        case "md", "markdown": self = .markdown
        case "html", "htm": self = .html
        case "css", "scss": self = .css
        case "sh", "zsh", "bash": self = .shell
        default: self = .plain
        }
    }

    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .python: return "Python"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .json: return "JSON"
        case .markdown: return "Markdown"
        case .html: return "HTML"
        case .css: return "CSS"
        case .shell: return "Shell"
        case .plain: return "Text"
        }
    }
}

struct RecentWorkspace: Codable, Identifiable, Hashable {
    var id: String { path }
    let path: String
    var name: String { (path as NSString).lastPathComponent }
}

/// App-wide state: which folder is open, which documents are open, appearance.
@MainActor
final class AppModel: ObservableObject {
    @Published var workspace: URL
    @Published var tabs: [EditorTab] = []
    @Published var activeTabID: UUID?
    @Published var recents: [RecentWorkspace] = []

    @Published var fontSize: Double { didSet { Self.store(fontSize, "editor.fontSize") } }
    @Published var wrapLines: Bool { didSet { Self.store(wrapLines, "editor.wrapLines") } }
    @Published var highlighting: Bool { didSet { Self.store(highlighting, "editor.highlighting") } }
    @Published var themeRaw: String { didSet { Self.store(themeRaw, "editor.theme") } }
    @Published var showHiddenFiles: Bool { didSet { Self.store(showHiddenFiles, "app.showHiddenFiles") } }

    private static func store(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    var activeTab: EditorTab? {
        tabs.first { $0.id == activeTabID }
    }

    var colorScheme: ColorScheme? {
        switch themeRaw {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    init() {
        let defaults = UserDefaults.standard
        let storedSize = defaults.object(forKey: "editor.fontSize") as? Double
        let storedTheme = defaults.string(forKey: "editor.theme")
        self.fontSize = storedSize ?? 13
        self.wrapLines = defaults.object(forKey: "editor.wrapLines") as? Bool ?? false
        self.highlighting = defaults.object(forKey: "editor.highlighting") as? Bool ?? true
        self.themeRaw = storedTheme ?? "dark"
        self.showHiddenFiles = defaults.bool(forKey: "app.showHiddenFiles")

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let defaultWorkspace = documents.appendingPathComponent("Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: defaultWorkspace, withIntermediateDirectories: true)
        self.workspace = defaultWorkspace
        loadRecents()
        remember(defaultWorkspace)
    }

    // MARK: - workspaces

    func switchWorkspace(to url: URL) {
        workspace = url
        remember(url)
    }

    private func remember(_ url: URL) {
        let entry = RecentWorkspace(path: url.path)
        recents.removeAll { $0.path == entry.path }
        recents.insert(entry, at: 0)
        recents = Array(recents.prefix(8))
        if let data = try? JSONEncoder().encode(recents) {
            UserDefaults.standard.set(data, forKey: "app.recents")
        }
    }

    private func loadRecents() {
        guard let data = UserDefaults.standard.data(forKey: "app.recents"),
              let decoded = try? JSONDecoder().decode([RecentWorkspace].self, from: data) else { return }
        recents = decoded.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - documents

    func open(_ url: URL) {
        if let existing = tabs.first(where: { $0.url == url }) {
            activeTabID = existing.id
            return
        }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let tab = EditorTab(url: url, text: text)
            tabs.append(tab)
            activeTabID = tab.id
        } catch {
            let tab = EditorTab(url: url, text: "")
            tab.error = "Could not read file: \(error.localizedDescription)"
            tabs.append(tab)
            activeTabID = tab.id
        }
    }

    func close(_ tab: EditorTab) {
        tabs.removeAll { $0.id == tab.id }
        if activeTabID == tab.id {
            activeTabID = tabs.last?.id
        }
    }

    func saveActive() {
        activeTab?.save()
    }

    func closeAll() {
        tabs.removeAll()
        activeTabID = nil
    }
}

import SwiftUI

struct BrowserView: View {
    @EnvironmentObject private var app: AppModel
    let directory: URL

    @State private var entries: [FileEntry] = []
    @State private var query = ""
    @State private var showingSettings = false
    @State private var showingWorkbench = false
    @State private var showingFolderPicker = false
    @State private var showingNewFile = false
    @State private var newFileName = "untitled.swift"

    private var filtered: [FileEntry] {
        guard !query.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if !app.tabs.isEmpty {
                Section("Open") {
                    ForEach(app.tabs) { tab in
                        NavigationLink(value: tab.url) {
                            HStack(spacing: 10) {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(tab.name).lineLimit(1)
                                    if tab.isDirty {
                                        Text("Unsaved changes")
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Section {
                if filtered.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "folder")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("Empty folder").font(.headline)
                        Text("Create a file, or open this folder in VS Code mode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(filtered) { entry in
                        if entry.isDirectory {
                            NavigationLink(value: entry.url) {
                                row(entry, systemImage: "folder.fill", tint: .accentColor)
                            }
                        } else {
                            NavigationLink(value: entry.url) {
                                row(entry, systemImage: entry.symbolName, tint: .secondary)
                            }
                        }
                    }
                    .onDelete(perform: delete)
                }
            } header: {
                Text(directory.lastPathComponent)
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .automatic), prompt: "Filter files")
        .navigationTitle(directory == app.workspace ? app.workspace.lastPathComponent : directory.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        newFileName = "untitled.swift"
                        showingNewFile = true
                    } label: {
                        Label("New File", systemImage: "doc.badge.plus")
                    }
                    Button {
                        showingFolderPicker = true
                    } label: {
                        Label("Open Folder…", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        showingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gear")
                    }
                    Button {
                        showingWorkbench = true
                    } label: {
                        Label("VS Code Mode", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView() }
        .sheet(isPresented: $showingFolderPicker) {
            FolderPicker { url in
                url.startAccessingSecurityScopedResource()
                app.switchWorkspace(to: url)
            }
        }
        .fullScreenCover(isPresented: $showingWorkbench) {
            WorkbenchSheet()
        }
        .alert("New File", isPresented: $showingNewFile) {
            TextField("Name", text: $newFileName)
            Button("Create") {
                if let url = try? FileService.createFile(in: directory, named: newFileName) {
                    reload()
                    app.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear(perform: reload)
    }

    private func row(_ entry: FileEntry, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                if !entry.isDirectory && !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    private func reload() {
        entries = FileService.list(directory, showHidden: app.showHiddenFiles)
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            try? FileManager.default.removeItem(at: filtered[index].url)
        }
        reload()
    }
}

struct EditorScreen: View {
    @EnvironmentObject private var app: AppModel
    let url: URL

    var body: some View {
        Group {
            if let tab = app.tabs.first(where: { $0.url == url }) {
                EditorContent(tab: tab,
                              fontSize: app.fontSize,
                              wrapLines: app.wrapLines,
                              highlighting: app.highlighting,
                              isDark: app.colorScheme != .light,
                              tabs: app.tabs,
                              activeID: app.activeTabID,
                              onSelect: { app.activeTabID = $0 },
                              onClose: { app.close($0) })
            } else {
                ProgressView()
            }
        }
        .onAppear { app.open(url) }
    }
}

/// Observable on the tab itself: text and dirty state live in EditorTab, so the
/// view must observe it or the save button never updates while you type.
struct EditorContent: View {
    @ObservedObject var tab: EditorTab
    var fontSize: Double
    var wrapLines: Bool
    var highlighting: Bool
    var isDark: Bool
    var tabs: [EditorTab]
    var activeID: UUID?
    var onSelect: (UUID) -> Void
    var onClose: (EditorTab) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if tabs.count > 1 {
                tabStrip
                Divider()
            }

            CodeTextView(text: Binding(get: { tab.text }, set: { tab.text = $0 }),
                         language: tab.language,
                         fontSize: fontSize,
                         wrapLines: wrapLines,
                         highlighting: highlighting,
                         isDark: isDark)
                .background(Color(uiColor: .systemBackground))

            if let error = tab.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.red.opacity(0.85))
            }
        }
        .navigationTitle(tab.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    tab.save()
                } label: {
                    Text(tab.isDirty ? "Save" : "Saved")
                        .font(.footnote.weight(.semibold))
                }
                .disabled(!tab.isDirty)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Text(tab.language.displayName)
                    Button("Revert changes") { tab.revert() }
                    Button("Close file") { onClose(tab) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
    }

    private var tabStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tabs) { other in
                    Button {
                        onSelect(other.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text(other.name)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                            if other.isDirty {
                                Circle().fill(.orange).frame(width: 5, height: 5)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            other.id == activeID
                                ? Color.accentColor.opacity(0.22)
                                : Color(uiColor: .secondarySystemBackground),
                            in: Capsule()
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(uiColor: .systemBackground))
    }
}

struct FolderPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
        }
    }
}

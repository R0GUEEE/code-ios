import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Editor") {
                    HStack {
                        Text("Font size")
                        Spacer()
                        Text("\(Int(app.fontSize)) pt").foregroundStyle(.secondary)
                    }
                    Slider(value: $app.fontSize, in: 10...22, step: 1)

                    Toggle("Wrap long lines", isOn: $app.wrapLines)
                    Toggle("Syntax highlighting", isOn: $app.highlighting)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $app.themeRaw) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                }

                Section("Files") {
                    Toggle("Show hidden files", isOn: $app.showHiddenFiles)
                    LabeledContent("Workspace", value: app.workspace.lastPathComponent)
                    Button {
                        UIPasteboard.general.string = app.workspace.path
                    } label: {
                        Label("Copy workspace path", systemImage: "doc.on.doc")
                    }
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    LabeledContent("Engine", value: "Native SwiftUI + VS Code web workbench")
                    LabeledContent("Files", value: "\(app.tabs.count) open")
                }

                Section {
                    Button(role: .destructive) {
                        app.closeAll()
                    } label: {
                        Label("Close all files", systemImage: "xmark.circle")
                    }
                    .disabled(app.tabs.isEmpty)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }
}

/// The VS Code workbench, presented over the native app. Kept as its own mode
/// because the extension host and marketplace only exist inside it.
struct WorkbenchSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(.tint)
                Text("VS Code")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            ContentView()
        }
    }
}

struct RootView: View {
    @StateObject private var app = AppModel()

    var body: some View {
        NavigationStack {
            BrowserView(directory: app.workspace)
                .id(app.workspace)
                .navigationDestination(for: URL.self) { url in
                    let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    if isDirectory {
                        BrowserView(directory: url)
                    } else {
                        EditorScreen(url: url)
                    }
                }
        }
        .environmentObject(app)
        .preferredColorScheme(app.colorScheme)
    }
}

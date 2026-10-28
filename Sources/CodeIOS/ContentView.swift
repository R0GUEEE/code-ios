import SwiftUI
import UIKit
import WebKit

@MainActor
final class HostModel: ObservableObject {
    @Published var url: URL?
    @Published var failure: String?
    @Published var detail: String = "starting local server…"

    private var host: WebHost?

    var workspacePath: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent("Workspace", isDirectory: true).path
    }

    func startIfNeeded() {
        guard host == nil, url == nil else { return }
        Diagnostics.append("host: init begin")
        do {
            let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            seedSampleIfEmpty(workspace)
            Diagnostics.append("host: workspace ready at \(workspace.path)")

            let assets = try AssetInstaller.prepare()
            Diagnostics.append("host: assets at \(assets.web.path)")
            let host = try WebHost(workspaceURL: workspace,
                                   webRoot: assets.web,
                                   extRoot: assets.extensions)
            Diagnostics.append("host: constructed")
            let base = try host.start()
            Diagnostics.append("host: listening on \(base.absoluteString)")

            self.host = host
            self.url = base
            self.detail = base.absoluteString
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            Diagnostics.append("host: FAILED — \(message)")
            self.failure = message
            self.detail = "host failed to start"
        }
    }

    func restart() {
        Diagnostics.append("host: restart requested")
        host?.stop()
        host = nil
        url = nil
        failure = nil
        detail = "restarting…"
        startIfNeeded()
    }

    private func seedSampleIfEmpty(_ workspace: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: workspace.path)) ?? []
        guard contents.isEmpty else { return }
        let readme = """
        # Hello from VS Code on iOS

        This folder lives in the app's Documents directory. It is served to the
        workbench through the `iosfs://` FileSystemProvider, so anything you save
        here is a real file on the device.

        - Files app → On My iPhone → VS Code → Workspace
        - Marketplace is Open VSX (`open-vsx.org`)
        """
        try? readme.write(to: workspace.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        let sample = """
        def greet(name: str) -> str:
            return f"hello {name}"


        if __name__ == "__main__":
            print(greet("iOS"))

        """
        try? sample.write(to: workspace.appendingPathComponent("hello.py"), atomically: true, encoding: .utf8)
    }
}

struct ContentView: View {
    @StateObject private var model = HostModel()
    @State private var reloadToken = 0
    @State private var showMenu = false
    @State private var showDiagnostics = false
    @State private var diagnosticsText = ""
    @State private var bootChecked = false

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if showDiagnostics {
                DiagnosticsView(text: diagnosticsText,
                                onRetry: {
                                    Diagnostics.clearDiagnostics()
                                    showDiagnostics = false
                                    model.restart()
                                },
                                onDismiss: {
                                    showDiagnostics = false
                                    model.startIfNeeded()
                                })
            } else if let url = model.url {
                WorkbenchWebView(url: url, reloadToken: reloadToken, onLoaded: {
                    Diagnostics.markBootCompleted("webview did finish")
                })
                .ignoresSafeArea(edges: [.bottom, .horizontal])
            } else if let failure = model.failure {
                DiagnosticsView(text: "\(failure)\n\n\(Diagnostics.log())",
                                onRetry: { model.restart() },
                                onDismiss: nil)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.detail).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }

            if model.url != nil && !showDiagnostics {
                HStack(spacing: 10) {
                    Spacer()
                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise").padding(8)
                    }
                    Button {
                        showMenu = true
                    } label: {
                        Image(systemName: "ellipsis.circle").padding(8)
                    }
                }
                .padding(.trailing, 6)
                .padding(.top, 2)
                .confirmationDialog("Workspace", isPresented: $showMenu, titleVisibility: .visible) {
                    Button("Copy workspace path") {
                        UIPasteboard.general.string = model.workspacePath
                    }
                    Button("Show diagnostics") {
                        diagnosticsText = Diagnostics.log()
                        showDiagnostics = true
                    }
                    Button("Restart workbench", role: .destructive) { model.restart() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(model.workspacePath)
                }
            }
        }
        .task {
            guard !bootChecked else { return }
            bootChecked = true

            Diagnostics.beginLaunch()
            if Diagnostics.previousLaunchCrashed {
                // The last run died between arming the marker and the page loading.
                Diagnostics.append("boot: previous launch crashed — entering diagnostics")
                diagnosticsText = Diagnostics.log()
                showDiagnostics = true
                return
            }
            model.startIfNeeded()
        }
    }
}

struct DiagnosticsView: View {
    let text: String
    let onRetry: () -> Void
    let onDismiss: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text("Startup diagnostics").font(.headline)
            }
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            .padding(8)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 10) {
                Button("Copy") { UIPasteboard.general.string = text }
                    .buttonStyle(.bordered)
                Button("Retry") { onRetry() }
                    .buttonStyle(.borderedProminent)
                if let onDismiss = onDismiss {
                    Button("Continue anyway") { onDismiss() }
                        .buttonStyle(.bordered)
                }
            }
            Text("Documents/launch.log holds the full trail.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .foregroundStyle(.white)
    }
}

struct WorkbenchWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int
    let onLoaded: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        Diagnostics.append("webview: create")
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.allowsBackForwardNavigationGestures = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        context.coordinator.lastToken = reloadToken
        Diagnostics.append("webview: load \(url.absoluteString)")
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            Diagnostics.append("webview: reload")
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLoaded: onLoaded)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastToken = -1
        private let onLoaded: () -> Void

        init(onLoaded: @escaping () -> Void) {
            self.onLoaded = onLoaded
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Diagnostics.append("webview: didFinish")
            onLoaded()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Diagnostics.append("webview: didFail — \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Diagnostics.append("webview: didFailProvisional — \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            Diagnostics.append("webview: content process terminated (jetsam?)")
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(.allow)
        }
    }
}

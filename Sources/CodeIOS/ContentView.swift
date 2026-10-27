import SwiftUI
import WebKit

@MainActor
final class HostModel: ObservableObject {
    @Published var url: URL?
    @Published var failure: String?
    @Published var detail: String = "starting local server…"

    private var host: WebHost?

    var workspacePath: String {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documents.appendingPathComponent("Workspace", isDirectory: true).path
    }

    func startIfNeeded() {
        guard host == nil, url == nil else { return }
        do {
            let workspace = URL(fileURLWithPath: workspacePath, isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            seedSampleIfEmpty(workspace)

            let host = try WebHost(workspaceURL: workspace)
            let base = try host.start()
            self.host = host
            self.url = base
            self.detail = base.absoluteString
        } catch {
            self.failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            self.detail = "host failed to start"
        }
    }

    func restart() {
        host?.stop()
        host = nil
        url = nil
        failure = nil
        detail = "restarting…"
        startIfNeeded()
    }

    /// A couple of sample files so the first launch isn't an empty box.
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

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let url = model.url {
                WorkbenchWebView(url: url, reloadToken: reloadToken)
                    .ignoresSafeArea(edges: [.bottom, .horizontal])
            } else if let failure = model.failure {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 40))
                    Text("Could not start the workbench").font(.headline)
                    Text(failure)
                        .font(.footnote.monospaced())
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    Button("Try again") { model.restart() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(model.detail).font(.footnote.monospaced()).foregroundStyle(.secondary)
                }
                .foregroundStyle(.white)
            }

            if model.url != nil {
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
                .background(.ultraThinMaterial.opacity(0.001))
                .confirmationDialog("Workspace", isPresented: $showMenu, titleVisibility: .visible) {
                    Button("Copy workspace path") {
                        UIPasteboard.general.string = model.workspacePath
                    }
                    Button("Open Files app") {
                        if let url = URL(string: "shareddocuments://") {
                            UIApplication.shared.open(url)
                        }
                    }
                    Button("Restart workbench", role: .destructive) { model.restart() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(model.workspacePath)
                }
            }
        }
        .task { model.startIfNeeded() }
    }
}

struct WorkbenchWebView: UIViewRepresentable {
    let url: URL
    let reloadToken: Int

    func makeUIView(context: Context) -> WKWebView {
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
        webView.customUserAgent = nil

        context.coordinator.lastToken = reloadToken
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastToken != reloadToken {
            context.coordinator.lastToken = reloadToken
            webView.reload()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastToken = -1

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            NSLog("codeios: page loaded")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            NSLog("codeios: navigation failed \(error)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            NSLog("codeios: provisional navigation failed \(error)")
        }
    }
}

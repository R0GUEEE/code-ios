import SwiftUI

/// Deliberately trivial: no WebKit, no Network, no file IO beyond the container.
/// Its only job is to answer one question — does an app built and signed by this
/// pipeline launch on this device at all?
@main
struct ProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

struct ProbeView: View {
    private let info: [(String, String)] = {
        let bundle = Bundle.main
        let version = UIDevice.current.systemVersion
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        var writable = "no container"
        if let documents = documents {
            let probe = documents.appendingPathComponent("probe.txt")
            let ok = (try? "probe \(Date())\n".write(to: probe, atomically: true, encoding: .utf8)) != nil
            writable = ok ? "writable (\(documents.lastPathComponent))" : "NOT writable"
        }
        return [
            ("iOS", version),
            ("Device", UIDevice.current.model),
            ("Bundle", bundle.bundleIdentifier ?? "-"),
            ("Version", (bundle.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "-"),
            ("Executable", bundle.infoDictionary?["CFBundleExecutable"] as? String ?? "-"),
            ("Documents", writable),
            ("Built", "\(__DATE__) \(__TIME__)")
        ]
    }()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    Text("Probe launched").font(.title2.bold())
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(info, id: \.0) { key, value in
                        HStack(alignment: .top) {
                            Text(key).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                            Text(value).textSelection(.enabled)
                        }
                        .font(.system(size: 13, design: .monospaced))
                    }
                }
                Text("If you can read this, the build pipeline and signing are fine —\nthe fault is in the main app's startup code.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .foregroundStyle(.white)
        }
    }
}

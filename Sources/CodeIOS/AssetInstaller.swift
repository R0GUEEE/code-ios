import Foundation
import ZIPFoundation

/// The workbench is ~720 files. Shipping them loose makes installs slow and fragile —
/// a sideloader that writes them in parallel can drop one (in our case the Info.plist
/// read failed right after a 726-file upload). So the bundle carries a single
/// `Web.zip` and it is unpacked once into Application Support.
enum AssetInstaller {
    static func prepare() throws -> (web: URL, extensions: URL) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let root = support.appendingPathComponent("Workbench", isDirectory: true)
        let web = root.appendingPathComponent("Web", isDirectory: true)
        let extensions = root.appendingPathComponent("Extensions", isDirectory: true)
        let marker = root.appendingPathComponent(".assets-version")

        let build = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
        let tag = build + "-1"

        let workbench = web.appendingPathComponent(WebHost.workbenchPath)
        if (try? String(contentsOf: marker, encoding: .utf8)) == tag,
           FileManager.default.fileExists(atPath: workbench.path) {
            Diagnostics.append("assets: reused \(root.path)")
            return (web, extensions)
        }

        guard let zip = findZip("Web") else {
            throw HostError("Web.zip is missing from the bundle (looked in "
                            + "bundle root, Resources/ and resourceURL)")
        }

        Diagnostics.append("assets: unpacking \(zip.lastPathComponent) → \(root.path)")
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let started = Date()
        try FileManager.default.unzipItem(at: zip, to: root)
        try? tag.write(to: marker, atomically: true, encoding: .utf8)

        guard FileManager.default.fileExists(atPath: workbench.path) else {
            throw HostError("Web.zip unpacked without \(WebHost.workbenchPath)")
        }
        let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
        Diagnostics.append("assets: unpacked in \(seconds)s")
        return (web, extensions)
    }

    /// Folder references land in `<app>/Resources/`, not the bundle root.
    private static func findZip(_ name: String) -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("\(name).zip"))
            candidates.append(resources.appendingPathComponent("Resources/\(name).zip"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("\(name).zip"))
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Resources/\(name).zip"))
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}

import SwiftUI

@main
struct CodeIOSApp: App {
    init() {
        // Earliest thing that runs: arm the watchdog and the crash handlers, so a
        // death anywhere after this point leaves a trail in Documents/launch.log.
        Diagnostics.beginLaunch()
        Diagnostics.append("app: init")
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .statusBarHidden(false)
        }
    }
}

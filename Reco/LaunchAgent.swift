import AppKit
import ServiceManagement

/// Runs Reco as a launchd agent so the app relaunches automatically after a
/// crash or a watchdog kill. A normal quit exits cleanly and stays quit.
enum LaunchAgent {
    private static var plistName: String {
        "\(Bundle.main.bundleIdentifier ?? "llc.wvlen.Reco").plist"
    }

    private static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    static var isEnabled: Bool {
        service.status == .enabled
    }

    /// Earlier releases registered a plain login item, which launchd does not
    /// relaunch after a crash. Move that registration to the agent.
    static func migrateFromLoginItem() {
        guard SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        try? service.register()
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            // launchd may start its own instance right away; that instance
            // terminates this one and takes over.
            try service.register()
        } else {
            // Unregistering tears down the launchd-owned process, which may be
            // this one. Hand the session to a fresh instance first so the app
            // survives the toggle, and clear the crash marker so the handoff
            // is not reported as a crash.
            UncleanExitSentinel.endSession()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(
                at: Bundle.main.bundleURL,
                configuration: configuration
            )
            try service.unregister()
        }
    }
}

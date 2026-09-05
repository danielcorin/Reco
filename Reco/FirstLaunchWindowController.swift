import AppKit
import SwiftUI

@MainActor
final class FirstLaunchWindowController: NSWindowController, NSWindowDelegate {
    static let completionKey = "hasCompletedFirstLaunch"

    private let coordinator: DictationCoordinator

    init(coordinator: DictationCoordinator) {
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 560, height: 500)),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Reco"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()

        super.init(window: window)
        window.delegate = self

        window.contentView = NSHostingView(
            rootView: FirstLaunchView(
                coordinator: coordinator,
                onFinish: { [weak self] in
                    self?.finish()
                }
            )
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    static var shouldPresentAutomatically: Bool {
        !UserDefaults.standard.bool(forKey: completionKey)
    }

    func present() {
        if window?.isVisible != true {
            coordinator.startPermissionPolling()
        }
        showWindow(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        coordinator.stopPermissionPolling()
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: Self.completionKey)
        close()
    }
}

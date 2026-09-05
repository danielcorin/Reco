//
//  RecoApp.swift
//  Reco
//
//  Created by Daniel Corin on 7/10/26.
//

import RecoCore
import SwiftUI

@main
struct RecoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = RecoAppModel.shared

    var body: some Scene {
        MenuBarExtra(isInserted: showMenuBarIconBinding) {
            MenuContentView(
                coordinator: model.coordinator,
                showMenuBarIcon: showMenuBarIconBinding,
                configurationError: model.configurationError,
                onShowSetup: appDelegate.showSetup
            )
        } label: {
            MenuBarLabel(coordinator: model.coordinator)
        }
        .menuBarExtraStyle(.window)
    }

    private var showMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { model.configuration.showMenuBarIcon },
            set: { model.setShowMenuBarIcon($0) }
        )
    }
}

private struct MenuBarLabel: View {
    @ObservedObject var coordinator: DictationCoordinator

    var body: some View {
        Image(systemName: coordinator.menuBarSymbol)
            .accessibilityLabel("Reco")
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = RecoAppModel.shared
    private var firstLaunchWindowController: FirstLaunchWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        if FirstLaunchWindowController.shouldPresentAutomatically {
            showSetup()
        }
    }

    func showSetup() {
        let controller =
            firstLaunchWindowController
            ?? FirstLaunchWindowController(coordinator: model.coordinator)
        firstLaunchWindowController = controller
        controller.present()
    }

    // Launching Reco while it's already running restores a hidden menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        model.setShowMenuBarIcon(true)
        if FirstLaunchWindowController.shouldPresentAutomatically {
            showSetup()
        }
        return false
    }
}

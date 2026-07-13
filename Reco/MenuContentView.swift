import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                Circle()
                    .fill(coordinator.statusColor)
                    .frame(width: 8, height: 8)

                Text(coordinator.statusText)
                    .font(.system(size: 13, weight: .medium))

                Spacer(minLength: 12)
            }

            if coordinator.state == .loadingModel {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: coordinator.modelLoadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.orange)

                    HStack {
                        Text(coordinator.modelLoadDetail)
                        Spacer()
                        Text(coordinator.modelLoadProgress, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Text("Shortcut")
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    coordinator.beginShortcutCapture()
                } label: {
                    Text(coordinator.isCapturingShortcut ? "Press shortcut…" : coordinator.hotkey.displayName)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Text("Hold to record. Double-tap to keep recording; press once to stop.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            HStack {
                Text("Start at login")
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("Start at login", isOn: launchAtLoginBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            HStack {
                Text("Hide menu bar icon")
                    .foregroundStyle(.secondary)

                Spacer()

                Toggle("Hide menu bar icon", isOn: hideMenuBarIconBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            Text("The shortcut keeps working while hidden. Open Reco again to bring the icon back.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if coordinator.needsPermissions {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Reco needs microphone and input access to listen for the shortcut and paste text.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Button("Allow Access") {
                        coordinator.requestPermissions()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            if let error = coordinator.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Text("NVIDIA Parakeet v3 · On-device")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
            }
        }
        .padding(16)
        .frame(width: 290)
        .onAppear {
            coordinator.refreshPermissions()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .task {
            while !Task.isCancelled {
                coordinator.refreshPermissions()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLogin },
            set: { enabled in
                launchAtLogin = enabled
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }
        )
    }

    private var hideMenuBarIconBinding: Binding<Bool> {
        Binding(
            get: { !showMenuBarIcon },
            set: { showMenuBarIcon = !$0 }
        )
    }
}

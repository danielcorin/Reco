import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @Binding var showMenuBarIcon: Bool
    let configurationError: String?
    let onShowSetup: () -> Void
    @State private var launchAtLogin = false
    @State private var cliInstallResult: String?

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

            if let error = coordinator.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if case .failed = coordinator.modelPreparationState {
                Button("Retry Model Download") {
                    coordinator.retryModelPreparation()
                }
                .controlSize(.small)
            }

            if let configurationError {
                Text(configurationError)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            menuSection("Recording") {
                HStack {
                    Text("Shortcut")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button {
                        coordinator.beginShortcutCapture()
                    } label: {
                        Text(
                            coordinator.isCapturingShortcut
                                ? "Press shortcut…" : coordinator.hotkey.displayName
                        )
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .frame(minWidth: 72)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!coordinator.canChangeShortcut)
                    .help("Press a key with Control, Option, Shift, or Command. Escape cancels.")
                }

                Text(
                    coordinator.isCapturingShortcut
                        ? "Press a key with a modifier. Escape cancels."
                        : "Hold to record. Double-tap to keep recording; press once to stop."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if coordinator.lastTranscription != nil {
                    HStack {
                        Text("Last transcription")
                            .foregroundStyle(.secondary)

                        Spacer()

                        Button("Copy") {
                            coordinator.copyLastTranscription()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Divider()

            menuSection("Audio") {
                HStack {
                    Text("System audio")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Toggle("System audio", isOn: systemAudioBinding)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .disabled(
                            coordinator.capturesSystemAudio
                                && !coordinator.capturesMicrophone
                        )
                }

                HStack {
                    Text("Microphone")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Picker("Microphone", selection: microphoneBinding) {
                        Text(coordinator.automaticMicrophoneName)
                            .tag(DictationCoordinator.MicrophoneSelection.automatic)

                        ForEach(coordinator.availableMicrophones) { device in
                            Text(device.name)
                                .tag(DictationCoordinator.MicrophoneSelection.device(device.id))
                        }

                        Text("Off")
                            .tag(DictationCoordinator.MicrophoneSelection.off)
                            .disabled(!coordinator.capturesSystemAudio)
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .frame(maxWidth: 180)
                }

                Text(
                    "Connected microphones refresh automatically. Changes apply to the next recording."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.needsPermissions {
                Divider()

                menuSection("Permissions") {
                    Text("Grant the access required by the selected audio sources.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(coordinator.requiredPermissions) { permission in
                        permissionRow(permission)
                    }
                }
            }

            Divider()

            menuSection("App") {
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

                Text(
                    "The shortcut keeps working while hidden. Open Reco again to bring the icon back."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Setup assistant")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("Open…") {
                        onShowSetup()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                HStack {
                    Text("Command line")
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(CLIInstaller.isInstalled ? "Installed" : "Install…") {
                        installCLI()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(CLIInstaller.isInstalled)
                }

                if let cliInstallResult {
                    Text(cliInstallResult)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            Divider()

            HStack {
                Text("NVIDIA Parakeet v3 · On-device")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)

                Spacer()

                Button("About Reco") {
                    showAboutPanel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))

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
            coordinator.startPermissionPolling()
            let currentLaunchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin != currentLaunchAtLogin {
                launchAtLogin = currentLaunchAtLogin
            }
            if cliInstallResult != nil {
                cliInstallResult = nil
            }
        }
        .onDisappear {
            coordinator.stopPermissionPolling()
            coordinator.cancelShortcutCapture()
        }
    }

    private func menuSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)

            content()
        }
    }

    @ViewBuilder
    private func permissionRow(_ permission: DictationCoordinator.Permission) -> some View {
        let granted = coordinator.isGranted(permission)
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(granted ? Color.green : Color.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text(permission.displayName)
                    .font(.system(size: 12, weight: .medium))
                Text(permission.purpose)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Grant…") {
                    coordinator.requestPermission(permission)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
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

    private var systemAudioBinding: Binding<Bool> {
        Binding(
            get: { coordinator.capturesSystemAudio },
            set: { coordinator.setSystemAudioEnabled($0) }
        )
    }

    private var microphoneBinding: Binding<DictationCoordinator.MicrophoneSelection> {
        Binding(
            get: { coordinator.microphoneSelection },
            set: { coordinator.selectMicrophone($0) }
        )
    }

    private func showAboutPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private func installCLI() {
        do {
            let destination = try CLIInstaller.install()
            cliInstallResult = "Installed at \(destination.path)"
        } catch {
            cliInstallResult = error.localizedDescription
        }
    }
}

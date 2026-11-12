import SwiftUI

struct FirstLaunchView: View {
    private enum Step {
        case permissions
        case model
    }

    @ObservedObject var coordinator: DictationCoordinator
    let onFinish: () -> Void

    @State private var step: Step = .permissions

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                switch step {
                case .permissions:
                    permissionsStep
                case .model:
                    modelStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 500)
        .background(.background)
        .onAppear {
            step = permissionsComplete ? .model : .permissions
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 3) {
                Text("Welcome to Reco")
                    .font(RecoStyle.Font.windowTitle)

                Text("Private, on-device transcription from your menu bar")
                    .font(RecoStyle.Font.body)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(step == .permissions ? "1 of 2" : "2 of 2")
                .font(RecoStyle.Font.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.secondary.opacity(0.1), in: Capsule())
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Allow access")
                    .font(RecoStyle.Font.stepTitle)

                Text("Reco only uses these permissions while you dictate, and your audio stays on this Mac.")
                    .font(RecoStyle.Font.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(coordinator.requiredPermissions.enumerated()), id: \.element.id) {
                    index, permission in
                    permissionRow(permission)

                    if index < coordinator.requiredPermissions.count - 1 {
                        Divider()
                            .padding(.leading, 47)
                    }
                }
            }
            .background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.secondary.opacity(0.14), lineWidth: 1)
            )

            Spacer()

            HStack {
                Text(permissionsComplete ? "All permissions are ready." : "Grant each permission to continue.")
                    .font(RecoStyle.Font.detail)
                    .foregroundStyle(permissionsComplete ? Color.green : Color.secondary)

                Spacer()

                Button("Continue") {
                    step = .model
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!permissionsComplete)
            }
        }
        .padding(28)
    }

    private var modelStep: some View {
        VStack(spacing: 22) {
            Spacer()

            modelStatusSymbol

            VStack(spacing: 6) {
                Text(modelTitle)
                    .font(RecoStyle.Font.stepTitle)

                Text(modelDescription)
                    .font(RecoStyle.Font.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 390)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if coordinator.modelPreparationState == .loading {
                VStack(spacing: 7) {
                    ProgressView(value: coordinator.modelLoadProgress, total: 1)
                        .progressViewStyle(.linear)
                        .tint(.accentColor)

                    HStack {
                        Text(coordinator.modelLoadDetail)
                        Spacer()
                        Text(
                            coordinator.modelLoadProgress,
                            format: .percent.precision(.fractionLength(0))
                        )
                    }
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 390)
            }

            Text("NVIDIA Parakeet v3 · Downloaded once · Runs entirely on-device")
                .font(RecoStyle.Font.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            HStack {
                Button("Back") {
                    step = .permissions
                }
                .controlSize(.large)

                Spacer()

                if case .failed = coordinator.modelPreparationState {
                    Button("Try Again") {
                        coordinator.retryModelPreparation()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button("Start Using Reco") {
                        onFinish()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        coordinator.modelPreparationState != .ready
                            || !permissionsComplete
                    )
                }
            }
        }
        .padding(28)
    }

    @ViewBuilder
    private func permissionRow(_ permission: DictationCoordinator.Permission) -> some View {
        let granted = coordinator.isGranted(permission)

        HStack(spacing: 13) {
            Image(systemName: symbol(for: permission))
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(granted ? Color.green : Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(permission.displayName)
                    .font(RecoStyle.Font.bodyEmphasized)
                Text(permission.purpose)
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(RecoStyle.Font.captionEmphasized)
                    .foregroundStyle(.green)
            } else {
                Button("Allow…") {
                    coordinator.requestPermission(permission)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 62)
    }

    @ViewBuilder
    private var modelStatusSymbol: some View {
        switch coordinator.modelPreparationState {
        case .loading:
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor)
                .symbolEffect(.pulse)
        case .ready:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 46))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(.orange)
        }
    }

    private var permissionsComplete: Bool {
        coordinator.requiredPermissions.allSatisfy(coordinator.isGranted)
    }

    private var modelTitle: String {
        switch coordinator.modelPreparationState {
        case .loading:
            "Preparing on-device transcription"
        case .ready:
            "Reco is ready"
        case .failed:
            "The model couldn’t be prepared"
        }
    }

    private var modelDescription: String {
        switch coordinator.modelPreparationState {
        case .loading:
            "Reco is downloading and preparing its speech model. The first setup can take a few minutes."
        case .ready:
            "Hold \(coordinator.hotkey.displayName) to dictate. Release the shortcut and Reco will insert the transcription into the active app."
        case .failed(let message):
            message
        }
    }

    private func symbol(for permission: DictationCoordinator.Permission) -> String {
        switch permission {
        case .microphone:
            "mic.fill"
        case .systemAudio:
            "speaker.wave.2.fill"
        case .accessibility:
            "text.cursor"
        }
    }
}

import RecoCore
import ServiceManagement
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var coordinator: DictationCoordinator
    @ObservedObject var usage: UsageTracker
    @ObservedObject var vocabulary: PersonalVocabulary
    @Binding var showMenuBarIcon: Bool
    let configurationError: String?
    let onShowSetup: () -> Void
    @State private var launchAtLogin = false
    @State private var cliInstalled = CLIInstaller.isInstalled
    @State private var copiedLastTranscription = false
    @State private var copyResetTask: Task<Void, Never>?

    private static let idleHint = "Hold to dictate. Double-tap to lock, press again to stop."
    private static let captureHint = "Press a key with Control, Option, Shift, or Command. Esc cancels."

    var body: some View {
        VStack(alignment: .leading, spacing: RecoStyle.sectionSpacing) {
            header

            if hasAttentionItems {
                attentionCallouts
            }

            if let lastTranscription = coordinator.lastTranscription {
                Divider()
                lastTranscriptionSection(lastTranscription)
            }

            Divider()
            inputSection

            Divider()
            vocabularySection

            Divider()
            VStack(alignment: .leading, spacing: RecoStyle.rowSpacing) {
                MenuSectionHeader(title: "Usage")
                UsageStatsSection(stats: usage.stats)
            }

            Divider()
            footer
        }
        .font(RecoStyle.Font.body)
        .padding(RecoStyle.menuPadding)
        .frame(width: RecoStyle.menuWidth)
        .background {
            // ⌘Q quits from the open panel, like any other Mac app.
            Button("Quit Reco") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .hidden()
        }
        .onAppear {
            coordinator.startPermissionPolling()
            usage.refresh()
            vocabulary.reload()
            let currentLaunchAtLogin = SMAppService.mainApp.status == .enabled
            if launchAtLogin != currentLaunchAtLogin {
                launchAtLogin = currentLaunchAtLogin
            }
            let installed = CLIInstaller.isInstalled
            if cliInstalled != installed {
                cliInstalled = installed
            }
        }
        .onDisappear {
            coordinator.stopPermissionPolling()
            coordinator.cancelShortcutCapture()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(coordinator.statusColor)
                    .frame(width: 7, height: 7)

                Text(coordinator.statusText)
                    .font(RecoStyle.Font.title)

                Spacer(minLength: 12)

                shortcutButton
            }

            // Both hints occupy the same space, so starting or cancelling a
            // shortcut change never moves the rest of the menu.
            ZStack(alignment: .topLeading) {
                hintText(Self.idleHint)
                    .opacity(coordinator.isCapturingShortcut ? 0 : 1)
                hintText(Self.captureHint)
                    .opacity(coordinator.isCapturingShortcut ? 1 : 0)
            }

            if coordinator.state == .loadingModel {
                VStack(alignment: .leading, spacing: 5) {
                    ProgressView(value: coordinator.modelLoadProgress, total: 1)
                        .progressViewStyle(.linear)

                    HStack {
                        Text(coordinator.modelLoadDetail)
                        Spacer()
                        Text(
                            coordinator.modelLoadProgress,
                            format: .percent.precision(.fractionLength(0))
                        )
                        .monospacedDigit()
                    }
                    .font(RecoStyle.Font.footnote)
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var shortcutButton: some View {
        Button {
            coordinator.beginShortcutCapture()
        } label: {
            // Reserve the wider of the two labels so the button keeps its size.
            ZStack {
                Text("Press Keys…").hidden()
                Text(coordinator.hotkey.displayName).hidden()
                Text(coordinator.isCapturingShortcut ? "Press Keys…" : coordinator.hotkey.displayName)
            }
            .font(RecoStyle.Font.shortcut)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(!coordinator.canChangeShortcut)
        .help("Click to choose a new shortcut")
    }

    private func hintText(_ text: String) -> some View {
        Text(text)
            .font(RecoStyle.Font.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Needs attention

    private var missingPermissions: [DictationCoordinator.Permission] {
        guard coordinator.needsPermissions else { return [] }
        return coordinator.requiredPermissions.filter { !coordinator.isGranted($0) }
    }

    private var modelFailed: Bool {
        if case .failed = coordinator.modelPreparationState { return true }
        return false
    }

    private var hasAttentionItems: Bool {
        !missingPermissions.isEmpty
            || coordinator.visibleErrorMessage != nil
            || configurationError != nil
            || vocabulary.loadError != nil
    }

    private var attentionCallouts: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !missingPermissions.isEmpty {
                AttentionCallout(
                    symbol: "lock.shield",
                    title: "Allow access to dictate"
                ) {
                    ForEach(missingPermissions) { permission in
                        permissionRow(permission)
                    }
                }
            }

            if let error = coordinator.visibleErrorMessage {
                AttentionCallout(symbol: "exclamationmark.triangle.fill", title: error) {
                    if modelFailed {
                        HStack {
                            Spacer()
                            Button("Retry Download") {
                                coordinator.retryModelPreparation()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            if let configurationError {
                AttentionCallout(symbol: "exclamationmark.triangle.fill", title: configurationError) {
                    EmptyView()
                }
            }

            if let vocabularyError = vocabulary.loadError {
                AttentionCallout(symbol: "exclamationmark.triangle.fill", title: vocabularyError) {
                    HStack {
                        Spacer()
                        Button("Edit Vocabulary") { editVocabulary() }
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    private func permissionRow(_ permission: DictationCoordinator.Permission) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(permission.displayName)
                    .font(RecoStyle.Font.detailEmphasized)
                Text(permission.purpose)
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button("Allow…") {
                coordinator.requestPermission(permission)
            }
            .controlSize(.small)
        }
    }

    // MARK: Last transcription

    private func lastTranscriptionSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MenuSectionHeader(title: "Last Transcription")
                Spacer()
                Button {
                    copyLastTranscription()
                } label: {
                    // Reserve room for "Copied" so the swap doesn't shift anything.
                    ZStack(alignment: .trailing) {
                        Label("Copied", systemImage: "checkmark").hidden()
                        Label(
                            copiedLastTranscription ? "Copied" : "Copy",
                            systemImage: copiedLastTranscription ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .font(RecoStyle.Font.caption)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Text(text)
                .font(RecoStyle.Font.detail)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(text)
                .contextMenu {
                    Button("Copy") { copyLastTranscription() }
                }
        }
    }

    private func copyLastTranscription() {
        coordinator.copyLastTranscription()
        copiedLastTranscription = true
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedLastTranscription = false
        }
    }

    // MARK: Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: RecoStyle.rowSpacing) {
            MenuSectionHeader(title: "Input")

            MenuRow(title: "Microphone") {
                Menu {
                    Picker("Microphone", selection: microphoneBinding) {
                        Text(automaticMicrophoneTitle)
                            .tag(DictationCoordinator.MicrophoneSelection.automatic)

                        ForEach(coordinator.availableMicrophones) { device in
                            Text(device.name)
                                .tag(DictationCoordinator.MicrophoneSelection.device(device.id))
                        }

                        Text("Off")
                            .tag(DictationCoordinator.MicrophoneSelection.off)
                            .disabled(!coordinator.capturesSystemAudio)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } label: {
                    Text(coordinator.selectedMicrophoneName)
                        .truncationMode(.middle)
                }
                .controlSize(.small)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: 190, alignment: .trailing)
                .help("Changes apply to the next recording.")
            }

            MenuRow(title: "System audio") {
                Toggle("System audio", isOn: systemAudioBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(coordinator.capturesSystemAudio && !coordinator.capturesMicrophone)
                    .help("Also record what’s playing on this Mac.")
            }
        }
    }

    private var automaticMicrophoneTitle: String {
        coordinator.automaticMicrophoneDeviceName.map { "Automatic (\($0))" } ?? "Automatic"
    }

    // MARK: Vocabulary

    private var vocabularySection: some View {
        VocabularySection(
            rows: vocabulary.recentFixes.map { fix in
                VocabularyFixRow(
                    id: fix.id,
                    heard: fix.correction.heard,
                    corrected: fix.correction.corrected,
                    label: Self.label(for: fix.kind),
                    isRemoved: fix.kind == .forgotten,
                    canStopFixing: vocabulary.canRemoveRule(for: fix)
                )
            },
            wordCount: vocabulary.vocabulary.terms.count,
            unavailableReason: {
                if case .failed(let reason) = coordinator.boostStatus { return reason }
                return nil
            }(),
            onTeach: teachWord,
            onEdit: editVocabulary,
            onStopFixing: { id in
                guard let fix = vocabulary.recentFixes.first(where: { $0.id == id }) else { return }
                vocabulary.removeRule(for: fix)
            },
            onRetry: { coordinator.retryBoostPreparation() }
        )
    }

    private static func label(for kind: PersonalVocabulary.RecentFix.Kind) -> String {
        switch kind {
        case .applied(.taught): "Taught"
        case .applied(.learned): "Learned"
        case .applied(.nearbyText): "Nearby text"
        case .learned: "New rule"
        case .forgotten: "Removed"
        }
    }

    private func teachWord() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Teach Reco a word"
        alert.informativeText =
            "Reco listens for this word. If it writes something else instead, list those spellings too."

        let word = NSTextField()
        word.placeholderString = "Word or phrase, like Reco"
        let heard = NSTextField()
        heard.placeholderString = "Heard as (optional), like Rico, Rekko"
        let stack = NSStackView(views: [word, heard])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 52)
        for field in [word, heard] {
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        }
        alert.accessoryView = stack
        alert.addButton(withTitle: "Teach")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = word

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let spellings = heard.stringValue
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        do {
            try vocabulary.teach(word.stringValue, heard: spellings)
        } catch {
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "Couldn’t add that word"
            failure.informativeText = error.localizedDescription
            failure.runModal()
        }
    }

    private func editVocabulary() {
        let url = vocabulary.store.fileURL
        do {
            if !FileManager.default.fileExists(atPath: url.path) {
                try vocabulary.store.writeTemplate()
            }
        } catch {
            NSLog("Reco: couldn’t create the vocabulary file: %@", error.localizedDescription)
            return
        }
        // .toml often has no default app; fall back to TextEdit.
        let configuration = NSWorkspace.OpenConfiguration()
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else if let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: configuration)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("Parakeet v3 · On-device")
                .font(RecoStyle.Font.footnote)
                .foregroundStyle(.tertiary)

            Spacer()

            Menu {
                Toggle("Start at Login", isOn: launchAtLoginBinding)
                Button("Hide Menu Bar Icon…") { confirmHideMenuBarIcon() }

                Divider()

                Button("Setup Assistant…") { onShowSetup() }
                if cliInstalled {
                    Button("Command Line Tool Installed") {}
                        .disabled(true)
                } else {
                    Button("Install Command Line Tool…") { installCLI() }
                }

                Divider()

                Button("About Reco") { showAboutPanel() }
                Button("Quit Reco") { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
    }

    // MARK: Bindings and actions

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

    private func confirmHideMenuBarIcon() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Hide the menu bar icon?"
        alert.informativeText =
            "Reco keeps running and \(coordinator.hotkey.displayName) still records. To show the icon again, open Reco from your Applications folder."
        alert.addButton(withTitle: "Hide Icon")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            showMenuBarIcon = false
        }
    }

    private func showAboutPanel() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    private func installCLI() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        do {
            let destination = try CLIInstaller.install()
            cliInstalled = true
            alert.messageText = "Command line tool installed"
            alert.informativeText =
                "Run reco from Terminal. It’s installed at \(destination.path); make sure that folder is on your PATH."
        } catch {
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t install the command line tool"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }
}

/// A tinted box for something the user needs to act on, shown at the top of
/// the menu so it's seen first.
private struct AttentionCallout<Content: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: symbol)
                    .foregroundStyle(.orange)
                Text(title)
                    .font(RecoStyle.Font.detailEmphasized)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(RecoStyle.Font.detail)

            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.1),
            in: RoundedRectangle(cornerRadius: RecoStyle.cornerRadius)
        )
    }
}

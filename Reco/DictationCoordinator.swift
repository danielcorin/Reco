import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import RecoCore
import SwiftUI

@MainActor
final class DictationCoordinator: ObservableObject {
    enum ModelPreparationState: Equatable {
        case loading
        case ready
        case failed(String)
    }

    enum State: Equatable {
        case loadingModel
        case ready
        case recording(latched: Bool)
        case transcribing
        case failed
    }

    enum Permission: CaseIterable, Identifiable {
        case microphone
        case systemAudio
        case accessibility

        var id: Self { self }

        var displayName: String {
            switch self {
            case .microphone: "Microphone"
            case .systemAudio: "Screen & System Audio"
            case .accessibility: "Accessibility"
            }
        }

        var purpose: String {
            switch self {
            case .microphone: "Captures your voice"
            case .systemAudio: "Captures system audio"
            case .accessibility: "Inserts the transcription"
            }
        }
    }

    enum MicrophoneSelection: Hashable {
        case automatic
        case device(String)
        case off
    }

    @Published private(set) var state: State = .loadingModel
    @Published private(set) var hotkey: Hotkey
    @Published private(set) var isCapturingShortcut = false
    @Published private(set) var needsPermissions = false
    @Published private(set) var grantedPermissions: Set<Permission> = []
    @Published private(set) var lastTranscription: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var modelLoadProgress = 0.0
    @Published private(set) var modelLoadDetail = "Downloading model…"
    @Published private(set) var modelPreparationState: ModelPreparationState = .loading
    @Published private(set) var availableMicrophones: [AudioInputDevice] = []
    @Published private(set) var microphoneSelection: MicrophoneSelection = .automatic
    @Published private(set) var capturesSystemAudio = true

    private let recorder = AudioRecorder()
    private let transcriber = ParakeetTranscriber()
    private let hotkeyMonitor = HotkeyMonitor()
    private let overlay = RecordingOverlayController()
    private var releaseTask: Task<Void, Never>?
    private var recordingStopTask: Task<URL, Error>?
    private let transcriptionQueue = SerialTaskQueue()
    private var pendingTranscriptions = 0
    private var clipboardRestoreTask: Task<Void, Never>?
    private var savedClipboardItems: [NSPasteboardItem]?
    private var clipboardTranscriptChangeCount: Int?
    private var shortcutCaptureTask: Task<Void, Never>?
    private var permissionPollCancellable: AnyCancellable?
    private var permissionPollingClients = 0
    private var audioDeviceObservers: [NSObjectProtocol] = []
    private var started = false
    private var isHotkeyHeld = false
    private var isStartingRecording = false
    private var releasedWhileStarting = false
    private var latchRequestedWhileStarting = false
    private var isRequestingPermissions = false
    private var cliRecordingID: UUID?

    private static let doubleTapWindow: Duration = .milliseconds(280)
    private static let clipboardRestoreDelay: Duration = .milliseconds(500)
    private static let missingPasteAccessMessage =
        "Text was copied, but Accessibility access is required to paste it automatically."

    var onHotkeyChanged: ((Hotkey) throws -> Void)?

    init(initialHotkey: Hotkey) {
        hotkey = initialHotkey
    }

    var menuBarSymbol: String {
        switch state {
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        default: "waveform.circle"
        }
    }

    var statusText: String {
        switch state {
        case .loadingModel: "Loading Parakeet…"
        case .ready: "Ready"
        case .recording(let latched): latched ? "Recording · locked" : "Recording"
        case .transcribing: "Transcribing…"
        case .failed: "Needs attention"
        }
    }

    var statusColor: Color {
        switch state {
        case .ready: .green
        case .recording: .red
        case .loadingModel, .transcribing: .orange
        case .failed: .red
        }
    }

    var capturesMicrophone: Bool {
        microphoneSelection != .off
    }

    var canChangeShortcut: Bool {
        if case .recording = state { return false }
        return !isStartingRecording
    }

    var automaticMicrophoneName: String {
        let preferred =
            availableMicrophones.first(where: \.isBuiltIn)
            ?? availableMicrophones.first
        return preferred.map { "Automatic · \($0.name)" } ?? "Automatic"
    }

    var requiredPermissions: [Permission] {
        Permission.allCases.filter { permission in
            switch permission {
            case .microphone: capturesMicrophone
            case .systemAudio: capturesSystemAudio
            case .accessibility: true
            }
        }
    }

    func isGranted(_ permission: Permission) -> Bool {
        grantedPermissions.contains(permission)
    }

    func start() {
        guard !started else { return }
        started = true

        overlay.prepare()

        hotkeyMonitor.hotkey = hotkey
        hotkeyMonitor.onKeyDown = { [weak self] in self?.hotkeyPressed() }
        hotkeyMonitor.onKeyUp = { [weak self] in self?.hotkeyReleased() }
        hotkeyMonitor.onCaptured = { [weak self] shortcut in
            self?.finishShortcutCapture(shortcut)
        }
        recorder.onLevel = { [weak self] level in
            self?.overlay.updateLevel(level)
        }

        if !hotkeyMonitor.start() {
            errorMessage = "Couldn’t register the shortcut. Choose a different key combination."
        }
        refreshAudioDevices()
        startAudioDeviceObservation()
        refreshPermissions()

        prepareModel()
    }

    func retryModelPreparation() {
        guard case .failed = modelPreparationState else { return }
        prepareModel()
    }

    func beginShortcutCapture() {
        guard canChangeShortcut else { return }
        if isCapturingShortcut {
            cancelShortcutCapture()
            return
        }

        errorMessage = nil
        guard hotkeyMonitor.captureNextShortcut() else {
            isCapturingShortcut = false
            errorMessage = "Couldn’t listen for a new shortcut. Try again."
            return
        }
        isCapturingShortcut = true
        shortcutCaptureTask?.cancel()
        shortcutCaptureTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.isCapturingShortcut else { return }
            self.hotkeyMonitor.cancelCapture()
            self.isCapturingShortcut = false
            self.errorMessage = "No shortcut received. Click the shortcut and try again."
        }
    }

    func cancelShortcutCapture() {
        shortcutCaptureTask?.cancel()
        shortcutCaptureTask = nil
        hotkeyMonitor.cancelCapture()
        if isCapturingShortcut {
            isCapturingShortcut = false
        }
    }

    func applyConfiguredHotkey(_ configuredHotkey: Hotkey) throws {
        guard configuredHotkey != hotkey else { return }
        guard hotkeyMonitor.updateHotkey(configuredHotkey) else {
            throw HotkeyApplicationError.registrationFailed(configuredHotkey.displayName)
        }
        hotkey = configuredHotkey
    }

    func selectMicrophone(_ selection: MicrophoneSelection) {
        guard selection != .off || capturesSystemAudio else { return }

        let resolvedSelection: MicrophoneSelection
        if case .device(let id) = selection,
            !availableMicrophones.contains(where: { $0.id == id })
        {
            resolvedSelection = .automatic
        } else {
            resolvedSelection = selection
        }
        guard microphoneSelection != resolvedSelection else { return }
        microphoneSelection = resolvedSelection
        refreshPermissions()
    }

    func setSystemAudioEnabled(_ enabled: Bool) {
        guard enabled || capturesMicrophone else { return }
        guard capturesSystemAudio != enabled else { return }
        capturesSystemAudio = enabled
        refreshPermissions()
    }

    func refreshAudioDevices() {
        let devices = AudioRecorder.availableMicrophones()
        if availableMicrophones != devices {
            availableMicrophones = devices
        }
        if case .device(let id) = microphoneSelection,
            !devices.contains(where: { $0.id == id })
        {
            microphoneSelection = .automatic
        }
    }

    func requestPermission(_ permission: Permission) {
        guard !isRequestingPermissions else { return }
        isRequestingPermissions = true

        Task {
            defer { isRequestingPermissions = false }

            switch permission {
            case .microphone:
                if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .audio)
                }
                refreshAudioDevices()
            case .systemAudio:
                if !CGPreflightScreenCaptureAccess() {
                    _ = CGRequestScreenCaptureAccess()
                }
            case .accessibility:
                if !CGPreflightPostEventAccess() {
                    // Register this exact app bundle with Accessibility before opening
                    // System Settings so the user does not have to add it manually.
                    let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
                    let options = [promptKey: true] as CFDictionary
                    _ = AXIsProcessTrustedWithOptions(options)

                    // Event posting has a distinct preflight API even though macOS
                    // presents the approval in the Accessibility pane.
                    _ = CGRequestPostEventAccess()
                }
            }

            // System prompts and TCC registration are asynchronous. Give macOS
            // time to settle before deciding whether Settings must be opened.
            try? await Task.sleep(for: .seconds(1))
            refreshPermissions()

            guard !isGranted(permission) else { return }
            switch permission {
            case .microphone:
                openPrivacySettings(anchor: "Privacy_Microphone")
            case .systemAudio:
                openPrivacySettings(anchor: "Privacy_ScreenCapture")
            case .accessibility:
                openPrivacySettings(anchor: "Privacy_Accessibility")
            }
        }
    }

    func refreshPermissions() {
        var granted: Set<Permission> = []
        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            granted.insert(.microphone)
        }
        if CGPreflightScreenCaptureAccess() {
            granted.insert(.systemAudio)
        }
        if CGPreflightPostEventAccess() {
            granted.insert(.accessibility)
        }

        // MenuBarExtra can invoke onAppear again while processing an observed
        // change. @Published emits even when a value is assigned to itself, so
        // only publish real permission changes or SwiftUI can enter a render loop.
        if grantedPermissions != granted {
            grantedPermissions = granted
        }

        let missingPermissions = requiredPermissions.contains { !granted.contains($0) }
        if needsPermissions != missingPermissions {
            needsPermissions = missingPermissions
        }

        if granted.contains(.accessibility), errorMessage == Self.missingPasteAccessMessage {
            errorMessage = nil
        }
    }

    /// Poll while the menu is open so permission rows update after the user
    /// returns from System Settings. A Combine timer avoids tying this work to
    /// SwiftUI's task-modifier lifecycle, which is fragile for MenuBarExtra
    /// views that are repeatedly inserted and removed.
    func startPermissionPolling() {
        permissionPollingClients += 1
        refreshAudioDevices()
        refreshPermissions()
        guard needsPermissions, permissionPollCancellable == nil else { return }

        permissionPollCancellable = Timer.publish(
            every: 1,
            tolerance: 0.1,
            on: .main,
            in: .common
        )
        .autoconnect()
        .sink { [weak self] _ in
            guard let self else { return }
            self.refreshPermissions()
            if !self.needsPermissions {
                self.permissionPollCancellable?.cancel()
                self.permissionPollCancellable = nil
            }
        }
    }

    func stopPermissionPolling() {
        permissionPollingClients = max(permissionPollingClients - 1, 0)
        guard permissionPollingClients == 0 else { return }
        permissionPollCancellable?.cancel()
        permissionPollCancellable = nil
    }

    private func prepareModel() {
        modelLoadProgress = 0
        modelLoadDetail = "Downloading model…"
        modelPreparationState = .loading
        errorMessage = nil
        state = .loadingModel

        Task {
            do {
                try await transcriber.prepare { [weak self] progress, stage in
                    guard let self else { return }
                    modelLoadProgress = progress
                    switch stage {
                    case .downloading:
                        modelLoadDetail = "Downloading model…"
                    case .preparing:
                        modelLoadDetail = "Preparing model…"
                    }
                }
                modelLoadProgress = 1
                modelPreparationState = .ready
                if state == .loadingModel { state = .ready }
            } catch {
                let message = "Couldn’t load Parakeet: \(error.localizedDescription)"
                modelPreparationState = .failed(message)
                errorMessage = message
                state = .failed
            }
        }
    }

    private func openPrivacySettings(anchor: String) {
        guard
            let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
            )
        else { return }

        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.open(
                URL(fileURLWithPath: "/System/Applications/System Settings.app")
            )
        }
    }

    private func startAudioDeviceObservation() {
        guard audioDeviceObservers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ] {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshAudioDevices()
                }
            }
            audioDeviceObservers.append(observer)
        }
    }

    private func finishShortcutCapture(_ shortcut: Hotkey?) {
        shortcutCaptureTask?.cancel()
        shortcutCaptureTask = nil
        isCapturingShortcut = false
        guard let shortcut else { return }

        let previousHotkey = hotkey
        guard hotkeyMonitor.updateHotkey(shortcut) else {
            errorMessage = "That shortcut couldn’t be registered. Choose a different combination."
            return
        }
        do {
            try onHotkeyChanged?(shortcut)
            hotkey = shortcut
        } catch {
            _ = hotkeyMonitor.updateHotkey(previousHotkey)
            errorMessage = "Couldn’t save the shortcut: \(error.localizedDescription)"
        }
    }

    private func hotkeyPressed() {
        guard cliRecordingID == nil else { return }
        isHotkeyHeld = true

        // Starting ScreenCaptureKit can take longer than a normal double-tap.
        // Remember a second press during startup and apply the lock once the
        // recorder is ready instead of dropping the gesture.
        if isStartingRecording {
            if releasedWhileStarting {
                latchRequestedWhileStarting = true
            }
            return
        }

        switch state {
        case .ready, .transcribing, .failed:
            guard modelPreparationState == .ready else { return }
            overlay.show(latched: false)
            beginRecording()
        case .recording(let latched):
            if latched {
                releaseTask?.cancel()
                releaseTask = nil
                finishRecording()
            } else if releaseTask != nil {
                releaseTask?.cancel()
                releaseTask = nil
                state = .recording(latched: true)
                overlay.show(latched: true)
            }
        default:
            break
        }
    }

    private func hotkeyReleased() {
        guard cliRecordingID == nil else { return }
        isHotkeyHeld = false
        if isStartingRecording {
            releasedWhileStarting = true
            return
        }
        guard case .recording(let latched) = state, !latched else { return }
        scheduleRelease()
    }

    private func scheduleRelease() {
        releaseTask?.cancel()
        releaseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.doubleTapWindow)
            guard !Task.isCancelled else { return }
            self?.releaseTask = nil
            self?.finishRecording()
        }
    }

    func startCLIRecording() async throws -> UUID {
        guard modelPreparationState == .ready else {
            throw RecordingCommandError("The transcription model is not ready. Check Reco’s menu and try again.")
        }
        guard cliRecordingID == nil, !isStartingRecording, !isCapturingShortcut else {
            throw RecordingCommandError("Reco is busy. Finish the current recording or shortcut capture first.")
        }
        if case .recording = state {
            throw RecordingCommandError("A recording is already in progress.")
        }
        let id = UUID()
        cliRecordingID = id
        isHotkeyHeld = false
        overlay.show(latched: true)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                beginRecording(latched: true) { continuation.resume(with: $0) }
            }
            return id
        } catch {
            cliRecordingID = nil
            throw error
        }
    }

    func finishCLIRecording(_ id: UUID) async throws -> String {
        guard cliRecordingID == id, case .recording = state else {
            throw RecordingCommandError("That CLI recording is no longer active.")
        }
        cliRecordingID = nil
        return try await withCheckedThrowingContinuation { continuation in
            finishRecording { continuation.resume(with: $0) }
        }
    }

    func transcribeCLIFile(_ url: URL) async throws -> String {
        guard modelPreparationState == .ready else {
            throw RecordingCommandError("The transcription model is not ready. Check Reco’s menu and try again.")
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey])
        guard values?.isRegularFile == true, values?.isReadable == true else {
            throw RecordingCommandError("Audio file is missing or unreadable: \(url.path)")
        }
        return try await withCheckedThrowingContinuation { continuation in
            transcriptionQueue.enqueue { [self] in
                do {
                    let text = try await transcriber.transcribe(url)
                    guard !text.isEmpty else {
                        continuation.resume(throwing: RecordingCommandError("No speech was detected."))
                        return
                    }
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(
                        throwing: RecordingCommandError(
                            "Transcription failed: \(error.localizedDescription)"
                        ))
                }
            }
        }
    }

    private func beginRecording(
        latched: Bool = false,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        guard !isStartingRecording else { return }
        let microphoneDeviceID: String?
        switch microphoneSelection {
        case .automatic, .off:
            microphoneDeviceID = nil
        case .device(let id):
            microphoneDeviceID = id
        }
        let shouldCaptureMicrophone = capturesMicrophone
        let shouldCaptureSystemAudio = capturesSystemAudio
        let previousStop = recordingStopTask
        isStartingRecording = true
        releasedWhileStarting = false
        latchRequestedWhileStarting = false
        errorMessage = nil
        Task {
            do {
                // A new press may arrive while the previous capture is shutting down.
                // Keep its hold/double-tap state, then start once the recorder is free.
                _ = try? await previousStop?.value
                try await recorder.start(
                    microphoneDeviceID: microphoneDeviceID,
                    capturesMicrophone: shouldCaptureMicrophone,
                    capturesSystemAudio: shouldCaptureSystemAudio
                )
                let shouldLatch = latched || latchRequestedWhileStarting
                isStartingRecording = false
                releasedWhileStarting = false
                latchRequestedWhileStarting = false
                state = .recording(latched: shouldLatch)
                if shouldLatch {
                    overlay.show(latched: true)
                } else if !isHotkeyHeld {
                    scheduleRelease()
                }
                completion?(.success(()))
            } catch {
                isStartingRecording = false
                fail(error.localizedDescription)
                completion?(.failure(error))
            }
        }
    }

    private func finishRecording(completion: ((Result<String, Error>) -> Void)? = nil) {
        guard case .recording = state else { return }
        overlay.showTranscribing()
        state = .transcribing

        // Stop capture immediately; serialize inference and delivery so short clips
        // cannot overtake earlier, longer dictations.
        let stopTask = Task { try await recorder.stop() }
        recordingStopTask = stopTask
        pendingTranscriptions += 1
        transcriptionQueue.enqueue { [self] in
            let result = await transcribeRecording(stopTask, deliverToApp: completion == nil)
            let errorText: String?
            switch result {
            case .success: errorText = nil
            case .failure(let error): errorText = error.localizedDescription
            }
            pendingTranscriptions -= 1
            if pendingTranscriptions == 0 {
                recordingStopTask = nil
            }
            transcriptionEnded(errorText: errorText)
            completion?(result)
        }
    }

    private func transcribeRecording(
        _ stopTask: Task<URL, Error>, deliverToApp: Bool
    ) async -> Result<String, Error> {
        let url: URL
        do {
            url = try await stopTask.value
        } catch {
            return .failure(error)
        }

        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let text = try await transcriber.transcribe(url)
            guard !text.isEmpty else {
                return .failure(RecordingCommandError("No speech was detected."))
            }
            if deliverToApp { deliverTranscription(text) }
            return .success(text)
        } catch {
            return .failure(RecordingCommandError("Transcription failed: \(error.localizedDescription)"))
        }
    }

    private func transcriptionEnded(errorText: String?) {
        if let errorText {
            errorMessage = errorText
        }
        // Completion must not overwrite the overlay or state of a newer recording.
        guard state == .transcribing, !isStartingRecording else { return }
        guard pendingTranscriptions == 0 else { return }
        overlay.hide()
        if errorText == nil {
            state = .ready
        } else {
            state = .failed
            scheduleFailedReset()
        }
    }

    private func deliverTranscription(_ text: String) {
        lastTranscription = text

        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            needsPermissions = true
            errorMessage = Self.missingPasteAccessMessage
            return
        }

        if let field = focusedUIElement(), insertViaAccessibility(text, into: field) {
            return
        }

        // Chromium-family apps build their accessibility tree lazily, so a
        // missing or unusable focused element means "paste", not "nothing is
        // focused" — the pasteboard is restored afterward either way.
        pasteRestoringClipboard(text)
    }

    func copyLastTranscription() {
        guard let lastTranscription else { return }
        copyToClipboard(lastTranscription)
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func focusedUIElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(
                systemWide, kAXFocusedUIElementAttribute as CFString, &focusedRef
            ) == .success,
            let focusedRef,
            CFGetTypeID(focusedRef) == AXUIElementGetTypeID()
        else { return nil }
        return (focusedRef as! AXUIElement)
    }

    // Inserts without touching the clipboard. Only classic AppKit text views
    // honor a settable AXSelectedText; Electron apps, terminals, and SwiftUI
    // fields do not, and those fall through to the paste path.
    private func insertViaAccessibility(_ text: String, into field: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        guard
            AXUIElementIsAttributeSettable(
                field, kAXSelectedTextAttribute as CFString, &settable
            ) == .success,
            settable.boolValue,
            AXUIElementSetAttributeValue(
                field, kAXSelectedTextAttribute as CFString, text as CFString
            ) == .success
        else { return false }

        // Some apps report success without inserting anything. Distrust the
        // result when the field's value is readable and the text is absent.
        var valueRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXValueAttribute as CFString, &valueRef)
            == .success,
            let value = valueRef as? String,
            !value.contains(text)
        {
            return false
        }
        return true
    }

    private func pasteRestoringClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        clipboardRestoreTask?.cancel()

        // Consecutive clips can finish before the restore delay expires. Keep
        // the original clipboard in that case, rather than saving our own text.
        if pasteboard.changeCount != clipboardTranscriptChangeCount {
            savedClipboardItems = (pasteboard.pasteboardItems ?? []).map { item in
                let copy = NSPasteboardItem()
                for type in item.types {
                    if let data = item.data(forType: type) {
                        copy.setData(data, forType: type)
                    }
                }
                return copy
            }
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount
        clipboardTranscriptChangeCount = transcriptChangeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        clipboardRestoreTask = Task { [weak self] in
            // Give the frontmost app time to read the pasteboard before
            // putting the previous contents back.
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            guard !Task.isCancelled, let self else { return }
            defer {
                self.savedClipboardItems = nil
                self.clipboardTranscriptChangeCount = nil
                self.clipboardRestoreTask = nil
            }
            // If the user copied something in the meantime, keep their copy.
            guard pasteboard.changeCount == transcriptChangeCount else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(self.savedClipboardItems ?? [])
        }
    }

    private func fail(_ message: String) {
        isStartingRecording = false
        releasedWhileStarting = false
        latchRequestedWhileStarting = false
        isHotkeyHeld = false
        releaseTask?.cancel()
        releaseTask = nil
        overlay.hide()
        errorMessage = message
        state = .failed
        scheduleFailedReset()
    }

    private func scheduleFailedReset() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.state == .failed, !self.isStartingRecording else { return }
            if self.pendingTranscriptions > 0 {
                self.state = .transcribing
                self.overlay.showTranscribing()
            } else if self.modelPreparationState == .ready {
                self.state = .ready
            }
        }
    }
}

private enum HotkeyApplicationError: LocalizedError {
    case registrationFailed(String)

    var errorDescription: String? {
        switch self {
        case .registrationFailed(let shortcut):
            "Couldn’t register \(shortcut). Choose a different shortcut."
        }
    }
}

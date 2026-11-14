import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import RecoCore
import SwiftUI
import os

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

    /// The word-boosting model loads after Parakeet and never blocks
    /// dictation: until it is ready, transcripts are simply not boosted.
    enum BoostStatus: Equatable {
        case loading
        case ready
        case failed(String)
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
    @Published private(set) var boostStatus: BoostStatus = .loading

    let vocabulary: PersonalVocabulary

    private let recorder = AudioRecorder()
    private let transcriber = ParakeetTranscriber()
    private let booster = VocabularyBooster()
    /// The current recording's word list, built while the user speaks.
    private var pendingPlan: Task<BoostPlan?, Never>?
    /// The last insertion, kept in memory until an edit to it is reviewed.
    private var pendingInsertion: PendingInsertion?
    private var insertionReviewTask: Task<Void, Never>?
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
    private var copiedWithoutPaste = false

    private static let doubleTapWindow: Duration = .milliseconds(280)
    /// How long after an insertion Reco looks for corrections, if no new
    /// dictation prompts it sooner.
    private static let insertionReviewDelay: Duration = .seconds(90)
    private static let log = Logger(subsystem: "com.danielcorin.Reco", category: "vocabulary")
    private static let focusLookupTimeout: Float = 0.5
    private static let clipboardRestoreDelay: Duration = .milliseconds(500)
    private static let noSpeechMessage = "No speech was detected."
    private static let missingPasteAccessMessage =
        "Text was copied, but Accessibility access is required to paste it automatically."
    // Ghostty-based terminals accept AXSelectedText, but their AXValue is the
    // rendered screen, which updates asynchronously. The readback check then
    // misses the inserted text and the paste fallback inserts it a second time.
    private static let pasteOnlyBundleIDs: Set<String> = [
        "com.cmuxterm.app",
        "com.mitchellh.ghostty",
    ]

    var onHotkeyChanged: ((Hotkey) throws -> Void)?
    /// Called with the text of every successful transcription, from any source.
    var onTranscribed: ((String) -> Void)?

    init(initialHotkey: Hotkey, vocabulary: PersonalVocabulary) {
        hotkey = initialHotkey
        self.vocabulary = vocabulary
    }

    var menuBarSymbol: String {
        switch state {
        case .recording: "waveform.circle.fill"
        case .transcribing: "ellipsis.circle"
        default: needsAttention ? "exclamationmark.circle" : "waveform.circle"
        }
    }

    /// Something the user has to act on before dictation fully works.
    var needsAttention: Bool {
        if case .failed = modelPreparationState { return true }
        return needsPermissions
    }

    /// The error to show in the menu. A missing-Accessibility message is
    /// covered by the permissions callout, so it isn't repeated.
    var visibleErrorMessage: String? {
        if errorMessage == Self.missingPasteAccessMessage, needsPermissions { return nil }
        return errorMessage
    }

    var statusText: String {
        switch state {
        case .loadingModel: "Loading model…"
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

    /// The microphone Automatic resolves to: the built-in one when present.
    var automaticMicrophoneDeviceName: String? {
        let preferred =
            availableMicrophones.first(where: \.isBuiltIn)
            ?? availableMicrophones.first
        return preferred?.name
    }

    /// The name of the microphone the next recording will use.
    var selectedMicrophoneName: String {
        switch microphoneSelection {
        case .automatic:
            automaticMicrophoneDeviceName ?? "Automatic"
        case .device(let id):
            availableMicrophones.first { $0.id == id }?.name ?? "Automatic"
        case .off:
            "Off"
        }
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

    func retryBoostPreparation() {
        guard case .failed = boostStatus else { return }
        prepareBooster()
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
                // The coordinator lives as long as the app; the task already
                // holds it strongly.
                try await transcriber.prepare { [self] progress, stage in
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
                prepareBooster()
            } catch {
                let message = "Couldn’t load Parakeet: \(error.localizedDescription)"
                modelPreparationState = .failed(message)
                errorMessage = message
                state = .failed
            }
        }
    }

    private func prepareBooster() {
        boostStatus = .loading
        Task {
            do {
                try await booster.prepare()
                boostStatus = .ready
            } catch {
                boostStatus = .failed(error.localizedDescription)
                Self.log.error("Word boosting unavailable: \(error.localizedDescription, privacy: .public)")
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
            // Accessibility reads run after the recorder starts, not before.
            Task { [weak self] in self?.prepareDictation(readingContext: true) }
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
        prepareDictation(readingContext: false)
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
        let terms = vocabulary.boostTerms(nearby: [])
        let plan = Task { [booster] in await booster.plan(for: terms) }
        return try await withCheckedThrowingContinuation { continuation in
            transcriptionQueue.enqueue { [self] in
                do {
                    let (text, fixes) = try await transcribe(url, plan: await plan.value)
                    vocabulary.recordApplied(fixes)
                    guard !text.isEmpty else {
                        continuation.resume(throwing: RecordingCommandError(Self.noSpeechMessage))
                        return
                    }
                    onTranscribed?(text)
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
        let planTask = pendingPlan
        pendingPlan = nil
        pendingTranscriptions += 1
        transcriptionQueue.enqueue { [self] in
            let result = await transcribeRecording(
                stopTask, plan: planTask, deliverToApp: completion == nil)
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
        _ stopTask: Task<URL, Error>, plan planTask: Task<BoostPlan?, Never>?, deliverToApp: Bool
    ) async -> Result<String, Error> {
        let url: URL
        do {
            url = try await stopTask.value
        } catch {
            return .failure(error)
        }

        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let (text, fixes) = try await transcribe(url, plan: await planTask?.value)
            guard !text.isEmpty else {
                return .failure(RecordingCommandError(Self.noSpeechMessage))
            }
            vocabulary.recordApplied(fixes)
            onTranscribed?(text)
            if deliverToApp { deliverTranscription(text, fixes: fixes) }
            return .success(text)
        } catch {
            return .failure(RecordingCommandError("Transcription failed: \(error.localizedDescription)"))
        }
    }

    /// Reviews the previous insertion for corrections, then builds this
    /// recording's word list from the vocabulary and, for hotkey dictation,
    /// the text around the cursor. Runs while the user is speaking.
    private func prepareDictation(readingContext: Bool) {
        reviewPendingInsertion()
        var nearby: [String] = []
        if readingContext, AXIsProcessTrusted(), let field = focusedUIElement(), !Self.isPasteOnly(field),
            let focused = FocusedText.capture(from: field, includeTitle: true)
        {
            nearby = ContextTerms.extract(
                before: focused.context.before,
                after: focused.context.after,
                title: focused.windowTitle
            )
        }
        let terms = vocabulary.boostTerms(nearby: nearby)
        pendingPlan = Task { [booster] in await booster.plan(for: terms) }
    }

    /// Parakeet and, when there is a word list, the word-boosting model run
    /// on the recording in parallel; the rescoring itself takes milliseconds.
    private func transcribe(_ url: URL, plan: BoostPlan?) async throws -> (String, [AppliedFix]) {
        guard let plan else { return (try await transcriber.transcribe(url).text, []) }

        let started = ContinuousClock.now
        async let scoresTask = try? await booster.scoreAudio(url, plan: plan)
        let transcript = try await transcriber.transcribe(url)
        let transcribed = ContinuousClock.now
        let scores = await scoresTask
        let scored = ContinuousClock.now

        var text = transcript.text
        var fixes: [AppliedFix] = []
        if let scores {
            (text, fixes) = booster.rescore(
                transcript, scores: scores, plan: plan, isOrdinaryWord: PersonalVocabulary.isOrdinaryWord)
        }
        let personal = plan.terms.filter { $0.origin != .nearbyText }
        let cased = Vocabulary.applyingCase(of: personal.map(\.text), to: text)
        text = cased.text
        fixes += cased.fixes.map { fix in
            AppliedFix(
                correction: fix,
                origin: personal.first { $0.text == fix.corrected }?.origin ?? .taught
            )
        }

        let wait = scored - transcribed
        Self.log.info(
            "Boosted \(plan.terms.count) terms: Parakeet \((transcribed - started).formatted(.units(allowed: [.milliseconds])), privacy: .public), extra wait \(wait.formatted(.units(allowed: [.milliseconds])), privacy: .public), \(fixes.count) fixes"
        )
        return (text, fixes)
    }

    /// Looks for corrections to the last insertion and teaches them to the
    /// vocabulary. The insertion is forgotten afterward either way.
    private func reviewPendingInsertion() {
        insertionReviewTask?.cancel()
        insertionReviewTask = nil
        guard let insertion = pendingInsertion else { return }
        pendingInsertion = nil
        guard let edited = insertion.editedText() else { return }
        let review = CorrectionLearner.review(
            inserted: insertion.insertedText,
            edited: edited,
            applied: insertion.appliedFixes.map(\.correction),
            isOrdinaryWord: PersonalVocabulary.isOrdinaryWord
        )
        vocabulary.learn(from: review, applied: insertion.appliedFixes)
    }

    private func rememberInsertion(_ text: String, at focused: FocusedText, fixes: [AppliedFix]) {
        let anchors = EditRecovery.anchors(for: focused.context)
        pendingInsertion = PendingInsertion(
            element: focused.element,
            location: focused.selection.location,
            insertedText: text,
            beforeAnchor: anchors.before,
            afterAnchor: anchors.after,
            appliedFixes: fixes
        )
        insertionReviewTask?.cancel()
        insertionReviewTask = Task { [weak self] in
            try? await Task.sleep(for: Self.insertionReviewDelay)
            guard !Task.isCancelled else { return }
            self?.reviewPendingInsertion()
        }
    }

    private func transcriptionEnded(errorText: String?) {
        if let errorText {
            errorMessage = errorText
        }
        // Completion must not overwrite the overlay or state of a newer recording.
        guard state == .transcribing, !isStartingRecording else { return }
        guard pendingTranscriptions == 0 else { return }
        if let errorText {
            overlay.showNotice(errorText == Self.noSpeechMessage ? .noSpeech : .transcriptionFailed)
        } else if copiedWithoutPaste {
            overlay.showNotice(.copied)
        } else {
            overlay.hide()
        }
        copiedWithoutPaste = false
        if errorText == nil {
            state = .ready
        } else {
            state = .failed
            scheduleFailedReset()
        }
    }

    private func deliverTranscription(_ text: String, fixes: [AppliedFix]) {
        lastTranscription = text
        copiedWithoutPaste = false

        guard AXIsProcessTrusted() else {
            copyToClipboard(text)
            copiedWithoutPaste = true
            needsPermissions = true
            errorMessage = Self.missingPasteAccessMessage
            return
        }

        let field = focusedUIElement()
        let pasteOnly = field.map(Self.isPasteOnly) ?? true
        // Fit the transcript to the text around the cursor where it can be
        // read; elsewhere it goes in exactly as transcribed.
        let focused = pasteOnly ? nil : field.flatMap { FocusedText.capture(from: $0) }
        let formatted = TranscriptFormatter.fit(text, into: focused?.context) { [vocabulary] word in
            vocabulary.keepsCapitalized(word, in: text)
        }
        if let focused { rememberInsertion(formatted, at: focused, fixes: fixes) }

        if let field, !pasteOnly, insertViaAccessibility(formatted, into: field) {
            return
        }

        // Chromium-family apps build their accessibility tree lazily, so a
        // missing or unusable focused element means "paste", not "nothing is
        // focused" — the pasteboard is restored afterward either way.
        pasteRestoringClipboard(formatted)
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
        // This runs on the main thread at every key press and delivery; a hung
        // app would otherwise hold it for Accessibility's default 6 seconds.
        // On a timeout Reco skips context and pastes, as it does for Chromium.
        AXUIElementSetMessagingTimeout(systemWide, Self.focusLookupTimeout)
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

    private static func isPasteOnly(_ field: AXUIElement) -> Bool {
        var pid: pid_t = 0
        guard AXUIElementGetPid(field, &pid) == .success,
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        else { return false }
        return pasteOnlyBundleIDs.contains(bundleID)
    }

    // Inserts without touching the clipboard. Only classic AppKit text views
    // honor a settable AXSelectedText; Electron apps, most terminals, and
    // SwiftUI fields do not, and those fall through to the paste path.
    private func insertViaAccessibility(_ text: String, into field: AXUIElement) -> Bool {
        // Reading context shortened this element's timeout. An insertion that
        // times out but lands anyway would be pasted a second time, so give
        // it Accessibility's full default (0 restores it).
        AXUIElementSetMessagingTimeout(field, 0)
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
        overlay.showNotice(.recordingFailed)
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

import AVFoundation
import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import SwiftUI

@MainActor
final class DictationCoordinator: ObservableObject {
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

    @Published private(set) var state: State = .loadingModel
    @Published private(set) var hotkey: Hotkey
    @Published private(set) var isCapturingShortcut = false
    @Published private(set) var needsPermissions = false
    @Published private(set) var grantedPermissions: Set<Permission> = []
    @Published private(set) var lastTranscription: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var modelLoadProgress = 0.0
    @Published private(set) var modelLoadDetail = "Downloading model…"

    private let recorder = AudioRecorder()
    private let transcriber = ParakeetTranscriber()
    private let hotkeyMonitor = HotkeyMonitor()
    private let overlay = RecordingOverlayController()
    private var releaseTask: Task<Void, Never>?
    private var shortcutCaptureTask: Task<Void, Never>?
    private var started = false
    private var isHotkeyHeld = false
    private var isStartingRecording = false
    private var releasedWhileStarting = false
    private var latchRequestedWhileStarting = false
    private var isRequestingPermissions = false

    private static let hotkeyDefaultsKey = "hotkey"
    private static let doubleTapWindow: Duration = .milliseconds(280)
    private static let clipboardRestoreDelay: Duration = .milliseconds(500)
    private static let missingPasteAccessMessage =
        "Text was copied, but Accessibility access is required to paste it automatically."

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hotkeyDefaultsKey),
            let saved = try? JSONDecoder().decode(Hotkey.self, from: data)
        {
            hotkey = saved
        } else {
            hotkey = .defaultHotkey
        }
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
        refreshPermissions()

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
                if state == .loadingModel { state = .ready }
            } catch {
                fail("Couldn’t load Parakeet: \(error.localizedDescription)")
            }
        }
    }

    func beginShortcutCapture() {
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
        isCapturingShortcut = false
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

        grantedPermissions = granted
        needsPermissions = granted.count != Permission.allCases.count

        if granted.contains(.accessibility), errorMessage == Self.missingPasteAccessMessage {
            errorMessage = nil
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

    private func finishShortcutCapture(_ shortcut: Hotkey?) {
        shortcutCaptureTask?.cancel()
        shortcutCaptureTask = nil
        isCapturingShortcut = false
        guard let shortcut else {
            errorMessage = "Use at least one modifier key in the shortcut."
            return
        }

        guard hotkeyMonitor.updateHotkey(shortcut) else {
            errorMessage = "That shortcut couldn’t be registered. Choose a different combination."
            return
        }
        hotkey = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.hotkeyDefaultsKey)
        }
    }

    private func hotkeyPressed() {
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
        isHotkeyHeld = false
        if isStartingRecording {
            releasedWhileStarting = true
            return
        }
        guard case .recording(let latched) = state, !latched else { return }
        overlay.hide()
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

    private func beginRecording() {
        guard !isStartingRecording else { return }
        isStartingRecording = true
        releasedWhileStarting = false
        latchRequestedWhileStarting = false
        errorMessage = nil
        Task {
            do {
                try await recorder.start()
                let shouldLatch = latchRequestedWhileStarting
                isStartingRecording = false
                releasedWhileStarting = false
                latchRequestedWhileStarting = false
                state = .recording(latched: shouldLatch)
                if shouldLatch {
                    overlay.show(latched: true)
                } else if !isHotkeyHeld {
                    overlay.hide()
                    scheduleRelease()
                }
            } catch {
                isStartingRecording = false
                fail(error.localizedDescription)
            }
        }
    }

    private func finishRecording() {
        guard case .recording = state else { return }
        overlay.hide()
        state = .transcribing

        Task {
            let url: URL
            do {
                url = try await recorder.stop()
            } catch {
                fail(error.localizedDescription)
                return
            }

            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await transcriber.transcribe(url)
                guard !text.isEmpty else {
                    transcriptionEnded(errorText: "No speech was detected.")
                    return
                }
                deliverTranscription(text)
                transcriptionEnded(errorText: nil)
            } catch {
                transcriptionEnded(errorText: "Transcription failed: \(error.localizedDescription)")
            }
        }
    }

    private func transcriptionEnded(errorText: String?) {
        guard let errorText else {
            if state == .transcribing { state = .ready }
            return
        }

        errorMessage = errorText
        // Don't clobber a recording that started while this clip was transcribing.
        guard state == .transcribing, !isStartingRecording else { return }
        state = .failed
        scheduleFailedReset()
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
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let transcriptChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        Task {
            // Give the frontmost app time to read the pasteboard before
            // putting the previous contents back.
            try? await Task.sleep(for: Self.clipboardRestoreDelay)
            // If the user copied something in the meantime, keep their copy.
            guard pasteboard.changeCount == transcriptChangeCount else { return }
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
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
            guard let self, self.state == .failed else { return }
            self.state = .ready
        }
    }
}

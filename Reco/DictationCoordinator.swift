import AppKit
import AVFoundation
import ApplicationServices
import Combine
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

    @Published private(set) var state: State = .loadingModel
    @Published private(set) var hotkey: Hotkey
    @Published private(set) var isCapturingShortcut = false
    @Published private(set) var needsPermissions = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var modelLoadProgress = 0.0
    @Published private(set) var modelLoadDetail = "Downloading model…"

    private let recorder = AudioRecorder()
    private let transcriber = ParakeetTranscriber()
    private let hotkeyMonitor = HotkeyMonitor()
    private let overlay = RecordingOverlayController()
    private var releaseTask: Task<Void, Never>?
    private var started = false
    private var isHotkeyHeld = false
    private var isStartingRecording = false

    private static let hotkeyDefaultsKey = "hotkey"
    private static let doubleTapWindow: Duration = .milliseconds(280)

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.hotkeyDefaultsKey),
           let saved = try? JSONDecoder().decode(Hotkey.self, from: data) {
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

        refreshPermissions()
        if !hotkeyMonitor.start() {
            needsPermissions = true
        }

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
        isCapturingShortcut = true
        errorMessage = nil
        hotkeyMonitor.captureNextShortcut()
    }

    func requestPermissions() {
        _ = CGRequestListenEventAccess()
        _ = CGRequestPostEventAccess()

        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refreshPermissions()
            _ = hotkeyMonitor.start()
        }
    }

    func refreshPermissions() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        needsPermissions = mic != .authorized
            || !CGPreflightListenEventAccess()
            || !CGPreflightPostEventAccess()
    }

    private func finishShortcutCapture(_ shortcut: Hotkey?) {
        isCapturingShortcut = false
        guard let shortcut else {
            errorMessage = "Use at least one modifier key in the shortcut."
            return
        }

        hotkey = shortcut
        hotkeyMonitor.hotkey = shortcut
        if let data = try? JSONEncoder().encode(shortcut) {
            UserDefaults.standard.set(data, forKey: Self.hotkeyDefaultsKey)
        }
    }

    private func hotkeyPressed() {
        isHotkeyHeld = true
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
        errorMessage = nil
        Task {
            do {
                try await recorder.start()
                isStartingRecording = false
                state = .recording(latched: false)
                if !isHotkeyHeld {
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

        let url: URL
        do {
            url = try recorder.stop()
        } catch {
            fail(error.localizedDescription)
            return
        }

        Task {
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                let text = try await transcriber.transcribe(url)
                guard !text.isEmpty else {
                    transcriptionEnded(errorText: "No speech was detected.")
                    return
                }
                copyAndPaste(text)
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

    private func copyAndPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard CGPreflightPostEventAccess() else {
            needsPermissions = true
            errorMessage = "Text was copied, but input access is required to paste it automatically."
            return
        }

        let source = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }

    private func fail(_ message: String) {
        isStartingRecording = false
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

import AppKit
import Combine
import SwiftUI

/// A short message the pill shows after a recording ends, where the user is
/// already looking, before it fades away.
enum RecordingNotice: Equatable {
    /// The text is on the clipboard but couldn't be pasted.
    case copied
    case noSpeech
    case transcriptionFailed
    case recordingFailed

    var symbol: String {
        switch self {
        case .copied: "doc.on.clipboard"
        case .noSpeech, .transcriptionFailed, .recordingFailed: "exclamationmark.triangle.fill"
        }
    }

    var title: String {
        switch self {
        case .copied: "Copied to clipboard"
        case .noSpeech: "No speech heard"
        case .transcriptionFailed: "Transcription failed"
        case .recordingFailed: "Couldn’t record"
        }
    }
}

@MainActor
final class RecordingOverlayController {
    /// One width for every state, sized for the longest label, so the pill
    /// never resizes as a recording moves from state to state.
    static let size = NSSize(width: 196, height: 38)
    private static let noticeDuration: Duration = .milliseconds(1600)

    private var panel: NSPanel?
    private let model = RecordingOverlayModel()
    private var isVisible = false
    private var hideToken = 0

    func prepare() {
        _ = ensurePanel()
    }

    func show(latched: Bool) {
        // Locking an ongoing recording keeps its clock running.
        if !isVisible || model.recordingStart == nil {
            model.recordingStart = .now
        }
        model.phase = .recording(latched: latched)
        present()
    }

    func showTranscribing() {
        model.phase = .transcribing
        model.level = 0
        present()
    }

    func showNotice(_ notice: RecordingNotice) {
        model.phase = .notice(notice)
        model.level = 0
        present()
        let token = hideToken
        Task { [weak self] in
            try? await Task.sleep(for: Self.noticeDuration)
            guard let self, self.hideToken == token else { return }
            self.hide()
        }
    }

    private func present() {
        if !model.phase.isRecording {
            model.recordingStart = nil
        }
        let wasVisible = isVisible
        isVisible = true
        hideToken += 1

        let panel = ensurePanel()
        if !wasVisible {
            position(panel)
        }
        // A zero-length animation also cancels a fade-out still in flight.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().alphaValue = 1
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        guard isVisible, let panel else { return }
        isVisible = false
        model.level = 0
        model.recordingStart = nil
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.12
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.hideToken == token else { return }
                    self.panel?.orderOut(nil)
                }
            })
    }

    func updateLevel(_ level: Float) {
        guard isVisible, case .recording = model.phase else { return }
        model.level = level
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: RecordingPillView(model: model))
        panel.alphaValue = 0
        panel.contentView?.layoutSubtreeIfNeeded()
        self.panel = panel
        return panel
    }

    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let x = frame.midX - panel.frame.width / 2
        let y = frame.minY + 42
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class RecordingOverlayModel: ObservableObject {
    enum Phase: Equatable {
        case recording(latched: Bool)
        case transcribing
        case notice(RecordingNotice)

        var isRecording: Bool {
            if case .recording = self { true } else { false }
        }
    }

    @Published var phase: Phase = .recording(latched: false)
    @Published var recordingStart: Date?
    @Published var level: Float = 0
}

struct RecordingPillView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        HStack(spacing: 8) {
            leadingGlyph
                .frame(width: 18, height: 18)

            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if let start = model.recordingStart, model.phase.isRecording {
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
                    .frame(width: 40, alignment: .trailing)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: RecordingOverlayController.size.width, height: RecordingOverlayController.size.height)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch model.phase {
        case .recording(let latched):
            if latched {
                Image(systemName: "lock.fill")
                    .font(.system(size: 12, weight: .semibold))
            } else {
                LiveWaveform(level: model.level)
            }
        case .transcribing:
            ProgressView()
                .controlSize(.small)
                .colorScheme(.dark)
        case .notice(let notice):
            Image(systemName: notice.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(notice == .copied ? Color.white : Color.yellow)
        }
    }

    private var title: String {
        switch model.phase {
        case .recording(let latched): latched ? "Locked" : "Recording"
        case .transcribing: "Transcribing…"
        case .notice(let notice): notice.title
        }
    }
}

private struct LiveWaveform: View {
    let level: Float
    private let weights: [CGFloat] = [0.48, 0.76, 1, 0.7, 0.44]

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(weights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.9))
                    .frame(width: 2, height: height(for: weights[index]))
            }
        }
        .frame(width: 18, height: 18)
        .animation(.linear(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }

    private func height(for weight: CGFloat) -> CGFloat {
        let signal = max(CGFloat(level), 0.06)
        return 3 + (14 * signal * weight)
    }
}

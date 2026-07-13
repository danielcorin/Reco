import AppKit
import Combine
import SwiftUI

@MainActor
final class RecordingOverlayController {
    private var panel: NSPanel?
    private let model = RecordingOverlayModel()
    private var isVisible = false
    private var hideToken = 0

    func prepare() {
        _ = ensurePanel()
    }

    func show(latched: Bool) {
        model.latched = latched
        isVisible = true
        hideToken += 1

        let panel = ensurePanel()
        panel.setContentSize(NSSize(width: latched ? 162 : 136, height: 38))
        position(panel)
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
        hideToken += 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.hideToken == token else { return }
            panel.orderOut(nil)
        })
    }

    func updateLevel(_ level: Float) {
        model.level = level
    }

    private func ensurePanel() -> NSPanel {
        if let panel { return panel }

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 136, height: 38)),
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
private final class RecordingOverlayModel: ObservableObject {
    @Published var latched = false
    @Published var level: Float = 0
}

private struct RecordingPillView: View {
    @ObservedObject var model: RecordingOverlayModel

    var body: some View {
        HStack(spacing: 7) {
            LiveWaveform(level: model.level)

            Text(model.latched ? "Recording · locked" : "Recording")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.82), in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 0.5))
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

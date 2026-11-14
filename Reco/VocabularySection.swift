import SwiftUI

/// One recent fix as the menu shows it.
struct VocabularyFixRow: Identifiable, Equatable {
    let id: UUID
    let heard: String
    let corrected: String
    /// Where the fix came from: Taught, Learned, Nearby text, New rule, Removed.
    let label: String
    let isRemoved: Bool
    let canStopFixing: Bool
}

/// The menu's Vocabulary section: Teach and Edit actions, then the most recent
/// fixes, each removable so an optimistic fix that was wrong never repeats.
struct VocabularySection: View {
    let rows: [VocabularyFixRow]
    let wordCount: Int
    let unavailableReason: String?
    let onTeach: () -> Void
    let onEdit: () -> Void
    let onStopFixing: (UUID) -> Void
    let onRetry: () -> Void

    static let visibleRows = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                MenuSectionHeader(title: "Vocabulary")
                Spacer()
                headerButton("Teach…", systemImage: "plus", action: onTeach)
                    .help("Add a word Reco should listen for")
                headerButton("Edit", systemImage: "square.and.pencil", action: onEdit)
                    .help("Open vocabulary.toml")
            }

            if let unavailableReason {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Word boosting is unavailable.")
                        .help(unavailableReason)
                    Spacer(minLength: 8)
                    Button("Retry", action: onRetry)
                        .controlSize(.small)
                }
                .font(RecoStyle.Font.caption)
            }

            if rows.isEmpty {
                Text(summary)
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows.prefix(Self.visibleRows)) { row in
                        FixRowView(row: row, onStopFixing: { onStopFixing(row.id) })
                    }
                }
            }
        }
    }

    private var summary: String {
        let words = wordCount == 1 ? "1 word" : "\(wordCount) words"
        return wordCount == 0
            ? "Fixes appear here. Reco learns from corrections you make after dictating."
            : "Listening for \(words). Fixes appear here."
    }

    private func headerButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(RecoStyle.Font.caption)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

private struct FixRowView: View {
    let row: VocabularyFixRow
    let onStopFixing: () -> Void
    @State private var isHovered = false

    private var showsRemove: Bool { row.canStopFixing && isHovered }

    var body: some View {
        HStack(spacing: 6) {
            (Text(row.heard).foregroundStyle(.secondary)
                + Text("  →  ").foregroundStyle(.tertiary)
                + Text(row.corrected))
                .strikethrough(row.isRemoved, color: .secondary)
                .font(RecoStyle.Font.detail)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("\(row.heard) → \(row.corrected)")

            Spacer(minLength: 8)

            // The remove button takes the label's place on hover, so the
            // label column stays aligned and nothing shifts.
            ZStack(alignment: .trailing) {
                Text(row.label)
                    .font(RecoStyle.Font.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .opacity(showsRemove ? 0 : 1)

                Button(action: onStopFixing) {
                    Label("Stop", systemImage: "xmark.circle.fill")
                        .font(RecoStyle.Font.caption)
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Stop making this fix")
                .opacity(showsRemove ? 1 : 0)
                .disabled(!showsRemove)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .contextMenu {
            Button("Stop Making This Fix", action: onStopFixing)
                .disabled(!row.canStopFixing)
            Button("Copy “\(row.corrected)”") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.corrected, forType: .string)
            }
        }
    }
}

import SwiftUI

/// Shared type and spacing for Reco's menu and setup window, so sibling
/// elements match and no view hard-codes its own sizes.
enum RecoStyle {
    static let menuWidth: CGFloat = 300
    static let menuPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let rowSpacing: CGFloat = 10
    static let cornerRadius: CGFloat = 8

    enum Font {
        static let windowTitle = SwiftUI.Font.system(size: 22, weight: .semibold)
        static let stepTitle = SwiftUI.Font.system(size: 18, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let bodyEmphasized = SwiftUI.Font.system(size: 13, weight: .medium)
        static let body = SwiftUI.Font.system(size: 13)
        static let detail = SwiftUI.Font.system(size: 12)
        static let detailEmphasized = SwiftUI.Font.system(size: 12, weight: .medium)
        static let caption = SwiftUI.Font.system(size: 11)
        static let captionEmphasized = SwiftUI.Font.system(size: 11, weight: .medium)
        static let badge = SwiftUI.Font.system(size: 11, weight: .semibold, design: .rounded)
        static let footnote = SwiftUI.Font.system(size: 10)
        static let sectionHeader = SwiftUI.Font.system(size: 10, weight: .semibold)
        static let shortcut = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let statValue = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let axis = SwiftUI.Font.system(size: 9)
    }
}

struct MenuSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(RecoStyle.Font.sectionHeader)
            .foregroundStyle(.tertiary)
            .tracking(0.5)
    }
}

/// A label on the leading edge and a control on the trailing edge.
struct MenuRow<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            trailing
        }
    }
}

import SwiftUI

/// Shared look for the app's glass surfaces: one corner radius and padding for cards, tips and control panels.
enum GlassCardStyle {
    static let cornerRadius: CGFloat = 22
    static let padding: CGFloat = 16
}

/// A one-time tip on glass, dismissed for good with its close button (remembered under `key` in user defaults).
struct FirstRunTip: View {
    /// Every tip's defaults key (the UI-test reset marks them all seen).
    static let allKeys = ["library.hintDismissed", "recipe.hintDismissed", "review.hintDismissed"]
    let key: String
    let symbol: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    @AppStorage private var dismissed: Bool

    init(key: String, symbol: String, title: LocalizedStringKey, message: LocalizedStringKey) {
        self.key = key
        self.symbol = symbol
        self.title = title
        self.message = message
        _dismissed = AppStorage(wrappedValue: false, key)
    }

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .padding(.top, 12)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 12)
                .accessibilityElement(children: .combine)
                Spacer(minLength: 0)
                Button {
                    withAnimation(.snappy) { dismissed = true }
                } label: {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss tip")
            }
            .padding(.leading, 14)
            .glassEffect(.regular, in: .rect(cornerRadius: GlassCardStyle.cornerRadius))
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

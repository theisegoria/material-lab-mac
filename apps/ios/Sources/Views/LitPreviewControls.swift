import SwiftUI

/// Lighting, displacement and the preview-only wear and wetness sliders under the 3D preview.
struct LitPreviewControls: View {
    @Binding var settings: LitPreviewSettings
    let hasHeight: Bool
    /// True when the height span comes from a full derivation (otherwise an estimate is used for live previews).
    let measuredSpan: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Lighting", selection: $settings.environment) {
                ForEach(PreviewEnvironment.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("preview-lighting")

            if hasHeight {
                SliderRow(title: "Displacement", symbol: "mountain.2",
                          value: $settings.displacementScale, range: LitPreviewSettings.displacementRange,
                          valueText: settings.displacementScale == 0
                              ? String(localized: "Off")
                              : settings.displacementScale.formatted(.number.precision(.fractionLength(1))) + "×",
                          identifier: "preview-displacement")
                Text(measuredSpan
                     ? "Moves the surface by the height map at its derived relief. 1× is true to scale."
                     : "Moves the surface by the height map. The relief is estimated until full-resolution maps are derived.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 6) {
                Label("Preview only", systemImage: "eye")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .glassEffect(.regular.tint(.orange.opacity(0.35)), in: .capsule)
                Text("Not saved to maps or exports")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            SliderRow(title: "Wetness", symbol: "drop", value: $settings.wetness, range: 0...1,
                      valueText: settings.wetness.formatted(.percent.precision(.fractionLength(0))),
                      identifier: "preview-wetness")
            SliderRow(title: "Wear", symbol: "hand.raised.fingers.spread", value: $settings.wear, range: 0...1,
                      valueText: settings.wear.formatted(.percent.precision(.fractionLength(0))),
                      identifier: "preview-wear")

            if settings.wetness > 0 || settings.wear > 0 || settings.displacementScale != 1 {
                Button("Reset Preview", systemImage: "arrow.counterclockwise") {
                    withAnimation(.snappy) {
                        settings.wetness = 0
                        settings.wear = 0
                        settings.displacementScale = 1
                    }
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("preview-reset")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
    }
}

private struct SliderRow: View {
    let title: LocalizedStringKey
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String
    let identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.subheadline)
                Spacer()
                Text(valueText)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(Text(title))
                .accessibilityValue(valueText)
                .accessibilityIdentifier(identifier)
        }
    }
}

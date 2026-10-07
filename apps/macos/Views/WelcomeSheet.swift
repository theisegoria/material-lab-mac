import SwiftUI
import TipKit

/// First-run welcome: the three steps from a photo to an engine-ready material. Shown once, and from the Help menu.
struct WelcomeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0

    private struct Step {
        let symbol: String
        let title: String
        let text: String
    }

    private let steps = [
        Step(symbol: "photo.on.rectangle.angled", title: "Import a photo",
             text: "Drop in a straight-on photo of a surface (or a hand-painted albedo), or receive a capture from Material Capture on your iPhone."),
        Step(symbol: "slider.horizontal.3", title: "Choose a material and tune",
             text: "Pick a material such as Red brick or Brushed steel, then adjust relief, roughness and tiling. Maps update live; ⌘1–9 switch between them, and ⌘Z undoes."),
        Step(symbol: "square.and.arrow.up.on.square", title: "Export anywhere",
             text: "⌘E writes the .pbrmaterial bundle plus glTF, USDZ, MaterialX, Unreal, Unity, Godot, Blender, Substance, Roblox or Minecraft files."),
    ]

    var body: some View {
        VStack(spacing: 22) {
            Text("Welcome to Material Lab")
                .font(.largeTitle.weight(.semibold))
            let step = steps[page]
            VStack(spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .frame(height: 70)
                Text("\(page + 1). \(step.title)").font(.title2.weight(.semibold))
                Text(step.text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }
            .id(page)
            .transition(.push(from: .trailing))
            .frame(height: 230)
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { index in
                    Circle()
                        .fill(index == page ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(page + 1) of \(steps.count)")
            HStack {
                Button("Skip") { finish() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if page > 0 {
                    Button("Back") { withAnimation { page -= 1 } }
                }
                Button(page == steps.count - 1 ? "Get Started" : "Continue") {
                    if page == steps.count - 1 { finish() } else { withAnimation { page += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(28)
        .frame(width: 560)
    }

    private func finish() {
        WelcomeSheet.hasBeenShown = true
        dismiss()
    }

    static var hasBeenShown: Bool {
        get { UserDefaults.standard.bool(forKey: "materialLab.welcomeShown") }
        set { UserDefaults.standard.set(newValue, forKey: "materialLab.welcomeShown") }
    }
}

/// Points new users at the material library.
struct MaterialMenuTip: Tip {
    var title: Text { Text("Start from a material") }
    var message: Text? { Text("Red brick, oak planks, rusted steel and 36 more set the relief, roughness and AO for you.") }
    var image: Image? { Image(systemName: "square.stack.3d.up") }
}

/// Points new users at the export formats.
struct ExportTip: Tip {
    var title: Text { Text("Export for your engine") }
    var message: Text? { Text("Choose glTF, USDZ, Unreal, Unity, Godot and more alongside the bundle.") }
    var image: Image? { Image(systemName: "square.and.arrow.up.on.square") }
}

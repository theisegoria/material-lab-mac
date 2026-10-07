import SwiftUI

/// The albedo lit by a movable light through the normal and occlusion maps, as on the Mac. Drag to move the light.
struct RelitView: View {
    let material: DerivedMaterial
    @State private var azimuth: Float = -2.35
    @State private var elevation: Float = 0.62
    @State private var image: CGImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                } else {
                    ProgressView()
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .overlay(alignment: .bottomLeading) {
                Label("Drag to move the light", systemImage: "sun.max")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(12)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                // The drag point is where the light shines from, seen from above.
                let x = Float(value.location.x / geometry.size.width) * 2 - 1
                let y = Float(value.location.y / geometry.size.height) * 2 - 1
                azimuth = atan2(-y, x)
                elevation = max(0.08, (Float.pi / 2) * (1 - min(1, (x * x + y * y).squareRoot())))
            })
            .accessibilityElement()
            .accessibilityLabel("Relit preview")
            .accessibilityValue("Light elevation \(Int(elevation * 180 / .pi)) degrees")
            .accessibilityAdjustableAction { direction in
                azimuth += direction == .increment ? 0.3 : -0.3
            }
        }
        .task(id: "\(ObjectIdentifier(material.correctedSource))|\(azimuth)|\(elevation)") {
            let material = material, azimuth = azimuth, elevation = elevation
            let relit = await Task.detached(priority: .userInitiated) {
                MaterialProcessor.relitImage(material, azimuth: azimuth, elevation: elevation)
            }.value
            if !Task.isCancelled { image = relit }
        }
    }
}

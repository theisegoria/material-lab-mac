import CoreGraphics
import RealityKit

/// Image-based lighting for the 3D previews, generated procedurally (nothing to download or bundle).
enum PreviewEnvironment: String, CaseIterable, Identifiable, Sendable {
    case studio, overcast, sunset
    var id: String { rawValue }
    var title: String { L(englishTitle) }
    var englishTitle: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .studio: "light.panel"
        case .overcast: "cloud"
        case .sunset: "sun.horizon"
        }
    }

    /// Zenith, horizon and ground colours, plus a soft key (position in the equirect, size, colour).
    private var palette: (top: [CGFloat], horizon: [CGFloat], ground: [CGFloat], key: CGRect, keyColor: [CGFloat]) {
        switch self {
        case .studio:
            ([0.98, 0.98, 1.0], [0.62, 0.64, 0.68], [0.20, 0.20, 0.21], CGRect(x: 40, y: 84, width: 56, height: 26), [1, 0.96, 0.9, 0.9])
        case .overcast:
            ([0.86, 0.88, 0.92], [0.72, 0.74, 0.77], [0.30, 0.31, 0.30], CGRect(x: 0, y: 96, width: 256, height: 32), [0.95, 0.96, 1, 0.5])
        case .sunset:
            ([0.32, 0.42, 0.66], [1.0, 0.62, 0.38], [0.16, 0.12, 0.12], CGRect(x: 150, y: 62, width: 34, height: 12), [1, 0.82, 0.55, 1])
        }
    }

    /// An equirectangular sky (top row = zenith) for `EnvironmentResource`.
    @MainActor
    func makeResource() -> EnvironmentResource? {
        let width = 256, height = 128
        let p = palette
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        func color(_ c: [CGFloat]) -> CGColor { CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: c.count > 3 ? c[3] : 1) }
        let colors = [color(p.top), color(p.horizon), color(p.ground)] as CFArray
        guard let gradient = CGGradient(colorsSpace: space, colors: colors, locations: [0, 0.5, 1]) else { return nil }
        // CoreGraphics' origin is bottom-left; the top row of the equirect is the zenith.
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: CGFloat(height)), end: .zero, options: [])
        context.setFillColor(color(p.keyColor))
        context.fillEllipse(in: p.key)
        guard let image = context.makeImage() else { return nil }
        return try? EnvironmentResource(equirectangular: image, options: .init(samplingQuality: .normal))
    }
}

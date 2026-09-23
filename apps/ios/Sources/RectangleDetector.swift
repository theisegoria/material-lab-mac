import CoreGraphics
import Vision

/// Finds the most prominent flat rectangular surface (a tile, board, swatch) for the initial crop.
enum RectangleDetector {
    static func detect(in image: CGImage) -> PerspectiveQuad? {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.3
        request.maximumAspectRatio = 1
        request.minimumSize = 0.25
        request.minimumConfidence = 0.7
        request.quadratureTolerance = 25
        request.maximumObservations = 1
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do { try handler.perform([request]) } catch { return nil }
        guard let observation = request.results?.first else { return nil }
        // Vision uses a lower-left origin; the crop editor uses upper-left.
        func point(_ p: CGPoint) -> MaterialCapture.NormalizedPoint {
            .init(x: min(1, max(0, Double(p.x))), y: min(1, max(0, 1 - Double(p.y))))
        }
        let detected = PerspectiveQuad(topLeft: point(observation.topLeft),
                                       topRight: point(observation.topRight),
                                       bottomRight: point(observation.bottomRight),
                                       bottomLeft: point(observation.bottomLeft))
        // Detected edges sit on the boundary; pull corners inward so no background bleeds into the albedo.
        let quad = detected.inset(by: 0.015)
        return quad.isValid ? quad : nil
    }
}

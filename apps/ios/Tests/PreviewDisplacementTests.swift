import simd
import XCTest
@testable import MaterialCapture

final class PreviewDisplacementTests: XCTestCase {
    /// A height field with a bright stripe across the top rows (t near 1).
    private func field() -> PreviewHeightField {
        let w = 32, h = 32
        var values = [Float](repeating: 0.25, count: w * h)
        for y in 0..<4 { for x in 0..<w { values[y * w + x] = 1 } }
        return PreviewHeightField(width: w, height: h, values: values)
    }

    func testSamplingWrapsAndFlipsLikeTheMaterialShader() {
        let f = field()
        // t near 1 is the image's top row; t near 0.5 is the middle.
        XCTAssertEqual(f.sample(s: 0.5, t: 0.97), 1, accuracy: 1e-4)
        XCTAssertEqual(f.sample(s: 0.5, t: 0.5), 0.25, accuracy: 1e-4)
        // Repeats wrap.
        XCTAssertEqual(f.sample(s: 2.5, t: 1.97), f.sample(s: 0.5, t: 0.97), accuracy: 1e-5)
        XCTAssertEqual(f.mean, (4 * 1 + 28 * 0.25) / 32, accuracy: 1e-5)
    }

    func testDisplacedShapesFaceOutwardAndScaleWithTheSlider() {
        let f = field()
        for shape in PreviewShape.allCases {
            let flat = DisplacedPreviewMesh.make(shape: shape, field: f, tiling: 2, heightSpan: 0.04, scale: 0)
            let bumpy = DisplacedPreviewMesh.make(shape: shape, field: f, tiling: 2, heightSpan: 0.04, scale: 2)
            XCTAssertEqual(flat.positions.count, bumpy.positions.count)
            XCTAssertEqual(flat.normals.count, flat.positions.count)
            XCTAssertEqual(flat.uvs.count, flat.positions.count)
            XCTAssertEqual(flat.indices.count % 3, 0)
            XCTAssertTrue(flat.indices.allSatisfy { Int($0) < flat.positions.count })
            // Scale 0 leaves the shape undisplaced; a positive scale moves vertices.
            let moved = zip(flat.positions, bumpy.positions).map { simd_distance($0, $1) }.max() ?? 0
            XCTAssertGreaterThan(moved, 1e-4, "\(shape)")
            // Triangles wind outward: their face normal agrees with the vertex normals.
            var agree = 0, total = 0
            for t in Swift.stride(from: 0, to: bumpy.indices.count, by: 3 * 37) {
                let a = Int(bumpy.indices[t]), b = Int(bumpy.indices[t + 1]), c = Int(bumpy.indices[t + 2])
                let n = cross(bumpy.positions[b] - bumpy.positions[a], bumpy.positions[c] - bumpy.positions[a])
                guard simd_length(n) > 1e-12 else { continue }
                total += 1
                if dot(n, bumpy.normals[a]) > 0 { agree += 1 }
            }
            XCTAssertGreaterThan(Double(agree), Double(total) * 0.98, "\(shape)")
        }
        // On the sphere the undisplaced radius is the preview radius.
        let sphere = DisplacedPreviewMesh.make(shape: .sphere, field: f, tiling: 2, heightSpan: 0.04, scale: 0)
        XCTAssertTrue(sphere.positions.allSatisfy { abs(simd_length($0) - 0.21) < 1e-5 })
    }
}

import AppKit
import QuickLookThumbnailing

/// Finder thumbnails for .pbrmaterial bundles: the albedo, with the normal map as a small inset.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let bundle = request.fileURL
        guard let albedo = NSImage(contentsOf: bundle.appendingPathComponent("albedo.png")) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }
        let normal = NSImage(contentsOf: bundle.appendingPathComponent("normal.png"))
        let side = min(request.maximumSize.width, request.maximumSize.height)
        let size = CGSize(width: side, height: side)
        handler(QLThumbnailReply(contextSize: size, currentContextDrawing: { () -> Bool in
            let rect = CGRect(origin: .zero, size: size)
            NSGraphicsContext.current?.imageInterpolation = .high
            albedo.draw(in: rect)
            if let normal, side >= 64 {
                let inset = side * 0.34, margin = side * 0.05
                let frame = CGRect(x: side - inset - margin, y: margin, width: inset, height: inset)
                let path = NSBezierPath(roundedRect: frame, xRadius: inset * 0.12, yRadius: inset * 0.12)
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                normal.draw(in: frame)
                NSGraphicsContext.restoreGraphicsState()
                NSColor.white.withAlphaComponent(0.85).setStroke()
                path.lineWidth = max(1, side / 160)
                path.stroke()
            }
            return true
        }), nil)
    }
}

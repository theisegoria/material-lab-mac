import AVFoundation
import SwiftUI

struct PairingScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> PairingScannerController {
        let controller = PairingScannerController()
        controller.onCode = onCode
        controller.onError = onError
        return controller
    }
    func updateUIViewController(_ controller: PairingScannerController, context: Context) {}
}

final class PairingScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onError: ((String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "io.materiallab.capture.qr")
    private var preview: AVCaptureVideoPreviewLayer?
    private var consumed = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                DispatchQueue.main.async { self.onError?("Camera access is required to scan the Mac QR code. Paste the code instead.") }
                return
            }
            self.queue.async { self.configureAndStart() }
        }
    }

    /// Runs on `queue`. Adds input and output atomically and rolls back a partial configuration.
    private func configureAndStart() {
        if session.inputs.isEmpty {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: camera) else {
                fail("QR scanner camera is unavailable. Paste the code instead.")
                return
            }
            let output = AVCaptureMetadataOutput()
            session.beginConfiguration()
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                fail("QR scanner camera is unavailable. Paste the code instead.")
                return
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                session.removeInput(input)
                session.commitConfiguration()
                fail("QR scanner is unavailable. Paste the code instead.")
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            if output.availableMetadataObjectTypes.contains(.qr) {
                output.metadataObjectTypes = [.qr]
            }
            session.commitConfiguration()
            DispatchQueue.main.async {
                let preview = AVCaptureVideoPreviewLayer(session: self.session)
                preview.videoGravity = .resizeAspectFill
                preview.frame = self.view.bounds
                self.view.layer.insertSublayer(preview, at: 0)
                self.preview = preview
            }
        }
        session.startRunning()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        queue.async { [session] in session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !consumed,
              let code = metadataObjects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject })
                  .first(where: { $0.type == .qr })?.stringValue else { return }
        consumed = true
        onCode?(code)
    }
}

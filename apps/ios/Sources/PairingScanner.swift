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
            self.queue.async {
                guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                      let input = try? AVCaptureDeviceInput(device: camera),
                      self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.onError?("QR scanner camera is unavailable. Paste the code instead.") }
                    return
                }
                self.session.addInput(input)
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    DispatchQueue.main.async { self.onError?("QR scanner is unavailable.") }
                    return
                }
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                DispatchQueue.main.async {
                    let preview = AVCaptureVideoPreviewLayer(session: self.session)
                    preview.videoGravity = .resizeAspectFill
                    preview.frame = self.view.bounds
                    self.view.layer.insertSublayer(preview, at: 0)
                    self.preview = preview
                }
                self.session.startRunning()
            }
        }
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

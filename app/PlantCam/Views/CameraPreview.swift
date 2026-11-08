import AVFoundation
import SwiftUI
import UIKit

final class PreviewView: UIView {
    private var observer: NSObjectProtocol?

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // The layer class is fixed above, so this cast always holds.
        layer as! AVCaptureVideoPreviewLayer
    }

    func attach(_ session: AVCaptureSession) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspect
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.didStartRunningNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyRotation() }
        }
        applyRotation()
    }

    func applyRotation() {
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyRotation()
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

/// The live camera picture. Tap to focus, pinch to zoom.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let running: Bool
    let onTap: (CGPoint) -> Void
    let onPinchBegan: () -> Void
    let onPinchChanged: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onPinchBegan: onPinchBegan, onPinchChanged: onPinchChanged)
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.attach(session)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        view.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pinched(_:)))
        view.addGestureRecognizer(pinch)
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onPinchBegan = onPinchBegan
        context.coordinator.onPinchChanged = onPinchChanged
        uiView.applyRotation()
    }

    final class Coordinator: NSObject {
        var onTap: (CGPoint) -> Void
        var onPinchBegan: () -> Void
        var onPinchChanged: (CGFloat) -> Void
        weak var view: PreviewView?

        init(
            onTap: @escaping (CGPoint) -> Void,
            onPinchBegan: @escaping () -> Void,
            onPinchChanged: @escaping (CGFloat) -> Void
        ) {
            self.onTap = onTap
            self.onPinchBegan = onPinchBegan
            self.onPinchChanged = onPinchChanged
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = view else { return }
            let point = gesture.location(in: view)
            onTap(view.previewLayer.captureDevicePointConverted(fromLayerPoint: point))
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began:
                onPinchBegan()
            case .changed:
                onPinchChanged(gesture.scale)
            default:
                break
            }
        }
    }
}

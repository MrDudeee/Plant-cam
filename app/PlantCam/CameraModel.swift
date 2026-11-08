import AVFoundation
import Photos
import SwiftUI
import UIKit

enum CaptureError: LocalizedError {
    case noAlbum

    var errorDescription: String? {
        switch self {
        case .noAlbum: return "Couldn't open the album."
        }
    }
}

/// Takes a photo and files it straight into the album for the chosen view.
@MainActor
final class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()

    @Published private(set) var permission: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    @Published private(set) var ghost: UIImage?
    /// How far in the picture is: 1 is the main lens, 0.5 the ultra-wide, higher is closer.
    @Published private(set) var zoom: CGFloat = 1
    @Published private(set) var minZoom: CGFloat = 1
    @Published private(set) var maxZoom: CGFloat = 1

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "plantcam.camera")
    private var configured = false
    private var target: PlantView = .side
    /// The camera's own zoom number that means 1x here (2 on phones with an ultra-wide lens).
    private var zoomBase: CGFloat = 1
    private var pinchStart: CGFloat = 1
    private var zoomByView: [PlantView: CGFloat] = [:]

    // MARK: Start and stop

    func start(view: PlantView) async {
        target = view
        if permission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        guard permission == .authorized else { return }
        configureIfNeeded()
        let session = self.session
        queue.async {
            if !session.isRunning { session.startRunning() }
        }
        running = true
        loadGhost(for: view)
    }

    func stop() {
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
        running = false
    }

    func select(view: PlantView) {
        target = view
        message = ""
        setZoom(zoomByView[view] ?? 1)
        loadGhost(for: view)
    }

    // MARK: Setting up the camera

    /// Uses the phone's combined camera, like the Camera app, so zooming moves smoothly between lenses.
    nonisolated private static func bestDevice() -> AVCaptureDevice? {
        AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
    }

    nonisolated private static func zoomRange(for device: AVCaptureDevice) -> (base: CGFloat, lowest: CGFloat, highest: CGFloat) {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        var base: CGFloat = 1
        if hasUltraWide {
            base = device.virtualDeviceSwitchOverVideoZoomFactors.first.map { CGFloat(truncating: $0) } ?? 2
        }
        let lowest = max(0.5, device.minAvailableVideoZoomFactor / base)
        let highest = min(10, device.maxAvailableVideoZoomFactor / base)
        return (base, lowest, max(lowest, highest))
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let session = self.session
        let output = self.output
        queue.async { [weak self] in
            session.beginConfiguration()
            session.sessionPreset = .photo
            // Leave the app's audio alone so staying connected to Claude keeps working.
            session.automaticallyConfiguresApplicationAudioSession = false
            var base: CGFloat = 1
            var lowest: CGFloat = 1
            var highest: CGFloat = 1
            if let device = CameraModel.bestDevice(),
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
                let range = CameraModel.zoomRange(for: device)
                base = range.base
                lowest = range.lowest
                highest = range.highest
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, base))
                    device.unlockForConfiguration()
                } catch {}
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            CameraModel.turnUpright(output)
            session.commitConfiguration()
            let readyBase = base
            let readyLowest = lowest
            let readyHighest = highest
            Task { @MainActor in
                self?.deviceReady(base: readyBase, lowest: readyLowest, highest: readyHighest)
            }
        }
    }

    private func deviceReady(base: CGFloat, lowest: CGFloat, highest: CGFloat) {
        zoomBase = base
        minZoom = lowest
        maxZoom = highest
        setZoom(zoomByView[target] ?? 1)
    }

    /// The app stays upright, so photos are taken as portrait.
    nonisolated private static func turnUpright(_ output: AVCapturePhotoOutput) {
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
    }

    // MARK: Zoom and focus

    func setZoom(_ value: CGFloat) {
        let clamped = min(maxZoom, max(minZoom, value))
        zoom = clamped
        zoomByView[target] = clamped
        let session = self.session
        let factor = clamped * zoomBase
        queue.async {
            guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = min(device.maxAvailableVideoZoomFactor, max(device.minAvailableVideoZoomFactor, factor))
                device.unlockForConfiguration()
            } catch {}
        }
    }

    func pinchBegan() {
        pinchStart = zoom
    }

    func pinchChanged(_ scale: CGFloat) {
        setZoom(pinchStart * scale)
    }

    func focus(atDevicePoint point: CGPoint) {
        let session = self.session
        queue.async {
            guard let device = (session.inputs.first as? AVCaptureDeviceInput)?.device else { return }
            do {
                try device.lockForConfiguration()
                if device.isFocusPointOfInterestSupported {
                    device.focusPointOfInterest = point
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    device.exposureMode = .autoExpose
                }
                device.unlockForConfiguration()
            } catch {}
        }
    }

    // MARK: The faint last photo

    func loadGhost(for view: PlantView) {
        ghost = nil
        Task { [weak self] in
            guard let last = PhotoService.shared.assets(in: view).last else { return }
            let picture = await PhotoService.shared.image(for: last, longEdge: 900)
            guard let self = self, self.target == view else { return }
            self.ghost = picture
        }
    }

    // MARK: Taking a photo

    func capture(view: PlantView) {
        guard running, !busy else { return }
        target = view
        busy = true
        message = ""
        output.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    fileprivate func finishCapture(data: Data?, failure: String?) async {
        defer { busy = false }
        guard let data = data else {
            message = failure ?? "Couldn't take the photo."
            return
        }
        let view = target
        do {
            try await save(data, to: view)
            message = "Saved to \(view.albumName)"
        } catch {
            message = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func save(_ data: Data, to view: PlantView) async throws {
        guard let collection = try PhotoService.shared.album(for: view, create: true) else {
            throw CaptureError.noAlbum
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
            if let albumRequest = PHAssetCollectionChangeRequest(for: collection),
               let placeholder = request.placeholderForCreatedAsset {
                albumRequest.addAssets([placeholder] as NSArray)
            }
        }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let data = photo.fileDataRepresentation()
        let failure = error?.localizedDescription
        Task { @MainActor in
            await self.finishCapture(data: data, failure: failure)
        }
    }
}

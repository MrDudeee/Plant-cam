import AVFoundation
import Photos
import SwiftUI
import UIKit

enum Lens: String, CaseIterable, Identifiable {
    case wide, ultraWide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wide: return "1\u{00D7}"
        case .ultraWide: return "0.5\u{00D7} (close-up)"
        }
    }

    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide: return .builtInWideAngleCamera
        case .ultraWide: return .builtInUltraWideCamera
        }
    }
}

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
    @Published var lens: Lens = .wide {
        didSet { if lens != oldValue { switchLens() } }
    }

    let hasUltraWide = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil

    private let output = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "plantcam.camera")
    private var configured = false
    private var target: PlantView = .side

    // MARK: Start and stop

    func start(view: PlantView) async {
        target = view
        if permission == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        permission = AVCaptureDevice.authorizationStatus(for: .video)
        guard permission == .authorized else { return }
        applyDefaultLens(for: view)
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
        applyDefaultLens(for: view)
        loadGhost(for: view)
    }

    /// Close-ups of the nodes start on the wide-angle lens, which can focus closest.
    private func applyDefaultLens(for view: PlantView) {
        let wanted: Lens = (view == .nodes && hasUltraWide) ? .ultraWide : .wide
        if lens != wanted { lens = wanted }
    }

    // MARK: Setting up the camera

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        let session = self.session
        let output = self.output
        let type = lens.deviceType
        queue.async {
            session.beginConfiguration()
            session.sessionPreset = .photo
            // Leave the app's audio alone so staying connected to Claude keeps working.
            session.automaticallyConfiguresApplicationAudioSession = false
            let device = AVCaptureDevice.default(type, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            if let device = device,
               let input = try? AVCaptureDeviceInput(device: device),
               session.canAddInput(input) {
                session.addInput(input)
            }
            if session.canAddOutput(output) {
                session.addOutput(output)
            }
            CameraModel.turnUpright(output)
            session.commitConfiguration()
        }
    }

    private func switchLens() {
        guard configured else { return }
        let session = self.session
        let output = self.output
        let type = lens.deviceType
        queue.async {
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back),
                  let replacement = try? AVCaptureDeviceInput(device: device) else { return }
            session.beginConfiguration()
            for old in session.inputs {
                session.removeInput(old)
            }
            if session.canAddInput(replacement) {
                session.addInput(replacement)
            }
            CameraModel.turnUpright(output)
            session.commitConfiguration()
        }
    }

    /// The app stays upright, so photos are taken as portrait.
    nonisolated private static func turnUpright(_ output: AVCapturePhotoOutput) {
        if let connection = output.connection(with: .video), connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
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

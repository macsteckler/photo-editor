import AVFoundation
import CoreVideo
import UIKit

/// Captures RAW stills and provides viewfinder frames.
///
/// "RAW" mode captures the sensor's Bayer data: a single frame with none of Apple's
/// processing (no Deep Fusion/Smart HDR, no tone mapping, no sharpening).
/// "ProRAW" mode is Apple's multi-frame computational RAW (48 MP on supported cameras).
final class CameraModel: NSObject, ObservableObject {
    enum RawMode: String, CaseIterable, Identifiable {
        case bayer = "RAW", proRAW = "ProRAW"
        var id: String { rawValue }
    }

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "nitrate.session")
    private let videoQueue = DispatchQueue(label: "nitrate.video")
    private var device: AVCaptureDevice?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var configured = false

    @Published var rawMode: RawMode = .bayer
    @Published var proRAWSupported = false
    @Published var authorized = true
    @Published var lastError: String?
    @Published var shutterFlash = false

    /// Called on a background queue with the DNG data of each capture.
    var onCapture: ((Data) -> Void)?

    private let frameLock = NSLock()
    private var frame: CVPixelBuffer?
    /// Latest viewfinder frame (BGRA, portrait-oriented).
    var latestFrame: CVPixelBuffer? {
        frameLock.lock(); defer { frameLock.unlock() }
        return frame
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { ok in
                DispatchQueue.main.async { self.authorized = ok }
                if ok { self.startSession() }
            }
        default:
            authorized = false
        }
    }

    func stop() {
        sessionQueue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func startSession() {
        sessionQueue.async {
            if !self.configured { self.configure() }
            if !self.session.isRunning { self.session.startRunning() }
        }
    }

    private func configure() {
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: dev), session.canAddInput(input),
              session.canAddOutput(photoOutput) else {
            session.commitConfiguration()
            publishError("The camera is not available.")
            return
        }
        session.addInput(input)
        session.addOutput(photoOutput)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if let c = videoOutput.connection(with: .video), c.isVideoRotationAngleSupported(90) {
            c.videoRotationAngle = 90 // portrait viewfinder
        }

        if let maxDims = dev.activeFormat.supportedMaxPhotoDimensions.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) {
            photoOutput.maxPhotoDimensions = maxDims
        }
        let pro = photoOutput.isAppleProRAWSupported
        if pro { photoOutput.isAppleProRAWEnabled = true }
        session.commitConfiguration()

        device = dev
        rotation = AVCaptureDevice.RotationCoordinator(device: dev, previewLayer: nil)
        configured = true
        DispatchQueue.main.async { self.proRAWSupported = pro }
    }

    func capture() {
        let mode = rawMode
        sessionQueue.async {
            let formats = self.photoOutput.availableRawPhotoPixelFormatTypes
            let preferred: OSType? = mode == .proRAW
                ? formats.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) })
                : formats.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
            guard let format = preferred ?? formats.first else {
                self.publishError("RAW capture isn't available on this camera.")
                return
            }
            let settings = AVCapturePhotoSettings(rawPixelFormatType: format)
            if AVCapturePhotoOutput.isAppleProRAWPixelFormat(format) {
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
            } else {
                settings.photoQualityPrioritization = .speed
            }
            if let conn = self.photoOutput.connection(with: .video), let r = self.rotation {
                let angle = r.videoRotationAngleForHorizonLevelCapture
                if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
            }
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    /// Tap-to-focus/expose. `point` is normalised in the portrait viewfinder.
    func focus(at point: CGPoint) {
        sessionQueue.async {
            guard let dev = self.device, (try? dev.lockForConfiguration()) != nil else { return }
            let p = CGPoint(x: point.y, y: 1 - point.x) // portrait view -> sensor (landscape) coordinates
            if dev.isFocusPointOfInterestSupported { dev.focusPointOfInterest = p; dev.focusMode = .autoFocus }
            if dev.isExposurePointOfInterestSupported { dev.exposurePointOfInterest = p; dev.exposureMode = .autoExpose }
            dev.unlockForConfiguration()
        }
    }

    private func publishError(_ message: String) {
        DispatchQueue.main.async { self.lastError = message }
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        DispatchQueue.main.async {
            self.shutterFlash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { self.shutterFlash = false }
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            publishError(error.localizedDescription)
            return
        }
        guard photo.isRawPhoto, let data = photo.fileDataRepresentation() else {
            publishError("The camera did not return RAW data.")
            return
        }
        onCapture?(data)
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameLock.lock()
        frame = pb
        frameLock.unlock()
    }
}

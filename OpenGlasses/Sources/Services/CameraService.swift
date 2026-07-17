import Foundation
import AVFoundation
import Combine
import Photos
import MWDATCore
import MWDATCamera
import UIKit

/// Service for capturing photos and streaming video from Ray-Ban Meta smart glasses.
///
/// Uses a persistent `DeviceSession` + `Stream` pair for both photo capture and
/// video streaming, following Meta's official sample app pattern (DAT SDK 0.7+).
@MainActor
class CameraService: ObservableObject {
    @Published var lastPhoto: UIImage?
    @Published var isCaptureInProgress: Bool = false
    @Published var isStreaming: Bool = false
    @Published var streamingStatus: StreamingStatus = .stopped

    enum StreamingStatus: String {
        case streaming, waiting, stopped
    }

    /// Lazily initialized after Wearables.configure() has been called.
    private lazy var deviceSelector = AutoDeviceSelector(wearables: Wearables.shared)
    private var deviceSession: DeviceSession?
    private var streamSession: MWDATCamera.Stream?
    private var photoListenerToken: (any AnyListenerToken)?
    private var stateListenerToken: (any AnyListenerToken)?
    private var videoFrameListenerToken: (any AnyListenerToken)?
    private var errorListenerToken: (any AnyListenerToken)?
    private var photoContinuation: CheckedContinuation<Data, Error>?
    /// Debounced post-capture teardown — keeps the camera session warm for rapid follow-up questions.
    private var teardownTask: Task<Void, Never>?

    /// Whether camera permission has been granted (cached to avoid re-checking).
    var permissionGranted = false

    /// Callback for continuous video frames (used by Gemini Live mode)
    var onVideoFrame: ((UIImage) -> Void)?

    /// Debug event callback for connection status logging
    var onDebugEvent: ((String) -> Void)?

    /// Combine publisher for video frames (used by recording/broadcast services).
    let framePublisher = PassthroughSubject<UIImage, Never>()

    /// The most recent video frame captured from the glasses camera
    private(set) var latestFrame: UIImage?

    /// Optional callback to report SDK registration progress (state 0–3) back to UI.
    var onRegistrationProgress: ((Int) -> Void)?

    // MARK: - HEVC Decoder Stall Detection
    /// Timestamp of the last successfully decoded video frame.
    private var lastFrameTime: Date = .distantPast
    /// Stall detection timer — fires if no frame arrives for 1.5 seconds.
    private var stallDetectionTask: Task<Void, Never>?
    /// Whether we're currently recovering from a stall (prevents re-entrant recovery).
    private var isRecoveringFromStall = false
    /// Number of consecutive stall recoveries (for diagnostics).
    private var stallRecoveryCount = 0

    /// iPhone back-camera fallback, used when the glasses camera is unavailable.
    private let phoneSource = PhoneCameraSource()

    /// Name of the Photos album where glasses photos are saved.
    private nonisolated static let albumName = "Glasses"

    // MARK: - Permission

    private func waitForRegistration(minState: Int, timeoutSeconds: Double) async -> Int {
        let waitStart = ContinuousClock.now
        while true {
            let state = Wearables.shared.registrationState.rawValue
            onRegistrationProgress?(state)
            if state >= minState { return state }
            if ContinuousClock.now - waitStart > .seconds(timeoutSeconds) { return state }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func ensurePermission() async throws {
        if permissionGranted { return }

        let regState = Wearables.shared.registrationState
        NSLog("[Camera] SDK state: %d (need 3 for camera permissions)", regState.rawValue)
        onRegistrationProgress?(regState.rawValue)

        // iOS Camera Permission
        let iosVideoStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if iosVideoStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted { throw CameraError.permissionDenied }
        } else if iosVideoStatus == .denied || iosVideoStatus == .restricted {
            throw CameraError.permissionDenied
        }

        // Wait for full SDK registration
        let settledState = await waitForRegistration(minState: 3, timeoutSeconds: 15)
        if settledState < 3 {
            NSLog("[Camera] State %d is not fully registered.", settledState)
            throw CameraError.sdkNotRegistered
        }

        // Check/request Meta camera permission with retries
        let maxAttempts = 3
        for attempt in 0..<maxAttempts {
            if attempt > 0 {
                NSLog("[Camera] Permission retry %d/%d...", attempt + 1, maxAttempts)
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }

            do {
                let readyState = await waitForRegistration(minState: 3, timeoutSeconds: 10)
                if readyState < 3 { throw CameraError.sdkNotRegistered }

                let status = try await Wearables.shared.checkPermissionStatus(.camera)
                NSLog("[Camera] checkPermissionStatus: %@", String(describing: status))
                if status == .granted {
                    permissionGranted = true
                    return
                }

                let requestStatus = try await Wearables.shared.requestPermission(.camera)
                guard requestStatus == .granted else { throw CameraError.permissionDenied }
                permissionGranted = true
                return
            } catch {
                NSLog("[Camera] Permission attempt %d/%d failed: %@",
                      attempt + 1, maxAttempts, error.localizedDescription)

                if let nsError = error as NSError?, nsError.domain == "MWDATCore.PermissionError" {
                    let currentState = Wearables.shared.registrationState.rawValue
                    if currentState < 3 { throw CameraError.sdkNotRegistered }
                }
                if (error as? CameraError) == .permissionDenied { throw error }
                if attempt == maxAttempts - 1 { throw CameraError.sdkNotRegistered }
            }
        }
    }

    // MARK: - Persistent Session

    /// Ensure the persistent stream session exists. Creates it on first call.
    private func ensureSession() async throws {
        guard streamSession == nil else { return }

        // DAT 0.7: DeviceSession owns the connection; Streams hang off it.
        if deviceSession?.state == .stopped {
            deviceSession = nil
        }

        if deviceSession == nil {
            deviceSession = try Wearables.shared.createSession(deviceSelector: deviceSelector)
        }

        guard let deviceSession else { throw CameraError.captureFailed }

        if deviceSession.state != .started {
            try deviceSession.start()
            let deadline = ContinuousClock.now + .seconds(20)
            while ContinuousClock.now < deadline {
                if deviceSession.state == .started { break }
                if deviceSession.state == .stopped { break }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        guard deviceSession.state == .started else {
            throw CameraError.streamNotReady
        }

        let resolution: StreamingResolution = {
            switch Config.cameraResolution {
            case "low": return .low
            case "medium": return .medium
            default: return .high
            }
        }()
        let fps = UInt(Config.cameraFrameRate)
        guard let stream = try deviceSession.addStream(
            config: MWDATCamera.StreamConfiguration(
                videoCodec: .raw,
                resolution: resolution,
                frameRate: fps
            )
        ) else {
            throw CameraError.streamNotReady
        }
        streamSession = stream
        attachListeners(to: stream)
        NSLog("[Camera] Created persistent Stream (.\(Config.cameraResolution), \(fps)fps)")
    }

    /// Attach all publishers to the session (state, video frames, photo data, errors).
    private func attachListeners(to session: MWDATCamera.Stream) {
        var frameCount = 0

        stateListenerToken = session.statePublisher.listen { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                NSLog("[Camera] State changed: %@", String(describing: state))
                switch state {
                case .streaming:
                    self.streamingStatus = .streaming
                case .waitingForDevice:
                    self.streamingStatus = .waiting
                case .stopped:
                    self.streamingStatus = .stopped
                    self.isStreaming = false
                case .stopping, .starting, .paused:
                    self.streamingStatus = .waiting
                @unknown default:
                    break
                }
            }
        }

        videoFrameListenerToken = session.videoFramePublisher.listen { [weak self] frame in
            // Immediate pixel buffer copy: `makeUIImage()` copies the pixel data out of
            // the VideoToolbox buffer pool right away, preventing VT pool exhaustion
            // that can occur if the buffer is held across async boundaries.
            let image = frame.makeUIImage()
            Task { @MainActor in
                guard let self, let image else { return }
                frameCount += 1
                self.lastFrameTime = Date()
                self.latestFrame = image
                if frameCount <= 3 || frameCount % 30 == 0 {
                    NSLog("[Camera] Video frame #%d (%dx%d)",
                          frameCount, Int(image.size.width), Int(image.size.height))
                }
                self.onVideoFrame?(image)
                self.framePublisher.send(image)
            }
        }

        photoListenerToken = session.photoDataPublisher.listen { [weak self] photoData in
            Task { @MainActor in
                self?.handlePhotoData(photoData)
            }
        }

        errorListenerToken = session.errorPublisher.listen { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                let message = CameraErrorPolicy.message(for: error)
                NSLog("[Camera] Error: %@", message)
                self.onDebugEvent?("Camera error: \(message)")

                // Fail a pending capture fast on a terminal error (hinges closed, thermal/battery
                // shutdown, device gone) instead of waiting out the 5s timeout below.
                if CameraErrorPolicy.abortsCapture(error), let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    if let fallback = self.latestFrameAsJPEG() {
                        NSLog("[Camera] Terminal error during capture — using latest video frame")
                        cont.resume(returning: fallback)
                    } else {
                        cont.resume(throwing: CameraError.captureFailed)
                    }
                }
            }
        }
    }

    /// Wait for the session to reach `.streaming` state, starting it if necessary.
    private func waitForStreaming(timeout: TimeInterval = 20) async throws {
        guard let session = streamSession else { throw CameraError.captureFailed }

        // Start the session if not already running
        if session.state == .stopped {
            session.start()  // DAT 0.8.0: Stream.start() is synchronous
        }

        // Wait for streaming state. The DAT 0.8.0 stream bounces through
        // stopped/waitingForDevice during a cold start (~15-18s on this hardware), so a
        // transient .stopped is NOT fatal — nudge start() again and keep waiting within
        // the single deadline. Throwing here used to trigger a reset that killed the
        // stream 1-2s before it came up (observed 2026-07-16).
        let deadline = ContinuousClock.now + .seconds(timeout)
        var restartNudges = 0
        while ContinuousClock.now < deadline {
            if session.state == .streaming { break }
            if session.state == .stopped && restartNudges < 3 {
                restartNudges += 1
                NSLog("[Camera] Stream idle during warm-up — nudging start() (%d)", restartNudges)
                session.start()
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        if session.state != .streaming {
            throw CameraError.streamNotReady
        }

        // Wait for the first video frame to actually arrive — the state becomes
        // .streaming before data flows, and capturePhoto won't work until then.
        NSLog("[Camera] Streaming state reached, waiting for first video frame...")
        while ContinuousClock.now < deadline {
            if latestFrame != nil { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }

        // Even if no frame arrived, let the caller proceed (fallback will handle it)
        NSLog("[Camera] No video frame arrived within timeout, proceeding anyway")
    }

    // MARK: - Photo Capture

    /// Capture a photo from the glasses camera. Returns JPEG data.
    /// Reuses the persistent session — starts it if needed, does NOT stop it after capture.
    func capturePhoto() async throws -> Data {
        // Glasses are usable for the camera only once fully registered (state 3). When
        // they're offline / not connected / not registered, capture from the iPhone back
        // camera instead so the vision tools keep working without glasses.
        if Wearables.shared.registrationState.rawValue < 3 {
            NSLog("[Camera] Glasses not registered (state < 3) — capturing from iPhone back camera")
            return try await phoneSource.capturePhoto()
        }
        do {
            return try await captureFromGlasses()
        } catch {
            NSLog("[Camera] Glasses capture failed (%@) — falling back to iPhone back camera",
                  error.localizedDescription)
            return try await phoneSource.capturePhoto()
        }
    }

    /// Capture a photo from the glasses camera. Returns JPEG data.
    private func captureFromGlasses() async throws -> Data {
        isCaptureInProgress = true
        defer { isCaptureInProgress = false }

        // Reuse a still-warm session from a recent capture (cancel its pending teardown).
        teardownTask?.cancel()
        teardownTask = nil

        try await ensurePermission()

        // Establish session + stream with retries. Session creation lives INSIDE the
        // retry loop: MWDAT needs settle time after a reset, and a too-eager recreate
        // throws "A session already exists for this device" (seen 2026-07-16), which
        // previously escaped the loop and dumped the capture onto the iPhone camera.
        var lastError: Error?
        for attempt in 1...2 {
            do {
                try await ensureSession()
                // Generous single window — the camera cold-starts in ~15-18s and the
                // wait loop now tolerates the warm-up bounce without being reset.
                try await waitForStreaming(timeout: 30)
                lastError = nil
                break
            } catch {
                NSLog("[Camera] Stream setup attempt %d failed: %@", attempt, error.localizedDescription)
                lastError = error
                if attempt < 2 {
                    await resetSession()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        if let error = lastError { throw error }

        // Capture using continuation — with video frame fallback
        let photoData: Data = try await withCheckedThrowingContinuation { continuation in
            self.photoContinuation = continuation

            NSLog("[Camera] Calling capturePhoto(format: .jpeg)...")
            let success = streamSession!.capturePhoto(format: .jpeg)
            if !success {
                self.photoContinuation = nil
                // capturePhoto returned false — fall back to latest video frame
                if let fallback = self.latestFrameAsJPEG() {
                    NSLog("[Camera] capturePhoto returned false, using latest video frame")
                    continuation.resume(returning: fallback)
                } else {
                    continuation.resume(throwing: CameraError.captureFailed)
                }
                return
            }

            // Timeout after 8 seconds — fall back to latest video frame
            Task {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if let cont = self.photoContinuation {
                    self.photoContinuation = nil
                    if let fallback = self.latestFrameAsJPEG() {
                        NSLog("[Camera] Photo capture timed out, using latest video frame (%d bytes)", fallback.count)
                        cont.resume(returning: fallback)
                    } else {
                        NSLog("[Camera] Photo capture timed out, no video frame available")
                        cont.resume(throwing: CameraError.timeout)
                    }
                }
            }
        }

        if let image = UIImage(data: photoData) {
            lastPhoto = image
        }

        // Tear down session after capture to save battery (unless explicitly streaming).
        // Full reset is required because MWDAT StreamSession can't reliably restart
        // after stop — a fresh session must be created for the next capture.
        if !isStreaming {
            teardownTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000_000)
                guard let self, !Task.isCancelled else { return }
                if !self.isStreaming && !self.isCaptureInProgress {
                    NSLog("[Camera] Keep-warm window elapsed — tearing down session")
                    await self.resetSession()
                }
            }
        }

        print("📸 Photo captured: \(photoData.count) bytes")
        return photoData
    }

    private func handlePhotoData(_ photoData: PhotoData) {
        guard let continuation = photoContinuation else {
            NSLog("[Camera] Photo data received but no continuation waiting (timeout may have fired first)")
            return
        }
        photoContinuation = nil
        NSLog("[Camera] Photo captured via SDK (%d bytes)", photoData.data.count)
        continuation.resume(returning: photoData.data)
    }

    /// Convert the latest video frame to JPEG data for use as a photo fallback.
    private func latestFrameAsJPEG(quality: CGFloat = 0.85) -> Data? {
        guard let frame = latestFrame else { return nil }
        return frame.jpegData(compressionQuality: quality)
    }

    // MARK: - Continuous Video Streaming (for Gemini Live)

    /// Start continuous video streaming from the glasses camera.
    func startStreaming() async throws {
        guard !isStreaming else { return }

        try await ensurePermission()
        try await ensureSession()
        try await waitForStreaming()

        isStreaming = true
        startStallDetection()
        NSLog("[Camera] Streaming started")
    }

    /// Stop continuous video streaming. Session is kept alive for reuse.
    func stopStreaming() async {
        guard isStreaming else { return }
        stopStallDetection()
        if let session = streamSession {
            session.stop()
        }
        isStreaming = false
        latestFrame = nil
        NSLog("[Camera] Streaming stopped (session kept alive)")
    }

    // MARK: - HEVC Decoder Stall Detection & Auto-Recovery

    /// Start monitoring for decoder stalls (no frames for 1.5 seconds).
    /// If a stall is detected, the session is torn down and recreated.
    private func startStallDetection() {
        stopStallDetection()
        lastFrameTime = Date()
        stallDetectionTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000) // Check every 0.5s
                guard !Task.isCancelled, let self else { break }
                guard self.isStreaming, !self.isRecoveringFromStall else { continue }

                let elapsed = Date().timeIntervalSince(self.lastFrameTime)
                if elapsed > 1.5 {
                    NSLog("[Camera] ⚠️ Decoder stall detected (%.1fs since last frame) — auto-recovering", elapsed)
                    self.isRecoveringFromStall = true
                    self.stallRecoveryCount += 1
                    await self.recoverFromStall()
                    self.isRecoveringFromStall = false
                }
            }
        }
    }

    /// Stop stall detection monitoring.
    private func stopStallDetection() {
        stallDetectionTask?.cancel()
        stallDetectionTask = nil
    }

    /// Tear down and recreate the stream session to recover from a decoder stall.
    private func recoverFromStall() async {
        NSLog("[Camera] Stall recovery #%d — resetting session", stallRecoveryCount)
        onDebugEvent?("Camera stall recovery #\(stallRecoveryCount)")

        // Tear down the current session
        await resetSession()

        // Recreate
        do {
            try await ensureSession()
            try await waitForStreaming()
            lastFrameTime = Date()
            NSLog("[Camera] Stall recovery successful — streaming resumed")
        } catch {
            NSLog("[Camera] Stall recovery failed: %@", error.localizedDescription)
            isStreaming = false
        }
    }

    /// Reset the session completely (for error recovery).
    private func resetSession() async {
        if let session = streamSession {
            session.stop()
        }
        deviceSession?.stop()
        stateListenerToken = nil
        videoFrameListenerToken = nil
        photoListenerToken = nil
        errorListenerToken = nil
        streamSession = nil
        deviceSession = nil
        latestFrame = nil
        NSLog("[Camera] Session reset")
    }

    /// Tear down everything — called on mode switch or app termination.
    func tearDown() async {
        await stopStreaming()
        await resetSession()
        permissionGranted = false
        NSLog("[Camera] Torn down completely")
    }

    // MARK: - Photo Library

    /// Save photo data to the "Glasses" album in the photo library.
    func saveToPhotoLibrary(_ data: Data) {
        guard let image = UIImage(data: data) else { return }

        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                NSLog("[Camera] Photo library access denied")
                return
            }

            // Fetch/create album BEFORE performChanges to avoid nested change block deadlock
            let album = self.fetchGlassesAlbum()

            PHPhotoLibrary.shared().performChanges {
                let creationRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)

                if let album {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    if let placeholder = creationRequest.placeholderForCreatedAsset {
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                    }
                }
            } completionHandler: { success, error in
                if success {
                    print("📸 Photo saved to Glasses album")
                } else if let error {
                    NSLog("[Camera] Save to album failed: %@", error.localizedDescription)
                    // Fallback: save without album
                    UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                    print("📸 Photo saved to camera roll (album unavailable)")
                }
            }
        }
    }

    /// Fetch the "Glasses" album, creating it if it doesn't exist.
    private nonisolated func fetchGlassesAlbum() -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", CameraService.albumName)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)

        if let existing = collections.firstObject {
            return existing
        }

        // Create the album synchronously
        var localIdentifier: String?
        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let createRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: CameraService.albumName)
                localIdentifier = createRequest.placeholderForCreatedAssetCollection.localIdentifier
            }
        } catch {
            NSLog("[Camera] Failed to create Glasses album: %@", error.localizedDescription)
            return nil
        }

        guard let identifier = localIdentifier else { return nil }
        let result = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil)
        return result.firstObject
    }

    // MARK: - Audio Session Helpers

    /// Restore audio session configuration for wake word detection after camera streaming.
    func restoreAudioForWakeWord() {
        // No-op: audio session management is handled by WakeWordService
    }

    // Error mapping now lives in the pure, typed `CameraErrorPolicy` (DAT 0.8.0 unified errors).
}

enum CameraError: LocalizedError {
    case permissionDenied
    case captureFailed
    case timeout
    case notConnected
    case sdkNotRegistered
    case streamNotReady

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Camera permission denied"
        case .captureFailed: return "Failed to capture photo"
        case .timeout: return "Photo capture timed out"
        case .notConnected: return "Glasses not connected"
        case .sdkNotRegistered: return "Meta SDK not registered — open Meta app first"
        case .streamNotReady: return "Camera stream not ready — try again"
        }
    }
}

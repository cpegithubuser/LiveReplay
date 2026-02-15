//
//  CameraManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 1/29/25.
//

import AVKit
import CoreMedia
import Combine

final class CameraManager: NSObject, ObservableObject {
    // MARK: - Discovery helpers (single source of truth)

    /// Preferred camera types for this app.
    /// Keep the list small and predictable: front wide + back wide/ultrawide/tele.
    static let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .builtInUltraWideCamera,
        .builtInTelephotoCamera
    ]

    /// Discover devices without mutating CameraManager state.
    /// - Parameters:
    ///   - allTypes: when true, returns devices across all positions/types (for inspection).
    ///   - location: used only when `allTypes == false`.
    func discoverDevices(allTypes: Bool, location: CameraPosition) -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        let position: AVCaptureDevice.Position

        if allTypes {
            types = Self.preferredDeviceTypes
            position = .unspecified
        } else {
            switch location {
            case .back:
                types = [
                    .builtInWideAngleCamera,
                    .builtInTelephotoCamera,
                    .builtInUltraWideCamera,
                    .builtInDualCamera
                ]
            case .front:
                types = [
                    .builtInWideAngleCamera,
                    .builtInTrueDepthCamera
                ]
            }
            position = location.avPosition
        }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: position
        )

        return discovery.devices.sorted { a, b in
            if a.position != b.position {
                let rank: (AVCaptureDevice.Position) -> Int = { pos in
                    switch pos {
                    case .back: return 0
                    case .front: return 1
                    default: return 2
                    }
                }
                return rank(a.position) < rank(b.position)
            }
            return a.localizedName < b.localizedName
        }
    }

    /// Convenience: preferred devices across both front/back.
    /// This is what SettingsView should present as "Camera" choices.
    func discoverPreferredDevices() -> [AVCaptureDevice] {
        discoverDevices(allTypes: true, location: cameraLocation)
    }

    /// Discover formats for a device without mutating CameraManager state.
    /// - Parameters:
    ///   - allFormats: when true, returns all formats.
    func discoverFormats(allFormats: Bool, device: AVCaptureDevice) -> [AVCaptureDevice.Format] {
        var formats: [AVCaptureDevice.Format]

        if allFormats {
            formats = device.formats
        } else {
            let videoRangeType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // "420v"
            let wantedResolutions: [(Int32, Int32)] = [
                (1280, 720),
                (1920, 1080),
                (3840, 2160)
            ]

            formats = device.formats.filter { fmt in
                let desc = fmt.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let mediaSub = CMFormatDescriptionGetMediaSubType(desc)
                return mediaSub == videoRangeType
                    && wantedResolutions.contains { $0.0 == dims.width && $0.1 == dims.height }
            }
        }

        // Stable ordering: larger resolution first, then higher max FPS.
        formats.sort {
            let aDesc = $0.formatDescription
            let bDesc = $1.formatDescription
            let aDims = CMVideoFormatDescriptionGetDimensions(aDesc)
            let bDims = CMVideoFormatDescriptionGetDimensions(bDesc)

            if aDims.width != bDims.width { return aDims.width > bDims.width }
            if aDims.height != bDims.height { return aDims.height > bDims.height }

            let aFPS = $0.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            let bFPS = $1.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
            return aFPS > bFPS
        }

        return formats
    }
    
    static let shared = CameraManager()

    /// Computed properties to avoid dependency cycles
    var playbackManager: PlaybackManager { .shared }
    var bufferManager: BufferManager { .shared }
    
    private let sessionQueue = DispatchQueue(label: "com.myapp.camera.sessionQueue")
    
    let writerQueue = DispatchQueue(
        label: "com.myapp.camera.writerQueue",
        qos: .userInitiated
    )

    private let captureQueue = DispatchQueue(
        label: "com.myapp.camera.captureQueue",
 //       qos: .userInteractive
        qos: .userInitiated
    )

    /// Gate capture/writer while backgrounding or doing hard resets.
    /// Minimal strategy: when true, captureOutput should early-return and writerQueue work should bail.
    @Published var isBackgroundedOrShuttingDown: Bool = false
    
    /// True while a camera flip is in progress. Used to prevent transient mirroring/connection tweaks
    /// from applying to the outgoing preview/player before the queue is cleared.
    @Published var isCameraSwitchInProgress: Bool = false
    
    // This is the number of frames that we dropped/skipped in captureoutput. We will drop a few when the session starts to eliminate dark frames.
    var droppedFrames: Int = 0
    
    @Published var cameraSession: AVCaptureSession? = nil
    
    @Published var cameraAspectRatio: CGFloat = 4.0/3.0
    
    var delegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    
    //asset writer
    let assetWriterInterval: Double = 1.0 // seconds (segment length)
    lazy var segmentDuration = CMTimeMake(value: Int64(assetWriterInterval * 10), timescale: 10)
    
    var assetWriter: AVAssetWriter!
    var videoInput: AVAssetWriterInput!
    var startTime: CMTime!

    var initializationData = Data()
    
    var writerStarted = false
    
    /// Throttle lightweight writer re-creation attempts (used by captureOutput self-heal).
    private var lastWriterRecreateAttemptTime: CFTimeInterval = 0
    
    /// When true, write each segment to disk as segment_N.mp4 in debugSegmentsFolder; folder is cleared on launch.
    var debugWriteSegmentsToDisk: Bool = false
    private static let debugSegmentsFolderName = "debug_segments"
    
//    @Published var cameraLocation: AVCaptureDevice.Position = .back {
//        didSet {
//            configureCamera()
//            handleDeviceOrientationChange()
//        }
//    }
    
    enum CameraPosition {
        case back, front
        var avPosition: AVCaptureDevice.Position {
            switch self {
            case .back:  return .back
            case .front: return .front
            }
        }
    }

    // MARK: - Best-effort camera switching helpers (size/fps buckets + format preference)

    enum VideoSizeBucket {
        case k4, p1080, p720
    }

    enum FPSBucket: Int, CaseIterable {
        case fps30 = 30
        case fps60 = 60
        case fps120 = 120
        case fps240 = 240

        /// Descending order (highest first)
        static var descending: [FPSBucket] { [.fps240, .fps120, .fps60, .fps30] }
    }

    private func sizeBucket(for format: AVCaptureDevice.Format) -> VideoSizeBucket? {
        let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        switch (dims.width, dims.height) {
        case (3840, 2160): return .k4
        case (_, 1080):    return .p1080
        case (_, 720):     return .p720
        default:           return nil
        }
    }

    private func fpsBucket(for format: AVCaptureDevice.Format) -> FPSBucket {
        let fpsMax = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        if fpsMax >= 240 { return .fps240 }
        if fpsMax >= 120 { return .fps120 }
        if fpsMax >= 60  { return .fps60 }
        return .fps30
    }

    private func formatPreferenceKey(_ format: AVCaptureDevice.Format) -> (Int, Int) {
        // Lower is better: prefer non-HDR (0) over HDR (1), and prefer binned (0) over not binned (1).
        let hdrKey = format.isVideoHDRSupported ? 1 : 0
        let binnedKey = format.isVideoBinned ? 0 : 1
        return (hdrKey, binnedKey)
    }

    private func pickPreferredIndex(_ indices: [Int], in formats: [AVCaptureDevice.Format]) -> Int? {
        guard !indices.isEmpty else { return nil }
        return indices.min { a, b in
            let ka = formatPreferenceKey(formats[a])
            let kb = formatPreferenceKey(formats[b])
            if ka.0 != kb.0 { return ka.0 < kb.0 }
            if ka.1 != kb.1 { return ka.1 < kb.1 }
            return a < b
        }
    }

    private func oppositePosition(for position: AVCaptureDevice.Position) -> AVCaptureDevice.Position {
        switch position {
        case .back:  return .front
        case .front: return .back
        default:     return .unspecified
        }
    }
    @Published var cameraLocation: CameraPosition = .back {
        willSet {
            isCameraSwitchInProgress = true
            // Minimal camera-switch behavior: clear replay pipeline (buffer + player queue),
            // but do NOT do full background teardown.
            prepareForCameraSwitch()
            cancelAssetWriter()
        }
        didSet {
            updateAvailableDevices()
            initializeAssetWriter()
            // Once the new session/writer has been kicked off, allow mirroring updates again.
            // isCameraSwitchInProgress = false   // <--- REMOVED per instructions
        }
    }
    /// All AVCaptureDevices matching the current `cameraLocation`
    @Published var availableDevices: [AVCaptureDevice] = []

    /// The uniqueID of the device the user has picked
    @Published var selectedDeviceUniqueID: String = "" {
        willSet {
            cancelAssetWriter()
        }
        didSet {
            updateAvailableFormats()
            initializeCaptureSession()
            initializeAssetWriter()
        }
    }
    
    /// All the 420v formats (filtered to only 720p, 1080p, 4K) on the selected device
    @Published var availableFormats: [AVCaptureDevice.Format] = []

    /// Which format (by index into `availableFormats`) the user has picked
    @Published var selectedFormatIndex: Int = 0 {
        willSet {
            cancelAssetWriter()
        }
        didSet {
            guard availableFormats.indices.contains(selectedFormatIndex) else { return }
            // 1) recompute fps for the new format, but only 30/60/120/240 if supported
            let ranges = availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges
            let standardRates: [Double] = [30, 60, 120, 240]
            availableFrameRates = standardRates.filter { rate in
                ranges.contains { Double(rate) >= $0.minFrameRate && Double(rate) <= $0.maxFrameRate }
            }
            // pick first valid or fall back to 30
            selectedFrameRate = availableFrameRates.first ?? 30

            // 2) restart with new format+fps
            initializeCaptureSession()
            initializeAssetWriter()
        }
    }

    @Published var availableFrameRates: [Double] = []
    @Published var selectedFrameRate: Double = 0 {
        willSet {
            cancelAssetWriter()
        }
        didSet {
            initializeCaptureSession()
            initializeAssetWriter()
        }
    }
    

    private func updateAvailableDevices() {
        // Show only the preferred cameras for this app.
        let devices = discoverPreferredDevices()

        DispatchQueue.main.async {
            self.availableDevices = devices
            // make sure selectedDeviceUniqueID is valid
            if self.selectedDeviceUniqueID.isEmpty || !devices.map(\.uniqueID).contains(self.selectedDeviceUniqueID) {
                self.selectedDeviceUniqueID = devices.first?.uniqueID ?? ""
            }
            self.updateAvailableFormats()
            self.initializeCaptureSession()
        }
    }

    private func updateAvailableFormats() {
        guard let device = selectedDevice else {
            availableFormats = []
            selectedFormatIndex = 0
            return
        }

        // Back to filtered list: 420v/420f at 720p/1080p/4K.
        availableFormats = discoverFormats(allFormats: false, device: device)

        guard !availableFormats.isEmpty else {
            selectedFormatIndex = 0
            return
        }

        // Clamp the selected index safely.
        if !availableFormats.indices.contains(selectedFormatIndex) {
            selectedFormatIndex = 0
        }

        // Recompute FPS choices for the selected format.
        let ranges = availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges
        availableFrameRates = ranges.map { $0.maxFrameRate }.sorted()
        if !availableFrameRates.contains(selectedFrameRate) {
            selectedFrameRate = availableFrameRates.first ?? 30
        }
    }



    enum CameraError: Error {
        case noDevice, cannotAddInput, cannotAddOutput
    }
    
    /// convenience: the actual AVCaptureDevice the user picked
    var selectedDevice: AVCaptureDevice? {
        availableDevices.first { $0.uniqueID == selectedDeviceUniqueID }
    }
    
    @Published var captureVideoOrientation: AVCaptureVideoOrientation = .landscapeRight {
        didSet {
            if let connection = cameraSession?.outputs.first?.connections.first {
//                connection.videoOrientation = captureVideoOrientation
                connection.videoOrientation = .landscapeRight
                print("captureVideoOrientation \(captureVideoOrientation)")
            }
        }
    }
    
    @Published var selectedVideoOrientation: AVCaptureVideoOrientation = .landscapeRight {
        didSet {
            // 1) update the live AVCaptureConnection
            if let conn = cameraSession?
                .outputs
                .compactMap({ $0 as? AVCaptureVideoDataOutput })
                .first?
                .connection(with: .video)
            {
                conn.videoOrientation = selectedVideoOrientation
            }

            // 2) re-initialize the writer to pick up the new orientation
            initializeAssetWriter()
        }
    }
    
    @Published var mirroredReplay = false {
        didSet {
            // Avoid a brief mirrored/unmirrored flash on the outgoing video while switching cameras.
            guard !isCameraSwitchInProgress else { return }
            if let connection = cameraSession?.outputs.first?.connections.first {
                if mirroredReplay == true {
                    connection.isVideoMirrored = true
                } else {
                    connection.isVideoMirrored = false
                }
            }
        }
    }

    override init() {
        super.init()
        if debugWriteSegmentsToDisk {
            clearDebugSegmentsFolder()
        }
        updateAvailableDevices()
        printAllCaptureDeviceFormats()
        // no run addDeviceOrientationObserver. just suppoerting landscape right to start
        // If you later want true device-orientation support, re-enable the observer:
        // addDeviceOrientationObserver()
        initializeCaptureSession()
    }
    // MARK: - Minimal background/foreground lifecycle

    /// Called when app is moving to background. Minimal behavior: stop capture, stop writer, clear buffer + playback queue.
    func stopForBackground() {
        // Gate immediately so any in-flight captureOutput work bails early.
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = true
        }

        // Stop capture session (no more buffers). Some buffers may still be in-flight, so
        // captureOutput must guard on isBackgroundedOrShuttingDown.
        cancelCaptureSession()

        // Cancel writer and clear writer state.
        cancelAssetWriter()

        // Clear replay pipeline deterministically:
        // 1) stop/clear the queue so the player releases items
        // 2) reset the buffer (safe now that capture is gated)
        PlaybackManager.shared.stopAndClearQueue {
            BufferManager.shared.resetBuffer()
        }
    }

    /// Called when app returns to foreground. Minimal behavior: restart capture + writer.
    func startAfterForeground() {
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = false
        }

        initializeCaptureSession()
        initializeAssetWriter()
    }

    // MARK: - Camera switch behavior

    /// Camera switch behavior: clear buffer + player queue; let existing didSet flows rebuild.
    func prepareForCameraSwitch() {
        droppedFrames = 0

        // Order matters:
        // 1) Stop/clear queue first so the player releases any current item before we mutate buffer/compositions.
        // 2) Then reset the buffer.
        // 3) Only then allow mirroring/connection changes again (prevents a brief flash on the outgoing video).
        PlaybackManager.shared.stopAndClearQueue { [weak self] in
            BufferManager.shared.resetBuffer()
            DispatchQueue.main.async {
                self?.isCameraSwitchInProgress = false
            }
        }
    }

    // MARK: - Best-effort flip (preserve intent, downgrade if needed)

    /// Flip front/back while preserving the user’s intent (size bucket + fps bucket).
    /// If the target camera cannot satisfy the intent, downgrade to the closest valid combination,
    /// then choose the preferred format (non-HDR, then binned).
    func flipCameraBestEffort() {
        // Capture intent from currently selected format.
        var desiredSize: VideoSizeBucket? = nil
        var desiredFPS: FPSBucket = .fps30

        if availableFormats.indices.contains(selectedFormatIndex) {
            let fmt = availableFormats[selectedFormatIndex]
            desiredSize = sizeBucket(for: fmt)
            desiredFPS = fpsBucket(for: fmt)
        }

        // Determine current physical position and target physical position.
        let currentPhysicalPosition: AVCaptureDevice.Position = selectedDevice?.position ?? cameraLocation.avPosition
        let targetPhysicalPosition: AVCaptureDevice.Position = oppositePosition(for: currentPhysicalPosition)

        // Toggle cameraLocation (keeps the app’s existing semantics for mirroring/connection behavior).
        cameraLocation = (cameraLocation == .back) ? .front : .back

        // Select a device on the target side (if available). This triggers format/session rebuild via didSet.
        if let targetDevice = availableDevices.first(where: { $0.position == targetPhysicalPosition }) {
            selectedDeviceUniqueID = targetDevice.uniqueID
        }

        // Apply best-effort format selection after formats are ready.
        applyBestEffortSelectionWhenReady(
            desiredSize: desiredSize,
            desiredFPS: desiredFPS,
            targetPhysicalPosition: targetPhysicalPosition
        )
    }

    private func applyBestEffortSelectionWhenReady(
        desiredSize: VideoSizeBucket?,
        desiredFPS: FPSBucket,
        targetPhysicalPosition: AVCaptureDevice.Position,
        attemptsRemaining: Int = 12
    ) {
        // Wait for device + formats to populate.
        guard attemptsRemaining > 0 else { return }

        // If we still don’t have a target-side device selected, try to pick one.
        if selectedDevice?.position != targetPhysicalPosition {
            if let targetDevice = availableDevices.first(where: { $0.position == targetPhysicalPosition }) {
                if selectedDeviceUniqueID != targetDevice.uniqueID {
                    selectedDeviceUniqueID = targetDevice.uniqueID
                }
            }
        }

        // If formats aren’t ready yet, retry shortly.
        if availableFormats.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.applyBestEffortSelectionWhenReady(
                    desiredSize: desiredSize,
                    desiredFPS: desiredFPS,
                    targetPhysicalPosition: targetPhysicalPosition,
                    attemptsRemaining: attemptsRemaining - 1
                )
            }
            return
        }

        applyBestEffortFormatSelection(desiredSize: desiredSize, desiredFPS: desiredFPS)
    }

    private func applyBestEffortFormatSelection(desiredSize: VideoSizeBucket?, desiredFPS: FPSBucket) {
        let formats = availableFormats
        guard !formats.isEmpty else { return }

        func matches(_ idx: Int, size: VideoSizeBucket?, fps: FPSBucket) -> Bool {
            if let size = size {
                guard sizeBucket(for: formats[idx]) == size else { return false }
            }
            return fpsBucket(for: formats[idx]) == fps
        }

        let allIdx = Array(formats.indices)

        // 1) Strict match: desired size + desired fps
        if let size = desiredSize {
            let strict = allIdx.filter { matches($0, size: size, fps: desiredFPS) }
            if let pick = pickPreferredIndex(strict, in: formats) {
                selectedFormatIndex = pick
                return
            }
        }

        // 2) Keep size, downgrade FPS (starting from desiredFPS and walking down)
        if let size = desiredSize, let start = FPSBucket.descending.firstIndex(of: desiredFPS) {
            for fps in FPSBucket.descending[start...] {
                let candidates = allIdx.filter { matches($0, size: size, fps: fps) }
                if let pick = pickPreferredIndex(candidates, in: formats) {
                    selectedFormatIndex = pick
                    return
                }
            }
        }

        // 3) Keep FPS, downgrade size (starting from desiredSize and walking down)
        let sizeOrder: [VideoSizeBucket] = [.k4, .p1080, .p720]
        if let desiredSize = desiredSize, let start = sizeOrder.firstIndex(of: desiredSize) {
            for size in sizeOrder[start...] {
                let candidates = allIdx.filter { matches($0, size: size, fps: desiredFPS) }
                if let pick = pickPreferredIndex(candidates, in: formats) {
                    selectedFormatIndex = pick
                    return
                }
            }
        } else {
            // If size unknown, try desired FPS across any size.
            let candidates = allIdx.filter { fpsBucket(for: formats[$0]) == desiredFPS }
            if let pick = pickPreferredIndex(candidates, in: formats) {
                selectedFormatIndex = pick
                return
            }
        }

        // 4) Last resort: pick any format by preference
        if let pick = pickPreferredIndex(allIdx, in: formats) {
            selectedFormatIndex = pick
        } else {
            selectedFormatIndex = 0
        }
    }
    
    /// URL for debug segment writes (Documents/debug_segments/). Call clearDebugSegmentsFolder() when enabling.
    func debugSegmentsFolderURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.debugSegmentsFolderName, isDirectory: true)
    }
    
    /// Remove entire debug_segments folder so next writes start clean. Call on launch when debugWriteSegmentsToDisk is on.
    func clearDebugSegmentsFolder() {
        guard let url = debugSegmentsFolderURL() else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    
    
    @objc func handleDeviceOrientationChange() {
        // Determine video orientation based on device orientation
        let videoOrientation: AVCaptureVideoOrientation
        switch UIDevice.current.orientation {
//        case .portrait:
//            videoOrientation = .portrait
//        case .landscapeLeft:
//            videoOrientation = .landscapeRight
//        case .landscapeRight:
//            videoOrientation = .landscapeLeft
//        case .portraitUpsideDown:
//            return // Ignore upside-down orientation
//        default:
//            videoOrientation = .portrait // Default to portrait for other cases
        default:
            videoOrientation = .landscapeRight // Default to portrait for other cases
        }
        DispatchQueue.main.async {
            self.captureVideoOrientation = videoOrientation
        }
        print("Updated video orientation to: \(videoOrientation.rawValue)")

        // Reinitialize the asset writer with updated settings
        initializeAssetWriter()
    }
    
    
    
    func addDeviceOrientationObserver() {
        // Add NotificationCenter observer for orientation changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleDeviceOrientationChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }


    func printAllCaptureDeviceFormats() {
        // FourCC constant for kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange (“420v”)
        let videoRangeType: FourCharCode = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera,
                .builtInDualCamera,
                .builtInTrueDepthCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        // only these video resolutions
        let wantedResolutions: [(Int32, Int32)] = [
            (1280, 720),      // 720p
            (1920, 1080),      // 1080p
            (3840, 2160)      // 4K UHD
        ]

        for device in discovery.devices {
            print("🔹 Device: \(device.localizedName) (\(device.position))")

            for (idx, format) in device.formats.enumerated() {
                let desc = format.formatDescription
                let mediaSubType = CMFormatDescriptionGetMediaSubType(desc)
                // filter to only “420v”
                guard mediaSubType == videoRangeType else { continue }

                // get the dims
                let dims = CMVideoFormatDescriptionGetDimensions(desc)

                // filter to only our wanted resolutions
                guard wantedResolutions.contains(where: { $0.0 == dims.width && $0.1 == dims.height }) else {
                    continue
                }

                // — everything below here is unchanged —
                let b0 = UInt8((mediaSubType >> 24) & 0xFF)
                let b1 = UInt8((mediaSubType >> 16) & 0xFF)
                let b2 = UInt8((mediaSubType >>  8) & 0xFF)
                let b3 = UInt8( mediaSubType         & 0xFF)
                let pixelFormatString = String(bytes: [b0,b1,b2,b3], encoding: .ascii)
                                         ?? "\(mediaSubType)"

                let fps = format.videoSupportedFrameRateRanges
                             .map { String(format: "%.1f–%.1f fps", $0.minFrameRate, $0.maxFrameRate) }
                             .joined(separator: ", ")

                let fov = String(format: "%.1f°", format.videoFieldOfView)
                let isoRange = String(format: "%.0f–%.0f", format.minISO, format.maxISO)
                let minExp = CMTimeGetSeconds(format.minExposureDuration)
                let maxExp = CMTimeGetSeconds(format.maxExposureDuration)
                let expRange = String(format: "%.5fs–%.5fs", minExp, maxExp)
                let maxZoom = String(format: "%.2f×", format.videoMaxZoomFactor)
                let upThresh = String(format: "%.2f×", format.videoZoomFactorUpscaleThreshold)
                let photoDims = format.highResolutionStillImageDimensions
                let photoSize = "\(photoDims.width)x\(photoDims.height)"
                let hdr      = format.isVideoHDRSupported
                let binned   = format.isVideoBinned
                let multicam = format.isMultiCamSupported
                let depthCnt = format.supportedDepthDataFormats.count
                let portrait = format.isPortraitEffectSupported

                print("""
                Format [\(idx)]:
                  • Resolution:             \(dims.width)x\(dims.height)
                  • PixelFormat:            \(pixelFormatString)
                  • FPS Ranges:             \(fps)
                  • Field of View:          \(fov)
                  • ISO Range:              \(isoRange)
                  • Exposure Duration:      \(expRange)
                  • Zoom (max/upscale):     \(maxZoom) / \(upThresh)
                  • HDR Supported:          \(hdr)
                  • Video Binned:           \(binned)
                  • Multi-cam Supported:    \(multicam)
                  • Depth Formats Count:    \(depthCnt)
                  • Portrait Matte Supported: \(portrait)
                  • Still-Image Dims:       \(photoSize)
                """)
            }

            print("")  // blank line between devices
        }
    }
    
}
    

extension CameraManager {
    
    func cancelCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            // If there’s an existing session, tear it down
            if let session = self.cameraSession {
                session.beginConfiguration()
                session.inputs.forEach  { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                if session.isRunning {
                    session.stopRunning()
                }
                DispatchQueue.main.async {
                    self.cameraSession = nil
                }
                // If we were switching cameras, allow downstream mirroring updates once session is gone.
                DispatchQueue.main.async { self.isCameraSwitchInProgress = false }
            }
        }
    }
    
    /// Public call to start a new capture session. Stops a current session if running.
    func initializeCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }
            
            // If there’s an existing session, tear it down
            if let session = self.cameraSession {
                session.beginConfiguration()
                session.inputs.forEach  { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                if session.isRunning {
                    session.stopRunning()
                }
                DispatchQueue.main.async {
                    self.cameraSession = nil
                }
            }
            
            // Always create a fresh capture session
            do {
                try self.createCaptureSession()
            } catch {
                print("⚠️ initializeCaptureSession failed:", error)
            }
        }
    }
    
    /// Create a capture session
    private func createCaptureSession() throws {
        /// Check for a camera device. If none, we're not goign to start a capture session. This function will run again when a camera device is available (from didset)
        guard let device = selectedDevice else {
            print("⏳ Waiting for camera device…")
            return
          }
        let idx      = min(selectedFormatIndex, availableFormats.count - 1)
        let format   = availableFormats[idx]
        let fpsValue = Int32(selectedFrameRate)
        let oneFrame = CMTime(value: 1, timescale: fpsValue)
        
        // 2️⃣ compute & publish aspect ratio
        let dims   = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let aspect = CGFloat(dims.width) / CGFloat(dims.height)
        DispatchQueue.main.async { self.cameraAspectRatio = aspect }
        
        // 3️⃣ begin building the session
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .inputPriority
        
        // — add the device input —
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)
        
        // — add the video output —
        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)
        
        // — live‐connection settings —
        if let conn = output.connection(with: .video) {
            conn.videoOrientation = captureVideoOrientation
            conn.isVideoMirrored  = mirroredReplay
        }
        
        session.commitConfiguration()
        
        // 4️⃣ lock & apply format + FPS to the device
        try device.lockForConfiguration()
        device.activeFormat                = format
        device.activeVideoMinFrameDuration = oneFrame
        device.activeVideoMaxFrameDuration = oneFrame

        // Debug: confirm what actually got applied.
        let activeDims = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let activeFPS = 1.0 / max(0.000001, CMTimeGetSeconds(device.activeVideoMinFrameDuration))
        print("✅ ACTIVE format \(activeDims.width)x\(activeDims.height) @ \(String(format: "%.1f", activeFPS))fps, HDR=\(device.activeFormat.isVideoHDRSupported), binned=\(device.activeFormat.isVideoBinned)")

        device.unlockForConfiguration()
        
        // 5️⃣ publish & start running
        DispatchQueue.main.async { self.cameraSession = session }
        session.startRunning()
    }
    
}

extension CameraManager {
    
    func cancelAssetWriter() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            if let writer = self.assetWriter, writer.status == .writing || writer.status == .unknown {
                writer.cancelWriting()
            }
            self.assetWriter = nil
            self.videoInput = nil
            self.startTime = nil
            self.initializationData = Data()
            self.writerStarted = false
            self.droppedFrames = 0
        }
    }
    
    /// Public call to (re)start the asset writer.
    ///
    /// IMPORTANT: This is a *pipeline* operation (used when settings change, camera flips, foregrounding, etc.).
    /// It is allowed to reset state like `droppedFrames`.
    func initializeAssetWriter() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }

            self.droppedFrames = 0
            self.createAssetWriter()
        }
    }

    /// Lightweight writer recreation used by captureOutput "self-heal" paths.
    ///
    /// This intentionally does *not* reset the replay pipeline (no buffer reset / queue clear),
    /// because calling those during foreground recovery can produce a "blank" player.
    ///
    /// Call this when `assetWriter`/`videoInput` are unexpectedly nil or unusable while capture is running.
    func recreateAssetWriterIfPossible(throttleSeconds: Double = 0.5) {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }

            // Only attempt if we have a running capture session.
            guard let session = self.cameraSession, session.isRunning else { return }

            // Throttle to avoid rapid-fire recreation loops.
            let now = CACurrentMediaTime()
            if now - self.lastWriterRecreateAttemptTime < throttleSeconds {
                return
            }
            self.lastWriterRecreateAttemptTime = now

            // If we already have a usable writer+input, do nothing.
            if let w = self.assetWriter,
               self.videoInput != nil,
               (w.status == .unknown || w.status == .writing) {
                return
            }

            // Otherwise, rebuild writer objects without touching BufferManager / PlaybackManager.
            // Clear any stale writer state first so we don't keep references to a failed/cancelled writer.
            if let w = self.assetWriter, (w.status == .writing || w.status == .unknown) {
                w.cancelWriting()
            }

            self.assetWriter = nil
            self.videoInput = nil
            self.startTime = nil
            self.initializationData = Data()
            self.writerStarted = false

            self.createAssetWriter()
        }
    }
    
    /// Create an asset writer
    func createAssetWriter() {
        guard !isBackgroundedOrShuttingDown else { return }
        guard let session = cameraSession, session.isRunning else {
            print("⏳ createAssetWriter deferred: capture session not running")
            return
        }
        // snapshot all settings
        let orientation = selectedVideoOrientation
        let fmt         = availableFormats[selectedFormatIndex]
        let dims        = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let isPortrait  = orientation == .portrait || orientation == .portraitUpsideDown
        let width  = isPortrait ? dims.height : dims.width
        let height = isPortrait ? dims.width  : dims.height

        /// Simple encoder settings (no compression hints) — lower CPU
        let settings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(width),
            AVVideoHeightKey: Int(height)
        ]

        // build the writer
        assetWriter = try? AVAssetWriter(contentType: .mpeg4Movie)
        assetWriter?.outputFileTypeProfile          = .mpeg4AppleHLS
        assetWriter?.preferredOutputSegmentInterval = segmentDuration
        assetWriter?.initialSegmentStartTime        = .zero
        assetWriter?.delegate                       = self

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true

        if let w = assetWriter, w.canAdd(videoInput) {
            w.add(videoInput)
        }

        print("📝 AssetWriter initialized for orientation \(orientation)")
    }
    
}

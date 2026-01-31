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
    
    // This is the number of frames that we dropped/skipped in captureoutput. We will drop a few when the session starts to eliminate dark frames.
    var droppedFrames: Int = 0
    
    @Published var cameraSession: AVCaptureSession? = nil
    
    @Published var cameraAspectRatio: CGFloat = 4.0/3.0
    
    var delegate: AVCaptureVideoDataOutputSampleBufferDelegate?
    
    //asset writer
    let assetWriterInterval: Double = 1.0 // seconds
    lazy var segmentDuration = CMTimeMake(value: Int64(assetWriterInterval * 10), timescale: 10)
    
    var assetWriter: AVAssetWriter!
    var videoInput: AVAssetWriterInput!
    var startTime: CMTime!

    var initializationData = Data()
    
    var writerStarted = false
    
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
    @Published var cameraLocation: CameraPosition = .back {
        willSet {
            cancelAssetWriter()
        }
        didSet {
            updateAvailableDevices()
            BufferManager.shared.resetBuffer()
            initializeAssetWriter()
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
        // choose which device‐types you want users to see
        let types: [AVCaptureDevice.DeviceType]
        switch cameraLocation {
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

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: cameraLocation.avPosition
        )
        let devices = discovery.devices
        DispatchQueue.main.async {
            self.availableDevices = devices
            // make sure selectedDeviceUniqueID is valid
            if !devices.map(\.uniqueID).contains(self.selectedDeviceUniqueID) {
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

        let videoRangeType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            let wantedResolutions: [(Int32, Int32)] = [
                (1280, 720),
                (1920, 1080),
                (3840, 2160)
            ]

        availableFormats = device.formats.filter { fmt in
            let desc = fmt.formatDescription
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            let mediaSub = CMFormatDescriptionGetMediaSubType(desc)
            // only 420v & one of our wanted sizes
            return mediaSub == videoRangeType
                && wantedResolutions.contains { $0.0 == dims.width && $0.1 == dims.height }
        }

        guard !availableFormats.isEmpty else {
            selectedFormatIndex = 0
            return
        }
        
        // recompute FPS choices for the newly-selected format
        if availableFormats.indices.contains(selectedFormatIndex) {
            let ranges = availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges
            // we’ll just list each range’s maxFrameRate
            availableFrameRates = ranges.map { $0.maxFrameRate }.sorted()
            // clamp the selectedFrameRate
            if !availableFrameRates.contains(selectedFrameRate) {
                selectedFrameRate = availableFrameRates.first ?? availableFrameRates.first ?? 30
            }
        } else {
            availableFrameRates = []
            selectedFrameRate = 0
        }
        
        // clamp the selected index
        // clamp, *then* restart
        let safeIndex = min(selectedFormatIndex, availableFormats.count-1)
        if safeIndex != selectedFormatIndex {
            selectedFormatIndex = safeIndex   // this will call restartSession()
        }
        
        if selectedFormatIndex >= availableFormats.count {
            selectedFormatIndex = 0       // this will trigger restartSession() once
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
        // addDeviceOrientationObserver()
        initializeCaptureSession()
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
            }
        }
    }
    
    /// Public call to start a new capture session. Stops a current session if running.
    func initializeCaptureSession() {
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
            if let writer = self.assetWriter, writer.status == .writing {
                writer.cancelWriting()
            }
        }
    }
    
    /// Public call to start the asset writer. Finished the old one first if needed.
    func initializeAssetWriter() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            self.droppedFrames = 0
            BufferManager.shared.resetBuffer()
            self.createAssetWriter()
        }
    }
    
    /// Create an asset writer
    private func createAssetWriter() {
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

        // --- NEW: GOP/keyframe + no B-frame hints ---
        let fps        = max(1, Int(round(selectedFrameRate)))          // expected fps
        let gopSeconds = min(assetWriterInterval, 1.0)                  // ~1s GOP to match 1s segments
        let compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,                     // pacing hint
            AVVideoMaxKeyFrameIntervalKey: fps,                         // ~1s in frames
            AVVideoMaxKeyFrameIntervalDurationKey: gopSeconds,          // ~1s in seconds
            AVVideoAllowFrameReorderingKey: false,                      // avoid B-frame reorder at joins
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        
        let settings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: compression
        ]

        // build the writer
        assetWriter = try? AVAssetWriter(contentType: .mpeg4Movie)
        assetWriter?.outputFileTypeProfile          = .mpeg4AppleHLS
        assetWriter?.preferredOutputSegmentInterval = segmentDuration
        assetWriter?.initialSegmentStartTime        = .zero
        assetWriter?.delegate                       = self

        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.performsMultiPassEncodingIfSupported = false

        if let w = assetWriter, w.canAdd(videoInput) {
            w.add(videoInput)
        }

        print("📝 AssetWriter initialized for orientation \(orientation)")
    }
    
}

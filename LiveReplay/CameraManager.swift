//
//  CameraManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 1/29/25.
//

import AVKit
import CoreMedia
import Combine
import AVFoundation

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
        qos: .userInitiated
    )

    /// Gate captureOutput / writer work while we are restarting pipeline (background or camera switch).
    @Published var isBackgroundedOrShuttingDown: Bool = false

    /// Drop a few frames because often they are dark from camera starting up
    var droppedFrames: Int = 0

    @Published var cameraSession: AVCaptureSession? = nil
    @Published var cameraAspectRatio: CGFloat = 4.0/3.0

    // asset writer
    let assetWriterInterval: Double = 1.0 // seconds (segment length)
    lazy var segmentDuration = CMTimeMake(value: Int64(assetWriterInterval * 10), timescale: 10)

    var assetWriter: AVAssetWriter!
    var videoInput: AVAssetWriterInput!
    var startTime: CMTime!

    var initializationData = Data()
    var writerStarted = false

    /// When true, write each segment to disk as segment_N.mp4 in debugSegmentsFolder; folder is cleared on launch.
    var debugWriteSegmentsToDisk: Bool = false
    private static let debugSegmentsFolderName = "debug_segments"

    enum CameraPosition {
        case back, front
        var avPosition: AVCaptureDevice.Position {
            switch self {
            case .back:  return .back
            case .front: return .front
            }
        }
    }

    private var isSwitchingCamera: Bool = false

    private func beginSwitchGate() {
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = true
        }
        isSwitchingCamera = true
    }

    private func endSwitchGate() {
        isSwitchingCamera = false
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = false
        }
    }

    
    /// IMPORTANT: keep observer LIGHT. Do not reset buffer / writer here (avoid double resets + races).
    @Published var cameraLocation: CameraPosition = .back {
        didSet {
            updateAvailableDevices()
        }
    }

    /// All AVCaptureDevices matching the current `cameraLocation`
    @Published var availableDevices: [AVCaptureDevice] = []

    /// The uniqueID of the device the user has picked
    @Published var selectedDeviceUniqueID: String = "" {
        willSet {
            // keep minimal: stop writer only; session will be rebuilt when devices update
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
        willSet { cancelAssetWriter() }
        didSet {
            let ranges = availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges
            let standardRates: [Double] = [30, 60, 120, 240]
            availableFrameRates = standardRates.filter { rate in
                ranges.contains { Double(rate) >= $0.minFrameRate && Double(rate) <= $0.maxFrameRate }
            }
            selectedFrameRate = availableFrameRates.first ?? 30

            initializeCaptureSession()
            initializeAssetWriter()
        }
    }

    @Published var availableFrameRates: [Double] = []
    @Published var selectedFrameRate: Double = 0 {
        willSet { cancelAssetWriter() }
        didSet {
            initializeCaptureSession()
            initializeAssetWriter()
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
                connection.videoOrientation = .landscapeRight
                print("captureVideoOrientation \(captureVideoOrientation)")
            }
        }
    }

    @Published var selectedVideoOrientation: AVCaptureVideoOrientation = .landscapeRight {
        didSet {
            guard !isSwitchingCamera else { return }   // defer applying to a possibly-old connection
            if let conn = cameraSession?
                .outputs
                .compactMap({ $0 as? AVCaptureVideoDataOutput })
                .first?
                .connection(with: .video)
            {
                conn.videoOrientation = selectedVideoOrientation
            }
            initializeAssetWriter()
        }
    }

    @Published var mirroredReplay = false {
        didSet {
            guard !isSwitchingCamera else { return }   // defer applying to a possibly-old connection
            if let connection = cameraSession?.outputs.first?.connections.first {
                connection.isVideoMirrored = mirroredReplay
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
        initializeCaptureSession()
    }

    // MARK: - Background / Foreground (minimal + solid)

    /// Called when app goes to background:
    /// - Stop capture session
    /// - Cancel writer
    /// - Reset buffer
    /// - Clear player queue
    func stopForBackground() {
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = true
        }

        // Stop capture
        cancelCaptureSession()

        // Stop writer & clear writer state
        cancelAssetWriter()

        // Reset replay pipeline
        BufferManager.shared.resetBuffer()
        PlaybackManager.shared.stopAndClearQueue()
    }

    /// Called when app returns foreground:
    /// - Restart capture
    /// - Restart writer
    func startAfterForeground() {
        DispatchQueue.main.async {
            self.isBackgroundedOrShuttingDown = false
        }
        initializeCaptureSession()
        initializeAssetWriter()
    }

    // MARK: - Camera switching (minimal + solid)

    /// Camera switch behavior: clear buffer + queue; then rebuild session + writer.
    /// (We DO restart capture session because device changes require it.)
    func switchCameraCleanly() {
        let newLocation: CameraPosition = (cameraLocation == .back) ? .front : .back

        beginSwitchGate()

        // 1) Stop capture session FIRST so old connection is gone (prevents mirrored/orientation touching old feed).
        cancelCaptureSession()

        // 2) Cancel writer + clear writer state (prevents old-camera segment from slipping in)
        cancelAssetWriter()

        // 3) Clear player queue, then AFTER it visually drops, reset buffer + switch camera + restart.
        PlaybackManager.shared.stopAndClearQueue { [weak self] in
            guard let self else { return }

            // No more in-flight addNewAsset should be happening because we gated + stopped session + cancelled writer.
            BufferManager.shared.resetBuffer()

            // switch camera (don’t do extra resets in cameraLocation observers)
            DispatchQueue.main.async {
                self.cameraLocation = newLocation

                // restart
                self.initializeCaptureSession()
                self.initializeAssetWriter()

                self.endSwitchGate()
            }
        }
    }


    /// Kept for your UI button that calls it.
    @objc func handleDeviceOrientationChange() {
        let videoOrientation: AVCaptureVideoOrientation
        switch UIDevice.current.orientation {
        default:
            videoOrientation = .landscapeRight
        }
        DispatchQueue.main.async {
            self.captureVideoOrientation = videoOrientation
        }
        print("Updated video orientation to: \(videoOrientation.rawValue)")
        initializeAssetWriter()
    }

    // MARK: - Debug segments folder

    func debugSegmentsFolderURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Self.debugSegmentsFolderName, isDirectory: true)
    }

    func clearDebugSegmentsFolder() {
        guard let url = debugSegmentsFolderURL() else { return }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    // MARK: - Devices/formats

    private func updateAvailableDevices() {
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
            if !devices.map(\.uniqueID).contains(self.selectedDeviceUniqueID) {
                self.selectedDeviceUniqueID = devices.first?.uniqueID ?? ""
            }
            self.updateAvailableFormats()
            // keep original behavior if you want auto-restart here:
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
            return mediaSub == videoRangeType
            && wantedResolutions.contains { $0.0 == dims.width && $0.1 == dims.height }
        }

        guard !availableFormats.isEmpty else {
            selectedFormatIndex = 0
            return
        }

        if availableFormats.indices.contains(selectedFormatIndex) {
            let ranges = availableFormats[selectedFormatIndex].videoSupportedFrameRateRanges
            availableFrameRates = ranges.map { $0.maxFrameRate }.sorted()
            if !availableFrameRates.contains(selectedFrameRate) {
                selectedFrameRate = availableFrameRates.first ?? 30
            }
        } else {
            availableFrameRates = []
            selectedFrameRate = 0
        }

        let safeIndex = min(selectedFormatIndex, availableFormats.count - 1)
        if safeIndex != selectedFormatIndex {
            selectedFormatIndex = safeIndex
        }
        if selectedFormatIndex >= availableFormats.count {
            selectedFormatIndex = 0
        }
    }

    // MARK: - Session control

    func cancelCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if let session = self.cameraSession {
                session.beginConfiguration()
                session.inputs.forEach  { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                if session.isRunning { session.stopRunning() }
                DispatchQueue.main.async { self.cameraSession = nil }
            }
        }
    }

    func initializeCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if let session = self.cameraSession {
                session.beginConfiguration()
                session.inputs.forEach  { session.removeInput($0) }
                session.outputs.forEach { session.removeOutput($0) }
                session.commitConfiguration()
                if session.isRunning { session.stopRunning() }
                DispatchQueue.main.async { self.cameraSession = nil }
            }

            do {
                try self.createCaptureSession()
            } catch {
                print("⚠️ initializeCaptureSession failed:", error)
            }
        }
    }

    private func createCaptureSession() throws {
        guard let device = selectedDevice else {
            print("⏳ Waiting for camera device…")
            return
        }

        let idx      = min(selectedFormatIndex, availableFormats.count - 1)
        let format   = availableFormats[idx]
        let fpsValue = Int32(selectedFrameRate)
        let oneFrame = CMTime(value: 1, timescale: fpsValue)

        let dims   = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let aspect = CGFloat(dims.width) / CGFloat(dims.height)
        DispatchQueue.main.async { self.cameraAspectRatio = aspect }

        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = .inputPriority

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CameraError.cannotAddOutput
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: captureQueue)

        if let conn = output.connection(with: .video) {
            conn.videoOrientation = captureVideoOrientation
            conn.isVideoMirrored  = mirroredReplay
        }

        session.commitConfiguration()

        try device.lockForConfiguration()
        device.activeFormat                = format
        device.activeVideoMinFrameDuration = oneFrame
        device.activeVideoMaxFrameDuration = oneFrame
        device.unlockForConfiguration()

        DispatchQueue.main.async { self.cameraSession = session }
        session.startRunning()
    }

    // MARK: - Writer control

    func cancelAssetWriter() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            if let w = self.assetWriter, w.status == .writing || w.status == .unknown {
                w.cancelWriting()
            }
            self.assetWriter = nil
            self.videoInput = nil
            self.startTime = nil
            self.initializationData = Data()
            self.writerStarted = false
            self.droppedFrames = 0
        }
    }

    func initializeAssetWriter() {
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }

            self.droppedFrames = 0
            BufferManager.shared.resetBuffer()
            self.createAssetWriter()
        }
    }

    /// NOTE: must be non-private so captureOutput can call it if writer is missing.
    func createAssetWriter() {
        guard !isBackgroundedOrShuttingDown else { return }
        guard let session = cameraSession, session.isRunning else {
            print("⏳ createAssetWriter deferred: capture session not running")
            return
        }

        let orientation = selectedVideoOrientation
        let fmt         = availableFormats[selectedFormatIndex]
        let dims        = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let isPortrait  = orientation == .portrait || orientation == .portraitUpsideDown
        let width  = isPortrait ? dims.height : dims.width
        let height = isPortrait ? dims.width  : dims.height

        let fps        = max(1, Int(round(selectedFrameRate)))
        let gopSeconds = min(assetWriterInterval, 1.0)
        let gopFrames  = max(1, fps * Int(assetWriterInterval))

        let compression: [String: Any] = [
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: gopFrames,
            AVVideoMaxKeyFrameIntervalDurationKey: gopSeconds,
            AVVideoAllowFrameReorderingKey: false,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]

        let settings: [String: Any] = [
            AVVideoCodecKey:  AVVideoCodecType.h264,
            AVVideoWidthKey:  Int(width),
            AVVideoHeightKey: Int(height),
            AVVideoCompressionPropertiesKey: compression
        ]

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

        startTime = nil
        initializationData = Data()
        writerStarted = false

        print("📝 AssetWriter initialized for orientation \(orientation)")
    }

    // MARK: - Keep your existing implementation (unchanged)
    func printAllCaptureDeviceFormats() {
        // keep your existing implementation
    }
}

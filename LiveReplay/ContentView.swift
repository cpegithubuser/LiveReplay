//
//  ContentView.swift
//  LiveReplay
//
//  Created by Albert Soong on 2/2/25.
//

import SwiftUI
import AVKit
import Combine

struct ContentView: View {
    
    @ObservedObject var playbackManager = PlaybackManager.shared
    @ObservedObject var settings = SettingsManager.shared
    @ObservedObject var cameraManager = CameraManager.shared
    @State public var showSettings = false
    
    var size: CGSize = (CGSize(width: 200, height: 2000))
    @State private var showPlayerControls: Bool = false
    @State private var isPlaying: Bool = false
    /// Video Seeker Properties
    @GestureState private var isDragging: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var progress: CGFloat = 0
    @State private var available: CGFloat = 0
    @State private var lastDraggedProgress: CGFloat = 0
    @State private var dragStartTranslation: CGFloat = 0
    @State private var drag2StartTranslation: CGFloat = 0

    @State private var displayDelayTime: Double? = nil
    @State private var isScrubbableReady = false

    @State private var lastUpdateTime: TimeInterval = 0
    
    @State private var snapshotImage: UIImage? = nil
    @State private var cancellables = Set<AnyCancellable>()
    
    /// Track whether the PiP is visible
    @State private var showPiP: Bool = true
    /// Track the PiP’s cumulative offset
    @State private var pipOffset: CGSize = .zero
    @State private var lastDragOffset: CGSize = .zero
    /// Track whether we want the video flipped
    @State private var isFlipped: Bool = false
    
    /// For Gridlines. -1 is no lines
    @State private var numberOfGridLines: Int = -1
    
    
    @State private var playbackUpdateTimer: Timer?
    /// Scrub fractions
    @State private var leftBound:  CGFloat = 1   // L
    @State private var rightBound: CGFloat = 1   // R

    @inline(__always)
    private func canon600(_ t: CMTime) -> CMTime {
        CMTimeConvertScale(t, timescale: 600, method: .default)
    }

    
    var body: some View {
        
        ZStack {
            //Constant replay player  avqueueplayer
            if playbackManager.playerConstant.status == .readyToPlay || true {
                ZStack {
                    //VideoPlayer(player: playbackManager.playerConstant)
                    //AVPlayerViewControllerWrapper(player: playbackManager.playerConstant)
                    PlayerView(player: playbackManager.playerConstant, isFlipped: isFlipped)
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .edgesIgnoringSafeArea(.all)
                        .overlay(
                            GridOverlay(numberOfGridLines: numberOfGridLines)
                        )
                        .onAppear {
                            addPeriodicTimeObserver()
                            print("Adding periodic time observer")
                            // Assign the snapshot handler from the UI to the manager
                            playbackManager.snapshotHandler = {
                                snapshotAndOverlay()
                            }
                            print("Adding snapshot handler")
                            markerProgress = progress(for: bookmarkedDelay)
                            lastMarkerProgress = markerProgress
                        }
                        .onChange(of: playbackManager.maxScrubbingDelay) { _ in
                            // if the window size changes, keep marker aligned to the same absolute delay
                            markerProgress = progress(for: bookmarkedDelay)
                            lastMarkerProgress = markerProgress
                        }
                        .onDisappear { removePeriodicTimeObserver() }
                        .overlay(
                            VStack {
                                Spacer() // Push buttons to bottom
                                VideoSeekerView(size)
                                HStack(spacing: 20) { // Spacing between buttons
                                    // Reverse 10s Button
                                    Button(action: playbackManager.rewind10Seconds) {
                                        Image(systemName: "gobackward.10")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 25, height: 25)
                                            .foregroundColor(.white)
                                            .padding(10)
                                            .background(Circle().fill(Color.blue.opacity(0.5)))
                                    }
                                    
                                    // Play/Pause Button
                                    Button(action: playbackManager.togglePlayPause) {
                                        Image(systemName: playbackManager.playerConstant.rate == 0 ? "play.fill" : "pause.fill")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 25, height: 25)
                                            .foregroundColor(.white)
                                            .padding(10)
                                            .background(Circle().fill(Color.blue.opacity(0.5)))
                                    }
                                    
                                    // Forward 10s Button
                                    Button(action: playbackManager.forward10Seconds) {
                                        Image(systemName: "goforward.10")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 25, height: 25)
                                            .foregroundColor(.white)
                                            .padding(10)
                                            .background(Circle().fill(Color.blue.opacity(0.5)))
                                    }
                               // this is the frame by frame view
                               //     ScrollingTickMarksView()
                               //         .frame(width:300, height: 30)
                                    // Fixed Dealy button

//                                    Button(action: playbackManager.pingPong) {
//                                        Image(systemName: playbackManager.isPlayingPingPong ?  "arrow.left.arrow.right.circle.fill" : "arrow.left.arrow.right.circle")
//                                            .resizable()
//                                            .scaledToFit()
//                                            .frame(width: 35, height: 35)
//                                            .foregroundColor(.white)
//                                            .padding(5)
//                                            .background(Circle().fill(Color.red.opacity(0.5)))
//                                    }
//                                    Button(action: playbackManager.loop) {
//                                        Image(systemName: playbackManager.isPlayingLoop ? "arrow.clockwise.circle.fill" : "arrow.clockwise.circle")
//                                            .resizable()
//                                            .scaledToFit()
//                                            .frame(width: 35, height: 35)
//                                            .foregroundColor(.white)
//                                            .padding(5)
//                                            .background(Circle().fill(Color.red.opacity(0.5)))
//                                    }
                                    Button(action: { showPiP.toggle() }) {
                                        Image(systemName: showPiP ? "pip.fill" : "pip")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 35, height: 35)
                                            .foregroundColor(.white)
                                            .padding(5)
                                            .background(Circle().fill(Color.purple.opacity(0.5)))
                                    }
                                    Button(action: { isFlipped.toggle() }) {
                                        Image(systemName: isFlipped ? "flip.horizontal" : "flip.horizontal")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 35, height: 35)
                                            .foregroundColor(.white)
                                            .padding(5)
                                            .background(Circle().fill(Color.purple.opacity(0.5)))
                                   }
//                                    Button(action: {
//                                        // advance 0→1→2→3→0
//                                        numberOfGridLines = (numberOfGridLines < 9) ? (numberOfGridLines + 2) : -1
//                                    }) {
//                                        Image(systemName: numberOfGridLines>0 ? "grid.circle.fill" : "grid.circle")
//                                            .resizable()
//                                            .scaledToFit()
//                                            .frame(width: 35, height: 35)
//                                            .foregroundColor(.white)
//                                            .padding(5)
//                                            .background(Circle().fill(Color.purple.opacity(0.5)))
//                                    }
                                    .buttonStyle(NoTapAnimationStyle())
                                    Button(action: goToFixedDelay) {
                                        Image(systemName: "bookmark.circle")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 35, height: 35)
                                            .foregroundColor(.white)
                                            .padding(5)
                                            .background(Circle().fill(Color.red.opacity(0.5)))
                                    }
                                    Button {
                                    //    CameraManager.shared.flipCameraCleanly()
                                        cameraManager.cameraLocation = (cameraManager.cameraLocation == .back) ? .front : .back
                                      //  CameraManager.shared.handleDeviceOrientationChange()
                          //              BufferManager.shared.resetBuffer()
                                    } label: {
                                        Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90.camera")
                                            .resizable()
                                            .scaledToFit()
                                            .frame(width: 35, height: 35)
                                            .foregroundColor(.white)
                                            .padding(5)
                                            .background(Circle().fill(Color.purple.opacity(0.5)))
                                    }
 }
                                .padding(.bottom, 30)
                            }
                            , alignment: .bottom // Align buttons to bottom
                        )
//                    if let item = playbackManager.playerConstant.currentItem  {
//                        VStack {
//                            Text(playbackManager.describePlayerItem(item))
//                                .padding()
//                                .background(Color.black.opacity(0.7)) // Background to make the text readable
//                                .foregroundColor(.white)
//                                .cornerRadius(10)
//                                .padding()
//                            Text("size:\(Int(item.presentationSize.width))×\(Int(item.presentationSize.height))")
//                                .padding()
//                                .background(Color.black.opacity(0.7)) // Background to make the text readable
//                                .foregroundColor(.white)
//                                .cornerRadius(10)
//                                .padding()
//                            Spacer()
//                        }
//                        .padding(.bottom, 30) // Adjust to your needs
//                    }

                }
            }
            

            if showSettings {
                SettingsView(showSettings: $showSettings)
                    .statusBarHidden()
            } else {
                VStack{
                    Spacer()
                    HStack {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .padding(7)
                                .foregroundColor(Color.white)
                                .background(Color.yellow)
                                .cornerRadius(12)
                                .padding(15)
                        }
                        Spacer()
                    }

                }
            }
            GeometryReader { geo in
            //                if geo.size.height > geo.size.width {
            //                    let previewScale = geo.size.height * 0.25
            //                    let previewWidth = geo.size.height / cameraManager.cameraAspectRatio
            //                    let previewHeight = previewWidth / cameraManager.cameraAspectRatio
            //                } else {
            //                    let previewScale = geo.size.width * 0.25
            //                    let previewWidth = geo.size.width
            //                    let previewHeight = previewWidth / cameraManager.cameraAspectRatio
            //                }
                // 1) Are we taller than wide?
                let isPortrait = geo.size.height > geo.size.width

                // 2) Pick your “primary dimension” = 25% of height if portrait, else 25% of width
                let primary = (isPortrait ? geo.size.height : geo.size.width) * 0.25

                // 3) Compute a frame that respects your cameraAspectRatio:
                //
                //    cameraAspectRatio = (formatWidth / formatHeight)
                //
                // If portrait: make height = primary, width = primary / aspect
                // If landscape: make width  = primary, height = primary / aspect
                let previewWidth  = isPortrait
                  ? primary / cameraManager.cameraAspectRatio
                  : primary
                let previewHeight = isPortrait
                  ? primary
                  : primary / cameraManager.cameraAspectRatio

                ZStack {
                    // Your camera preview
                    CameraPreview()
                        .frame(width: previewWidth, height: previewHeight)

                    // LIVE badge in top‐left
                    Text("LIVE")
                        .font(.caption2).bold()
                        .foregroundColor(.red)
                        .padding(4)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    // Close (“X”) button in top‐right
                    Button(action: { showPiP = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .scaleEffect(1.3)
                            .foregroundColor(.white)
                            .padding(2)
                            .background(Color.black.opacity(0.4))
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                .frame(width: previewWidth, height: previewHeight)
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.7), lineWidth: 1)
                )
                .shadow(radius: 4)
                .offset(x: pipOffset.width, y: pipOffset.height)
                // 3) Drag gesture to update pipOffset
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            // value.translation is the drag from the start; add to lastDragOffset
                            pipOffset = CGSize(
                                width: lastDragOffset.width + value.translation.width,
                                height: lastDragOffset.height + value.translation.height
                            )
                        }
                        .onEnded { _ in
                            // Save the final offset for the next drag
                            lastDragOffset = pipOffset
                        }
                )
                .padding(10)
                .frame(maxWidth: .infinity,
                       maxHeight: .infinity,
                       alignment: .bottomTrailing)
                /// The two below hide the pip window
                .opacity(showPiP ? 1 : 0)
                .allowsHitTesting(showPiP) // allows a tap to flow through preview (to the next layer)
            }

        }
        .background(Color.black)
        .ignoresSafeArea()
        .overlay(OnScreenLogOverlayView())
    }
    struct NoTapAnimationStyle: PrimitiveButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                // Make the whole button surface tappable. Without this only content in the label is tappable and not whitespace. Order is important so add it before the tap gesture
                .contentShape(Rectangle())
                .onTapGesture(perform: configuration.trigger)
        }
    }
    
    struct GridOverlay: View {
        let numberOfGridLines: Int

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height

                if numberOfGridLines > 0 {
                    // each “cell” is a square of this size:
                    let squareSize = w / CGFloat(numberOfGridLines + 1)
                    let centerX = w / 2
                    let centerY = h / 2
                    // mid‐index for 0..<lines so that one line is at offset=0
                    let midIndex = CGFloat(numberOfGridLines - 1) / 2

                    Path { path in
                        // verticals: center ± n*squareSize
                        for i in 0..<numberOfGridLines {
                            let x = centerX + (CGFloat(i) - midIndex) * squareSize
                            path.move(to: CGPoint(x: x, y: 0))
                            path.addLine(to: CGPoint(x: x, y: h))
                        }

                        // horizontals: center ± n*squareSize
                        for i in 0..<numberOfGridLines {
                            let y = centerY + (CGFloat(i) - midIndex) * squareSize
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: w, y: y))
                        }
                    }
                    .stroke(Color.red.opacity(0.3), lineWidth: 2)
                }
            }
        }
    }

    
    /// This function uses AVPlayerItemVideoOutput to capture the current video frame,
    /// sets it as an overlay, and then clears it after a brief delay.
    
    @MainActor
    private func snapshotAndOverlay() {
        printBug(.bugSnapshot, "snapshotandoverlay called")
        // Ensure we run on the main thread.
        DispatchQueue.main.async {
            guard let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = windowScene.windows.first,
                  let playerView = window.viewWithTag(999) else { return }
            print("GOT PAST!!")
            // Call snapshotView(afterScreenUpdates:) to get a snapshot of the current view.
            if let snapshot = playerView.snapshotView(afterScreenUpdates: false) {
                snapshot.tag = 1001 // Tag the snapshot view to identify it.
                snapshot.frame = playerView.bounds
                let watermark = UILabel(frame: snapshot.bounds)
                if let ci = playbackManager.playerConstant.currentItem {
                    watermark.text = "SNAP \(Unmanaged.passUnretained(ci).toOpaque()) \(playbackManager.delayTime.seconds)"
                    printBug(.bugSnapshot, "got snapshot \(Unmanaged.passUnretained(ci).toOpaque()) \(playbackManager.delayTime.seconds)")
                } else {
                    watermark.text = "SNAP \(playbackManager.delayTime)"
                    printBug(.bugSnapshot, "got snapshot \(playbackManager.delayTime.seconds)")
                }
                watermark.textColor = .red
                watermark.textAlignment = .center
                watermark.font = UIFont.boldSystemFont(ofSize: 22)
                watermark.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                
                // Add the watermark to the snapshot view
                snapshot.addSubview(watermark)

                playerView.addSubview(snapshot)
                playbackManager.playerConstant.advanceToNextItem()
                print("ADVANCINGGGG")
//                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
//                    printBug(.bugSnapshot, "removing snapshot")
//                    snapshot.removeFromSuperview()
//                }
                // Use Combine to observe the new currentItem’s status.
                // Note: We capture the currentItem at this point; if it changes, you may need to adjust this.
                if let newItem = playbackManager.playerConstant.currentItem {
                    newItem.publisher(for: \.status, options: [.initial, .new])
                        .filter { $0 == .readyToPlay }
                        .first()
                        .sink { _ in
                            printBug(.bugSnapshot, "player item is ready, removing snapshot")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                                printBug(.bugSnapshot, "removing snapshot")
                                snapshot.removeFromSuperview()
                            }
                        }
                        .store(in: &cancellables)
                } else {
                    // Fallback in case there's no currentItem.
                //    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        printBug(.bugSnapshot, "removing snapshot")
                        snapshot.removeFromSuperview()
                //    }
                }
                
            }
        }
    }
    
    
    /// Captures a snapshot from the current video frame using AVPlayerItemVideoOutput.
    private func snapshotFromPlayerItem(player: AVPlayer) -> UIImage? {
        guard let currentItem = player.currentItem else { return nil }
        
        // Set up video output with BGRA pixel format.
        let pixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        let videoOutput = AVPlayerItemVideoOutput(pixelBufferAttributes: pixelBufferAttributes)
        currentItem.add(videoOutput)
        
        // Use the player's current time.
        let currentTime = player.currentTime()
        guard videoOutput.hasNewPixelBuffer(forItemTime: currentTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: currentTime, itemTimeForDisplay: nil) else {
            return nil
        }
        
        // Convert the pixel buffer to a CIImage.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext(options: nil)
        
        // Create a CGImage from the CIImage.
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
    
    // MARK: - UI heartbeat + helpers (in ContentView)

    func addPeriodicTimeObserver() {
        // avoid stacking multiple timers
        playbackUpdateTimer?.invalidate()
        playbackUpdateTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            updatePlaybackProgressTick()
            autoStartPlaybackIfNeeded()

            if !isScrubbing && playbackManager.delayTime != .zero {
                //no adjust yet
                //adjustPlaybackSpeedToReachDelayTime()
            }
        }
        if let t = playbackUpdateTimer {
            RunLoop.main.add(t, forMode: .common)
        }
    }

    // Optional, call this from .onDisappear
    func removePeriodicTimeObserver() {
        playbackUpdateTimer?.invalidate()
        playbackUpdateTimer = nil
    }

    // MARK: - Tick handlers

    private func updatePlaybackProgressTick() {
        // Derive the scrubber's fractions & visible playhead
        recomputeScrubFractions()

        // Keep drag baseline fresh when not scrubbing
        if isScrubbableReady && !isScrubbing {
            lastDraggedProgress = progress
        }
    }

    private func autoStartPlaybackIfNeeded() {
        let maxD = playbackManager.maxScrubbingDelay.seconds
        let minD = playbackManager.minScrubbingDelay.seconds
        let boundaryEPS = 0.02      // small tolerance
        let preRoll    = 0.05       // compensate for startup overhead

        let now      = canon600(playbackManager.currentTime)
        let play     = canon600(playbackManager.getCurrentPlayingTime())
        let earliest = canon600(BufferManager.shared.earliestPlaybackBufferTime)

        // Live measurements (seconds)
        let bufferedSpan = max(0, (now - earliest).seconds)
        let currentDelay = max(0, (now - play).seconds)

        // Desired startup delay from the bookmark marker
        let desiredFromMarker = min(maxD, max(0, bookmarkedDelay.seconds))

        switch playbackManager.playbackState {
        case .playing:
            return

        case .unknown:
            guard BufferManager.shared.segmentIndex > 0 else { return }
            // Stay paused on cold start until we can honor the marker delay
            guard bufferedSpan >= desiredFromMarker - boundaryEPS else { return }

            // Pin target to the marker delay and start there
            playbackManager.delayTime = roundCMTimeToNearestTenth(
                CMTime(seconds: desiredFromMarker, preferredTimescale: 600)
            )
            let seekDelay = max(0, desiredFromMarker - preRoll)
            let targetAbs = now - CMTime(seconds: seekDelay, preferredTimescale: 600)

            playbackManager.pausePlayerTemporarily()
            playbackManager.scrub(to: targetAbs, allowSeekOnly: true)
            playbackManager.playPlayer()
            return

        case .paused:
            // if we're within epsilon of the right edge of our window, resume
            guard currentDelay >= maxD - boundaryEPS else { return }

            // pin the target to maxScrubbingDelay (what we *want*), but clamp for the actual seek
            playbackManager.delayTime = roundCMTimeToNearestTenth(
                CMTime(seconds: maxD, preferredTimescale: 600)
            )
            let seekEdge = min(maxD, bufferedSpan)            // safe seek inside buffer
            let seekDelay = max(0, seekEdge - preRoll)
            let targetAbs = now - CMTime(seconds: seekDelay, preferredTimescale: 600)

            playbackManager.pausePlayerTemporarily()
            playbackManager.scrub(to: targetAbs, allowSeekOnly: true)
            playbackManager.playPlayer()
        }
    }

    // MARK: - Scrubber fractions

    /// Computes:
    ///  - leftBound (white-left) from buffer fill vs max window
    ///  - rightBound (white-right) from min-scrub guard band
    ///  - progress (visible playhead inside [leftBound, rightBound]) when not dragging
    ///  - displayDelayTime (actual delay behind "now") when not dragging (optional)
    private func recomputeScrubFractions() {
        let maxD = playbackManager.maxScrubbingDelay.seconds
        let minD = playbackManager.minScrubbingDelay.seconds
        guard maxD > 0 else { return }

        let now     = canon600(playbackManager.currentTime)
        let oldest  = canon600(BufferManager.shared.earliestPlaybackBufferTime)
        let absPlay = canon600(playbackManager.getCurrentPlayingTime())

        // Actual buffered span available right now (seconds)
        let bufferedSpan = max(0, (now - oldest).seconds)

        // No segments / nothing playable yet → undefined delay
        let noSegments = BufferManager.shared.segmentIndex == 0
                      || playbackManager.playerConstant.items().isEmpty
                      || bufferedSpan <= 0.0001

        if noSegments {
            leftBound  = 1
            rightBound = CGFloat((maxD - minD) / maxD)
            isScrubbableReady = false
            if !isScrubbing {
                progress = rightBound
                displayDelayTime = nil   // undefined; don’t show "0s"
            }
            return
        }

        // Window bounds (for scrubber geometry only)
        leftBound  = CGFloat(max(0, 1 - bufferedSpan / maxD))   // white-left
        rightBound = CGFloat((maxD - minD) / maxD)              // white-right
        isScrubbableReady = rightBound > leftBound

        // Raw, *unclamped* actual delay for display/diagnostics
        let actualDelayRaw = max(0, (now - absPlay).seconds)

        // For progress knob: reflect actual delay up to the buffered span
        let windowSpan = min(maxD, bufferedSpan)
        let delayForProgress = min(actualDelayRaw, windowSpan)
        
        // Treat “near live” as undefined (or show LIVE) only for the unpinned display
        let liveEPS = 0.05
        if !isScrubbing {
            //progress = min(max(1 - (delayForProgress / maxD), leftBound), rightBound)
            let visual = max(1 - (actualDelayRaw / maxD), leftBound)
            progress = min(visual, 1)   // can be > rightBound, but never > 1
            displayDelayTime = (actualDelayRaw <= liveEPS) ? nil : actualDelayRaw
        }
    }


    // MARK: - Optional: auto-correct playback speed to chase a target delay

    private func adjustPlaybackSpeedToReachDelayTime() {
        guard playbackManager.playerConstant.rate != 0,
              playbackManager.delayTime != .zero else { return }

        let currentDelay = canon600(playbackManager.currentTime) - canon600(playbackManager.getCurrentPlayingTime())
        let diff = playbackManager.delayTime - currentDelay

        let epsBig  = 0.5
        let epsTiny = 0.05

        if diff.seconds < -epsBig {
            if playbackManager.playerConstant.rate != 2.0 {
                playbackManager.playerConstant.rate = 2.0
            }
        } else if diff.seconds >  epsBig {
            if playbackManager.playerConstant.rate != 0.5 {
                playbackManager.playerConstant.rate = 0.5
            }
        } else if diff.seconds < -epsTiny {
            if playbackManager.playerConstant.rate == 1.0 {
                playbackManager.playerConstant.rate = 1.1
            }
        } else if diff.seconds >  epsTiny {
            if playbackManager.playerConstant.rate == 1.0 {
                playbackManager.playerConstant.rate = 0.9
            }
        } else if (diff.seconds > -0.01 && playbackManager.playerConstant.rate > 1.0)
               || (diff.seconds <  0.01 && playbackManager.playerConstant.rate < 1.0) {
            playbackManager.playerConstant.rate = 1.0
        }
    }

    private func effectiveDelaySeconds() -> Double? {
        // if we’re dragging, show the dragged value
        if isScrubbing { return displayDelayTime }

        // if no segments or queue empty, don’t use a pinned delay yet
        if BufferManager.shared.segmentIndex == 0 ||
           playbackManager.playerConstant.items().isEmpty {
            return displayDelayTime   // nil during cold start → UI shows LIVE/blank
        }

        // else prefer pinned target when playing
        if playbackManager.delayTime != .zero &&
           playbackManager.playerConstant.rate != 0 {
            return playbackManager.delayTime.seconds
        }
        return displayDelayTime
    }
    
    func goToFixedDelay() {
        playbackManager.removePlaybackBoundaryObserver()
        playbackManager.isPlayingPingPong = false
        playbackManager.isPlayingLoop = false

        // clamp to the enforceable window for the actual seek
        let targetDelaySec = min(
            playbackManager.maxScrubbingDelay.seconds,
            max(0, bookmarkedDelay.seconds)
        )
        let delay = CMTime(seconds: targetDelaySec, preferredTimescale: 600)

        showAndScheduleHide()
        playbackManager.playerConstant.pause()
        playbackManager.scrub(delay: delay)

        // pin the playback target to the (clamped) delay so ±10/bookmark chase is exact
        playbackManager.delayTime = roundCMTimeToNearestTenth(delay)
        playbackManager.playPlayer()
    }
    
    @State private var bookmarkedDelay: CMTime = CMTime(seconds: 5, preferredTimescale: 600)

    // map delay ↔︎ normalized position (0→1 left→right)
    private func progress(for delay: CMTime) -> CGFloat {
        let maxD = max(0.0001, playbackManager.maxScrubbingDelay.seconds)
        let d = min(max(delay.seconds, 0), maxD)
        return CGFloat(1 - d / maxD)
    }

    private func delay(for progress: CGFloat) -> CMTime {
        let maxD = playbackManager.maxScrubbingDelay.seconds
        let p = min(max(Double(progress), 0), 1)
        return CMTime(seconds: (1 - p) * maxD, preferredTimescale: 600)
    }
    
    
    /// Marker state:
    /// progress 0→1 along the bar,
    /// GestureState to animate while dragging,
    /// and temporary vars to avoid jump on drag start.
    @State private var markerProgress: CGFloat = 0.95          // from 0…1
    @GestureState private var markerIsDragging: Bool = false
    @State private var markerDragStart: CGFloat = 0
    @State private var lastMarkerProgress: CGFloat = 0.95
    @State private var showMarker = false
    @State private var hideWorkItem: DispatchWorkItem?
    private func showAndScheduleHide() {
      // cancel any pending hide
      hideWorkItem?.cancel()
      // show now, with animation
      withAnimation(.easeInOut(duration: 0.3)) {
        showMarker = true
      }
      // schedule hide in 3s
      let work = DispatchWorkItem {
        withAnimation(.easeInOut(duration: 0.3)) {
          showMarker = false
        }
      }
      hideWorkItem = work
      DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
    @ViewBuilder
    func VideoSeekerView(_ videoSize: CGSize) -> some View {
        // Variables to track time and pending updates
        
        var pendingUpdate: CGFloat = 0
        GeometryReader { proxy in
            let totalWidth = proxy.size.width
            let barWidth = totalWidth * 0.8
            let margin = (totalWidth - barWidth) / 2
            let barHeight: CGFloat = 12
            let cornerRadius: CGFloat = barHeight / 2
            
            // Knob sizing + travel mapping
            let knobBaseDiameter: CGFloat = barHeight
            let knobTouchSize: CGFloat = 50
            let knobTouchHalf: CGFloat = knobTouchSize / 2
            
            let maxProgress = (playbackManager.maxScrubbingDelay.seconds - playbackManager.minScrubbingDelay.seconds) / playbackManager.maxScrubbingDelay.seconds
            
            let maxD = playbackManager.maxScrubbingDelay.seconds
            let minD = playbackManager.minScrubbingDelay.seconds
            let rightLimit = CGFloat((maxD - minD) / maxD) // progress cannot exceed this (i.e. cannot be < min delay)
            
            // Clamped version to keep in [0,1]
            let clampedMarker = max(0, min(rightLimit, markerProgress))

            // Convert to a time delay (seconds)
            let markerDelay = (1 - clampedMarker) * playbackManager.maxScrubbingDelay.seconds

            
            
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(.white)
//                Rectangle()
//                    .fill(.gray)
//                    .frame(width: max(barWidth * (maxProgress - available), 0)) // Adjust width
//                    .offset(x: barWidth * available) // Move red bar to start at "available"
//                Rectangle()
//                    .fill(.red)
//                    .frame(width: max(barWidth * (progress - available), 0)) // Adjust width
//                    .offset(x: barWidth * available) // Move red bar to start at "available"

                // scrubbable window background (gray)
                Rectangle()
                  .fill(.gray)
                  .frame(width: barWidth * max(rightBound - leftBound, 0))
                  .offset(x: barWidth * leftBound)

                // past portion in window (red)
                let progressInWindow = min(progress, rightBound)
                Rectangle()
                  .fill(.red)
                  .frame(width: barWidth * max(progressInWindow - leftBound, 0))
                  .offset(x: barWidth * leftBound)
                
                
//                TimelineView(.animation(minimumInterval: 0.03)) { timeline in
//                    let time = timeline.date.timeIntervalSinceReferenceDate
//                    let dotCount = 10
//                    let animationDuration = playbackManager.maxScrubbingDelay.seconds // match video duration
//
//                    ForEach(0..<dotCount, id: \.self) { i in
//                        let phase = Double(i) / Double(dotCount)
//                        let position = (time / animationDuration + phase).truncatingRemainder(dividingBy: 1)
//                        let x = barWidth * (1 - CGFloat(position)) // right to left
//
//                        Circle()
//                            .fill(Color.white.opacity(0.3))
//                            .frame(width: 5, height: 5)
//                            .offset(x: x)
//                    }
//                }

            }
            .allowsHitTesting(isScrubbableReady)
            .frame(width: barWidth, height: barHeight) // Apply width once here
            .cornerRadius(cornerRadius)
            .offset(x: margin)
            .overlay(alignment: .leading) {
                /// has playhead
                if playbackManager.playerConstant.currentItem != nil
                    && BufferManager.shared.segmentIndex > 0 {
                    Circle()
                        .fill(.red)
                        .frame(width: knobBaseDiameter, height: knobBaseDiameter)
                    /// Showing Drag Knob Only When Dragging
                        .scaleEffect(showPlayerControls || isDragging ? 1.5 : 1.0, anchor: .center)
                    /// For More Dragging Space
                        .frame(width: knobTouchSize, height: knobTouchSize)
                        .contentShape(Rectangle())
                    /// Moving Along Side With Gesture Progress
                        .offset(x: barWidth * progress + margin - knobTouchHalf)
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .updating($isDragging, body: { _, out, _ in
                                    out = true
                                })
                                .onChanged { value in
                                    // Avoid the initial jump
                                    if dragStartTranslation == 0 {
                                        dragStartTranslation = value.translation.width
                                        // start dragging from the nearest legal spot
                                        lastDraggedProgress = min(progress, rightBound)
                                        return
                                    }
                                    
                                    // 1) drag → normalized progress
                                    let delta = (value.translation.width - dragStartTranslation) / barWidth
                                    let raw   = lastDraggedProgress + delta
                                    let clamped = max(leftBound, min(rightBound, raw))
                                    progress = clamped
                                    
                                    // 2) UI while scrubbing
                                    isScrubbing = true
                                    let maxD = playbackManager.maxScrubbingDelay.seconds
                                    displayDelayTime = (1 - clamped) * maxD
                                    playbackManager.pausePlayerTemporarily()
                                    
                                    // 3) convert to absolute target time (global timeline) and scrub (throttled)
                                    let targetDelay = (1 - clamped) * maxD
                                    let targetTime = canon600(playbackManager.currentTime)
                                    - CMTime(seconds: targetDelay, preferredTimescale: 600)
                                    
                                    let nowTS = Date().timeIntervalSince1970
                                    if nowTS - lastUpdateTime >= 0.2 || true {   // throttle seeks while dragging (disabled)
                                        playbackManager.scrub(to: targetTime, allowSeekOnly: true)
                                        lastUpdateTime = nowTS
                                    }
                                }
                            
                                .onEnded { _ in
                                    lastDraggedProgress = progress
                                    dragStartTranslation = 0
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                        isScrubbing = false
                                        
                                        // Pin to “where we are now”
                                        let now  = canon600(playbackManager.currentTime)
                                        let play = canon600(playbackManager.getCurrentPlayingTime())
                                        var measured = now - play
                                        measured = CMTimeMaximum(.zero,
                                                                 CMTimeMinimum(measured, playbackManager.maxScrubbingDelay))
                                        playbackManager.delayTime = roundCMTimeToNearestTenth(measured)
                                        
                                        playbackManager.playPlayerIfWasPlaying()
                                    }
                                }
                        )
                }
            }
            .overlay(alignment: .leading) {
                VStack(spacing: 0) {
//                    Rectangle()
//                        .fill(Color.red)
//                        .frame(width: 2, height: 30)
                    ZStack {
                        Rectangle()
                            .fill(Color.red)
                            .frame(width: 50, height: 35)
                        Text(String(format: "%.1f s", bookmarkedDelay.seconds))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                        
                    }
                }
                .opacity(showMarker ? 1 : 0)
                .animation(
                    showMarker
                    ? .easeIn(duration: 0.3)
                    : .easeOut(duration: 1.0),
                    value: showMarker
                )
                .contentShape(Rectangle()) // enlarge hit-area
                .position(
                    x: barWidth * clampedMarker + margin,
                    y: (barHeight / 2) + 30
                )
//                .onTapGesture {
//                    let delay = CMTime(seconds: (1 - markerProgress) * playbackManager.maxScrubbingDelay.seconds, preferredTimescale: 600)
//                    DispatchQueue.global(qos: .userInitiated).async {
//                        playbackManager.playerConstant.pause()
//                        playbackManager.seeker?.smoothlyJump(delay: delay)
//                        playbackManager.delayTime = roundCMTimeToNearestTenth(delay)
//                        playbackManager.playerConstant.play()
//                    }
//                }
                .gesture(
                    DragGesture(minimumDistance: 0)
//                    .updating($markerIsDragging) { _, isDragging, _ in
//                        isDragging = true
//                    }
                    .onChanged { value in
                        if drag2StartTranslation == 0 {
                            drag2StartTranslation = value.translation.width
                            return
                        }
                        showAndScheduleHide()

                        let deltaX  = value.translation.width - drag2StartTranslation
                        let newProg = lastMarkerProgress + (deltaX / barWidth)
                        // clamp to [0,1] for geometry
                        markerProgress = min(max(newProg, 0), rightLimit)
                        // update the absolute bookmark to match the new position
                        bookmarkedDelay = delay(for: markerProgress)
                    }
                    .onEnded { _ in
                        lastMarkerProgress = markerProgress
                        markerDragStart = 0
                        drag2StartTranslation = 0
                    }
                    , isEnabled: showMarker
                )
                
            }
            .overlay(alignment: .bottomLeading) {
                Group {
                    if let d = effectiveDelaySeconds() {
                        Text("\(formatTimeDifference(d))s ago")
                            .foregroundColor(.white)
                    } else if isScrubbableReady {
                        Text("LIVE")
                            .fontWeight(.bold)
                            .foregroundColor(.red)   // stays red now
                    } else {
                        EmptyView()
                    }
                }
                .font(.system(size: 20))
                .frame(width: 150, height: 20)
                .offset(x: barWidth * progress, y: -10)
            }
            .overlay(alignment: .bottomLeading) {
                // Show the *actual* delay (can exceed window) for diagnostics
                let now  = canon600(playbackManager.currentTime)
                let play = canon600(playbackManager.getCurrentPlayingTime())
                let actual = max(0, (now - play).seconds)

                Text("\(formatTimeDifference(-actual)) \(playbackManager.playerConstant.rate)")
                    .font(.system(size: 14))
                    .foregroundColor(.white)
                    .frame(width: 180, height: 20)
                    .offset(x: barWidth * progress, y: 20)
            }
        }.frame(height: 50)
    }
    
}

func formatTimeDifference(_ diffSeconds: Double) -> String {
    
    guard !diffSeconds.isNaN else {
        return ""
    }
        
    let absDiff = abs(diffSeconds)

    if absDiff < 60 {
        // Format as a decimal number with one decimal place
        return String(format: "%.1f", diffSeconds)
    } else {
        // Convert to minutes, seconds, and fractional part
        let minutes = Int(diffSeconds) / 60
        let seconds = abs(diffSeconds - Double(minutes) * 60)
        let fraction = abs(diffSeconds.truncatingRemainder(dividingBy: 1)) // Fractional part

        return String(format: "%d:%04.1f", minutes, seconds)
    }
}


func roundCMTimeToNearestTenth(_ time: CMTime) -> CMTime {
    let seconds = CMTimeGetSeconds(time)
    let roundedSeconds = (seconds * 10).rounded() / 10
    return CMTimeMakeWithSeconds(roundedSeconds, preferredTimescale: time.timescale)
}







#Preview {
    ContentView()
}


//
//  PlaybackManager.swift
//  LiveReplay
//
//  Created by Albert Soong on 4/20/25.
//

    import AVKit
    import Combine

    final class PlaybackManager: ObservableObject {
        
        static let shared = PlaybackManager()

        var cameraManager: CameraManager { .shared }
        var bufferManager: BufferManager { .shared }
        
        @Published var playerConstant = AVQueuePlayer()

        @Published var seeker: PlayerSeeker?
        
        /// The smoothed live edge of recorded content.
        /// Content-time is the source of truth; interpolated between segment commits for smooth UI.
        var liveEdge: CMTime { BufferManager.shared.liveEdge }

        var earliestScrubbingTime: CMTime = .zero
        var delayTime: CMTime = .zero

        /// Short hold window to absorb AVPlayer's timebase snap when resuming.
        /// While CACurrentMediaTime() < scrubberHoldUntil, the scrubber knob
        /// stays at its previous position so the one-frame snap isn't visible.
        var scrubberHoldUntil: CFTimeInterval = 0

        func holdScrubberForSettle(_ seconds: Double = 0.25) {
            scrubberHoldUntil = CACurrentMediaTime() + seconds
        }

        /// The delay (liveEdge − playhead) saved when the app backgrounds.
        /// On resume, a seek re-establishes this delay so the knob stays put.
        var resumeTargetDelay: CMTime = .zero

        /// Closure provided by ContentView to perform a bookmark-style resume:
        /// seeks to the given delay, snaps the scrubber knob, and starts playing.
        /// This runs the same code path as the bookmark button, ensuring the knob
        /// and delay label are instantly correct with no drift.
        var resumeFromBackgroundHandler: ((CMTime) -> Void)?
        
        var maxScrubbingDelay = CMTimeMake(value: 30, timescale: 1)
        var minScrubbingDelay = CMTimeMake(value: 20, timescale: 10)
        
        // This closure will be provided by the UI (ContentView)
        var snapshotHandler: (() -> Void)?
        
        var nextItemIsSeeking: Bool = false
        
        /// keep track of the current playing asset and it's starting time. will be updated by observer
        var currentPlayingAsset: AVAsset?
        var currentlyPlayingAssetStartTime: CMTime = .zero
        var currentlyPlayingPlayerItemStartTime: CMTime = .zero
        
        private var currentItemObservation: NSKeyValueObservation?
        private var itemPlayerUntilEndObserver: Any?
        var playerItemStartTimeKey: UInt8 = 0
        
    //    var playbackEffectTimer: Timer?
    //    @Published var isPlayingPingPong: Bool = false
    //    var playingBackAndForthCount: Int = 0
        
        
        private var playbackBoundaryObserver: Any?
        private var playbackLoopStart: CMTime = .zero
        private var playbackLoopEnd: CMTime = .zero
        private let playbackLoopWindowDuration: CMTime = CMTime(seconds: 2, preferredTimescale: 600) // e.g. 2s total
        @Published var isPlayingPingPong = false
        @Published var isPlayingLoop = false

        private var isJumpingToItem: Bool = false
        
        enum PlaybackState {
          case unknown    // just started, no user action yet
          case paused     // user intentionally paused
          case playing    // playing (whether auto-started, user-started, or buffer-forced)
        }
        
        var playbackState: PlaybackState = .unknown
        
        /// True while doing "seek then pause"; cleared on play. Prevents late seek completion from pausing after user hit play.
        private var pendingPauseAfterSeek: Bool = false
        
        init() {
            seeker = PlayerSeeker(player: playerConstant)
     //       playerConstant.automaticallyWaitsToMinimizeStalling = true
            currentItemObservation = playerConstant.observe(\.currentItem, options: [.new]) {
                [weak self] _, change in
                self?.playerItemDidChange(to: change.newValue ?? nil)
            }
    //        itemPlayerUntilEndObserver = NotificationCenter.default.addObserver(
    //          forName: .AVPlayerItemDidPlayToEndTime,
    //          object: nil, queue: .main
    //        ) { note in
    //          (note.object as? AVPlayerItem)?.seek(to: .zero)
    //        }
        }
        
    //    /// -1 unkown, 0 was not playing before, 1 was playing before
    //    var wasPlayingBefore = -1
    //    func pausePlayerIfPlaying() {
    //        /// check only if -1 so we don't do it multiple times
    //        if wasPlayingBefore == -1 {
    //            if playerConstant.rate > 0 {
    //                wasPlayingBefore = 1
    //                playerConstant.pause()
    //            } else {
    //                wasPlayingBefore = 0
    //            }
    //        }
    //    }
    //    func playPlayerIfWasPlaying() {
    //        if wasPlayingBefore == 1 {
    //            playerConstant.play()
    //        }
    //        /// reset
    //        wasPlayingBefore = -1
    //    }
    //
    //    func resumeNormalPlayback() {
    //        playerConstant.rate = 1
    //        playerConstant.play()
    //    }
        
        
        func pausePlayer() {
            playerConstant.pause()
            playbackState = .paused
        }
        
        func playPlayer() {
            playerConstant.play()
            playbackState = .playing
        }
        
        func pausePlayerTemporarily() {
            if playerConstant.rate > 0 {
                playerConstant.pause()
            }
        }
        
        func playPlayerIfWasPlaying() {
            if playbackState == .playing {
                playerConstant.play()
            }
        }
        
        // Placeholder function for rewind 10 seconds
        func rewind10Secondsx() {
    //        DispatchQueue.global(qos: .userInitiated).async {
    //            self.pausePlayer()
    //            self.playerConstant.currentItem!.step(byCount: -1)
    //        }
    //        return
            ///Calculate target time, if using that
            var targetTime = CMTimeSubtract(getCurrentPlayingTime(), CMTime(seconds: 10, preferredTimescale: 600))
            targetTime = max(targetTime, liveEdge - maxScrubbingDelay)
            /// Calculate delay time, if using that
            var currentDelay = delayTime
            if currentDelay == .zero {
                currentDelay = liveEdge - getCurrentPlayingTime()
            }
            let delay = min(currentDelay + CMTime(seconds: 10, preferredTimescale: 600), liveEdge - BufferManager.shared.earliestPlaybackBufferTime, maxScrubbingDelay)
            printBug(.bugForwardRewind, "rewinding to delay: ", delay.seconds)
            printBug(.bugForwardRewind, "now, earliestscrubbing: ", liveEdge.seconds, earliestScrubbingTime.seconds, BufferManager.shared.earliestPlaybackBufferTime.seconds)
            DispatchQueue.global(qos: .userInitiated).async {
                self.pausePlayerTemporarily()
    //               seeker?.smoothlyJump(delay: delay)
    //            self.seeker?.smoothlyJump(targetTime: targetTime)
                self.scrub(to: targetTime)
                printBug(.bugForwardRewind, self.liveEdge.seconds, self.getCurrentPlayingTime().seconds)
                self.delayTime = roundCMTimeToNearestTenth(delay)
                self.playPlayerIfWasPlaying()
            }
        }
        
        // Play/pause: pin delay for UI. On pause, seek to current time (zero tolerance) then pause to avoid frame jump.
        func togglePlayPause() {
            if playerConstant.rate == 0 {
                pendingPauseAfterSeek = false
                delayTime = roundCMTimeToNearestTenth(liveEdge - getCurrentPlayingTime())
                playPlayer()
            } else {
                delayTime = roundCMTimeToNearestTenth(liveEdge - getCurrentPlayingTime())
                guard playerConstant.currentItem != nil else {
                    pausePlayer()
                    return
                }
                pendingPauseAfterSeek = true
                let nowInItem = playerConstant.currentTime()
                playerConstant.seek(to: nowInItem, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                    DispatchQueue.main.async {
                        guard let self = self, self.pendingPauseAfterSeek else { return }
                        self.pendingPauseAfterSeek = false
                        self.pausePlayer()
                    }
                }
            }
        }
        
        // Placeholder function for forward 10 seconds
        func forward10Secondsx() {
    //        DispatchQueue.global(qos: .userInitiated).async {
    //            self.pausePlayer()
    //            self.playerConstant.currentItem!.step(byCount: 1)
    //        }
    //        return
            ///Calculate target time, if using that
            var targetTime = CMTimeAdd(getCurrentPlayingTime(), CMTime(seconds: 10, preferredTimescale: 600))
            targetTime = min(targetTime, liveEdge-minScrubbingDelay)
            printBug(.bugForwardRewind, "getCurrentPlayingTime: ", getCurrentPlayingTime())
            printBug(.bugForwardRewind, "liveEdge: ", liveEdge)
            printBug(.bugForwardRewind, "minScrubbingDelay: ", minScrubbingDelay)
            printBug(.bugForwardRewind, "currentlyPlayingPlayerItemStartTime: ", currentlyPlayingPlayerItemStartTime)
            printBug(.bugForwardRewind, "playerConstant.currentTime(): ", playerConstant.currentTime())

            /// Calculate delay time, if using that
            var currentDelay = delayTime
            if currentDelay == .zero {
                currentDelay = liveEdge - getCurrentPlayingTime()
            }
            let delay = max(currentDelay - CMTime(seconds: 10, preferredTimescale: 600), minScrubbingDelay)
            printBug(.bugForwardRewind, "forwarding to delay: ", delay.seconds)
            DispatchQueue.global(qos: .userInitiated).async {
                self.pausePlayerTemporarily()
    //               seeker?.smoothlyJump(delay: delay)
    //            self.seeker?.smoothlyJump(targetTime: targetTime)
                self.scrub(to: targetTime)
                self.delayTime = roundCMTimeToNearestTenth(delay)
                self.playPlayerIfWasPlaying()
                
            }
        }

        func rewind10Seconds() {
            // Base delay = pinned target if set, else measured delay right now
            let now600      = CMTimeConvertScale(liveEdge,             timescale: 600, method: .default)
            let play600     = CMTimeConvertScale(getCurrentPlayingTime(), timescale: 600, method: .default)
            let earliest600 = CMTimeConvertScale(BufferManager.shared.earliestPlaybackBufferTime, timescale: 600, method: .default)

            let maxD = maxScrubbingDelay.seconds
            let minD = minScrubbingDelay.seconds
            let availableSec = max(0, (now600 - earliest600).seconds)        // how much buffer we truly have
            let upperSec     = min(maxD, availableSec)                       // cannot request beyond this

            let baseSec: Double = (delayTime != .zero) ? delayTime.seconds : max(0, (now600 - play600).seconds)
            let requestedSec = baseSec + 10.0

            // clamp to [minD, upperSec], but if buffer is tiny, allow up to upperSec
            let clampedSec: Double = (upperSec < minD)
                ? upperSec
                : min(max(requestedSec, minD), upperSec)

            // Pin exact target delay (what UI shows) and jump to now - delay
            delayTime = roundCMTimeToNearestTenth(CMTime(seconds: clampedSec, preferredTimescale: 600))
            let targetAbs = now600 - delayTime

            printBug(.bugForwardRewind, "rewind to delay:", clampedSec, "available:", availableSec)

            DispatchQueue.main.async {
                self.pausePlayerTemporarily()
                self.scrub(to: targetAbs, allowSeekOnly: true) {
                    self.playPlayerIfWasPlaying()
                }
            }
        }
        
        func forward10Seconds() {
            // Base delay = pinned target if set, else measured delay right now
            let now600      = CMTimeConvertScale(liveEdge,             timescale: 600, method: .default)
            let play600     = CMTimeConvertScale(getCurrentPlayingTime(), timescale: 600, method: .default)
            let earliest600 = CMTimeConvertScale(BufferManager.shared.earliestPlaybackBufferTime, timescale: 600, method: .default)

            let maxD = maxScrubbingDelay.seconds
            let minD = minScrubbingDelay.seconds
            let availableSec = max(0, (now600 - earliest600).seconds)        // how much buffer we truly have
            let upperSec     = min(maxD, availableSec)                       // cannot request beyond this

            let baseSec: Double = (delayTime != .zero) ? delayTime.seconds : max(0, (now600 - play600).seconds)
            let requestedSec = baseSec - 10.0

            // clamp to [minD, upperSec], but if buffer is tiny, allow up to upperSec
            let clampedSec: Double = (upperSec < minD)
                ? upperSec
                : min(max(requestedSec, minD), upperSec)

            // Pin exact target delay (what UI shows) and jump to now - delay
            delayTime = roundCMTimeToNearestTenth(CMTime(seconds: clampedSec, preferredTimescale: 600))
            let targetAbs = now600 - delayTime

            printBug(.bugForwardRewind, "forward to delay:", clampedSec, "available:", availableSec)

            DispatchQueue.main.async {
                self.pausePlayerTemporarily()
                self.scrub(to: targetAbs, allowSeekOnly: true) {
                    self.playPlayerIfWasPlaying()
                }
            }
        }
        
        private func configureLoopWindow(around time: CMTime) {
            let half = CMTimeMultiplyByFloat64(playbackLoopWindowDuration, multiplier: 0.5)
            playbackLoopStart = CMTimeSubtract(time, half)
            playbackLoopEnd   = CMTimeAdd(time, half)
            print("configure loop", half, time, playbackLoopStart, playbackLoopEnd)
        }
        func removePlaybackBoundaryObserver() {
            DispatchQueue.main.async {
                if let token = self.playbackBoundaryObserver {
                    self.playerConstant.removeTimeObserver(token)
                    self.playbackBoundaryObserver = nil
                }
            }
        }
        func pingPong() {
            /// Remove any boundary observer (could be ping pong or loop or anything new)
            removePlaybackBoundaryObserver()
            if !isPlayingPingPong {
                pausePlayerTemporarily()
    //            seeker?.smoothlyJump(targetTime: getCurrentPlayingTime(), allowSeekOnly: false)
                scrub(to: getCurrentPlayingTime(), allowSeekOnly: false)
                let current = playerConstant.currentTime()
                configureLoopWindow(around: current)
                startBoundaryObserver()
                playBackward()
                /// In case we were doing this
                isPlayingLoop = false
                isPlayingPingPong = true
            } else {
                playerConstant.rate = 1.0
                playPlayerIfWasPlaying()
                isPlayingPingPong = false
            }
        }
        
        private func startBoundaryObserver() {
            DispatchQueue.main.async {
                let times = [ NSValue(time: self.playbackLoopEnd), NSValue(time: self.playbackLoopStart) ]
                self.playbackBoundaryObserver = self.playerConstant.addBoundaryTimeObserver(
                    forTimes: times,
                    queue: .main
                ) { [weak self] in
                    guard let self = self else { return }
                    let rate = self.playerConstant.rate
                    let t    = self.playerConstant.currentTime()

                    if rate > 0, t >= self.playbackLoopEnd {
                        // we’ve just run past the end going forward
                        self.playBackward()
                    }
                    else if rate < 0, t <= self.playbackLoopStart {
                        // we’ve just run past the start going backward
                        self.playForward()
                    }
                }
            }
        }
        
        private var isReversing = false

        private func playForward() {
          isReversing = false
          playerConstant.rate = 1.0
        }

        private func playBackward() {
          isReversing = true
          playerConstant.rate = -1.0
        }

        private func flipDirection() {
          if isReversing {
              print("flip forward")
            playForward()
          } else {
              print("flip backward")
            playBackward()
          }
        }
        
        
        func loop() {
            /// Remove any boundary observer (could be ping pong or loop or anything new)
            removePlaybackBoundaryObserver()
            if !isPlayingLoop {
                pausePlayerTemporarily()
    //            seeker?.smoothlyJump(targetTime: getCurrentPlayingTime(), allowSeekOnly: false)
                scrub(to: getCurrentPlayingTime(), allowSeekOnly: false)
                let current = playerConstant.currentTime()
                configureLoopWindow(around: current)
                startLoop()
                /// In case we were doing this
                isPlayingPingPong = false
                isPlayingLoop = true
            } else {
                playerConstant.rate = 1.0
                playPlayerIfWasPlaying()
                isPlayingLoop = false
            }
        }
        
        
        func startLoop() {
          // 1) configure your window around the current playhead
            playerConstant.seek(
              to: playbackLoopStart,
              toleranceBefore: .zero,
              toleranceAfter: .zero
            )
            // 3) wire up a boundary observer on loopEnd only
            playbackBoundaryObserver = playerConstant.addBoundaryTimeObserver(
              forTimes: [ NSValue(time: playbackLoopEnd) ],
              queue: .main
            ) { [weak self] in
              guard let self = self else { return }
              // jump back to loopStart and continue playing
              self.playerConstant.seek(
                to: self.playbackLoopStart,
                toleranceBefore: .zero,
                toleranceAfter: .zero
              ) { _ in
                self.playerConstant.rate = 1.0
              }
            }
            
            // 4) kick off playback
            self.playerConstant.rate = 1.0

        }
        
        /// Look up the currentlyPlayingPlayerItemStartTime via associated object
        private func playerItemDidChange(to newItem: AVPlayerItem?) {
            guard let item = newItem else {
                printBug(.bugPlayerItemObserver, "⚠️ currentItem is nil")
                return
            }
            
            let ptrObs = Unmanaged.passUnretained(item).toOpaque()
            printBug(.bugPlayerItemObserver, "🤖 observed currentItem @ \(ptrObs)")
            
            if let startTime = objc_getAssociatedObject(item, &playerItemStartTimeKey) as? NSValue {
                currentlyPlayingPlayerItemStartTime = startTime.timeValue
                printBug(.bugPlayerItemObserver, "✅ found start time \(startTime.timeValue)")
            } else {
                printBug(.bugPlayerItemObserver, "⚠️ did not find start time")
            }
            return
        }
        
        func advanceToNextItemWithSnapshot() {
            DispatchQueue.main.async {
                // Call the UI snapshot callback if available
                if self.nextItemIsSeeking || true {
                    printBug(.bugSnapshot, "snapshot handler")
                    self.snapshotHandler?()
                } else {
                    // Advance to the next item
                    printBug(.bugSnapshot, "advance")
                    self.playerConstant.advanceToNextItem()
                }
            }
        }
        
        func getCurrentPlayingTime() -> CMTime {
            return currentlyPlayingPlayerItemStartTime +  playerConstant.currentTime()
        }
        
        func percentagePlayed() -> Double {
            earliestScrubbingTime = liveEdge - maxScrubbingDelay
            let timePlayed = getCurrentPlayingTime().seconds - earliestScrubbingTime.seconds
            let totalTime = maxScrubbingDelay.seconds
            printBug(.bugPercentagePlayed, "calculating progress", timePlayed / totalTime, bufferManager.earliestPlaybackBufferTime.seconds, earliestScrubbingTime.seconds, currentlyPlayingPlayerItemStartTime.seconds, playerConstant.currentTime().seconds, playerConstant.currentItem?.duration.seconds ?? "", getCurrentPlayingTime().seconds, liveEdge.seconds, maxScrubbingDelay.seconds, currentPlayingAsset, delayTime)
            return timePlayed / totalTime
        }
        
        /// Calculates the available scrubbing on the left (earlier time) side
        func percentageAvailable() -> Double {
            var available: Double = 0.0
            available = max(0, 1 - (liveEdge.seconds - bufferManager.earliestPlaybackBufferTime.seconds) / maxScrubbingDelay.seconds)
            return available
        }
        

        
        private var isJumping = false

        func jump(to absoluteTime: CMTime, completion: (() -> Void)? = nil) {
            printBug(.bugSmoothlyJump, "🔀 jump(to: \(absoluteTime)) called; isJumping=\(isJumping)")
            // 1️⃣ Drop any new jumps while one is in flight
            guard !isJumping else {
                printBug(.bugSmoothlyJump, "⚠️ Already jumping—ignoring this one.")
                completion?()
                return
            }
            isJumping = true

            // 2️⃣ Figure out which buffer‐slot holds that time…
            let oldest = bufferManager.segmentIndex % bufferManager.maxBufferSize
            var chosenIndex: Int?
            var localOffset = CMTime.zero

            for i in 0..<bufferManager.maxBufferSize {
              let idx = (oldest + i) % bufferManager.maxBufferSize
              if let item = bufferManager.playerItemBuffer[idx],
                 let startTime = bufferManager.timingBuffer[idx],
                 CMTimeAdd(startTime, item.duration) > absoluteTime
              {
                chosenIndex = idx
                localOffset = absoluteTime - startTime
                break
              }
            }
            guard let bufferIndex = chosenIndex,
                  let targetItem = bufferManager.playerItemBuffer[bufferIndex],
                  let currentItem = playerConstant.currentItem
            else {
              printBug(.bugSmoothlyJump, "⚠️ No buffer slot for \(absoluteTime); aborting jump.")
              isJumping = false
              completion?()
              return
            }

            // 3️⃣ Seek and then splice in on the _main_ thread
            DispatchQueue.main.async {
              printBug(.bugSmoothlyJump, "🔍 Seeking targetItem to \(localOffset)")
              targetItem.seek(to: localOffset, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
                guard let self = self else { return }
                DispatchQueue.main.async {
                  // ⚠️ Only insert if it isn’t already in the queue
                  let queueItems = self.playerConstant.items()
                  if queueItems.contains(targetItem) && false {
                    printBug(.bugSmoothlyJump, "⚠️ targetItem already in queue—skipping insert")
                  } else {
                    printBug(.bugSmoothlyJump, "➕ Inserting targetItem after currentItem")
                    self.playerConstant.insert(targetItem, after: currentItem)
                  }

                  printBug(.bugSmoothlyJump, "⏭ Advancing to next item")
                  self.playerConstant.advanceToNextItem()

                  printBug(.bugSmoothlyJump, "🗑 Pruning all other items")
                  self.playerConstant.items()
                    .filter { $0 !== targetItem }
                    .forEach(self.playerConstant.remove)

                  printBug(.bugSmoothlyJump, "✅ Jump complete")
                  self.isJumping = false
                  completion?()
                }
              }
            }
        }


        
        func scrub(to targetTime: CMTime, allowSeekOnly: Bool, completion: (() -> Void)? = nil) {
            guard let currentItem = playerConstant.currentItem else {
                printBug(.bugSmoothlyJump, "⚠️ No currentItem—nothing to scrub.")
                completion?()
                return
            }
            print("target time", targetTime)
            // Calculate the absolute time-range of the current AVPlayerItem in the global timeline:
            let itemPlayheadOffset = currentlyPlayingPlayerItemStartTime
            let itemLocalRange = CMTimeRange(start: itemPlayheadOffset,
                                             duration: currentItem.duration)
            print("currently playing", itemPlayheadOffset)
            print("itemlocalrange", itemLocalRange)
            if allowSeekOnly && itemLocalRange.containsTime(targetTime) {
                // …it falls inside the current item → just seek locally
                let localSeekTime = CMTimeSubtract(targetTime, itemPlayheadOffset)
                printBug(.bugSmoothlyJump, "Seeking inside currentItem to \(localSeekTime)")
                seeker?.smoothlySeek(to: localSeekTime, completion: completion)
            } else {
                // …it’s outside → find the right buffer slot & reload the queue
                printBug(.bugSmoothlyJump, "Need to jump to \(targetTime)")
            //    jumpToPlayingTime(targetTime: targetTime)
                jump(to: targetTime, completion: completion)
            }
        }
        
        /// 1) Absolute time scrub (allows in-item seeks)
        func scrub(to target: CMTime) {
            scrub(to: target, allowSeekOnly: true)
        }

        /// 2) Delay-based scrub (maps “now – delay” → absolute, then scrub)
        func scrub(delay: CMTime) {
            let target = liveEdge - delay
            scrub(to: target, allowSeekOnly: true)
        }

        /// Instant jump to a delay (e.g. bookmark): no smooth seek, knob can snap in UI.
        func scrubImmediate(delay: CMTime) {
            let targetTime = liveEdge - delay
            guard let currentItem = playerConstant.currentItem else { return }
            let itemPlayheadOffset = currentlyPlayingPlayerItemStartTime
            let itemLocalRange = CMTimeRange(start: itemPlayheadOffset,
                                             duration: currentItem.duration)
            if itemLocalRange.containsTime(targetTime) {
                let localSeekTime = CMTimeSubtract(targetTime, itemPlayheadOffset)
                seeker?.cancelPendingSeeks()
                seeker?.directlySeek(to: localSeekTime)
            } else {
                jump(to: targetTime, completion: nil)
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self, name: UIDevice.orientationDidChangeNotification, object: nil)
            print("Removed orientation observer.")
        }
        
        
        
        func printPlayerQueueWithAssets() {
            if doBug(.bugPlayerQueue) {
                printBug(.bugPlayerQueue, "🕰️ Current AVQueuePlayer Items: \(playerConstant.items().count)")
                
                for item in playerConstant.items() {
                    printBug(.bugPlayerQueue, "🔹 \(describePlayerItemWithAssets(item))")
                }
                printBug(.bugPlayerQueue, "End AVQueuePlayer Items")
            }
        }

        // Helper function to convert AVKeyValueStatus to a String.
        func assetStatusString(for asset: AVAsset) -> String {
            let status = asset.statusOfValue(forKey: "playable", error: nil)
            switch status {
            case .loaded:
                return "Loaded"
            case .loading:
                return "Loading"
            case .failed:
                return "Failed"
            case .unknown:
                return "Unknown"
            @unknown default:
                return "Unknown"
            }
        }

        func describePlayerItemWithAssets(_ item: AVPlayerItem) -> String {
            let memoryAddress = Unmanaged.passUnretained(item).toOpaque()
            let itemCurrentTime = item.currentTime().seconds
            let totalDuration = item.asset.duration.seconds

            let formattedCurrentTime = itemCurrentTime.isFinite ? String(format: "%.2f", itemCurrentTime) : "Unknown"
            let formattedTotalDuration = totalDuration.isFinite ? String(format: "%.2f", totalDuration) : "Unknown"
            
            // Get asset status string.
            let assetStatus = assetStatusString(for: item.asset)
            
            var description = "AVPlayerItem: \(memoryAddress), Time: \(formattedCurrentTime)/\(formattedTotalDuration) sec, Status: \(item.status), Asset Status: \(assetStatus), \(item.seekableTimeRanges)"
            
            if let asset = item.asset as? AVURLAsset {
                description += ", Asset ID: \(asset.hash), URL: \(asset.url)"
            } else if let composition = item.asset as? AVComposition {
                description += ", Composition ID: \(composition.hash), Asset ID: \(composition.hash)\n"
                description += describeCompositionAssets(composition)
            } else {
                description += ", Asset: Unknown"
            }
            
            return description
        }

        func describeCompositionAssets(_ composition: AVComposition) -> String {
            var details = "  Composition Tracks:\n"

            for track in composition.tracks {
                let mediaType = track.mediaType.rawValue
                let timeRange = track.timeRange
                let start = timeRange.start.seconds
                let duration = timeRange.duration.seconds
                details += "  - Track ID: \(track.trackID), Type: \(mediaType), Start: \(start), Duration: \(duration)\n"

                for segment in track.segments {
                    if let compSegment = segment as? AVCompositionTrackSegment, let sourceURL = compSegment.sourceURL {
                        let sourceStart = compSegment.timeMapping.source.start.seconds
                        let sourceDuration = compSegment.timeMapping.source.duration.seconds
                        details += "    - Source Asset: \(sourceURL)\n"
                        details += "      - Source Time Range: Start: \(sourceStart), Duration: \(sourceDuration)\n"
                    } else {
                        details += "    - ⚠️ Unknown Source Segment\n"
                    }
                }
            }

            return details
        }


        func describePlayerItem(_ item: AVPlayerItem) -> String {
            let memoryAddress = Unmanaged.passUnretained(item).toOpaque()
            let itemCurrentTime = item.currentTime().seconds
            let totalDuration = item.asset.duration.seconds

            let formattedCurrentTime = itemCurrentTime.isFinite ? String(format: "%.4f", itemCurrentTime) : "Unknown"
            let formattedTotalDuration = totalDuration.isFinite ? String(format: "%.4f", totalDuration) : "Unknown"

            if let asset = item.asset as? AVURLAsset {
                return "AVPlayerItem: \(memoryAddress), URL: \(asset.url), Time: \(formattedCurrentTime)/\(formattedTotalDuration) sec, Status: \(item.status), \(item.seekableTimeRanges)"
            } else {
                return "AVPlayerItem: \(memoryAddress), Time: \(formattedCurrentTime)/\(formattedTotalDuration) sec, Asset: Unknown, Status: \(item.status), \(item.seekableTimeRanges)"
            }
        }

        func printPlayerQueue() {
            if doBug(.bugPlayerQueue) {
                print("🎬 Current AVQueuePlayer Items:")
                
                let items = playerConstant.items()
                if items.isEmpty {
                    printBug(.bugPlayerQueue, "⚠️ Queue is empty.")
                } else {
                    for item in items {
                        let pointerAddress = Unmanaged.passUnretained(item).toOpaque()
                        printBug(.bugPlayerQueue, "AVPlayerItem: \(pointerAddress)")
                    }
                }
            }
        }

        func printPlayerItemBuffer() {
            if doBug(.bugBuffer) {
                printBug(.bugBuffer, "🕰️ Player Items (Oldest to Newest):")

                for i in 0..<bufferManager.maxBufferSize {
                    let bufferIndex = (bufferManager.segmentIndex + i) % bufferManager.maxBufferSize  // Iterate circularly
                    if let item = bufferManager.playerItemBuffer[bufferIndex] {
                        let memoryAddress = Unmanaged.passUnretained(item).toOpaque()  // Get Swift-style memory address
                        printBug(.bugBuffer, "🔹 \(bufferIndex): \(describePlayerItemWithAssets(item))", bufferManager.timingBuffer[bufferIndex], liveEdge)
                    }
                }
            }
        }
        
    }

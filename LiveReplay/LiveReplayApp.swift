//
//  LiveReplayApp.swift
//  LiveReplay
//
//  Created by Albert Soong on 7/21/25.
//

import SwiftUI
import AVFoundation
import CoreMedia

@main
struct LiveReplayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var backgroundTime: CFTimeInterval = 0
    @State private var wasPlaying: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                backgroundTime = CACurrentMediaTime()
                wasPlaying = PlaybackManager.shared.playerConstant.rate > 0
                PlaybackManager.shared.pausePlayer()
                CameraManager.shared.cancelCaptureSession()
                CameraManager.shared.cancelAssetWriter()

            case .active:
                // Subtract delta so currentTime (computed: wallClock + offset) stays where it was before background
                let delta = CACurrentMediaTime() - backgroundTime
                BufferManager.shared.bufferTimeOffset = CMTimeSubtract(
                    BufferManager.shared.bufferTimeOffset,
                    CMTime(seconds: delta, preferredTimescale: 600)
                )
                // Immediately update currentTime to reflect the adjusted offset
                // (prevents stale value between now and first captured frame)
                let now = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
                PlaybackManager.shared.currentTime = CMTimeAdd(now, BufferManager.shared.bufferTimeOffset)

                CameraManager.shared.initializeCaptureSession()
                // resetBuffer: false keeps the existing buffer and timeline intact across background
                CameraManager.shared.initializeAssetWriter(resetBuffer: false)

                // Defer player resume until the first frame arrives so that
                // playback and currentTime start advancing in sync (no scrub-bar drift).
                CameraManager.shared.resumePlaybackOnFirstFrame = wasPlaying

            default:
                break
            }
        }
    }
}

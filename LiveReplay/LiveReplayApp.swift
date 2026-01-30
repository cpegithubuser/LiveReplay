//
//  LiveReplayApp.swift
//  LiveReplay
//
//  Created by Albert Soong on 7/21/25.
//

import SwiftUI
import CoreMedia
import AVFoundation

@main
struct LiveReplayApp: App {
    @Environment(\.scenePhase) private var scenePhase
    
    // state to remember when we backgrounded
    @State private var backgroundTime: CFTimeInterval = 0
    @State private var wasPlaying: Bool = false
    
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
                    switch newPhase {
                    case .background:
                        // 1) Record the clock and pause everything
                        backgroundTime = CACurrentMediaTime()
                        wasPlaying    = PlaybackManager.shared.playerConstant.rate > 0
                        PlaybackManager.shared.pausePlayer()
                        // cancel the writer to avoid orphaned files
                        CameraManager.shared.assetWriter?.cancelWriting()

                    case .active:
                        // 2) Compute how long we were away
                        let delta = CACurrentMediaTime() - backgroundTime
                        let deltaCM = CMTime(seconds: delta, preferredTimescale: 600)

                        // 3) Shift your bufferTimeOffset so `currentTime` snaps back
                        // Use thread-safe method to adjust bufferTimeOffset
                        BufferManager.shared.adjustBufferTimeOffset(by: deltaCM)

                        // 4) Restart camera capture & asset writer
                        CameraManager.shared.initializeCaptureSession()
                        CameraManager.shared.initializeAssetWriter()

                        // 5) Resume playback only if we were playing before
                        if wasPlaying {
                          PlaybackManager.shared.playerConstant.play()
                          PlaybackManager.shared.playbackState = .playing
                        }

                    default:
                        break
                    }
                }

    }
}

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
    @State private var wasPlaying: Bool = false

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .onChange(of: scenePhase) { newPhase in
            switch newPhase {
            case .background:
                let pm = PlaybackManager.shared
                wasPlaying = pm.playerConstant.rate > 0

                // Save the current delay so we can re-establish it on return.
                // Only update when playing with a valid playhead.
                if wasPlaying,
                   pm.playerConstant.currentItem != nil {
                    let delay = pm.liveEdge - pm.getCurrentPlayingTime()
                    let clamped = CMTimeClampToRange(delay,
                        range: CMTimeRange(start: .zero, duration: pm.maxScrubbingDelay))
                    pm.resumeTargetDelay = clamped
                }

                BufferManager.shared.freezeLiveEdgeNow()
                pm.pausePlayer()
                CameraManager.shared.assetWriter?.cancelWriting()

            case .active:
                // liveEdge is frozen — it won't move until the first new
                // segment commits, so there's nothing to reconcile here.
                CameraManager.shared.initializeCaptureSession()
                CameraManager.shared.initializeAssetWriter(resetBuffer: false)

                // Defer resume until the first new segment is enqueued,
                // so liveEdge and the player start advancing in sync.
                CameraManager.shared.resumePlaybackOnFirstSegment = wasPlaying

            default:
                break
            }
        }
    }
}

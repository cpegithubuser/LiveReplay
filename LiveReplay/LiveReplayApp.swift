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
                // Minimal + solid behavior:
                // - stop player + clear AVQueuePlayer items
                // - tear down capture session + asset writer
                // - reset buffer (so no old-camera segments survive)
                backgroundTime = CACurrentMediaTime()
                wasPlaying = PlaybackManager.shared.playerConstant.rate > 0

                PlaybackManager.shared.stopAndClearQueue()
                BufferManager.shared.resetBuffer()
                CameraManager.shared.stopForBackground()

            case .active:
                // Minimal resume:
                // - restart capture + writer
                // - resume playback only if it was playing
                CameraManager.shared.startAfterForeground()

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

//
//  LiveReplayApp.swift
//  LiveReplay
//
//  Created by Albert Soong on 7/21/25.
//

import SwiftUI
import AVFoundation

@main
struct LiveReplayApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Remember whether we should resume playback after returning active
    @State private var wasPlaying: Bool = false

    // Avoid double-teardown when iOS delivers multiple background transitions
    @State private var didTeardownForBackground: Bool = false

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
                guard !didTeardownForBackground else { return }
                didTeardownForBackground = true

                wasPlaying = PlaybackManager.shared.playerConstant.rate > 0

                PlaybackManager.shared.stopAndClearQueue()
                BufferManager.shared.resetBuffer()
                CameraManager.shared.stopForBackground()

            case .active:
                // Minimal resume:
                // - restart capture + writer
                // - resume playback only if it was playing
                didTeardownForBackground = false

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

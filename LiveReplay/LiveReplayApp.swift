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

                PlaybackManager.shared.stopAndClearQueue()
                BufferManager.shared.resetBuffer()
                CameraManager.shared.stopForBackground()

            case .active:
                // Behave as if starting up: restart capture + writer only; do not auto-resume playback.
                // Same play logic as cold start (user taps play, or autoStartPlaybackIfNeeded with same guards).
                didTeardownForBackground = false

                CameraManager.shared.startAfterForeground()

            default:
                break
            }
        }
    }
}

//
//  CameraManager+CaptureOutput.swift
//  LiveReplay
//
//  Created by Albert Soong on 8/1/25.
//

import Foundation
import AVFoundation

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection)
    {
        // ✅ Guard #1: bail immediately if we're backgrounding/shutting down/switching
        if isBackgroundedOrShuttingDown { return }

        /// Drop a few frames because often they are dark from camera starting up
        if droppedFrames < 3 {
            droppedFrames += 1
            return
        }

        writerQueue.async { [weak self] in
            guard let self = self else { return }

            // ✅ Guard #2: bail again inside writerQueue (handles "already enqueued" work)
            if self.isBackgroundedOrShuttingDown { return }

            // Optional debug (unchanged)
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                _ = CVPixelBufferGetWidth(pixelBuffer)
                _ = CVPixelBufferGetHeight(pixelBuffer)
            } else {
                print("Could not access pixel buffer.")
            }

            // If we don't have a writer/input, do NOT recreate while gated.
            guard let writer = self.assetWriter,
                  let input  = self.videoInput
            else {
                // Minimal behavior: if we're active, try to create; if gated, the guard above already returned.
                self.createAssetWriter()
                return
            }

            // Start writer if needed
            if writer.status == .unknown {
                let success = writer.startWriting()
                assert(success)
                self.startTime = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: self.startTime)

                // record "now" -> buffer timeline offset
                self.bufferManager.bufferTimeOffset = CMTimeSubtract(
                    .zero,
                    CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
                )

            } else if writer.status == .writing {
                // normal path
            } else {
                // cancelled/failed/completed etc
                print("Asset writer in unexpected state: \(writer.status.rawValue)")
                return
            }

            // Safety: in case startTime is nil even though status progressed
            if self.startTime == nil {
                let success = writer.startWriting()
                assert(success)
                self.startTime = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: self.startTime)
            }

            if input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }
}

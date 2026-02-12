//
//  CameraManager+CaptureOutput.swift
//  LiveReplay
//
//  Created by Albert Soong on 8/1/25.
//

import Foundation
import AVFoundation

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    
    /// Throttle writer re-inits requested from captureOutput to avoid thrashing during transitions.
    private enum _WriterReinitGate {
        static var lastRequest: CFTimeInterval = 0
        static func shouldRequest(now: CFTimeInterval, minInterval: CFTimeInterval = 0.5) -> Bool {
            if now - lastRequest >= minInterval {
                lastRequest = now
                return true
            }
            return false
        }
    }
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        // Guard against late frames while backgrounding / switching cameras.
        if isBackgroundedOrShuttingDown {
            return
        }
        
        /// Drop a few frames because often they are dark from camera starting up
        if droppedFrames < 3 {
            droppedFrames += 1
            return
        }
        
        writerQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isBackgroundedOrShuttingDown else { return }
            
            // Print the width and height of the frame
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                //      print("Frame dimensions: \(width)x\(height)",UIDevice.current.orientation.rawValue, cameraSession?.outputs.first?.connections.first?.videoOrientation.rawValue ?? -1, currentTime)
                //            print("Frame dimensions: \(width)x\(height)",UIDevice.current.orientation.rawValue, cameraSession?.outputs.first?.connections.first?.videoOrientation.rawValue ?? -1, cameraLayer.connection?.videoOrientation.rawValue)
            } else {
                print("Could not access pixel buffer.")
            }
            
            guard let writer = self.assetWriter,
                  let input  = self.videoInput else {
                // Writer is being torn down / not ready yet (e.g., camera flip or foreground restart).
                // Minimal behavior: request a rebuild (throttled) and drop this frame.
                let now = CACurrentMediaTime()
                if _WriterReinitGate.shouldRequest(now: now) {
                    self.initializeAssetWriter()
                }
                return
            }

            switch writer.status {
            case .unknown:
                // Start the writer on the first frame we accept.
                let success = writer.startWriting()
                assert(success)
                self.startTime = sampleBuffer.presentationTimeStamp
                writer.startSession(atSourceTime: self.startTime)

                // Record CACurrentMediaTime of the first frame ("zero" on content timeline)
                self.bufferManager.bufferTimeOffset = CMTimeSubtract(
                    .zero,
                    CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 600)
                )

            case .writing:
                break

            case .failed, .cancelled:
                // Writer is not usable. Request a rebuild (throttled) and drop frame.
                let now = CACurrentMediaTime()
                if _WriterReinitGate.shouldRequest(now: now) {
                    self.cancelAssetWriter()
                    self.initializeAssetWriter()
                }
                return

            @unknown default:
                return
            }
            
            if input.isReadyForMoreMediaData {
              input.append(sampleBuffer)
            }
            
   //         print(sampleBuffer.presentationTimeStamp)
            
        }
    }
    

}

//
//  CameraPreview.swift
//  LiveReplay
//
//  Created by Albert Soong on 6/3/25.
//

import SwiftUI
import AVFoundation

// 1) UIView whose backing layer is AVCaptureVideoPreviewLayer
final class CameraPreviewUIView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        return layer as! AVCaptureVideoPreviewLayer
    }
}

struct CameraPreview: UIViewRepresentable {
    @ObservedObject private var manager = CameraManager.shared

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        // Always update to whatever the latest session is:
        uiView.videoPreviewLayer.session = manager.cameraSession

        // And update orientation each pass
        if let conn = uiView.videoPreviewLayer.connection {
            conn.videoOrientation = videoOrientation(from: UIDevice.current.orientation)
        }
    }
}

// Map UIDevice orientation → AVCaptureVideoOrientation
func videoOrientation(from deviceOrientation: UIDeviceOrientation) -> AVCaptureVideoOrientation {
    switch deviceOrientation {
//    case .portrait:           return .portrait
//    case .portraitUpsideDown: return .portraitUpsideDown
//    case .landscapeLeft:      return .landscapeRight   // note the “swap”
//    case .landscapeRight:     return .landscapeLeft    //  because the camera’s coordinate system is flipped
//    default:                  return .portrait         // fallback
    default:                  return .landscapeRight         // fallback
    }
}

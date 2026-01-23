//
//  PlayerView.swift
//  LiveReplay
//
//  Created by Albert Soong on 4/28/25.
//

import SwiftUI
import AVFoundation
import Combine

/// A UIView whose backing layer is AVPlayerLayer. You can assign an AVPlayer to its `.player` property.
final class PlayerUIView: UIView {
    override class var layerClass: AnyClass {
        return AVPlayerLayer.self
    }

    /// Convenience accessor for the underlying AVPlayerLayer
    var playerLayer: AVPlayerLayer {
        return layer as! AVPlayerLayer
    }

    /// Set this to your AVPlayer (or AVQueuePlayer) to render video
    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

    /// Video gravity (aspect, fill, etc.)
    var videoGravity: AVLayerVideoGravity {
        get { playerLayer.videoGravity }
        set { playerLayer.videoGravity = newValue }
    }
}


struct PlayerView: UIViewRepresentable {
    /// The AVPlayer (or AVQueuePlayer) that will drive playback
    var player: AVPlayer

    @ObservedObject var cameraManager = CameraManager.shared
    
    /// Whether the video should be flipped horizontally
    var isFlipped: Bool

    /// Minimum and maximum zoom scales
    var minZoom: CGFloat = 1.0
    var maxZoom: CGFloat = 4.0

    func makeCoordinator() -> Coordinator {
        return Coordinator(self)
    }

    func makeUIView(context: Context) -> UIScrollView {
        // 1) Create a UIScrollView
        let scrollView = UIScrollView(frame: .zero)
        /// Tag for the watermark to find
        scrollView.tag = 999
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = minZoom
        scrollView.maximumZoomScale = maxZoom
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
        scrollView.alwaysBounceHorizontal = false
        scrollView.alwaysBounceVertical = false

        // 2) Create the PlayerUIView (backed by AVPlayerLayer) and add it into the scroll view
        let playerContainer = PlayerUIView()
        playerContainer.videoGravity = .resizeAspect  // or .resizeAspectFill
        playerContainer.player = player
        playerContainer.translatesAutoresizingMaskIntoConstraints = false

        scrollView.addSubview(playerContainer)

        // 3) Constrain playerContainer to match scrollView’s size at zoomScale = 1.0
        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            playerContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Make playerContainer’s “intrinsic size” match the scrollView’s frame size
            playerContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            playerContainer.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // 4) Keep a reference in the coordinator so we can center after zoom
        context.coordinator.playerView = playerContainer

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        // 1) If the SwiftUI side changes `player`, update the layer’s player
        if let playerContainer = context.coordinator.playerView {
            playerContainer.player = player

            // 2) Apply horizontal flip (scaleX = -1) if isFlipped == true,
            //    otherwise reset to identity.
            if isFlipped && cameraManager.cameraLocation == .front {
                playerContainer.transform = CGAffineTransform(scaleX: -1, y: 1)
            } else {
                playerContainer.transform = .identity
            }
        }

        // You could also reset zoom back to 1.0 on certain conditions:
        // uiView.setZoomScale(minZoom, animated: false)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PlayerView
        weak var playerView: PlayerUIView?

        init(_ parent: PlayerView) {
            self.parent = parent
        }

        /// Tell the scrollView which subview should be zoomed
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return playerView
        }

        /// After zooming, center the playerView if it’s smaller than the scrollView
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let playerView = playerView else { return }

            // Calculate horizontal and vertical offset to keep content centered
            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0.0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0.0)

            playerView.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
        }
    }
}

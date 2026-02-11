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

    /// Keep the backing AVPlayerLayer sized to the view.
    /// Must be defensive: during pinch-zoom / transitions UIKit can momentarily produce non-finite geometry.
    override func layoutSubviews() {
        super.layoutSubviews()
        let b = bounds
        guard b.width.isFinite, b.height.isFinite, b.width > 0, b.height > 0 else {
            return
        }
        // Avoid implicit animations that can cause flashes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = b
        CATransaction.commit()
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

        // 2) Create a zoom container that the scroll view will zoom.
        //    This prevents us from fighting UIScrollView's zoom transform when we also need mirroring.
        let zoomContainer = UIView()
        zoomContainer.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(zoomContainer)

        // 3) Constrain zoomContainer to match scrollView’s size at zoomScale = 1.0
        NSLayoutConstraint.activate([
            zoomContainer.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            zoomContainer.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            zoomContainer.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            zoomContainer.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),

            // Make zoomContainer’s “intrinsic size” match the scrollView’s frame size
            zoomContainer.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            zoomContainer.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        // 4) Create the PlayerUIView (backed by AVPlayerLayer) inside the zoom container
        let playerContainer = PlayerUIView()
        playerContainer.videoGravity = .resizeAspect  // or .resizeAspectFill
        playerContainer.player = player
        playerContainer.translatesAutoresizingMaskIntoConstraints = false
        zoomContainer.addSubview(playerContainer)

        NSLayoutConstraint.activate([
            playerContainer.leadingAnchor.constraint(equalTo: zoomContainer.leadingAnchor),
            playerContainer.trailingAnchor.constraint(equalTo: zoomContainer.trailingAnchor),
            playerContainer.topAnchor.constraint(equalTo: zoomContainer.topAnchor),
            playerContainer.bottomAnchor.constraint(equalTo: zoomContainer.bottomAnchor)
        ])

        // 5) Keep references in the coordinator
        context.coordinator.zoomView = zoomContainer
        context.coordinator.playerView = playerContainer

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        guard let playerContainer = context.coordinator.playerView else { return }

        // If the SwiftUI side changes `player`, update the layer’s player.
        // IMPORTANT: do not rebind on every update; it can cause black frames during pinch-zoom.
        if playerContainer.player !== player {
            playerContainer.player = player
        }

        // Apply mirror on the PlayerUIView (NOT on the layer). The zoom transform is on zoomContainer.
        if isFlipped && cameraManager.cameraLocation == .front {
            playerContainer.transform = CGAffineTransform(scaleX: -1, y: 1)
        } else {
            playerContainer.transform = .identity
        }

        // Fix the "front camera after background" invisible case without fighting pinch-zoom.
        // If we ever land with a 0-size layout during transitions, ask UIKit for another layout pass.
        // Only force layout when not zooming (zooming can momentarily yield non-finite geometry).
        if playerContainer.bounds.size.width == 0 || playerContainer.bounds.size.height == 0 {
            DispatchQueue.main.async {
                guard uiView.isZooming == false else { return }
                uiView.setNeedsLayout()
                context.coordinator.zoomView?.setNeedsLayout()
                playerContainer.setNeedsLayout()
                if abs(uiView.zoomScale - 1.0) < 0.0001 {
                    uiView.layoutIfNeeded()
                    context.coordinator.zoomView?.layoutIfNeeded()
                    playerContainer.layoutIfNeeded()
                }
            }
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UIScrollViewDelegate {
        var parent: PlayerView
        weak var playerView: PlayerUIView?
        weak var zoomView: UIView?

        init(_ parent: PlayerView) {
            self.parent = parent
        }

        /// Tell the scrollView which subview should be zoomed
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            zoomView
        }

        /// After zooming, center the zoomView if it’s smaller than the scrollView
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let zoomView = zoomView else { return }

            let offsetX = max((scrollView.bounds.width - scrollView.contentSize.width) * 0.5, 0.0)
            let offsetY = max((scrollView.bounds.height - scrollView.contentSize.height) * 0.5, 0.0)

            zoomView.center = CGPoint(
                x: scrollView.contentSize.width * 0.5 + offsetX,
                y: scrollView.contentSize.height * 0.5 + offsetY
            )
        }
    }
}

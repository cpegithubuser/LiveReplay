//
//  ScrubberDotsLayerView.swift
//  LiveReplay
//
//  Flowing dots using CALayers + CAAnimation (no SwiftUI TimelineView / redraws).
//

import SwiftUI
import UIKit

struct ScrubberDotsLayerView: UIViewRepresentable {
    var barWidth: CGFloat
    var barHeight: CGFloat
    var leftBound: CGFloat
    var periodSec: Double
    var dotSize: CGFloat = 3
    var dotCount: Int = 12

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: CGRect(origin: .zero, size: CGSize(width: barWidth, height: barHeight)))
        view.backgroundColor = .clear
        view.layer.masksToBounds = true

        let dotColor = UIColor.black.withAlphaComponent(0.35).cgColor
        let halfDot = dotSize / 2
        let centerY = barHeight / 2

        for i in 0..<dotCount {
            let dot = CALayer()
            dot.name = "dot-\(i)"
            dot.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
            dot.cornerRadius = halfDot
            dot.backgroundColor = dotColor
            dot.position = CGPoint(x: barWidth + halfDot, y: centerY)
            view.layer.addSublayer(dot)
        }

        context.coordinator.dotLayers = (0..<dotCount).compactMap { i in
            view.layer.sublayers?.first(where: { $0.name == "dot-\(i)" })
        }
        context.coordinator.lastPeriodSec = periodSec
        context.coordinator.lastBarWidth = barWidth
        context.coordinator.lastBarHeight = barHeight
        context.coordinator.animationsAdded = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        let coord = context.coordinator
        let size = CGSize(width: barWidth, height: barHeight)
        view.bounds = CGRect(origin: .zero, size: size)

        // Mask: only show dots in scrubbable region [leftBound*barWidth, barWidth]
        let maskLayer = CALayer()
        maskLayer.backgroundColor = UIColor.white.cgColor
        maskLayer.frame = CGRect(
            x: barWidth * leftBound,
            y: 0,
            width: barWidth * max(0, 1 - leftBound),
            height: barHeight
        )
        view.layer.mask = maskLayer

        let halfDot = dotSize / 2
        let centerY = barHeight / 2
        let duration = max(0.001, periodSec)

        // Add repeating position animation to each dot (once); stagger by phase
        if !coord.animationsAdded, let dots = coord.dotLayers, dots.count == dotCount {
            coord.animationsAdded = true
            for (i, dot) in dots.enumerated() {
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = barWidth + halfDot
                anim.toValue = -halfDot
                anim.duration = duration
                anim.repeatCount = .infinity
                anim.timeOffset = Double(i) / Double(dotCount) * duration
                anim.isRemovedOnCompletion = false
                dot.add(anim, forKey: "flow")
            }
        }

        // If period or size changed, re-add animations (e.g. after initial layout with wrong size)
        if coord.lastPeriodSec != periodSec || coord.lastBarWidth != barWidth || coord.lastBarHeight != barHeight {
            coord.lastPeriodSec = periodSec
            coord.lastBarWidth = barWidth
            coord.lastBarHeight = barHeight
            coord.dotLayers?.enumerated().forEach { i, dot in
                dot.removeAnimation(forKey: "flow")
                dot.position = CGPoint(x: barWidth + halfDot, y: centerY)
                let anim = CABasicAnimation(keyPath: "position.x")
                anim.fromValue = barWidth + halfDot
                anim.toValue = -halfDot
                anim.duration = duration
                anim.repeatCount = .infinity
                anim.timeOffset = Double(i) / Double(dotCount) * duration
                anim.isRemovedOnCompletion = false
                dot.add(anim, forKey: "flow")
            }
        }
    }

    class Coordinator {
        var dotLayers: [CALayer]?
        var lastPeriodSec: Double = 0
        var lastBarWidth: CGFloat = 0
        var lastBarHeight: CGFloat = 0
        var animationsAdded: Bool = false
    }
}

import CoreGraphics
import SwiftUI
import Testing
@testable import RogaUI

@MainActor
struct HouseWindowAnimationTests {
    @Test(arguments: HouseWindowAnimation.allCases)
    func loopsWithoutJumping(_ animation: HouseWindowAnimation) {
        let lastTime = animation.duration - 0.000001
        for pane in HouseOutline.Pane.allCases {
            let last = animation.pose(of: pane, at: lastTime)
            let first = animation.pose(of: pane, at: 0)
            #expect(hypot(last.offset.x - first.offset.x, last.offset.y - first.offset.y) < 0.001)
            #expect(abs(last.turn - first.turn) < 0.001)
            #expect(abs(last.scale - first.scale) < 0.001)
            #expect(abs(last.shutterWidth - first.shutterWidth) < 0.001)
            #expect(abs(last.warmth - first.warmth) < 0.001)
            #expect(abs(last.glow - first.glow) < 0.001)
        }
        if let last = animation.beamTravel(at: lastTime), let first = animation.beamTravel(at: 0) {
            #expect(abs(last - first) < 0.001)
        }
    }

    @Test(arguments: HouseWindowAnimation.allCases)
    func panesFitTheDrawingAreaAtDifferentRotations(_ animation: HouseWindowAnimation) {
        let drawingArea = CGRect(x: 0, y: 0, width: 24, height: 24)
        for angle in [-35.0, 0, 11, 45, 90] {
            let placement = HouseWindowFigure.placement(in: drawingArea.size, rotation: .degrees(angle))
            for time in stride(from: 0, through: animation.duration, by: 1.0 / 60) {
                for pane in HouseOutline.Pane.allCases {
                    let path = pane.path
                    let bounds = path.boundingRect
                    let pose = animation.pose(of: pane, at: time)
                    let transform = pose.transform(around: CGPoint(x: bounds.midX, y: bounds.midY))
                    #expect(drawingArea.contains(path.applying(transform.concatenating(placement)).boundingRect))
                }
            }
        }
    }

    @Test func zeroRotationLevelsThePanes() {
        let size = HouseWindowFigure.frame.size
        let left = HouseOutline.Pane.topLeft.path.boundingRect
        let right = HouseOutline.Pane.topRight.path.boundingRect
        let leftCenter = CGPoint(x: left.midX, y: left.midY)
        let rightCenter = CGPoint(x: right.midX, y: right.midY)
        let original = HouseWindowFigure.placement(in: size, rotation: HouseWindowAnimation.logoRotation)
        let upright = HouseWindowFigure.placement(in: size, rotation: .zero)
        #expect(rightCenter.applying(original).y - leftCenter.applying(original).y > 10)
        #expect(abs(rightCenter.applying(upright).y - leftCenter.applying(upright).y) < 2)
    }

    @Test func chaseLightsTheOriginalPanesClockwise() {
        let chase = HouseWindowAnimation.windowChase
        for (index, brightest) in HouseOutline.Pane.allCases.enumerated() {
            let time = 0.042 + Double(index) * chase.duration / 4
            let brightestPose = chase.pose(of: brightest, at: time)
            #expect(abs(brightestPose.warmth - 1) < 0.001)
            for other in HouseOutline.Pane.allCases where other != brightest {
                #expect(chase.pose(of: other, at: time).warmth < brightestPose.warmth)
            }
        }
    }
}

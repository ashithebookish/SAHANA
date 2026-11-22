import CoreGraphics
import Foundation
import Vision

struct SeatTransitionDetector {
    static let frameRate = 10.0
    static let windowSize = 25
    static let stride = 5
    static let supportedWindowSizes = [20, 25, 30]

    struct Body {
        let hip: CGPoint
        let knee: CGPoint
        let torso: Double
    }

    enum Frame {
        case ambiguous
        case missing
        case visible(Body)

        var body: Body? {
            if case let .visible(body) = self { return body }
            return nil
        }

        var isAmbiguous: Bool {
            if case .ambiguous = self { return true }
            return false
        }
    }

    struct Signal {
        let hip: Double
        let leg: Double
        let sideways: Double
    }

    struct Evaluation {
        let action: String?
    }

    private struct Rule {
        let action: String
        let direction: Double
        let frames: Int
        let hip: Double
        let leg: Double
        let sideways: Double

        func matches(_ signal: Signal) -> Bool {
            direction * signal.hip >= hip && direction * signal.leg >= leg && signal.sideways <= sideways
        }
    }

    private static let rules = [
        Rule(action: "rise_from_seat", direction: 1, frames: 30, hip: 0.08, leg: 0.08, sideways: 0.35),
        Rule(action: "lower_to_seat", direction: -1, frames: 25, hip: 0.20, leg: 0.16, sideways: 0.60),
    ]
    private static let longestWindow = 30
    private static let shortestWindow = 25

    private static let required: [VNHumanBodyPoseObservation.JointName] = [
        .leftShoulder, .rightShoulder, .leftHip, .rightHip, .leftKnee, .rightKnee,
    ]

    private var frames: [Frame] = []
    private var firstTime: Double?
    private var lastIndex: Int?

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
        firstTime = nil
        lastIndex = nil
    }

    /// A nil evaluation means this frame did not complete a scheduled window.
    mutating func accept(
        _ poses: [VNHumanBodyPoseObservation], aspect: Double, time: Double
    ) throws -> Evaluation? {
        guard let index = beginSlot(at: time) else { return nil }
        let frame = try Self.frame(poses, aspect: aspect)
        return append(frame, at: index)
    }

    /// This overload makes timing and visibility testable independently of Vision.
    mutating func accept(_ frame: Frame, time: Double) -> Evaluation? {
        guard let index = beginSlot(at: time) else { return nil }
        return append(frame, at: index)
    }

    private mutating func beginSlot(at time: Double) -> Int? {
        guard time.isFinite else { return nil }
        if firstTime == nil { firstTime = time }
        guard let firstTime else { return nil }
        let slot = ((time - firstTime) * Self.frameRate).rounded()
        guard slot >= 0, slot < Double(Int.max) else { return nil }
        let index = Int(slot)
        if let lastIndex, index <= lastIndex { return nil }
        return index
    }

    private mutating func append(_ frame: Frame, at index: Int) -> Evaluation? {
        let gap = lastIndex.map { index - $0 - 1 } ?? 0
        if gap > 0 {
            frames.append(contentsOf: repeatElement(.missing, count: min(gap, Self.longestWindow)))
        }
        lastIndex = index
        frames.append(frame)
        if frames.count > Self.longestWindow { frames.removeFirst(frames.count - Self.longestWindow) }
        guard frames.count >= Self.shortestWindow,
              (index + 1).isMultiple(of: Self.stride) else { return nil }
        let matched = Self.rules.compactMap { rule -> String? in
            guard frames.count >= rule.frames,
                  let features = Self.signal(frames.suffix(rule.frames)),
                  rule.matches(features) else { return nil }
            return rule.action
        }
        return Evaluation(action: matched.count == 1 ? matched.first : nil)
    }

    static func frame(_ poses: [VNHumanBodyPoseObservation], aspect: Double) throws -> Frame {
        guard poses.count < 2 else { return .ambiguous }
        guard let pose = poses.first, aspect.isFinite, aspect > 0 else { return .missing }
        let points = try pose.recognizedPoints(.all)
        let visible = required.compactMap { joint -> CGPoint? in
            guard let point = points[joint], point.confidence >= 0.20 else { return nil }
            return CGPoint(x: point.location.x * aspect, y: point.location.y)
        }
        guard visible.count == required.count else { return .missing }
        let shoulders = midpoint(visible[0], visible[1])
        let hip = midpoint(visible[2], visible[3])
        let knee = midpoint(visible[4], visible[5])
        let torso = hypot(shoulders.x - hip.x, shoulders.y - hip.y)
        guard torso > 0.02, torso.isFinite else { return .missing }
        return .visible(Body(hip: hip, knee: knee, torso: torso))
    }

    static func signal(_ frames: ArraySlice<Frame>) -> Signal? {
        guard supportedWindowSizes.contains(frames.count), !frames.contains(where: \.isAmbiguous) else { return nil }
        let whole = frames.compactMap(\.body)
        let start = frames.prefix(stride).compactMap(\.body)
        let end = frames.suffix(stride).compactMap(\.body)
        guard whole.count >= frames.count * 4 / 5, start.count >= 4, end.count >= 4 else { return nil }
        let torso = median(whole.map(\.torso))
        let hip = (median(end.map { Double($0.hip.y) }) - median(start.map { Double($0.hip.y) })) / torso
        let leg = (median(end.map { Double($0.hip.y - $0.knee.y) }) -
                   median(start.map { Double($0.hip.y - $0.knee.y) })) / torso
        let sideways = abs(median(end.map { Double($0.hip.x) }) -
                           median(start.map { Double($0.hip.x) })) / torso
        return Signal(hip: hip, leg: leg, sideways: sideways)
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    private static func median(_ values: [Double]) -> Double {
        let ordered = values.sorted()
        return (ordered[(ordered.count - 1) / 2] + ordered[ordered.count / 2]) / 2
    }
}

@preconcurrency import AVFoundation
import CoreML
import Foundation
import Vision

final class MotionClassifier {
    private typealias Joint = VNHumanBodyPoseObservation.JointName

    static let labels: [String: String] = [
        "still_in_view": "Still in view", "seated_reposition": "Repositioned while seated",
        "reach_or_lean": "Reached or leaned", "rise_from_seat": "Rose from a seat",
        "lower_to_seat": "Lowered onto a seat", "seated_transfer": "Transferred between seats",
        "stepping": "Took steps", "other_expected_motion": "Other movement observed",
    ]

    private static let fullScope = "sahana_eight_label_prototype"
    private static let reducedScope = "sahana_four_label_prototype"
    private static let reducedLabels: Set<String> = [
        "still_in_view", "stepping", "rise_from_seat", "lower_to_seat",
    ]

    private struct ReducedModelInfo: Decodable {
        let scope: String
        let labels: [String]
        let frames_per_window: Int
        let frames_per_second: Int
        let minimum_pose_visibility: Double
        let minimum_joint_visibility: Double
        let minimum_point_confidence: Double
        let confidence_thresholds: [String: Double]
    }

    private struct Sample {
        let pose: MLMultiArray?
        let joints: Set<Joint>
    }

    private struct Model {
        let classifier: MLModel
        let input: String
        let label: String
        let scores: String
        let window: Int
        let zeros: MLMultiArray
        let confidenceThresholds: [String: Double]
    }

    struct RoomPoseEvidence {
        let time: Double
        let observation: RoomObservation
        let noBody: Bool
    }

    private let request = VNDetectHumanBodyPoseRequest()
    private var model: Model?
    private var samples: [Sample] = []
    private var lastFrame: Int?
    private var firstTime: Double?
    private var lastPrediction = -Double.infinity
    private var priorPoints: [Joint: CGPoint] = [:]
    private var priorRoomPoints: [Joint: CGPoint] = [:]
    private var stillnessAnchor: [Joint: CGPoint] = [:]
    private(set) var roomPose: RoomPoseEvidence?
    private var seatDetector: SeatTransitionDetector?
    private var seatResult: (action: String, time: Double)?
    private(set) var description = "Live Vision pose changes · reviewed movement model unavailable"
    private(set) var label = "Waiting for a clear view"
    var action: String?

    init(modelPath: String?) {
        guard let modelPath, !modelPath.isEmpty else { return }
        do {
            let url = URL(fileURLWithPath: modelPath)
            let configuration = MLModelConfiguration()
            let model = try MLModel(contentsOf: url, configuration: configuration)
            let details = model.modelDescription
            guard let input = details.inputDescriptionsByName.values.first(where: { $0.type == .multiArray }),
                  let constraint = input.multiArrayConstraint,
                  constraint.shape.count == 3,
                  constraint.dataType == .float32,
                  let output = details.predictedFeatureName,
                  let scores = details.predictedProbabilitiesName,
                  let classes = details.classLabels as? [String],
                  constraint.shape[1].intValue == 3, constraint.shape[2].intValue == 18,
                  let thresholds = try Self.approvedThresholds(
                    for: model, path: url, classes: classes, window: constraint.shape[0].intValue
                  )
            else {
                description = "Model rejected. Vision pose observations enabled."
                return
            }
            let zeros = try MLMultiArray(shape: [1, 3, 18], dataType: constraint.dataType)
            for index in 0..<zeros.count { zeros[index] = 0 }
            self.model = Model(classifier: model, input: input.name, label: output,
                               scores: scores, window: constraint.shape[0].intValue, zeros: zeros,
                               confidenceThresholds: thresholds)
            let count = thresholds.count
            description = "Core ML · \(count) evaluated \(count == 1 ? "action" : "actions") · on-device"
        } catch {
            description = "The installed model could not load. Vision presence enabled."
        }
    }

    private static func approvedThresholds(
        for model: MLModel, path: URL, classes: [String], window: Int
    ) throws -> [String: Double]? {
        let rawScope = model.modelDescription.metadata[.description] as? String
        let actionLabels = Set(classes)
        guard actionLabels.count == classes.count else { return nil }
        if rawScope == "Observable movement classifier. Scope: \(fullScope)" {
            guard [90, 120, 150].contains(window), actionLabels == Set(labels.keys) else { return nil }
            return Dictionary(uniqueKeysWithValues: labels.keys.map { ($0, 0.80) })
        }
        guard rawScope == "Observable movement classifier. Scope: \(reducedScope)",
              [60, 90, 120, 150].contains(window), actionLabels == reducedLabels else { return nil }
        let sidecar = path.deletingLastPathComponent().appendingPathComponent("model-info.json")
        let info = try JSONDecoder().decode(ReducedModelInfo.self, from: Data(contentsOf: sidecar))
        guard info.scope == reducedScope,
              Set(info.labels) == actionLabels, info.labels.count == actionLabels.count,
              info.frames_per_window == window, info.frames_per_second == 30,
              info.minimum_pose_visibility == 0.80, info.minimum_joint_visibility == 0.80,
              info.minimum_point_confidence == 0.20,
              !info.confidence_thresholds.isEmpty,
              info.confidence_thresholds.allSatisfy({
                actionLabels.contains($0.key) && (0.50...0.95).contains($0.value)
              }) else { return nil }
        return info.confidence_thresholds
    }

    func setSeatTrial(_ enabled: Bool) {
        seatDetector = enabled ? SeatTransitionDetector() : nil
        seatResult = nil
    }

    func invalidateSeatObservation() {
        seatDetector?.reset()
        seatResult = nil
    }

    func recentSeatAction(at time: Double) -> String? {
        guard let seatResult, time >= seatResult.time, time - seatResult.time <= 1.5 else { return nil }
        return seatResult.action
    }

    func accept(_ image: CVImageBuffer, time: Double) {
        guard time.isFinite else { return }
        if firstTime == nil { firstTime = time }
        guard let firstTime else { return }
        let frame = Int(((time - firstTime) * 30).rounded())
        if model == nil && seatDetector == nil && time - lastPrediction < 0.5 { return }
        if let lastFrame, frame <= lastFrame { return }
        defer { lastFrame = frame }
        do {
            let imageRequest = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up)
            try imageRequest.perform([request])
            let found = request.results ?? []
            try sampleRoomPose(found, at: time)
            if seatDetector != nil {
                let aspect = Double(CVPixelBufferGetWidth(image)) / Double(CVPixelBufferGetHeight(image))
                if let action = try seatDetector?.accept(found, aspect: aspect, time: time)?.action {
                    seatResult = (action, time)
                }
                if found.count != 1 { seatResult = nil }
            }
            if found.count > 1 {
                samples.removeAll(keepingCapacity: true)
                priorPoints.removeAll(keepingCapacity: true)
                publishMissing("More than one person in view", at: time)
                return
            }
            guard let model else {
                if time - lastPrediction >= 0.5 { try observePose(found.first, time: time) }
                return
            }
            let missing = Sample(pose: nil, joints: [])
            let gap = lastFrame.map { frame - $0 - 1 } ?? 0
            if gap > 0 {
                samples.append(contentsOf: repeatElement(missing, count: min(gap, model.window)))
            }
            if let pose = found.first {
                let joints = try pose.recognizedPoints(.all)
                samples.append(Sample(
                    pose: try pose.keypointsMultiArray(),
                    joints: Set(joints.lazy.filter { $0.value.confidence >= 0.20 }.map(\.key))
                ))
            } else {
                samples.append(missing)
            }
            if samples.count > model.window { samples.removeFirst(samples.count - model.window) }
            guard time - lastPrediction >= 0.5 else { return }
            guard samples.count == model.window else {
                publishMissing("Waiting for a complete movement window", at: time)
                return
            }
            try predict(model, time: time)
        } catch {
            seatDetector?.reset()
            seatResult = nil
            samples.removeAll(keepingCapacity: true)
            if roomPose.map({ time - $0.time >= 0.4 }) != false {
                resetRoomPose(at: time, noBody: false)
            }
            publishMissing("Observation unknown", at: time)
        }
    }

    private func sampleRoomPose(_ found: [VNHumanBodyPoseObservation], at time: Double) throws {
        let elapsed = roomPose.map { time - $0.time } ?? .infinity
        guard elapsed >= 0.4 else { return }
        guard found.count == 1, let pose = found.first else {
            resetRoomPose(at: time, noBody: found.isEmpty)
            return
        }

        let points = try pose.recognizedPoints(.all)
            .filter { $0.value.confidence >= 0.45 }
            .mapValues(\.location)
        let torso: Set<Joint> = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let limbs: Set<Joint> = [.leftElbow, .rightElbow, .leftWrist, .rightWrist,
                                 .leftKnee, .rightKnee, .leftAnkle, .rightAnkle]
        guard torso.isSubset(of: points.keys) else {
            resetRoomPose(at: time, noBody: false)
            return
        }

        let commonLimbs = limbs.filter { points[$0] != nil && priorRoomPoints[$0] != nil && stillnessAnchor[$0] != nil }
        let observation: RoomObservation
        if elapsed <= 0.95, torso.isSubset(of: priorRoomPoints.keys), torso.isSubset(of: stillnessAnchor.keys),
           commonLimbs.count >= 5,
           [.leftWrist, .rightWrist].contains(where: commonLimbs.contains),
           [.leftAnkle, .rightAnkle, .leftKnee, .rightKnee].contains(where: commonLimbs.contains) {
            let joints = torso.union(commonLimbs)
            let recent = Self.hasMotion(joints, points, comparedWith: priorRoomPoints, threshold: 0.020)
            let cumulative = Self.hasMotion(joints, points, comparedWith: stillnessAnchor, threshold: 0.026)
            observation = recent || cumulative ? .active : .inactive
        } else {
            observation = .visible
        }
        if observation != .inactive { stillnessAnchor = points }
        priorRoomPoints = points
        roomPose = RoomPoseEvidence(time: time, observation: observation, noBody: false)
    }

    private static func hasMotion(_ joints: Set<Joint>, _ points: [Joint: CGPoint],
                                  comparedWith earlier: [Joint: CGPoint], threshold: CGFloat) -> Bool {
        let displacements = joints.compactMap { joint -> CGFloat? in
            guard let current = points[joint], let prior = earlier[joint] else { return nil }
            return hypot(current.x - prior.x, current.y - prior.y)
        }
        return displacements.contains { $0 >= threshold * 1.5 }
            || displacements.count(where: { $0 >= threshold }) >= 2
    }

    private func resetRoomPose(at time: Double, noBody: Bool) {
        priorRoomPoints.removeAll(keepingCapacity: true)
        stillnessAnchor.removeAll(keepingCapacity: true)
        roomPose = RoomPoseEvidence(time: time, observation: .unknown, noBody: noBody)
    }

    private func observePose(_ pose: VNHumanBodyPoseObservation?, time: Double) throws {
        lastPrediction = time
        guard let pose else {
            priorPoints.removeAll(keepingCapacity: true)
            publishMissing("Observation unknown", at: time)
            return
        }
        let visible = try pose.recognizedPoints(.all)
            .filter { $0.value.confidence >= 0.40 }
            .mapValues(\.location)
        guard visible.count >= 5 else {
            priorPoints.removeAll(keepingCapacity: true)
            publishMissing("Observation unknown", at: time)
            return
        }
        let shift = visible.compactMap { joint, point -> CGFloat? in
            guard let before = priorPoints[joint] else { return nil }
            return hypot(point.x - before.x, point.y - before.y)
        }
        priorPoints = visible
        let changed = shift.count >= 5 && shift.filter { $0 >= 0.04 }.count >= 3
        label = changed ? "Pose change observed" : "Body pose visible"
        action = changed ? "pose_change" : "pose_visible"
    }

    private func predict(_ model: Model, time: Double) throws {
        let required = Int((Double(model.window) * 0.8).rounded(.up))
        guard samples.count(where: { $0.pose != nil }) >= required else {
            publishMissing("Observation unknown", at: time)
            return
        }
        let input = MLMultiArray(concatenating: samples.map { $0.pose ?? model.zeros },
                                 axis: 0, dataType: model.zeros.dataType)
        let prediction = try model.classifier.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [model.input: MLFeatureValue(multiArray: input)])
        )
        guard let result = prediction.featureValue(for: model.label)?.stringValue,
              let title = Self.labels[result],
              let threshold = model.confidenceThresholds[result],
              let score = prediction.featureValue(for: model.scores)?.dictionaryValue[AnyHashable(result)],
              score.doubleValue >= threshold,
              samples.count(where: { Self.visible($0.joints, for: result) }) >= required
        else {
            publishMissing("Observation unknown", at: time)
            return
        }
        label = title
        action = result
        lastPrediction = time
    }

    private func publishMissing(_ reason: String, at time: Double) {
        label = reason
        action = "missing"
        lastPrediction = time
    }

    private static func visible(_ joints: Set<Joint>, for action: String) -> Bool {
        let torso: Set<Joint> = [.leftShoulder, .rightShoulder, .leftHip, .rightHip]
        let knees: Set<Joint> = [.leftKnee, .rightKnee]
        switch action {
        case "reach_or_lean":
            return torso.isSubset(of: joints) &&
                ([Joint.leftElbow, .leftWrist].allSatisfy(joints.contains)
                    || [Joint.rightElbow, .rightWrist].allSatisfy(joints.contains))
        case "rise_from_seat", "lower_to_seat":
            return torso.union(knees).isSubset(of: joints)
        case "stepping":
            return knees.union([.leftAnkle, .rightAnkle, .leftHip, .rightHip]).isSubset(of: joints)
        default:
            return torso.isSubset(of: joints)
        }
    }
}

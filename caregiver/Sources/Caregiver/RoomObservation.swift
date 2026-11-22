import CoreVideo
import Foundation
import Vision

enum RoomObservation: Equatable {
    case unknown, visible, active, inactive, absent

    var label: String {
        switch self {
        case .unknown: "Room observation unknown"
        case .visible: "Person visible"
        case .active: "Movement observed"
        case .inactive: "No movement observed in the clear view"
        case .absent: "Calibrated room observed empty"
        }
    }

    var coveredSignal: (kind: String, value: String)? {
        switch self {
        case .inactive: ("activity", "inactive")
        case .absent: ("presence", "absent")
        default: nil
        }
    }
}

struct CameraObservationReport: Sendable {
    let kind: String
    let value: String
    let end: Date
    let start: Date?
}

struct RoomCoverageTracker {
    private var state: RoomObservation?
    private var lastMediaTime: Double?
    private var lastWallTime: Double?
    private var coveredThrough: Int?

    mutating func accept(_ next: RoomObservation, mediaTime: Double, wallTime: Date) -> [CameraObservationReport] {
        let wall = wallTime.timeIntervalSince1970
        guard mediaTime.isFinite, wall.isFinite else { return [] }
        let end = Int(wall.rounded(.down))
        var reports: [CameraObservationReport] = []
        let contiguous: Bool
        if let previousMedia = lastMediaTime, let previousWall = lastWallTime {
            let mediaGap = mediaTime - previousMedia
            let wallGap = wall - previousWall
            contiguous = (0...0.95).contains(mediaGap) && (0...1.2).contains(wallGap)
                && abs(wallGap - mediaGap) < 0.75
        } else {
            contiguous = false
        }

        if !contiguous || next != state {
            if contiguous, let lastWallTime,
               let report = interval(through: Int(lastWallTime.rounded(.down))) {
                reports.append(report)
            }
            if (!contiguous && state != nil) || next == .unknown || next == .visible {
                reports.append(point(kind: "activity", value: "missing", at: end))
            }
            switch next {
            case .visible, .active, .inactive:
                reports.append(point(kind: "presence", value: "present", at: end))
                if next == .active { reports.append(point(kind: "activity", value: "active", at: end)) }
            case .unknown, .absent:
                break
            }
            state = next
            coveredThrough = next.coveredSignal == nil ? nil : Int(wall.rounded(.up))
        } else if let coveredThrough, end - coveredThrough >= 4, let report = interval(through: end) {
            reports.append(report)
        }
        lastMediaTime = mediaTime
        lastWallTime = wall
        return reports
    }

    private mutating func interval(through end: Int) -> CameraObservationReport? {
        guard let start = coveredThrough, let signal = state?.coveredSignal, (1...60).contains(end - start) else {
            return nil
        }
        coveredThrough = end
        return CameraObservationReport(kind: signal.kind, value: signal.value,
                                       end: Date(timeIntervalSince1970: TimeInterval(end)),
                                       start: Date(timeIntervalSince1970: TimeInterval(start)))
    }

    private func point(kind: String, value: String, at time: Int) -> CameraObservationReport {
        CameraObservationReport(kind: kind, value: value, end: Date(timeIntervalSince1970: TimeInterval(time)), start: nil)
    }
}

struct CameraFrameFreshness {
    private var previous: Int?
    private var repeated = 0

    mutating func check(_ buffer: CVImageBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 16, height >= 12, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var hash = Hasher()
        for row in 0..<12 {
            for column in 0..<16 {
                let index = ((2 * row + 1) * height / 24) * bytesPerRow + 4 * ((2 * column + 1) * width / 32)
                hash.combine(UInt32(pixels[index]) << 16 | UInt32(pixels[index + 1]) << 8 | UInt32(pixels[index + 2]))
            }
        }
        let current = hash.finalize()
        repeated = current == previous ? repeated + 1 : 0
        previous = current
        return repeated < 3
    }
}

enum EmptyRoomCalibration: Equatable, Sendable {
    case off, sampling, ready, retry

    var label: String {
        switch self {
        case .off: "Room absence needs empty-room calibration for this camera session."
        case .sampling: "Check that the entire room is empty. Keep the camera still."
        case .ready: "Empty-room reference saved in memory for this session."
        case .retry: "The room could not be verified as empty and stable. Clear the view and try again."
        }
    }
}

final class EmptyRoomReference {
    private var reference: [UInt8]?
    private var lastFingerprint: Int?
    private var repeatedFrames = 0
    private var calibrationSamples = 0
    private var previousMediaTime: Double?
    private(set) var state: EmptyRoomCalibration = .off

    func begin() {
        reset()
        state = .sampling
    }

    func reset() {
        reference = nil
        lastFingerprint = nil
        repeatedFrames = 0
        calibrationSamples = 0
        previousMediaTime = nil
        state = .off
    }

    func verifiedEmpty(_ buffer: CVImageBuffer, noBody: Bool, mediaTime: Double) -> Bool {
        guard state == .ready || state == .sampling else { return false }
        let gap = previousMediaTime.map { mediaTime - $0 }
        previousMediaTime = mediaTime
        guard noBody, let current = fingerprint(buffer), matchingRoom(current) else {
            return rejectCurrentFrame()
        }
        if state == .sampling && gap.map({ !(0...0.95).contains($0) }) == true {
            return rejectCurrentFrame()
        }
        let hash = current.hashValue
        repeatedFrames = hash == lastFingerprint ? repeatedFrames + 1 : 0
        lastFingerprint = hash
        guard repeatedFrames < 3 else { return rejectCurrentFrame() }

        let people = VNDetectHumanRectanglesRequest()
        people.upperBodyOnly = false
        do {
            let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: .up)
            try handler.perform([people])
            guard people.results?.isEmpty == true else { return rejectCurrentFrame() }
        } catch {
            return rejectCurrentFrame()
        }

        if state == .sampling {
            if reference == nil { reference = current }
            calibrationSamples += 1
            if calibrationSamples >= 4 { state = .ready }
            return false
        }
        return true
    }

    private func rejectCurrentFrame() -> Bool {
        if state == .sampling {
            reset()
            state = .retry
        }
        return false
    }

    private func matchingRoom(_ current: [UInt8]) -> Bool {
        guard let reference else { return true }
        let changes = zip(current, reference).map { abs(Int($0) - Int($1)) }
        let largeChanges = changes.count(where: { $0 >= 14 })
        return changes.reduce(0, +) <= changes.count * 4 && largeChanges * 100 <= changes.count
    }

    private func fingerprint(_ buffer: CVImageBuffer) -> [UInt8]? {
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width >= 64, height >= 36, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let pixels = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var result: [UInt8] = []
        result.reserveCapacity(64 * 36)
        for row in 0..<36 {
            let y = (2 * row + 1) * height / 72
            for column in 0..<64 {
                let x = (2 * column + 1) * width / 128
                let index = y * bytesPerRow + 4 * x
                let value = (Int(pixels[index]) * 19 + Int(pixels[index + 1]) * 183 + Int(pixels[index + 2]) * 54) / 256
                result.append(UInt8(value))
            }
        }
        let mean = result.reduce(0) { $0 + Int($1) } / result.count
        let texture = result.count(where: { abs(Int($0) - mean) >= 16 })
        guard (28...227).contains(mean), texture * 6 >= result.count else { return nil }
        return result
    }
}

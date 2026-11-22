import AppKit
@preconcurrency import AVFoundation
import CoreImage
import ImageIO
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class LiveCamera {
    private(set) var personID: String?
    private(set) var running = false
    private(set) var starting = false
    private(set) var recording = false
    private(set) var message: String?
    private(set) var observationDeliveryIssue: String?
    private(set) var movementLabel = "Waiting for a clear view"
    private(set) var modelStatus = "Vision presence ready"
    private(set) var roomStatus = "Room observation unknown"
    private(set) var roomCalibration: EmptyRoomCalibration = .off
    private(set) var seatTrialEnabled = false
    private(set) var recordingURL: URL?
    private(set) var recordingPersonID: String?

    private var generation = UUID()
    private var capture: CameraCapture?
    private var cameraAPI: CameraService?
    private var lease: String?
    private var uploader: Task<Void, Never>?
    private var reporter: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?

    func start(personID: String) async {
        guard !starting, !running, !recording else { return }
        let id = UUID()
        generation = id
        starting = true
        self.personID = personID
        message = nil
        observationDeliveryIssue = nil
        recordingURL = nil
        recordingPersonID = nil
        movementLabel = "Waiting for a clear view"
        seatTrialEnabled = false
        roomStatus = "Room observation unknown"
        roomCalibration = .off
        do {
            let api = try CameraService(personID: personID)
            guard try await api.status().allowed else { throw CameraProblem.consentRequired }
            guard generation == id else { return }
            guard await AVCaptureDevice.requestAccess(for: .video) else { throw CameraProblem.permission }
            guard generation == id else { return }
            let lease = try await api.begin()
            guard generation == id else {
                await api.finish(lease)
                return
            }
            cameraAPI = api
            self.lease = lease
            let freshState = try await api.status()
            guard generation == id, freshState.allowed, freshState.active else {
                await api.finish(lease)
                if generation == id { throw CameraProblem.consentRequired }
                return
            }
            let (frames, output) = AsyncStream<CameraSample>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let (reports, evidenceOutput) = AsyncStream<CameraObservationReport>.makeStream(
                bufferingPolicy: .bufferingOldest(32)
            )
            let worker = CameraCapture(output: output, evidence: evidenceOutput, modelPath: ServiceConnection.actionModelPath)
            capture = worker
            modelStatus = try await worker.start(movementEnabled: freshState.movementAllowed)
            guard generation == id else {
                await worker.stop()
                return
            }
            starting = false
            running = true
            uploader = Task { [weak self] in await self?.publish(frames, api: api, lease: lease, id: id) }
            reporter = Task { [weak self] in
                await self?.publishObservations(reports, api: api, lease: lease, id: id)
            }
            heartbeat = Task { [weak self] in await self?.watch(api, id: id) }
        } catch {
            guard generation == id else { return }
            await stop()
            message = error.localizedDescription
        }
    }

    func stop() async {
        let previousCapture = capture, previousAPI = cameraAPI, previousLease = lease
        generation = UUID()
        uploader?.cancel()
        reporter?.cancel()
        heartbeat?.cancel()
        uploader = nil
        reporter = nil
        heartbeat = nil
        capture = nil
        cameraAPI = nil
        lease = nil
        personID = nil
        running = false
        starting = false
        movementLabel = "Camera is off"
        observationDeliveryIssue = nil
        seatTrialEnabled = false
        roomStatus = "Room observation unknown"
        roomCalibration = .off
        // Revoke the viewer lease immediately while the capture queue shuts down.
        async let localStop: Void? = previousCapture?.stop()
        if let previousAPI, let previousLease { await previousAPI.finish(previousLease) }
        _ = await localStop
    }

    func startRecording() async {
        guard running, !recording, let cameraAPI, let capture, let personID else { return }
        let current = generation
        do {
            guard try await cameraAPI.status().recordingAllowed else { throw CameraProblem.recordingConsent }
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.quickTimeMovie]
            panel.nameFieldStringValue = "SAHANA-recording.mov"
            panel.message = "Choose where to save a video-only recording on this Mac."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            guard generation == current, running else { return }
            guard try await cameraAPI.status().recordingAllowed else { throw CameraProblem.recordingConsent }
            guard generation == current, running, !recording else { return }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw CameraProblem.existingFile }
            recordingURL = nil
            recordingPersonID = nil
            recording = true
            message = nil
            await capture.record(to: url) { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.recording = false
                    switch result {
                    case .success(let url):
                        self.recordingURL = url
                        self.recordingPersonID = personID
                        self.message = "Video-only recording saved."
                    case .failure(let error):
                        self.message = error.localizedDescription
                    }
                }
            }
        } catch {
            message = error.localizedDescription
        }
    }

    func stopRecording() async {
        await capture?.stopRecording()
    }

    func movementConsentChanged(_ allowed: Bool, for personID: String) async {
        guard self.personID == personID else { return }
        await capture?.setMovementEnabled(allowed)
        if !allowed {
            movementLabel = "Movement observation off"
            seatTrialEnabled = false
            roomStatus = "Room observation unknown"
            roomCalibration = .off
        }
    }

    func setSeatTrial(_ enabled: Bool, for personID: String) async {
        guard self.personID == personID, running, let capture, let cameraAPI else { return }
        let current = generation
        if enabled {
            guard (try? await cameraAPI.status().movementAllowed) == true,
                  generation == current, running else { return }
        }
        let applied = await capture.setSeatTrial(enabled)
        if generation == current { seatTrialEnabled = applied }
    }

    func calibrateEmptyRoom(for personID: String) async {
        guard self.personID == personID, running, let capture, let cameraAPI else { return }
        let current = generation
        guard (try? await cameraAPI.status().movementAllowed) == true,
              generation == current, running else { return }
        if await capture.calibrateEmptyRoom(), generation == current { roomCalibration = .sampling }
    }

    private func publish(_ frames: AsyncStream<CameraSample>, api: CameraService, lease: String, id: UUID) async {
        for await sample in frames {
            guard !Task.isCancelled, generation == id else { return }
            do {
                try await api.publish(sample.jpeg, lease: lease)
                guard generation == id else { return }
                movementLabel = sample.label
                modelStatus = sample.modelStatus
                roomStatus = sample.roomStatus
                roomCalibration = sample.calibration
                if sample.droppedObservation { markObservationDeliveryIssue() }
            } catch {
                await stopAfterError(error, id: id)
                return
            }
        }
    }

    private func publishObservations(
        _ reports: AsyncStream<CameraObservationReport>, api: CameraService, lease: String, id: UUID
    ) async {
        for await report in reports {
            guard !Task.isCancelled, generation == id else { return }
            do {
                try await api.observe(report, lease: lease)
            } catch {
                guard !Task.isCancelled, generation == id else { return }
                markObservationDeliveryIssue()
            }
        }
    }

    private func markObservationDeliveryIssue() {
        observationDeliveryIssue = "Some observations could not be saved in this session. Live video continues."
    }

    private func watch(_ api: CameraService, id: UUID) async {
        while !Task.isCancelled, generation == id {
            do {
                try await Task.sleep(for: .seconds(1))
                let state = try await api.status()
                guard generation == id else { return }
                guard state.allowed, state.active else { throw CameraProblem.consentRequired }
                await capture?.setMovementEnabled(state.movementAllowed)
                if !state.movementAllowed { seatTrialEnabled = false }
                if recording && !state.recordingAllowed {
                    await stopRecording()
                    message = "Recording stopped because permission was withdrawn."
                }
            } catch {
                await stopAfterError(error, id: id)
                return
            }
        }
    }

    private func stopAfterError(_ error: Error, id: UUID) async {
        guard generation == id, !Task.isCancelled else { return }
        message = error.localizedDescription
        // This call may originate in the task that stop() cancels.
        Task { @MainActor [weak self] in
            guard let self, self.generation == id else { return }
            await self.stop()
        }
    }
}

private struct CameraSample: Sendable {
    let jpeg: Data
    let label: String
    let modelStatus: String
    let roomStatus: String
    let calibration: EmptyRoomCalibration
    let droppedObservation: Bool
}

private final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.sahana.camera.capture", qos: .userInitiated)
    private let session = AVCaptureSession()
    private let movie = AVCaptureMovieFileOutput()
    private let continuation: AsyncStream<CameraSample>.Continuation
    private let evidence: AsyncStream<CameraObservationReport>.Continuation
    private let modelPath: String?
    private let imageContext = CIContext()
    private var classifier: MotionClassifier?
    private var movementEnabled = false
    private var lastSeatReport: (action: String, time: Double)?
    private var lastJPEG = -Double.infinity
    private let emptyRoom = EmptyRoomReference()
    private var roomCoverage = RoomCoverageTracker()
    private var cameraFreshness = CameraFrameFreshness()
    private var didDropObservation = false
    private var roomObservation: RoomObservation = .unknown
    private var lastRoomSampleTime = -Double.infinity
    private var lastReportTime = -Double.infinity
    private var lastAction: String?
    private var recordingCompletion: (@Sendable (Result<URL, Error>) -> Void)?
    private var shutdownCompletion: CheckedContinuation<Void, Never>?

    init(output: AsyncStream<CameraSample>.Continuation,
         evidence: AsyncStream<CameraObservationReport>.Continuation, modelPath: String?) {
        continuation = output
        self.evidence = evidence
        self.modelPath = modelPath
    }

    func start(movementEnabled: Bool) async throws -> String {
        try await withCheckedThrowingContinuation { result in
            queue.async {
                do {
                    guard let device = AVCaptureDevice.default(for: .video) else { throw CameraProblem.noCamera }
                    let input = try AVCaptureDeviceInput(device: device)
                    let video = AVCaptureVideoDataOutput()
                    video.alwaysDiscardsLateVideoFrames = true
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    self.session.beginConfiguration()
                    if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                    guard self.session.canAddInput(input), self.session.canAddOutput(video) else {
                        self.session.commitConfiguration()
                        throw CameraProblem.noCamera
                    }
                    self.session.addInput(input)
                    self.session.addOutput(video)
                    video.setSampleBufferDelegate(self, queue: self.queue)
                    if self.session.canAddOutput(self.movie) {
                        self.session.addOutput(self.movie)
                        self.movie.maxRecordedDuration = CMTime(seconds: 300, preferredTimescale: 600)
                        self.movie.maxRecordedFileSize = 250 * 1024 * 1024
                    }
                    self.session.commitConfiguration()
                    if device.activeFormat.videoSupportedFrameRateRanges.contains(where: {
                        $0.minFrameRate <= 30 && $0.maxFrameRate >= 30
                    }), (try? device.lockForConfiguration()) != nil {
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                        device.unlockForConfiguration()
                    }
                    self.movementEnabled = movementEnabled
                    if movementEnabled { self.classifier = MotionClassifier(modelPath: self.modelPath) }
                    self.session.startRunning()
                    guard self.session.isRunning else { throw CameraProblem.noCamera }
                    result.resume(returning: self.classifier?.description ?? "Movement observation off")
                } catch { result.resume(throwing: error) }
            }
        }
    }

    func setMovementEnabled(_ enabled: Bool) async {
        await withCheckedContinuation { result in
            queue.async {
                if self.movementEnabled != enabled {
                    self.movementEnabled = enabled
                    self.classifier = enabled ? MotionClassifier(modelPath: self.modelPath) : nil
                    self.resetRoomObservation()
                }
                result.resume()
            }
        }
    }

    func setSeatTrial(_ enabled: Bool) async -> Bool {
        await withCheckedContinuation { result in
            queue.async {
                guard let classifier = self.classifier, self.session.isRunning else {
                    result.resume(returning: false)
                    return
                }
                classifier.setSeatTrial(enabled)
                self.lastSeatReport = nil
                result.resume(returning: enabled)
            }
        }
    }

    func calibrateEmptyRoom() async -> Bool {
        await withCheckedContinuation { result in
            queue.async {
                guard self.movementEnabled, self.session.isRunning else {
                    result.resume(returning: false)
                    return
                }
                self.emptyRoom.begin()
                result.resume(returning: true)
            }
        }
    }

    private func resetRoomObservation() {
        emptyRoom.reset()
        roomCoverage = RoomCoverageTracker()
        cameraFreshness = CameraFrameFreshness()
        didDropObservation = false
        roomObservation = .unknown
        lastRoomSampleTime = -.infinity
        lastReportTime = -.infinity
        lastAction = nil
        lastSeatReport = nil
    }

    func stop() async {
        await withCheckedContinuation { result in
            queue.async {
                if self.movie.isRecording { self.movie.stopRecording() }
                if self.session.isRunning { self.session.stopRunning() }
                self.resetRoomObservation()
                self.continuation.finish()
                self.evidence.finish()
                if self.recordingCompletion == nil {
                    result.resume()
                } else {
                    self.shutdownCompletion = result
                }
            }
        }
    }

    func record(to url: URL, completion: @escaping @Sendable (Result<URL, Error>) -> Void) async {
        await withCheckedContinuation { result in
            queue.async {
                guard self.session.isRunning, self.movie.connection(with: .video) != nil,
                      self.recordingCompletion == nil else {
                    completion(.failure(CameraProblem.cannotRecord))
                    result.resume()
                    return
                }
                self.recordingCompletion = completion
                self.movie.startRecording(to: url, recordingDelegate: self)
                result.resume()
            }
        }
    }

    func stopRecording() async {
        await withCheckedContinuation { result in
            queue.async {
                if self.movie.isRecording { self.movie.stopRecording() }
                result.resume()
            }
        }
    }

    nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                               from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            let finish = self.recordingCompletion
            self.recordingCompletion = nil
            if let error, (error as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool != true {
                finish?(.failure(error))
            } else {
                finish?(.success(outputFileURL))
            }
            self.shutdownCompletion?.resume()
            self.shutdownCompletion = nil
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput buffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        guard let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        let timestamp = Date()
        let time = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
        guard time.isFinite else { return }
        let fresh = classifier == nil || cameraFreshness.check(image)
        if !fresh, let classifier {
            classifier.invalidateSeatObservation()
            if roomObservation != .unknown {
                roomObservation = .unknown
                for report in roomCoverage.accept(.unknown, mediaTime: time, wallTime: timestamp) {
                    publishEvidence(report)
                }
            }
            if emptyRoom.state == .sampling {
                _ = emptyRoom.verifiedEmpty(image, noBody: false, mediaTime: time)
            }
        }
        // Relaying video never waits for an observation upload or retry.
        if time - lastJPEG >= 0.12, let jpeg = encode(image) {
            lastJPEG = time
            let seat = classifier?.recentSeatAction(at: time).flatMap { MotionClassifier.labels[$0] }
            let label = fresh ? seat ?? classifier?.label ?? "Movement observation off" : "Observation unknown"
            continuation.yield(CameraSample(jpeg: jpeg, label: label,
                                            modelStatus: classifier?.description ?? "Movement observation off",
                                            roomStatus: roomObservation.label, calibration: emptyRoom.state,
                                            droppedObservation: didDropObservation))
        }
        guard fresh, let classifier else { return }
        classifier.accept(image, time: time)
        if let pose = classifier.roomPose, pose.time != lastRoomSampleTime {
            lastRoomSampleTime = pose.time
            let empty = emptyRoom.verifiedEmpty(image, noBody: pose.noBody, mediaTime: pose.time)
            roomObservation = empty ? .absent : pose.observation
            for report in roomCoverage.accept(roomObservation, mediaTime: pose.time, wallTime: timestamp) {
                publishEvidence(report)
            }
        }
        // Seat recognition supplies its own pose and visibility checks. Room coverage
        // uses a stricter, differently timed pose sample for absence and inactivity.
        if let seat = classifier.recentSeatAction(at: time),
           lastSeatReport.map({ $0.action != seat || time - $0.time >= 4 }) != false {
            publishEvidence(CameraObservationReport(kind: "motion", value: seat, end: timestamp, start: nil))
            lastSeatReport = (seat, time)
            // A confirmed experimental transition and ordinary movement can share a window.
            // Keep the transition observation visible before publishing the next ordinary action.
            lastReportTime = time
        }
        if let action = classifier.action, action != lastAction, time - lastReportTime >= 5 {
            // Unknown action labels do not erase independently observed room coverage.
            if MotionClassifier.labels[action] != nil, roomObservation != .absent, roomObservation != .unknown {
                publishEvidence(CameraObservationReport(kind: "motion", value: action, end: timestamp, start: nil))
                lastReportTime = time
            }
            lastAction = action
        }
    }

    private func publishEvidence(_ report: CameraObservationReport) {
        if case .dropped = evidence.yield(report) { didDropObservation = true }
    }

    private func encode(_ buffer: CVImageBuffer) -> Data? {
        let source = CIImage(cvPixelBuffer: buffer)
        let ratio = min(1, 720 / source.extent.width)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        guard let image = imageContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.68] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}

private struct CameraService: Sendable {
    struct Status: Decodable {
        let allowed: Bool
        let recordingAllowed: Bool
        let movementAllowed: Bool
        let active: Bool
    }

    private struct Lease: Decodable { let sessionId: String }
    private let base: URL
    private let token: String
    private let personID: String
    private static let client = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)

    init(personID: String) throws {
        let connection = ServiceConnection.current()
        guard let token = connection.token, token.count >= 24 else {
            throw CameraProblem.server
        }
        self.base = connection.url
        self.token = token
        self.personID = personID
    }

    func status() async throws -> Status {
        try decode(Status.self, from: await send("GET", path: "camera"))
    }

    func begin() async throws -> String {
        let data = try JSONEncoder().encode(["setting": "shared_space"])
        let response = try await send("POST", path: "camera/session", data: data, type: "application/json")
        return try decode(Lease.self, from: response).sessionId
    }

    func finish(_ lease: String) async {
        _ = try? await send("DELETE", path: "camera/session", lease: lease)
    }

    func publish(_ data: Data, lease: String) async throws {
        _ = try await send("PUT", path: "camera/frame", data: data, type: "image/jpeg", lease: lease)
    }

    func observe(_ report: CameraObservationReport, lease: String) async throws {
        let formatter = ISO8601DateFormatter()
        var body = [
            "id": UUID().uuidString, "person": personID, "kind": report.kind, "observation": report.value,
            "source": "camera", "setting": "shared_space", "room": "Common room",
            "observed_at": formatter.string(from: report.end),
        ]
        if let start = report.start { body["coverage_start"] = formatter.string(from: start) }
        let data = try JSONEncoder().encode(body)
        do {
            _ = try await send("POST", path: "events", data: data, type: "application/json", lease: lease, shared: true)
        } catch {
            guard Self.retryableObservationFailure(error) else { throw error }
            try await Task.sleep(for: .milliseconds(150))
            // An earlier attempt may have committed before the response was lost.
            _ = try await send("POST", path: "events", data: data, type: "application/json", lease: lease, shared: true)
        }
    }

    private static func retryableObservationFailure(_ error: Error) -> Bool {
        if case let CameraProblem.api(status, _) = error { return (500..<600).contains(status) }
        guard let network = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(network.code)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }

    private func send(_ method: String, path: String, data: Data? = nil, type: String? = nil,
                      lease: String? = nil, shared: Bool = false) async throws -> Data {
        var url = shared ? base : base.appendingPathComponent("people").appendingPathComponent(personID)
        for part in path.split(separator: "/") { url.appendPathComponent(String(part)) }
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let type { request.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let lease { request.setValue(lease, forHTTPHeaderField: "X-SAHANA-Camera-Session") }
        let (bytes, response) = try await Self.client.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CameraProblem.server }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            throw CameraProblem.api(http.statusCode, detail?["detail"] as? String ?? "Camera session is unavailable.")
        }
        return bytes
    }
}

private enum CameraProblem: LocalizedError {
    case consentRequired, permission, noCamera, server, recordingConsent, existingFile, cannotRecord
    case api(Int, String)

    var errorDescription: String? {
        switch self {
        case .consentRequired: "Camera permission is off or paused for this profile."
        case .permission: "Allow SAHANA camera access in macOS Privacy & Security to share a live view."
        case .noCamera: "A local camera could not be started."
        case .server: "Open SAHANA through Start SAHANA.command to connect to its local API."
        case .recordingConsent: "Recording requires separate permission for this person."
        case .existingFile: "Choose a new file name for the recording."
        case .cannotRecord: "The selected camera cannot record with the active session."
        case .api(_, let message): message
        }
    }
}

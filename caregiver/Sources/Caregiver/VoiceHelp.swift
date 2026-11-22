@preconcurrency import AVFoundation
import Observation
import os
@preconcurrency import Speech

@MainActor
@Observable
final class VoiceHelp {
    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var timeout: Task<Void, Never>?
    private var pendingCommand: Task<Void, Never>?
    private var pendingKind: VoiceRequest?
    private var inputSignal: MicrophoneSignal?
    private var sessionID: UUID?
    private var tapInstalled = false

    private(set) var listening = false
    private(set) var starting = false
    private(set) var message: String?
    var active: Bool { sessionID != nil }

    func start(onRequest: @escaping @MainActor (VoiceRequest) -> Void) async {
        guard !active else { return }
        let id = UUID()
        sessionID = id
        starting = true
        message = nil

        guard let recognizer, recognizer.supportsOnDeviceRecognition else {
            finish("On-device English speech recognition is unavailable. Use the help button.")
            return
        }
        let speechAllowed = await Self.speechPermission()
        guard sessionID == id else { return }
        guard speechAllowed else {
            finish("Speech recognition permission is off. Use the help button.")
            return
        }

        let microphoneAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        guard sessionID == id else { return }
        guard microphoneAllowed else {
            finish("Microphone permission is off. Use the help button.")
            return
        }
        guard recognizer.isAvailable else {
            finish("Speech recognition is unavailable right now. Use the help button.")
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            finish("There is no available microphone. Use the help button.")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .confirmation
        request.contextualStrings = [
            "help", "help me", "I need help", "please help", "washroom", "bathroom", "toilet",
            "water", "I need water", "food", "I would like food",
        ]
        self.request = request

        let signal = MicrophoneSignal()
        inputSignal = signal
        recognition = Self.recognize(using: recognizer, request: request) { [weak self] update in
            Task { @MainActor [weak self] in
                guard let self, self.sessionID == id else { return }
                self.handle(update, id: id, onRequest: onRequest)
            }
        }
        Self.installRecordingTap(input: input, format: format, request: request, signal: signal)
        tapInstalled = true

        do {
            engine.prepare()
            try engine.start()
        } catch {
            finish("The microphone could not start. Use the help button.")
            return
        }

        starting = false
        listening = true
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) }
            catch { return }
            guard let self, self.sessionID == id else { return }
            self.stopRecording()
            do { try await Task.sleep(for: .seconds(3)) }
            catch { return }
            guard self.sessionID == id else { return }
            self.finish(self.inputFeedback())
        }
    }

    private func handle(
        _ update: RecognitionUpdate, id: UUID, onRequest: @escaping @MainActor (VoiceRequest) -> Void
    ) {
        switch update {
        case .partial(let kind?):
            guard kind != pendingKind else { return }
            pendingCommand?.cancel()
            pendingKind = kind
            // Allow partial speech to settle or become a more specific request.
            pendingCommand = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(650)) }
                catch { return }
                guard let self, self.sessionID == id else { return }
                self.finish()
                onRequest(kind)
            }
        case .partial(nil):
            pendingCommand?.cancel()
            pendingCommand = nil
            pendingKind = nil
        case .final(let kind?):
            finish()
            onRequest(kind)
        case .final(nil):
            finish(inputFeedback())
        case .failure(let code):
            guard pendingCommand == nil else { return }
            if code == 1110 || inputSignal?.hasAudibleInput == false {
                finish(inputFeedback())
            } else {
                finish("On-device speech recognition stopped (code \(code)). Try again or use the help button.")
            }
        }
    }

    private func inputFeedback() -> String {
        if inputSignal?.hasReceivedAudio != true {
            return "No microphone input reached SAHANA. Check the sound input or use the help button."
        }
        if inputSignal?.hasAudibleInput == false {
            return "The microphone received very little sound. Move closer, try again, or use the help button."
        }
        return "No request matched. Try “help,” “washroom,” “water,” or “food,” or use the request buttons."
    }

    func finish(_ message: String? = nil) {
        sessionID = nil
        starting = false
        listening = false
        stopRecording()
        recognition?.cancel()
        recognition = nil
        request = nil
        inputSignal = nil
        timeout?.cancel()
        timeout = nil
        pendingCommand?.cancel()
        pendingCommand = nil
        pendingKind = nil
        self.message = message
    }

    private func stopRecording() {
        if engine.isRunning { engine.stop() }
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
            request?.endAudio()
        }
        listening = false
    }

    nonisolated private static func speechPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func installRecordingTap(
        input: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest,
        signal: MicrophoneSignal
    ) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            signal.observe(buffer)
            request.append(buffer)
        }
    }

    nonisolated private static func recognize(
        using recognizer: SFSpeechRecognizer,
        request: SFSpeechAudioBufferRecognitionRequest,
        report: @escaping @Sendable (RecognitionUpdate) -> Void
    ) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            if let result {
                let kind = VoiceRequest.match(result.bestTranscription.formattedString)
                report(result.isFinal ? .final(kind) : .partial(kind))
            }
            if let error {
                report(.failure((error as NSError).code))
            }
        }
    }

}

enum VoiceRequest: String, Sendable {
    case general, toileting, hydration, meal

    static func match(_ transcription: String) -> VoiceRequest? {
        var words = transcription.lowercased().split { !$0.isLetter }
        if words.first == "please" { words.removeFirst() }
        if words.last == "please" { words.removeLast() }
        switch words.joined(separator: " ") {
        case "help", "help me", "i need help", "i d like help", "id like help", "i would like help":
            return .general
        case "washroom", "wash room", "bathroom", "toilet", "restroom", "i need the washroom",
             "i need the bathroom", "i need the toilet", "i need the restroom",
             "help me use the washroom", "help me use the bathroom":
            return .toileting
        case "water", "a drink", "i need water", "i want water", "i d like water", "i would like water",
             "can i have water", "can i have some water", "help me get water":
            return .hydration
        case "food", "meal", "i need food", "i want food", "i d like food", "i would like food",
             "can i have food", "can i have some food", "help me get food":
            return .meal
        default:
            return nil
        }
    }
}

private enum RecognitionUpdate: Sendable {
    case partial(VoiceRequest?)
    case final(VoiceRequest?)
    case failure(Int)
}

private final class MicrophoneSignal: Sendable {
    private struct Activity: Sendable {
        var received = false
        var audible: Bool?
    }

    private let activity = OSAllocatedUnfairLock(initialState: Activity())

    var hasReceivedAudio: Bool { activity.withLock { $0.received } }
    var hasAudibleInput: Bool? { activity.withLock { $0.audible } }

    func observe(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        let loud: Bool?
        if let samples = buffer.floatChannelData?[0] {
            loud = stride(from: 0, to: Int(buffer.frameLength), by: 8)
                .contains { abs(samples[$0 * buffer.stride]) >= 0.005 }
        } else {
            loud = nil
        }
        activity.withLock { state in
            state.received = true
            if state.audible != true, let loud { state.audible = loud }
        }
    }
}

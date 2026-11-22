import AppKit
import SwiftUI

private struct CameraStatus: Decodable {
    let active: Bool
    let latestObservation: CameraObservation?
    let latestSeatTransition: CameraObservation?
}

private struct CameraObservation: Decodable {
    let kind: String
    let observation: String
    let observedAt: Int

    var description: String {
        switch (kind, observation) {
        case (_, "missing"): "Unknown"
        case ("presence", "present"): "Person visible"
        case ("presence", "absent"): "Calibrated room observed empty"
        case ("activity", "active"): "Movement observed"
        case ("activity", "inactive"): "No movement observed in the clear view"
        case ("motion", let action): MotionClassifier.labels[action] ?? "Unknown"
        default: "Unknown"
        }
    }
}

struct CameraPanel: View {
    let person: Person?
    let camera: LiveCamera
    let connected: Bool
    private let api = LocalAPI()
    @State private var frame: NSImage?
    @State private var status: CameraStatus?
    @State private var feedError: String?
    @State private var confirmStart = false
    @State private var confirmEmptyRoom = false
    @State private var confirmSeatTrial = false

    private var ownsCamera: Bool { person != nil && camera.personID == person?.id }
    private var canView: Bool { connected && person?.canViewVideo == true }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline) {
                        heading
                        Spacer(minLength: 8)
                        indicator
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        heading
                        indicator
                    }
                }

                ZStack {
                    Color.black.opacity(0.52)
                    if canView, let frame {
                        Image(nsImage: frame)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .accessibilityLabel("Live shared-space video for \(person?.name ?? "the selected profile")")
                    } else {
                        emptyFeed
                    }
                }
                .frame(minHeight: 240)
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay {
                    RoundedRectangle(cornerRadius: 13)
                        .strokeBorder(Brand.line)
                        .allowsHitTesting(false)
                }

                if let person {
                    if canView, person.movement == 1 {
                        movementStatus
                    }
                    if canView || (ownsCamera && (camera.starting || camera.running)) {
                        controls
                    }
                    if canView, person.movement == 1, ownsCamera, camera.running {
                        roomControls
                    }
                    if camera.recordingPersonID == person.id, person.canRecordVideo, let url = camera.recordingURL {
                        Link(destination: url) {
                            Label("Open saved recording", systemImage: "film")
                        }
                    }
                    if let message = feedError ?? (ownsCamera || camera.personID == nil ? camera.message : nil) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(Brand.secondaryText)
                    }
                }
            }
        }
        .task(id: canView ? person?.id : nil) {
            frame = nil
            status = nil
            feedError = nil
            guard canView, let person else { return }
            await watch(person.id)
        }
        .confirmationDialog("Start this Mac’s camera?", isPresented: $confirmStart, titleVisibility: .visible) {
            if let person {
                Button("Start in the shared room") {
                    Task { await camera.start(personID: person.id) }
                }
                if person.movement == 1 {
                    Button("Start with seat-motion detection") {
                        Task {
                            await camera.start(personID: person.id)
                            await camera.setSeatTrial(true, for: person.id)
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check that this Mac is in the approved shared room and everyone in view agrees to live video. Seat detection needs a fixed, full-body view. Stop the camera before personal care or moving the Mac out of the shared room.")
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 4) {
            Heading("Live camera")
            if let person {
                Text(person.name).font(.subheadline).foregroundStyle(Brand.secondaryText)
            }
        }
    }

    private var indicator: some View {
        let live = canView && frame != nil
        let recording = live && ownsCamera && camera.recording
        let label = recording ? "Recording" : (live ? "Live" : "Offline")
        return Label(label, systemImage: recording ? "record.circle" : (live ? "video.fill" : "video.slash"))
            .font(.caption.weight(.semibold))
            .foregroundStyle(recording ? Color.red : (live ? Brand.gold : Brand.secondaryText))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Brand.raised, in: Capsule())
    }

    private var emptyFeed: some View {
        VStack(spacing: 10) {
            BrandEmblem().frame(width: 64, height: 64)
            Text(emptyTitle).font(.title3.weight(.semibold))
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(24)
    }

    private var emptyTitle: String {
        if person == nil { return "No profile selected" }
        if person?.paused == 1 { return "Monitoring paused" }
        if !connected { return "Camera disconnected" }
        if !canView { return "Camera permission is off" }
        if ownsCamera && camera.starting { return "Starting camera" }
        if status?.active == true { return "Waiting for video" }
        return "Camera ready to start"
    }

    private var emptyMessage: String {
        if person == nil { return "Add a profile to start coordinating care." }
        if person?.paused == 1 { return "The person can resume monitoring in the Patient screen." }
        if !connected { return "Reconnect to the local API to view a fresh frame." }
        if !canView { return "Turn on shared-room video in the Patient screen with the person’s agreement." }
        if status?.active == true { return "The feed appears as soon as this session sends a fresh frame." }
        return "Start this Mac’s camera in the approved shared room."
    }

    private var movementStatus: some View {
        let freshObservation = status?.latestObservation.flatMap { observation in
            Date().timeIntervalSince1970 - Double(observation.observedAt) < 6 ? observation : nil
        }
        let label: String
        if frame == nil {
            label = "Unknown"
        } else if ownsCamera && camera.running {
            label = camera.movementLabel
        } else {
            label = freshObservation?.description ?? "Unknown"
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label("Observed movement: \(label)", systemImage: "figure.stand")
                .font(.subheadline.weight(.semibold))
            if ownsCamera && camera.running {
                Text(camera.roomStatus)
                    .font(.callout)
                    .foregroundStyle(Brand.secondaryText)
            }
            if status?.active == true, let seat = status?.latestSeatTransition {
                Label("Last saved seat movement: \(seat.description) · \(clockText(seat.observedAt))",
                      systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(Brand.paleBlue)
            }
            if ownsCamera {
                Text(camera.modelStatus)
                    .font(.caption)
                    .foregroundStyle(Brand.secondaryText)
                if let issue = camera.observationDeliveryIssue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(Brand.gold)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var roomControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(camera.roomCalibration == .ready ? "Recalibrate empty room" : "Calibrate empty room",
                   systemImage: "viewfinder") { confirmEmptyRoom = true }
                .disabled(camera.roomCalibration == .sampling || frame == nil)
            Text(camera.roomCalibration.label)
                .font(.caption)
                .foregroundStyle(Brand.secondaryText)
            if let person {
                Button(camera.seatTrialEnabled ? "Stop seat-motion trial" : "Try seat-motion detection",
                       systemImage: "chair.lounge") {
                    if camera.seatTrialEnabled {
                        Task { await camera.setSeatTrial(false, for: person.id) }
                    } else {
                        confirmSeatTrial = true
                    }
                }
                .disabled(frame == nil)
            }
        }
        .confirmationDialog("Is the approved room empty?", isPresented: $confirmEmptyRoom, titleVisibility: .visible) {
            if let person {
                Button("Confirm the room is empty") {
                    Task { await camera.calibrateEmptyRoom(for: person.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check the entire room and keep this Mac fixed. SAHANA compares a temporary low-detail reference in memory with the rest of this camera session.")
        }
        .confirmationDialog("Try experimental seat detection?", isPresented: $confirmSeatTrial, titleVisibility: .visible) {
            if let person {
                Button("Start trial for this session") {
                    Task { await camera.setSeatTrial(true, for: person.id) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("With the person’s agreement, keep the camera fixed and show their full seated and standing postures. This trial records possible seat transitions for caregiver review.")
        }
    }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 9) { actionButtons }
            VStack(alignment: .leading, spacing: 9) { actionButtons }
        }
    }

    @ViewBuilder private var actionButtons: some View {
        if ownsCamera && (camera.running || camera.starting) {
            Button("Stop camera", systemImage: "stop.fill") {
                Task { await camera.stop() }
            }
            if camera.recording {
                Button("Stop recording", systemImage: "stop.circle") { Task { await camera.stopRecording() } }
            } else if person?.canRecordVideo == true && camera.running {
                Button("Record video", systemImage: "record.circle") { Task { await camera.startRecording() } }
            }
        } else if camera.personID != nil || camera.starting || status?.active == true {
            Text(status?.active == true
                 ? "Watching an active session"
                 : "This Mac’s camera is assigned to another profile.")
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
        } else {
            Button("Start this Mac’s camera", systemImage: "video") { confirmStart = true }
                .buttonStyle(GoldActionStyle())
        }
    }

    private func watch(_ personID: String) async {
        var nextStatus = Date.distantPast
        while !Task.isCancelled {
            do {
                if Date() >= nextStatus {
                    let loaded: CameraStatus = try await api.load("/people/\(personID)/camera")
                    guard !Task.isCancelled else { return }
                    status = loaded
                    nextStatus = Date().addingTimeInterval(1)
                }
                if status?.active == true {
                    let data = try await api.cameraFrame(for: personID)
                    guard !Task.isCancelled else { return }
                    frame = data.flatMap(NSImage.init(data:))
                } else {
                    frame = nil
                }
                feedError = nil
            } catch {
                guard !Task.isCancelled else { return }
                frame = nil
                status = nil
                feedError = "The video feed is unavailable."
                nextStatus = .distantPast
            }
            let delay: Duration = status?.active == true ? .milliseconds(125) : .milliseconds(550)
            do { try await Task.sleep(for: delay) } catch { return }
        }
    }
}

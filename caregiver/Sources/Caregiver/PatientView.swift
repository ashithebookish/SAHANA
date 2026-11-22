import Accessibility
import SwiftUI

struct PatientView: View {
    let model: PatientModel
    let camera: LiveCamera
    @State private var voice = VoiceHelp()
    @State private var confirmClear = false
    @State private var showUsernameEditor = false
    @State private var newUsername = ""
    @State private var preferenceLabel = ""
    @State private var preferenceTime = ""
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .largeTitle) private var greetingSize = 47.0
    @ScaledMetric(relativeTo: .title2) private var largeControlHeight = 54.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let snapshot = model.snapshot {
                    greeting(snapshot.person)
                    if let message = model.connectionError ?? model.actionError {
                        MessageBanner(message: message, symbol: "exclamationmark.circle",
                                      background: Brand.gold.opacity(0.25))
                    }
                    if let feedback = model.feedback {
                        MessageBanner(message: feedback.message, symbol: "checkmark.circle")
                    }
                    helpPanel
                    checkIns(snapshot.checkins)
                    reminders(snapshot.reminders)
                    if model.chatUnavailable {
                        MessageBanner(message: "The caregiver chat is temporarily unavailable.", symbol: "bubble")
                    } else {
                        ChatPanel(messages: model.chat, currentSender: .patient,
                                  disabled: controlsUnavailable, onSend: model.sendChat)
                            .id(snapshot.person.id)
                    }
                    actionPreferences
                    monitoring(snapshot)
                } else if let message = model.connectionError {
                    MessageBanner(message: message, symbol: "exclamationmark.circle",
                                  background: Brand.gold.opacity(0.25))
                    Button("Try again") { Task { await model.refresh() } }
                } else if model.profilesLoaded && model.profiles.isEmpty {
                    ContentUnavailableView(
                        "No care profile yet",
                        systemImage: "person.crop.circle.badge.plus",
                        description: Text("Add a profile in the Caregiver hub first.")
                    )
                } else {
                    ProgressView("Opening your care screen")
                        .frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .frame(maxWidth: 735)
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.personID) {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .onChange(of: model.personID) { _, _ in
            preferenceLabel = ""
            preferenceTime = ""
            showUsernameEditor = false
        }
        .onDisappear {
            voice.finish()
            model.feedback = nil
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, voice.listening { voice.finish() }
        }
        .onChange(of: model.feedback) { _, feedback in
            if let feedback { AccessibilityNotification.Announcement(feedback.message).post() }
        }
        .onChange(of: voice.message) { _, message in
            if let message { AccessibilityNotification.Announcement(message).post() }
        }
        .sheet(isPresented: $showUsernameEditor) {
            usernameEditor
        }
        .alert("Clear optional observations?", isPresented: $confirmClear) {
            Button("Clear observations", role: .destructive) { Task { await model.clearHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the optional observations recorded for this profile.")
        }
    }

    private var controlsUnavailable: Bool { model.working || model.connectionError != nil }

    private func greeting(_ person: Person) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                greetingText(person)
                Spacer(minLength: 6)
                profileControls(person)
            }
            VStack(alignment: .leading, spacing: 10) {
                greetingText(person)
                profileControls(person)
            }
        }
    }

    private func greetingText(_ person: Person) -> some View {
        Text("Hello, \(person.name)")
            .font(.system(size: greetingSize, weight: .semibold, design: .serif))
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func profileControls(_ person: Person) -> some View {
        HStack {
            profilePicker
            Button("Edit username", systemImage: "pencil") {
                newUsername = person.name
                showUsernameEditor = true
            }
            .disabled(controlsUnavailable)
        }
    }

    private var usernameEditor: some View {
        VStack(alignment: .leading, spacing: 15) {
            Heading("Edit username")
            TextField("Username", text: $newUsername)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveUsername)
            if let message = model.actionError {
                Text(message).foregroundStyle(Brand.gold)
            }
            HStack {
                Button("Cancel", role: .cancel) { showUsernameEditor = false }
                Spacer(minLength: 12)
                Button("Save username", action: saveUsername)
                    .buttonStyle(.borderedProminent)
                    .disabled(controlsUnavailable || username.isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 310, idealWidth: 370)
    }

    private var username: String { newUsername.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func saveUsername() {
        guard !controlsUnavailable, !username.isEmpty else { return }
        let name = username
        Task {
            if await model.rename(to: name) { showUsernameEditor = false }
        }
    }

    private var profilePicker: some View {
        Picker("Care profile", selection: Binding(
            get: { model.personID },
            set: {
                voice.finish()
                model.select($0)
            }
        )) {
            ForEach(model.profiles) { Text($0.name).tag($0.id) }
        }
        .fixedSize()
        .controlSize(.large)
        .disabled(model.working)
    }

    private var helpPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Need help?")
                .font(.title.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Send a request to your caregiver.")
                .font(.title3)
                .foregroundStyle(.white.opacity(0.88))

            Button {
                requestHelp("general")
            } label: {
                Label("Request help", systemImage: "hand.raised.fill")
                    .font(.title2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: largeControlHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PatientHelpButtonStyle())
            .disabled(controlsUnavailable)
            .keyboardShortcut(.return, modifiers: [.command])
            .accessibilityHint("Sends a request to your caregiver")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 15) { helpChoices }
                VStack(alignment: .leading, spacing: 10) { helpChoices }
            }
            .environment(\.colorScheme, .dark)

            if voice.listening {
                Label("Listening for your request…", systemImage: "waveform")
                    .font(.body.weight(.semibold))
                    .accessibilityAddTraits(.updatesFrequently)
            } else if voice.starting {
                Text("Waiting for permission…").font(.body)
            } else if voice.active {
                Text("Checking for a voice request…").font(.body)
            }
            Text("Say “help,” “washroom,” “water,” or “food.”")
                .font(.callout)
                .foregroundStyle(.white.opacity(0.88))
            if let message = voice.message {
                Text(message).font(.body).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [Brand.navy, Brand.surface], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 20)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(Brand.line)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var helpChoices: some View {
        Button {
            if voice.active {
                voice.finish()
            } else {
                Task {
                    await voice.start { kind in
                        requestHelp(kind.rawValue)
                    }
                }
            }
        } label: {
            Label(voice.active ? "Stop listening" : "Start voice request", systemImage: "mic")
        }
        .disabled(!voice.active && controlsUnavailable)
        .accessibilityHint("Listens on this Mac for up to five seconds. Audio and transcription are not saved.")
        .help("Voice help listens on this Mac for up to five seconds. Audio and transcription are not saved.")
        Menu("Other help", systemImage: "plus.circle") {
            Button("Help using the bathroom") { requestHelp("toileting") }
            Button("Help with a meal") { requestHelp("meal") }
            Button("Help getting a drink") { requestHelp("hydration") }
        }
        .disabled(controlsUnavailable)
    }

    private func requestHelp(_ kind: String) {
        voice.finish()
        Task { await model.requestHelp(kind) }
    }

    @ViewBuilder private func checkIns(_ all: [CheckIn]) -> some View {
        let pending = all.filter { $0.state == "open" || $0.state == "snoozed" }
        ForEach(pending) { checkin in
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(checkin.prompt)
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if checkin.state == "snoozed" {
                        Text("We’ll ask again at \(clockText(checkin.opensAt)).")
                            .font(.body)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 10) { responseButtons(checkin) }
                            VStack(alignment: .leading, spacing: 10) { responseButtons(checkin) }
                        }
                        .disabled(controlsUnavailable)
                    }
                }
            }
        }
    }

    @ViewBuilder private func responseButtons(_ checkin: CheckIn) -> some View {
        Button("I’m okay") { respond(checkin, "okay") }
        Button("I’d like help") { respond(checkin, "help") }
            .buttonStyle(.borderedProminent)
        Button("Ask me later") { respond(checkin, "snooze") }
    }

    private func respond(_ checkin: CheckIn, _ response: String) {
        voice.finish()
        Task { await model.reply(checkin, response: response) }
    }

    @ViewBuilder private func reminders(_ reminders: [PatientReminder]) -> some View {
        if !reminders.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Heading("Personal reminders")
                ForEach(reminders) { reminder in
                    Card {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Reminder for \(clockText(reminder.dueAt))", systemImage: "bell")
                                .font(.headline)
                            let highlighted = reminder.status == "Overdue" || reminder.status == "Due"
                            Pill(reminder.status, color: highlighted ? Brand.gold : Brand.paleBlue,
                                 fill: highlighted ? Brand.gold.opacity(0.17) : Brand.raised)
                            if reminder.acknowledgedAt == nil, reminder.status != "Completed" {
                                Button("Acknowledge reminder") {
                                    Task { await model.acknowledge(reminder) }
                                }
                                .disabled(controlsUnavailable)
                            } else if reminder.acknowledgedAt != nil {
                                Label("Acknowledged", systemImage: "checkmark.circle")
                            }
                        }
                    }
                }
            }
        }
    }

    private var actionPreferences: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Heading("My action preferences")
                Text("Choose when you prefer to do an activity each day. Your caregiver can see this schedule.")
                    .foregroundStyle(Brand.secondaryText)
                if model.preferencesUnavailable {
                    Text("Your action preferences are temporarily unavailable.")
                } else {
                    ForEach(model.preferences) { preference in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preference.label).font(.headline)
                                    Text("\(preference.at) · Every day").foregroundStyle(Brand.secondaryText)
                                }
                                Spacer(minLength: 8)
                                Button("Remove", systemImage: "minus.circle") {
                                    Task { await model.removePreference(preference) }
                                }
                                .labelStyle(.iconOnly)
                                .accessibilityLabel("Remove \(preference.label) at \(preference.at)")
                                .disabled(controlsUnavailable)
                            }
                            if preference.completedToday == true {
                                Label("Completed today", systemImage: "checkmark.circle")
                            } else if preference.dueToday == true {
                                Button("Log completed action") {
                                    Task { await model.completePreference(preference) }
                                }
                                .accessibilityHint(preference.label)
                                .disabled(controlsUnavailable)
                            }
                        }
                    }
                    Divider()
                    TextField("Activity name", text: $preferenceLabel)
                        .textFieldStyle(.roundedBorder)
                    TextField("Shanghai time (HH:mm)", text: $preferenceTime)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(savePreference)
                    Button("Add to my schedule", systemImage: "calendar.badge.plus", action: savePreference)
                        .disabled(controlsUnavailable || preferenceLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || dailyTime == nil)
                }
            }
        }
    }

    private var dailyTime: String? {
        let input = preferenceTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = input.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, (1...2).contains(parts[0].count), parts[1].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let hour = Int(parts[0]), (0...23).contains(hour),
              let minute = Int(parts[1]), (0...59).contains(minute) else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    private func savePreference() {
        let label = preferenceLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !controlsUnavailable, !label.isEmpty, let dailyTime else { return }
        Task {
            if await model.addPreference(label: label, at: dailyTime) {
                if preferenceLabel.trimmingCharacters(in: .whitespacesAndNewlines) == label { preferenceLabel = "" }
                preferenceTime = ""
            }
        }
    }

    private func monitoring(_ snapshot: PatientSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Heading("Optional monitoring")
                Label("Monitoring \(snapshot.person.monitoringStatus.lowercased())",
                      systemImage: snapshot.person.paused == 1 ? "pause.circle.fill" : "shield.lefthalf.filled")
                    .font(.headline)
                Text("You can request help and see reminders at any time.")
                    .font(.body)
                Button(snapshot.person.paused == 1 ? "Resume monitoring" : "Pause monitoring") {
                    changeConsent("paused", enabled: snapshot.person.paused == 0)
                }
                .disabled(controlsUnavailable)
                if snapshot.isLive {
                    Divider()
                    livePermissions(snapshot.person)
                }
                DisclosureGroup(snapshot.isLive ? "Optional observation history" : "What SAHANA records") {
                    recordingControls(snapshot)
                }
            }
        }
    }

    private func livePermissions(_ person: Person) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Toggle("Allow shared-room video", isOn: consent("camera", person.camera == true))
            Text("When this Mac’s camera is started in the approved shared room, caregivers can view a live feed on this Mac.")
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
            Toggle("Allow movement observations", isOn: consent("movement", person.movement == 1))
            Text("When video is active, SAHANA can process body movements on this Mac and log observations for review.")
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
            if person.camera == true {
                Toggle("Allow separate video recording", isOn: consent("recording", person.recording == true))
                Text("A caregiver must start a recording and choose where to save it. Ordinary live video is temporary.")
                    .font(.callout)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .disabled(controlsUnavailable)
    }

    private func recordingControls(_ snapshot: PatientSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            if snapshot.isLive {
                optionalHistory(snapshot.events)
            } else {
                Toggle("Allow staged movement observations", isOn: consent("movement", snapshot.person.movement == 1))
                Text("The demo records timed changes in presence or activity in a shared room. Caregivers can review these events.")
                Toggle("Allow staged facial observations", isOn: consent("facial", snapshot.person.facial == 1))
                Text("A staged facial observation saves one unconfirmed event for caregiver review.")
                if snapshot.person.facial == 1, snapshot.person.paused == 0 {
                    Button("Record staged facial observation") { Task { await model.stageFacialMovement() } }
                }
                Divider()
                DisclosureGroup("Optional observation history (\(snapshot.events.count))") {
                    optionalHistory(snapshot.events)
                }
            }
        }
        .padding(.vertical, 8)
        .disabled(controlsUnavailable)
    }

    @ViewBuilder private func optionalHistory(_ events: [CareEvent]) -> some View {
        if events.isEmpty {
            Text("There are no optional observations for this profile.").padding(.top, 6)
        } else {
            ForEach(events) { event in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(event.kindLabel) · \(clockText(event.observedAt))").font(.headline)
                    Text(event.reason)
                }
                .padding(.top, 8)
                .accessibilityElement(children: .combine)
            }
            Button("Clear optional history…", role: .destructive) { confirmClear = true }
                .padding(.top, 6)
        }
    }

    private func consent(_ setting: String, _ enabled: Bool) -> Binding<Bool> {
        Binding(get: { enabled }, set: { changeConsent(setting, enabled: $0) })
    }

    private func changeConsent(_ setting: String, enabled: Bool) {
        let patientID = model.personID
        Task {
            if setting == "movement" && !enabled {
                await camera.movementConsentChanged(false, for: patientID)
            }
            async let localStop: Void = stopCaptureIfNeeded(setting, enabled: enabled, personID: patientID)
            let changed = await model.setMonitoring(setting, enabled: enabled, for: patientID)
            if changed && setting == "movement" && enabled {
                await camera.movementConsentChanged(true, for: patientID)
            }
            await localStop
        }
    }

    private func stopCaptureIfNeeded(_ setting: String, enabled: Bool, personID: String) async {
        guard camera.personID == personID else { return }
        if (setting == "camera" && !enabled) || (setting == "paused" && enabled) {
            await camera.stop()
        } else if setting == "recording" && !enabled && camera.recording {
            await camera.stopRecording()
        }
    }
}

struct ChatPanel: View {
    let messages: [ChatMessage]
    let currentSender: ChatSender
    let disabled: Bool
    let onSend: @MainActor (String) async -> Bool
    @State private var draft = ""
    @State private var sending = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Heading(currentSender == .patient ? "Chat with your caregiver" : "Patient chat")
                if messages.isEmpty {
                    Text("No messages yet.").foregroundStyle(Brand.secondaryText)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(messages) { message in
                                    chatRow(message).id(message.id)
                                }
                            }
                        }
                        .frame(height: 145)
                        .onChange(of: messages.last?.id, initial: true) { _, latest in
                            if let latest { proxy.scrollTo(latest, anchor: .bottom) }
                        }
                    }
                }
                TextField("Write a message", text: $draft, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                Button("Send message", systemImage: "paperplane", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(disabled || sending || messageText.isEmpty)
            }
        }
    }

    private func chatRow(_ message: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.sender == currentSender ? "You" : message.sender.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
                if let createdAt = message.createdAt {
                    Text(clockText(createdAt)).font(.caption)
                }
            }
            .foregroundStyle(Brand.secondaryText)
            Text(message.message).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.raised, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    private var messageText: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let message = messageText
        guard !disabled, !sending, !message.isEmpty else { return }
        sending = true
        Task {
            defer { sending = false }
            if await onSend(message), messageText == message { draft = "" }
        }
    }
}

private struct PatientHelpButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .foregroundStyle(Brand.navy)
            .background(Brand.gold.opacity(configuration.isPressed ? 0.82 : 1),
                        in: RoundedRectangle(cornerRadius: 12))
            .opacity(enabled ? 1 : 0.65)
    }
}

import SwiftUI

struct ProfileCareDetails: View {
    let personID: String
    let model: WorkspaceModel
    private let api = LocalAPI()
    @State private var preferences: [RoutinePreference] = []
    @State private var messages: [ChatMessage] = []
    @State private var addRoutine = false
    @State private var routineName = ""
    @State private var routineTime = ""
    @State private var pendingMessage: (text: String, id: String)?
    @State private var error: String?
    @State private var working = false

    private var profilePath: String { "/people/\(personID)" }
    private var cleanName: String { routineName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSaveRoutine: Bool {
        !cleanName.isEmpty && cleanName.count <= 100 &&
            routineTime.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Heading("Daily routines")
                    if preferences.isEmpty {
                        Text("No scheduled routines.").foregroundStyle(Brand.secondaryText)
                    }
                    ForEach(preferences) { preference in
                        routineRow(preference)
                    }
                    DisclosureGroup("Add daily routine", isExpanded: $addRoutine) {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Routine name", text: $routineName)
                            TextField("Time in Shanghai", text: $routineTime, prompt: Text("HH:MM"))
                            Button("Save routine") {
                                Task {
                                    if await save("/preferences", payload: ["label": cleanName, "at": routineTime]) {
                                        routineName = ""
                                        routineTime = ""
                                        addRoutine = false
                                    }
                                }
                            }
                            .disabled(!canSaveRoutine || working)
                        }
                        .padding(.top, 8)
                    }
                }
            }
            ChatPanel(messages: messages, currentSender: .caregiver,
                      disabled: working || model.connectionError != nil, onSend: sendMessage)
            if let error {
                MessageBanner(message: error, symbol: "exclamationmark.circle")
            }
        }
        .task {
            while !Task.isCancelled {
                if !working { try? await reload() }
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
            }
        }
    }

    private func routineRow(_ preference: RoutinePreference) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(preference.label).font(.subheadline.weight(.medium))
            Text("\(preference.at) · Shanghai")
                .foregroundStyle(Brand.secondaryText)
                .font(.caption)
            if preference.completedToday == true {
                Label("Logged today", systemImage: "checkmark.circle").font(.caption)
            } else if preference.dueToday == true {
                Button("Log completion") {
                    Task {
                        if await save("/preferences/\(preference.id)/complete") {
                            await model.refresh()
                        }
                    }
                }
                .disabled(working)
                .accessibilityLabel("Log completion of \(preference.label)")
            } else {
                Text("Upcoming").font(.caption).foregroundStyle(Brand.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    private func sendMessage(_ text: String) async -> Bool {
        let id = pendingMessage.flatMap { $0.text == text ? $0.id : nil } ?? UUID().uuidString
        pendingMessage = (text, id)
        if await save("/chat", payload: ["id": id, "sender": "caregiver", "message": text]) {
            pendingMessage = nil
            return true
        }
        return false
    }

    private func reload() async throws {
        async let loadedMessages: [ChatMessage] = api.load(profilePath + "/chat")
        async let loadedPreferences: [RoutinePreference] = api.load(profilePath + "/preferences")
        let (chat, schedules) = try await (loadedMessages, loadedPreferences)
        guard !Task.isCancelled else { return }
        messages = chat
        preferences = schedules
    }

    private func save(_ path: String, payload: [String: Any]? = nil) async -> Bool {
        guard !working else { return false }
        working = true
        error = nil
        defer { working = false }
        do {
            try await api.request(profilePath + path, method: "POST", payload: payload)
        } catch {
            self.error = error.localizedDescription
            return false
        }
        try? await reload()
        return true
    }
}

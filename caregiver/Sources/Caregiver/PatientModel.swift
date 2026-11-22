import Foundation
import Observation

struct PatientSnapshot: Decodable {
    let now: Int
    let mode: String?
    let person: Person
    let checkins: [CheckIn]
    let events: [CareEvent]
    let reminders: [PatientReminder]

    var isLive: Bool { mode == "live" }
}

struct PatientReminder: Decodable, Identifiable {
    let id: String
    let dueAt: Int
    let acknowledgedAt: Int?
    let status: String
}

struct RoutinePreference: Decodable, Identifiable {
    let id: String
    let label: String
    let at: String
    let dueToday: Bool?
    let completedToday: Bool?
}

enum ChatSender: String, Decodable {
    case patient, caregiver
}

struct ChatMessage: Decodable, Identifiable {
    let id: String
    let sender: ChatSender
    let message: String
    let createdAt: Int?
}

@MainActor
@Observable
final class PatientModel {
    private let api = LocalAPI()
    private var version = 0
    private var pendingHelpIDs: [String: String] = [:]
    private var pendingChatID: (person: String, message: String, id: String)?

    var profiles: [ProfileSummary] = []
    var profilesLoaded = false
    var personID = ""
    var snapshot: PatientSnapshot?
    var preferences: [RoutinePreference] = []
    var chat: [ChatMessage] = []
    var preferencesUnavailable = false
    var chatUnavailable = false
    var working = false
    var connectionError: String?
    var actionError: String?
    var feedback: Notice?

    func select(_ id: String) {
        guard id != personID else { return }
        personID = id
        version += 1
        clearOpenProfile()
    }

    private func clearOpenProfile() {
        snapshot = nil
        preferences = []
        chat = []
        preferencesUnavailable = false
        chatUnavailable = false
        feedback = nil
        actionError = nil
    }

    func refresh() async {
        guard !working else { return }
        await loadSnapshot()
    }

    func requestHelp(_ kind: String) async {
        let key = "\(personID):\(kind)"
        let id = pendingHelpIDs[key] ?? UUID().uuidString
        pendingHelpIDs[key] = id

        if await change("/requests", payload: ["id": id, "person": personID, "kind": kind]) {
            pendingHelpIDs[key] = nil
            feedback = Notice(message: "Your caregiver received your help request.")
        }
    }

    func rename(to name: String) async -> Bool {
        guard await change("/people/\(personID)/profile", method: "PATCH", payload: ["name": name]) else {
            return false
        }
        feedback = Notice(message: "Your username was updated.")
        return true
    }

    func addPreference(label: String, at: String) async -> Bool {
        guard await change("/people/\(personID)/preferences", payload: ["label": label, "at": at]) else {
            return false
        }
        feedback = Notice(message: "Your action preference was saved.")
        return true
    }

    func completePreference(_ preference: RoutinePreference) async {
        if await change("/people/\(personID)/preferences/\(preference.id)/complete") {
            feedback = Notice(message: "Completed action logged.")
        }
    }

    func removePreference(_ preference: RoutinePreference) async {
        if await change("/people/\(personID)/preferences/\(preference.id)", method: "DELETE") {
            feedback = Notice(message: "Your action preference was removed.")
        }
    }

    func sendChat(_ message: String) async -> Bool {
        guard !working, !personID.isEmpty else { return false }
        let id: String
        if let pendingChatID, pendingChatID.person == personID, pendingChatID.message == message {
            id = pendingChatID.id
        } else {
            id = UUID().uuidString
            pendingChatID = (personID, message, id)
        }
        guard await change("/people/\(personID)/chat", payload: [
            "id": id, "sender": ChatSender.patient.rawValue, "message": message
        ]) else { return false }
        pendingChatID = nil
        feedback = Notice(message: "Message sent.")
        return true
    }

    func reply(_ checkin: CheckIn, response: String) async {
        if await change("/people/\(personID)/checkins/\(checkin.id)/response", payload: ["response": response]) {
            let message = switch response {
            case "help": "Your caregiver received your help request."
            case "snooze": "We’ll ask again later."
            default: "Thank you. This check-in is closed."
            }
            feedback = Notice(message: message)
        }
    }

    @discardableResult
    func setMonitoring(_ setting: String, enabled: Bool, for person: String) async -> Bool {
        guard personID == person else { return false }
        if await change("/people/\(personID)/monitoring", method: "PATCH", payload: [setting: enabled]) {
            switch setting {
            case "paused":
                feedback = Notice(message: enabled ? "Optional monitoring paused." : "Optional monitoring resumed.")
            case "camera":
                feedback = Notice(message: enabled ? "Shared-room video allowed." : "Shared-room video turned off.")
            case "recording":
                feedback = Notice(message: enabled ? "Separate recording permission granted." : "Recording permission turned off.")
            default:
                break
            }
            return true
        }
        return false
    }

    func acknowledge(_ reminder: PatientReminder) async {
        if await change("/people/\(personID)/reminders/\(reminder.id)/acknowledge") {
            feedback = Notice(message: "Reminder acknowledged.")
        }
    }

    func clearHistory() async {
        if await change("/people/\(personID)/monitoring/history", method: "DELETE") {
            feedback = Notice(message: "Optional observation history cleared.")
        }
    }

    func stageFacialMovement() async {
        guard let snapshot else { return }
        let date = Date(timeIntervalSince1970: TimeInterval(snapshot.now))
        if await change("/events", payload: [
            "id": UUID().uuidString, "person": personID, "kind": "facial",
            "source": "staged_facial", "observation": "movement", "setting": "shared_space",
            "observed_at": wireTime(date)
        ]) {
            feedback = Notice(message: "Staged observation saved as unconfirmed.")
        }
    }

    private func change(
        _ path: String,
        method: String = "POST",
        payload: [String: Any]? = nil
    ) async -> Bool {
        guard !working, !personID.isEmpty else { return false }
        working = true
        version += 1
        actionError = nil
        feedback = nil
        defer { working = false }
        do {
            try await api.request(path, method: method, payload: payload)
            await loadSnapshot()
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    private func loadSnapshot() async {
        version += 1
        let requestVersion = version
        do {
            let latestProfiles: [ProfileSummary] = try await api.load("/people")
            guard requestVersion == version, !Task.isCancelled else { return }
            profiles = latestProfiles
            profilesLoaded = true
            if !latestProfiles.contains(where: { $0.id == personID }) {
                let nextID = latestProfiles.first?.id ?? ""
                if personID != nextID {
                    personID = nextID
                    clearOpenProfile()
                }
            }
            if personID.isEmpty {
                connectionError = nil
                return
            }
            let path = "/people/\(personID)"
            async let latestSnapshot: PatientSnapshot = api.load("\(path)/patient")
            async let latestPreferences: [RoutinePreference]? = try? api.load("\(path)/preferences")
            async let latestChat: [ChatMessage]? = try? api.load("\(path)/chat")
            let (patient, carePreferences, messages) = try await (latestSnapshot, latestPreferences, latestChat)
            guard requestVersion == version, !Task.isCancelled else { return }
            snapshot = patient
            if let carePreferences { preferences = carePreferences }
            if let messages { chat = messages }
            preferencesUnavailable = carePreferences == nil
            chatUnavailable = messages == nil
            connectionError = nil
        } catch {
            guard requestVersion == version, !Task.isCancelled else { return }
            connectionError = "SAHANA could not connect to the local API. Run Start SAHANA and try again."
        }
    }
}

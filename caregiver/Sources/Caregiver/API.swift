import Foundation
import Observation

struct Snapshot: Decodable {
    let now: Int
    let detector: String
    let mode: String?
    let people: [Person]
    let events: [CareEvent]
    let checkins: [CheckIn]
    let queue: [CareTask]
    let completed: [CareTask]
    let notifications: [CareNotice]?

    var isLive: Bool { mode == "live" }
}

struct Person: Decodable, Identifiable {
    let id: String
    let name: String
    let movement: Int
    let facial: Int
    let paused: Int
    let breakfastWindow: String
    let selfMedication: Int?
    let camera: Bool?
    let recording: Bool?
    let routineWindows: [String: RoutineWindow]?

    var canViewVideo: Bool { camera == true && paused == 0 }
    var canRecordVideo: Bool { canViewVideo && recording == true }

    var monitoringStatus: String {
        if paused == 1 { return "Paused" }
        return movement == 1 || facial == 1 || camera == true ? "On" : "Off"
    }
}

struct RoutineWindow: Decodable {
    let start: String
    let end: String
    let name: String?
}

struct ProfileSummary: Decodable, Identifiable {
    let id: String
    let name: String
}

struct CareEvent: Decodable, Identifiable {
    let id: String
    let person: String
    let kind: String
    let observation: String
    let movementLabel: String?
    let observedAt: Int
    let source: String
    let reason: String
    let flagged: Int
    let optional: Int

    var sourceLabel: String {
        switch source {
        case "optional_movement": "Staged movement observation"
        case "camera": "On-device movement"
        case "staged_facial": "Staged observation"
        default: source.capitalized
        }
    }

    var kindLabel: String {
        switch kind {
        case "facial": "Facial movement"
        case "activity": "Observed activity"
        case "motion": "Observed movement"
        case "presence": "Room presence"
        default: kind.capitalized
        }
    }

    var observationLabel: String {
        movementLabel ?? observation.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

struct CheckIn: Decodable, Identifiable {
    let id: String
    let person: String
    let state: String
    let prompt: String
    let reason: String?
    let opensAt: Int
    let expiresAt: Int

    var status: String {
        switch state {
        case "open": "Awaiting response"
        case "snoozed": "Snoozed"
        case "okay": "Closed · I’m okay"
        case "help": "Closed · Help requested"
        case "cancelled": "Cancelled"
        default: state.capitalized
        }
    }
}

struct CareTask: Decodable, Identifiable {
    let id: String
    let person: String
    let kind: String
    let label: String
    let reason: String
    let eventReason: String?
    let priority: Int
    let deadline: Int
    let dueAt: Int?
    let waitSeconds: Int
    let remainingSeconds: Int
    let status: String
    let acknowledgedAt: Int?
    let administeredAt: Int?
    let selfManaged: Int?
    let reminderAcknowledgedAt: Int?
}

enum CareKind: String, CaseIterable, Identifiable {
    case medication, meal, hydration, toileting

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct Notice: Equatable {
    let id = UUID()
    let message: String
}

struct CareNotice: Decodable, Equatable, Identifiable {
    let id: String
    let person: String
    let message: String
    let createdAt: Int
}

private struct APIError: LocalizedError {
    var errorDescription: String?
}

@MainActor
struct LocalAPI {
    let origin: URL
    private let session: URLSession
    private let decoder = JSONDecoder()
    private let token: String?

    init() {
        let configured = ServiceConnection.current()
        origin = configured.url
        token = configured.token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        decoder.keyDecodingStrategy = .convertFromSnakeCase
    }

    func load<T: Decodable>(_ path: String) async throws -> T {
        try decoder.decode(T.self, from: await request(path))
    }

    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }

    @discardableResult
    func request(
        _ path: String,
        method: String = "GET",
        payload: [String: Any]? = nil,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: origin.appending(path: path))
        request.httpMethod = method
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let payload {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } else {
            request.httpBody = body
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let validation = (body?["detail"] as? [[String: Any]])?.first?["msg"] as? String
            let message = (body?["detail"] as? String) ?? validation
            throw APIError(errorDescription: message ?? "The local API could not accept this change.")
        }
        return data
    }

    func cameraFrame(for personID: String) async throws -> Data? {
        let data = try await request("/people/\(personID)/camera/frame")
        return data.isEmpty ? nil : data
    }
}

@MainActor
@Observable
final class WorkspaceModel {
    private let api = LocalAPI()
    private var version = 0

    var snapshot: Snapshot?
    var selectedPersonID = ""
    var connectionError: String?
    var actionError: String?
    var notices: [CareNotice] { snapshot?.notifications ?? [] }
    var working = false

    func refresh() async {
        guard !working else { return }
        await loadSnapshot()
    }

    @discardableResult
    func change(
        _ path: String,
        method: String = "POST",
        payload: [String: Any]? = nil
    ) async -> Bool {
        await applyChange(path, method: method, payload: payload) != nil
    }

    func createProfile(name: String, selfMedication: Bool) async -> Person? {
        guard let data = await applyChange(
            "/people", method: "POST", payload: ["name": name, "self_medication": selfMedication]
        ) else { return nil }
        do {
            return try api.decode(Person.self, from: data)
        } catch {
            actionError = "The profile was saved, but its response could not be opened."
            return nil
        }
    }

    private func applyChange(
        _ path: String,
        method: String,
        payload: [String: Any]?
    ) async -> Data? {
        guard !working else { return nil }
        working = true
        version += 1
        actionError = nil
        var response: Data?
        defer { working = false }
        do {
            response = try await api.request(path, method: method, payload: payload)
            if path == "/demo/reset" { selectedPersonID = "" }
        } catch {
            actionError = error.localizedDescription
        }
        await loadSnapshot()
        return response
    }

    func log(
        person: Person,
        kind: String,
        observation: String,
        at: Date,
        source: String = "manual",
        room: String? = nil,
        routine: String? = nil
    ) async -> Bool {
        var payload: [String: Any] = [
            "id": UUID().uuidString,
            "person": person.id,
            "kind": kind,
            "observation": observation,
            "source": source,
            "observed_at": wireTime(at)
        ]
        payload["room"] = room
        payload["routine"] = routine
        if source == "staged_facial" || source == "optional_movement" { payload["setting"] = "shared_space" }
        return await change("/events", payload: payload)
    }

    private func loadSnapshot() async {
        version += 1
        let requestVersion = version
        do {
            let latest: Snapshot = try await api.load("/caregiver")
            guard requestVersion == version else { return }
            snapshot = latest
            connectionError = nil
        } catch {
            guard !Task.isCancelled, requestVersion == version else { return }
            connectionError = "The local API at \(api.origin.absoluteString) is unavailable. Start SAHANA’s API, then refresh."
            return
        }

    }
}

let demoTimeZone = TimeZone(identifier: "Asia/Shanghai")!

func wireTime(_ date: Date) -> String {
    date.ISO8601Format()
}

func clockText(_ epoch: Int) -> String {
    let style = Date.FormatStyle(locale: Locale(identifier: "en_GB"), timeZone: demoTimeZone)
        .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
    return Date(timeIntervalSince1970: TimeInterval(epoch)).formatted(style)
}

func durationText(_ seconds: Int) -> String {
    let total = abs(seconds)
    let parts: [(Int, String)] = [
        (total / 86_400, "day"), (total % 86_400 / 3_600, "hour"),
        (total % 3_600 / 60, "minute"), (total % 60, "second")
    ]
    let nonzero = parts.filter { $0.0 > 0 }.prefix(2).map { count, unit in
        "\(count) \(unit)\(count == 1 ? "" : "s")"
    }
    return nonzero.isEmpty ? "0 seconds" : nonzero.joined(separator: " ")
}

func priorityText(_ number: Int) -> String {
    switch number {
    case 3: "High"
    case 1: "Low"
    default: "Standard"
    }
}

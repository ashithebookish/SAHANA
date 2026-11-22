import SwiftUI

struct ScheduleEditor: View {
    let model: WorkspaceModel
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var kind: CareKind
    @State private var label = ""
    @State private var due: Date
    @State private var deadline: Date
    @State private var priority = 2
    @State private var selfManaged = false

    init(model: WorkspaceModel, person: Person, now: Int, kind: CareKind = .medication) {
        self.model = model
        self.person = person
        _kind = State(initialValue: kind)
        let clock = Date(timeIntervalSince1970: TimeInterval(now))
        _due = State(initialValue: clock.addingTimeInterval(60))
        _deadline = State(initialValue: clock.addingTimeInterval(180))
    }

    var body: some View {
        EditorFrame(title: "Schedule care for \(person.name)", error: model.actionError) {
            Form {
                Picker("Care type", selection: $kind) {
                    ForEach(CareKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Task label", text: $label, prompt: Text("e.g. Morning reminder"))
                DatePicker("Scheduled time", selection: $due, displayedComponents: [.date, .hourAndMinute])
                DatePicker("Response deadline", selection: $deadline, displayedComponents: [.date, .hourAndMinute])
                Picker("Staff priority", selection: $priority) {
                    ForEach([3, 2, 1], id: \.self) { Text(priorityText($0)).tag($0) }
                }
                if allowsSelfManagement {
                    Toggle("Show a self-managed reminder on the patient screen", isOn: $selfManaged)
                }
            }
            .environment(\.timeZone, demoTimeZone)
            if deadline < due {
                Text("Choose a response deadline at or after the scheduled time.")
                    .font(.callout)
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create schedule") {
                Task {
                    let cleanLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
                    if await model.change("/schedules", payload: [
                        "person": person.id,
                        "kind": kind.rawValue,
                        "label": cleanLabel.isEmpty ? kind.title : cleanLabel,
                        "due_at": wireTime(due),
                        "deadline": wireTime(deadline),
                        "priority": priority,
                        "self_managed": allowsSelfManagement && selfManaged
                    ]) {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(deadline < due || label.count > 100 || model.working)
        }
        .onAppear { model.actionError = nil }
        .onChange(of: allowsSelfManagement) { _, allowed in
            if !allowed { selfManaged = false }
        }
    }

    private var allowsSelfManagement: Bool {
        kind == .medication && priority == 1 && person.selfMedication == 1
    }
}

struct ObservationEditor: View {
    let model: WorkspaceModel
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var kind: ObservationKind = .presence
    @State private var observation = "present"
    @State private var time: Date
    @State private var room = "Common room"
    @State private var routine = "lunch"
    @State private var optional = false
    private let now: Date
    private let live: Bool

    private enum ObservationKind: String, CaseIterable, Identifiable {
        case presence, activity, breakfast, routine
        var id: Self { self }

        var title: String {
            switch self {
            case .presence: "Room presence"
            case .activity: "Observed activity"
            case .breakfast: "Breakfast"
            case .routine: "Routine"
            }
        }

        var choices: [String] {
            let observations = switch self {
            case .presence: ["present", "absent"]
            case .activity: ["active", "inactive"]
            case .breakfast, .routine: ["completed"]
            }
            return observations + ["missing"]
        }

        var usesRoom: Bool { self == .presence || self == .activity }
    }

    init(model: WorkspaceModel, person: Person, now: Int, live: Bool) {
        self.model = model
        self.person = person
        self.live = live
        let clock = live ? Date() : Date(timeIntervalSince1970: TimeInterval(now))
        self.now = clock
        _time = State(initialValue: clock)
    }

    private var canStageMovement: Bool {
        !live && kind.usesRoom && person.movement == 1 && person.paused == 0
    }

    var body: some View {
        EditorFrame(title: "Record an observation for \(person.name)", error: model.actionError) {
            Form {
                Picker("Observation type", selection: $kind) {
                    ForEach(ObservationKind.allCases) { Text($0.title).tag($0) }
                }
                Picker("Observation", selection: $observation) {
                    ForEach(kind.choices, id: \.self) {
                        Text($0 == "missing" ? "Observation missing" : $0.capitalized).tag($0)
                    }
                }
                if kind == .routine {
                    Picker("Routine", selection: $routine) {
                        Text("Lunch").tag("lunch")
                        ForEach(RoutineCatalog.customWindows(person).filter { !RoutineCatalog.isMotion($0) }, id: \.self) { key in
                            Text(RoutineCatalog.title(key, for: person)).tag(key)
                        }
                    }
                }
                if kind.usesRoom, !(optional && canStageMovement) {
                    TextField("Room", text: $room)
                }
                DatePicker("Observed at", selection: $time, in: ...now, displayedComponents: [.date, .hourAndMinute])
                if canStageMovement {
                    Toggle("Stage an observation in the shared common room", isOn: $optional)
                }
            }
            .environment(\.timeZone, demoTimeZone)
            if observation == "missing" {
                Text("Activity remains unknown when an observation is missing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save observation") {
                Task {
                    let trimmedRoom = room.trimmingCharacters(in: .whitespacesAndNewlines)
                    let staged = optional && canStageMovement
                    let observedRoom = staged ? "Common room" : trimmedRoom
                    if await model.log(
                        person: person,
                        kind: kind.rawValue,
                        observation: observation,
                        at: time,
                        source: staged ? "optional_movement" : "manual",
                        room: kind.usesRoom && !observedRoom.isEmpty ? observedRoom : nil,
                        routine: kind == .routine ? routine : nil
                    ) {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(model.working || (kind.usesRoom && room.count > 100))
        }
        .onChange(of: kind) { _, newKind in
            observation = newKind.choices[0]
        }
        .onAppear { model.actionError = nil }
    }
}

struct ProfileEditor: View {
    let model: WorkspaceModel
    let didCreate: (Person) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var selfMedication = false

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        EditorFrame(title: "Add care profile", error: model.actionError, showsTimeZone: false) {
            Text("The person can control video and recording permissions in the Patient screen.")
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
            Form {
                TextField("Preferred name or care alias", text: $name)
                Toggle("Allow self-managed medication reminders", isOn: $selfMedication)
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Create profile") {
                Task {
                    if let person = await model.createProfile(name: trimmedName, selfMedication: selfMedication) {
                        didCreate(person)
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trimmedName.isEmpty || trimmedName.count > 80 || model.working)
        }
        .onAppear { model.actionError = nil }
    }
}

enum RoutineCatalog {
    static let presets = ["breakfast", "lunch", "common_room_presence", "common_room_activity"]
    static let motions = ["still_in_view", "stepping", "rise_from_seat", "lower_to_seat", "seated_reposition",
                          "reach_or_lean", "seated_transfer", "other_expected_motion"]

    static func isMotion(_ key: String) -> Bool { motions.contains(key) }

    static func customWindows(_ person: Person) -> [String] {
        (person.routineWindows ?? [:]).keys.filter { !presets.contains($0) }.sorted()
    }

    static func title(_ key: String, for person: Person) -> String {
        if let labelled = person.routineWindows?[key]?.name { return labelled }
        switch key {
        case "common_room_presence": return "Common room presence"
        case "common_room_activity": return "Common room activity"
        default: return MotionClassifier.labels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

struct RoutineEditor: View {
    let model: WorkspaceModel
    let person: Person
    @Environment(\.dismiss) private var dismiss
    @State private var signal = "breakfast"
    @State private var name = ""
    @State private var start = ""
    @State private var end = ""

    private static let newRoutine = "__new__"

    private var choices: [String] {
        RoutineCatalog.presets + RoutineCatalog.motions +
            RoutineCatalog.customWindows(person).filter { !RoutineCatalog.isMotion($0) }
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var key: String {
        if signal != Self.newRoutine { return signal }
        return cleanName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: "_")
    }

    private var isValid: Bool {
        guard !key.isEmpty, key.count <= 100, cleanName.count <= 100,
              let begin = minutes(start), let finish = minutes(end) else { return false }
        return begin < finish
    }

    var body: some View {
        EditorFrame(title: "Calibrate routines for \(person.name)", error: model.actionError) {
            Text("Choose or add a routine and agree on its usual time in Shanghai.")
                .font(.callout)
                .foregroundStyle(Brand.secondaryText)
            Form {
                Picker("Routine", selection: $signal) {
                    ForEach(choices, id: \.self) { item in
                        Text(RoutineCatalog.title(item, for: person)).tag(item)
                    }
                    Divider()
                    Text("New routine…").tag(Self.newRoutine)
                }
                if signal == Self.newRoutine {
                    TextField("Routine name", text: $name, prompt: Text("e.g. Afternoon reading"))
                }
                TextField("Window start", text: $start, prompt: Text("HH:MM"))
                TextField("Window end", text: $end, prompt: Text("HH:MM"))
            }
            if !isValid {
                Text("Enter a routine and a later end time in 24-hour form, such as 08:00 to 09:00.")
                    .font(.callout)
                    .foregroundStyle(Brand.secondaryText)
            }
        } actions: {
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Save window") {
                Task {
                    var payload = ["start": start, "end": end]
                    if signal == Self.newRoutine { payload["name"] = cleanName }
                    if await model.change(
                        "/people/\(person.id)/routines/\(key)",
                        method: "PUT", payload: payload
                    ) {
                        dismiss()
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || model.working)
        }
        .onAppear {
            model.actionError = nil
            loadWindow()
        }
        .onChange(of: signal) { _, _ in loadWindow() }
    }

    private func loadWindow() {
        let window = person.routineWindows?[key]
        start = window?.start ?? ""
        end = window?.end ?? ""
    }

    private func minutes(_ value: String) -> Int? {
        guard value.range(of: #"^(?:[01][0-9]|2[0-3]):[0-5][0-9]$"#, options: .regularExpression) != nil else { return nil }
        let fields = value.split(separator: ":").compactMap { Int($0) }
        guard fields.count == 2 else { return nil }
        return fields[0] * 60 + fields[1]
    }
}

private struct EditorFrame<Content: View, Actions: View>: View {
    let title: String
    let error: String?
    var showsTimeZone = true
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Heading(title)
                if showsTimeZone {
                    Text("All times use Asia/Shanghai (UTC+8)")
                        .font(.subheadline)
                        .foregroundStyle(Brand.secondaryText)
                }
                content
                if let error {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                Divider()
                HStack {
                    Spacer()
                    actions
                }
            }
            .padding(22)
            .frame(minWidth: 450, idealWidth: 480, maxWidth: 560, alignment: .leading)
        }
        .frame(minHeight: 300, idealHeight: 385, maxHeight: 500)
    }
}


import Accessibility
import SwiftUI

struct WorkspaceView: View {
    let model: WorkspaceModel
    let camera: LiveCamera
    @State private var editor: Editor?
    @State private var showHistory = true
    @State private var showNotifications = false
    @State private var scheduleKind = CareKind.medication
    @State private var resetMode: String?
    @State private var confirmMedication: CareTask?
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .largeTitle) private var heroSize = 36.0

    private enum Editor: String, Identifiable {
        case schedule, observation, profile, routine
        var id: Self { self }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if showNotifications, let snapshot = model.snapshot {
                        notificationFeed(snapshot)
                    }
                    if let error = model.connectionError ?? model.actionError {
                        MessageBanner(message: error, symbol: "exclamationmark.circle",
                                      background: Brand.gold.opacity(0.25))
                    }
                    if let snapshot = model.snapshot {
                        let wide = geometry.size.width >= 960 && !typeSize.isAccessibilitySize
                        if snapshot.isLive {
                            liveDashboard(snapshot, wide: wide)
                        } else {
                            let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
                                : AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                            layout {
                                queuePanel(snapshot)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                personPanel(snapshot)
                                    .frame(maxWidth: wide ? 335 : .infinity, alignment: .leading)
                            }
                        }
                        history(snapshot)
                    } else if model.connectionError == nil {
                        ProgressView("Connecting to the local API")
                            .frame(maxWidth: .infinity, minHeight: 220)
                    }
                }
                .frame(maxWidth: 1200)
                .padding(.horizontal, 26)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
        }
        .task {
            while !Task.isCancelled {
                await model.refresh()
                do { try await Task.sleep(for: .seconds(3)) }
                catch { return }
            }
        }
        .onAppear { showNotifications = !model.notices.isEmpty }
        .onChange(of: model.notices) { previous, current in
            let known = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let incoming = current.filter { known[$0.id] != $0 }
            if !incoming.isEmpty {
                showNotifications = true
                let announcement = incoming.count == 1 ? incoming[0].message : "\(incoming.count) new care notifications"
                AccessibilityNotification.Announcement(announcement).post()
            }
        }
        .sheet(item: $editor) { mode in
            if mode == .profile {
                ProfileEditor(model: model) { model.selectedPersonID = $0.id }
            } else if let snapshot = model.snapshot, let person = selectedPerson(snapshot) {
                switch mode {
                case .schedule:
                    ScheduleEditor(model: model, person: person, now: snapshot.now, kind: scheduleKind)
                case .observation:
                    ObservationEditor(model: model, person: person, now: snapshot.now, live: snapshot.isLive)
                case .routine:
                    RoutineEditor(model: model, person: person)
                case .profile:
                    EmptyView()
                }
            }
        }
        .alert("Reset the synthetic demo?", isPresented: pending($resetMode), presenting: resetMode) { detector in
            Button("Reset demo", role: .destructive) {
                change("/demo/reset", payload: ["detector": detector])
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The demo clock will reset and the current demo records will be removed.")
        }
        .alert("Confirm medication was administered?", isPresented: pending($confirmMedication),
               presenting: confirmMedication) { task in
            Button("Confirm administration") {
                update(task, action: "confirm_medication")
            }
            Button("Cancel", role: .cancel) {}
        } message: { task in
            Text("Record staff confirmation that \(task.label) was administered.")
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 16) {
                pageTitle
                Spacer(minLength: 12)
                clock
                headerActions
            }
            VStack(alignment: .leading, spacing: 12) {
                pageTitle
                clock
                headerActions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 5)
    }

    private var headerActions: some View {
        ControlGroup {
            Button {
                showNotifications.toggle()
            } label: {
                Label("Notifications (\(model.notices.count))",
                      systemImage: model.notices.isEmpty ? "bell" : "bell.badge")
            }
            .accessibilityValue(showNotifications ? "Shown" : "Hidden")
            .help("Show or hide unresolved care notifications")

            Button {
                Task { await model.refresh() }
            } label: {
                Label("Refresh data", systemImage: "arrow.clockwise")
            }
            .accessibilityLabel("Refresh data")
            .help("Refresh data from the local API")
            .keyboardShortcut("r", modifiers: .command)

            if model.snapshot?.isLive == false {
                Menu("Demo controls", systemImage: "slider.horizontal.3") {
                    Button("Advance 1 minute") { advance(60) }
                    Button("Advance 2 minutes") { advance(120) }
                    Button("Advance 10 minutes") { advance(600) }
                    Divider()
                    Button("Reset with personalized detector") { resetMode = "personalized" }
                    Button("Reset with fixed-rule detector") { resetMode = "fixed" }
                }
                .accessibilityLabel("Demo controls")
                .help("Advance the demo clock or reset synthetic data")
            }
        }
        .environment(\.colorScheme, .dark)
        .disabled(model.working || model.snapshot == nil)
    }

    private var pageTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Caregiver hub")
                .font(.system(size: heroSize, weight: .semibold, design: .serif))
                .accessibilityAddTraits(.isHeader)
            Text(model.snapshot?.isLive == false ? "Synthetic care demonstration" : "Camera, routines and care queue")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var clock: some View {
        if let snapshot = model.snapshot {
            VStack(alignment: .leading, spacing: 4) {
                Label(snapshot.isLive ? "Local time" : "Synthetic demo clock", systemImage: "clock")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Brand.gold)
                Text("\(clockText(snapshot.now)) · Shanghai")
                    .font(.title3.weight(.semibold).monospacedDigit())
                if !snapshot.isLive {
                    Text(snapshot.detector == "fixed" ? "Fixed-rule detector" : "Personalized detector")
                        .font(.caption)
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .background(Brand.surface, in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .combine)
        }
    }

    private func notificationFeed(_ snapshot: Snapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Heading("Notifications")
                    Spacer()
                    Button("Hide", systemImage: "xmark") { showNotifications = false }
                        .labelStyle(.iconOnly)
                        .accessibilityLabel("Hide notifications")
                }
                if model.notices.isEmpty {
                    Text("No unresolved care notifications.")
                        .font(.callout)
                        .foregroundStyle(Brand.secondaryText)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.notices) { item in
                                Button {
                                    model.selectedPersonID = item.person
                                } label: {
                                    ViewThatFits(in: .horizontal) {
                                        HStack {
                                            notificationLabel(item, snapshot)
                                            Spacer()
                                            Text(clockText(item.createdAt))
                                                .foregroundStyle(Brand.secondaryText)
                                        }
                                        VStack(alignment: .leading, spacing: 3) {
                                            notificationLabel(item, snapshot)
                                            Text(clockText(item.createdAt))
                                                .foregroundStyle(Brand.secondaryText)
                                        }
                                    }
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Brand.raised, in: RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Selects this patient's profile")
                            }
                        }
                    }
                    .frame(maxHeight: 175)
                }
            }
        }
    }

    private func notificationLabel(_ item: CareNotice, _ snapshot: Snapshot) -> some View {
        Label {
            Text(item.message).fontWeight(.semibold)
            Text(name(item.person, snapshot)).foregroundStyle(Brand.secondaryText)
        } icon: {
            Image(systemName: "bell.badge")
                .foregroundStyle(item.message.hasPrefix("High priority") ? Brand.gold : Brand.paleBlue)
        }
        .accessibilityElement(children: .combine)
    }

    private func liveDashboard(_ snapshot: Snapshot, wide: Bool) -> some View {
        let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 20))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 15))
        return VStack(alignment: .leading, spacing: 20) {
            layout {
                if !wide { profileRail(snapshot) }
                CameraPanel(person: selectedPerson(snapshot), camera: camera, connected: model.connectionError == nil)
                    .id(selectedPerson(snapshot)?.id)
                    .frame(maxWidth: .infinity)
                if wide { profileRail(snapshot).frame(width: 286) }
            }
            layout {
                queuePanel(snapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if selectedPerson(snapshot) != nil {
                    personPanel(snapshot)
                        .frame(maxWidth: wide ? 320 : .infinity, alignment: .leading)
                }
            }
        }
    }

    private func profileRail(_ snapshot: Snapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Heading("Profiles")
                    Spacer(minLength: 8)
                    if !snapshot.people.isEmpty {
                        Button {
                            editor = .profile
                        } label: {
                            Image(systemName: "plus")
                                .frame(minWidth: 25, minHeight: 24)
                        }
                        .accessibilityLabel("Add profile")
                        .help("Add a care profile")
                        .disabled(model.working || model.connectionError != nil)
                    }
                }
                if snapshot.people.isEmpty {
                    Text("Use the person’s preferred name or a care alias.")
                        .foregroundStyle(Brand.secondaryText)
                        .font(.callout)
                    Button("Add a profile", systemImage: "person.badge.plus") { editor = .profile }
                        .buttonStyle(GoldActionStyle())
                } else {
                    ForEach(snapshot.people) { person in
                        profileButton(person, selected: selectedPerson(snapshot)?.id == person.id)
                    }
                }
            }
        }
    }

    private func profileButton(_ person: Person, selected: Bool) -> some View {
        let cameraState = person.paused == 1 ? "Monitoring paused"
            : (person.canViewVideo ? "Video allowed" : "Video off")
        return Button(action: { model.selectedPersonID = person.id }) {
            HStack(spacing: 11) {
                Image(systemName: person.canViewVideo ? "video.fill" : "person.crop.circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Brand.gold : Brand.paleBlue)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(person.name).font(.headline).foregroundStyle(Brand.cream)
                    Text(cameraState).font(.caption).foregroundStyle(Brand.secondaryText)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Brand.gold)
                        .accessibilityHidden(true)
                }
            }
            .padding(11)
            .contentShape(Rectangle())
            .background(selected ? Brand.raised : Brand.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Brand.gold.opacity(0.56) : Brand.line)
                    .allowsHitTesting(false)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(person.name)
        .accessibilityValue(cameraState)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func queuePanel(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    queueHeading(snapshot)
                    Spacer(minLength: 12)
                    addSchedule
                }
                VStack(alignment: .leading, spacing: 8) {
                    queueHeading(snapshot)
                    addSchedule
                }
            }
            if snapshot.queue.isEmpty {
                Card {
                    Label("No open tasks", systemImage: "checkmark.circle")
                        .font(.headline)
                        .foregroundStyle(Brand.paleBlue)
                }
            }
            ForEach(snapshot.queue) { task in
                taskCard(task, snapshot)
            }
        }
    }

    private var addSchedule: some View {
        Menu {
            Button("Schedule medication", systemImage: "pills") { openSchedule(.medication) }
            Button("Schedule meal", systemImage: "fork.knife") { openSchedule(.meal) }
            Button("Schedule hydration", systemImage: "drop") { openSchedule(.hydration) }
            Button("Schedule toileting", systemImage: "figure.walk") { openSchedule(.toileting) }
        } label: {
            Label("Schedule care", systemImage: "plus")
        }
        .menuStyle(.borderedButton)
        .help("Create a scheduled care task for the selected person")
        .disabled(model.working || model.connectionError != nil || model.snapshot?.people.isEmpty != false)
    }

    private func openSchedule(_ kind: CareKind) {
        scheduleKind = kind
        editor = .schedule
    }

    private func queueHeading(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Heading("Care queue")
            Text("\(snapshot.queue.count) open · Sorted by priority and response deadline")
                .font(.subheadline)
                .foregroundStyle(Brand.secondaryText)
        }
    }

    private func taskCard(_ task: CareTask, _ snapshot: Snapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 11) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) {
                        taskTitle(task, snapshot)
                        Spacer(minLength: 8)
                        taskStatus(task)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        taskTitle(task, snapshot)
                        taskStatus(task)
                    }
                }
                Text(task.reason).font(.body)
                if let eventReason = task.eventReason {
                    Label(eventReason, systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 5) {
                    if let dueAt = task.dueAt {
                        Label("Scheduled \(clockText(dueAt))", systemImage: "calendar")
                    }
                    Label("Waiting \(durationText(task.waitSeconds))", systemImage: "hourglass")
                    Label(deadlineText(task), systemImage: "clock")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                if task.kind == "medication", task.acknowledgedAt != nil || task.reminderAcknowledgedAt != nil {
                    Text(task.reminderAcknowledgedAt == nil
                        ? "Task acknowledged · Awaiting staff confirmation"
                        : "Personal reminder acknowledged · Awaiting staff confirmation")
                        .font(.subheadline.weight(.medium))
                }
                if task.selfManaged == 1 {
                    Label("Self-managed reminder", systemImage: "person.crop.circle")
                        .font(.subheadline)
                }
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack { taskActions(task) }
                    VStack(alignment: .leading, spacing: 8) { taskActions(task) }
                }
                .disabled(model.working || model.connectionError != nil)
            }
        }
    }

    private func taskTitle(_ task: CareTask, _ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.label).font(.headline).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    Text(name(task.person, snapshot)).font(.subheadline)
                    priorityBadge(task.priority)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(name(task.person, snapshot)).font(.subheadline)
                    priorityBadge(task.priority)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func priorityBadge(_ priority: Int) -> some View {
        Pill("\(priorityText(priority)) priority", color: priority == 3 ? Brand.gold : Brand.paleBlue,
             fill: priority == 3 ? Brand.gold.opacity(0.16) : Brand.raised)
    }

    private func taskStatus(_ task: CareTask) -> some View {
        Pill(task.status, color: task.status == "Overdue" ? Brand.gold : Brand.paleBlue,
             fill: task.status == "Overdue" ? Brand.gold.opacity(0.16) : Brand.raised)
    }

    @ViewBuilder private func taskActions(_ task: CareTask) -> some View {
        Button("Acknowledge") { update(task, action: "acknowledge") }
            .disabled(task.acknowledgedAt != nil)
            .accessibilityLabel("Acknowledge \(task.label)")

        Menu("Priority") {
            ForEach([3, 2, 1], id: \.self) { priority in
                Button(priorityText(priority)) { update(task, action: "priority", priority: priority) }
                    .disabled(priority == task.priority)
            }
        }
        .accessibilityLabel("Change priority for \(task.label)")

        Menu("Deadline") {
            Button("Add 5 minutes") { setDeadline(task, relative: 300) }
            Button("Add 15 minutes") { setDeadline(task, relative: 900) }
        }
        .accessibilityLabel("Adjust deadline for \(task.label)")

        if task.kind == "medication" {
            Button("Confirm administration") { confirmMedication = task }
                .disabled(task.status == "Upcoming")
                .accessibilityLabel("Confirm administration of \(task.label)")
        } else {
            Button(task.dueAt == nil ? "Resolve" : "Log completion") { update(task, action: "resolve") }
                .disabled(task.status == "Upcoming")
                .accessibilityLabel("Complete \(task.label)")
        }
    }

    private func personPanel(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let person = selectedPerson(snapshot) {
                Heading(snapshot.isLive ? "Care for \(person.name)" : "People")
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        if !snapshot.isLive {
                            Picker("Demo profile", selection: Binding(
                                get: { person.id },
                                set: { model.selectedPersonID = $0 }
                            )) {
                                ForEach(snapshot.people) { Text($0.name).tag($0.id) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityLabel("Select demo profile")
                        }
                        if let windows = person.routineWindows, !windows.isEmpty {
                            ForEach(windows.keys.sorted(), id: \.self) { key in
                                if let window = windows[key] {
                                    Label("\(RoutineCatalog.title(key, for: person)) \(window.start)–\(window.end)",
                                          systemImage: "clock")
                                        .font(.subheadline)
                                        .foregroundStyle(Brand.secondaryText)
                                }
                            }
                        } else {
                            Text(windowDescription(person, snapshot))
                                .font(.subheadline)
                                .foregroundStyle(Brand.secondaryText)
                        }

                        Divider()

                        Label("Monitoring \(person.monitoringStatus.lowercased())",
                              systemImage: person.paused == 1 ? "pause.circle" : "shield.lefthalf.filled")
                            .font(.subheadline.weight(.medium))
                        if !snapshot.isLive || person.routineWindows?["breakfast"] != nil {
                            ShareLink(item: routineSummary(person, snapshot)) {
                                Label("Share routine window", systemImage: "square.and.arrow.up")
                            }
                        }
                        if snapshot.isLive {
                            Button("Calibrate routine windows", systemImage: "clock.arrow.circlepath") {
                                editor = .routine
                            }
                            .disabled(model.working || model.connectionError != nil)
                        }

                        Divider()

                        personActions(person, snapshot)
                    }
                }
                if snapshot.isLive {
                    ProfileCareDetails(personID: person.id, model: model).id(person.id)
                }
                if !snapshot.checkins.filter({ $0.person == person.id }).isEmpty {
                    Heading("Check-ins")
                }
                ForEach(snapshot.checkins.filter { $0.person == person.id }) { checkin in
                    checkInCard(checkin)
                }
            }
        }
    }

    private func windowDescription(_ person: Person, _ snapshot: Snapshot) -> String {
        if snapshot.isLive && person.routineWindows?["breakfast"] == nil {
            return "Breakfast window awaiting calibration"
        }
        let label = snapshot.detector == "fixed" ? "Shared" : "Usual"
        return "\(label) breakfast window \(person.breakfastWindow)"
    }

    private func routineSummary(_ person: Person, _ snapshot: Snapshot) -> String {
        let label = snapshot.detector == "fixed" ? "shared" : "usual"
        return "SAHANA · \(label.capitalized) breakfast window \(person.breakfastWindow) (Shanghai)"
    }

    private func personActions(_ person: Person, _ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                Task {
                    _ = await model.log(person: person, kind: "breakfast", observation: "completed",
                                        at: snapshot.isLive ? Date()
                                            : Date(timeIntervalSince1970: TimeInterval(snapshot.now)))
                }
            } label: {
                Label("Log breakfast now", systemImage: "fork.knife")
            }
            Button {
                editor = .observation
            } label: {
                Label("Log an observation", systemImage: "square.and.pencil")
            }
            Menu("Log an assistance request") {
                Button("General assistance") { assistance(person, kind: "general") }
                ForEach(CareKind.allCases) { kind in
                    Button("\(kind.title) assistance") { assistance(person, kind: kind.rawValue) }
                }
            }
        }
        .disabled(model.working || model.connectionError != nil)
    }

    private func checkInCard(_ checkin: CheckIn) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Pill(checkin.status, color: Brand.paleBlue)
                if let reason = checkin.reason {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary)
                }
                if checkin.state == "snoozed" {
                    Text("Asking again at \(clockText(checkin.opensAt)).")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func history(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Heading("Recorded care")
            Card {
                DisclosureGroup("Observations (\(snapshot.events.count))", isExpanded: $showHistory) {
                    if snapshot.events.isEmpty {
                        Text("No observations recorded.").foregroundStyle(.secondary).padding(.top, 10)
                    }
                    ForEach(snapshot.events) { event in
                        VStack(alignment: .leading, spacing: 6) {
                            Divider()
                            Text("\(name(event.person, snapshot)) · \(event.kindLabel)")
                                .font(.headline)
                            Text("\(clockText(event.observedAt)) · \(event.sourceLabel) · \(event.observationLabel)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(event.reason)
                            if event.flagged == 1 {
                                Pill("Routine change", color: Brand.gold, fill: Brand.gold.opacity(0.16))
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .padding(.top, 7)
                    }
                }

                Divider().padding(.vertical, 5)

                DisclosureGroup("Completed tasks (\(snapshot.completed.count))") {
                    ForEach(snapshot.completed) { task in
                        VStack(alignment: .leading, spacing: 5) {
                            Divider()
                            Text("\(task.label) · \(name(task.person, snapshot))").font(.headline)
                            if let time = task.administeredAt {
                                Text("Staff confirmed administration at \(clockText(time)).")
                            } else {
                                Text("Completed.")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .padding(.top, 7)
                    }
                }
            }
        }
    }

    private func selectedPerson(_ snapshot: Snapshot) -> Person? {
        snapshot.people.first { $0.id == model.selectedPersonID } ?? snapshot.people.first
    }

    private func name(_ id: String, _ snapshot: Snapshot) -> String {
        snapshot.people.first { $0.id == id }?.name ?? id
    }

    private func deadlineText(_ task: CareTask) -> String {
        let suffix: String
        if task.remainingSeconds < 0 {
            suffix = "\(durationText(task.remainingSeconds)) past deadline"
        } else if task.remainingSeconds == 0 {
            suffix = "Deadline now"
        } else {
            suffix = "\(durationText(task.remainingSeconds)) left"
        }
        return "Response deadline \(clockText(task.deadline)) · \(suffix)"
    }

    private func setDeadline(_ task: CareTask, relative seconds: Int) {
        let base = max(task.deadline, model.snapshot?.now ?? task.deadline)
        let deadline = wireTime(Date(timeIntervalSince1970: TimeInterval(base + seconds)))
        change("/tasks/\(task.id)", method: "PATCH", payload: ["action": "deadline", "deadline": deadline])
    }

    private func update(_ task: CareTask, action: String, priority: Int? = nil) {
        var payload: [String: Any] = ["action": action]
        payload["priority"] = priority
        change("/tasks/\(task.id)", method: "PATCH", payload: payload)
    }

    private func assistance(_ person: Person, kind: String) {
        change("/requests", payload: ["person": person.id, "kind": kind])
    }

    private func advance(_ seconds: Int) {
        change("/demo/clock", payload: ["seconds": seconds])
    }

    private func change(
        _ path: String, method: String = "POST", payload: [String: Any]? = nil
    ) {
        Task { await model.change(path, method: method, payload: payload) }
    }

    private func pending<T>(_ item: Binding<T?>) -> Binding<Bool> {
        Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
    }
}

struct Heading: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.title2.weight(.semibold)).accessibilityAddTraits(.isHeader)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            content
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .strokeBorder(Brand.line)
                .allowsHitTesting(false)
        }
    }
}

struct Pill: View {
    let title: String
    let color: Color
    let fill: Color?

    init(_ title: String, color: Color, fill: Color? = nil) {
        self.title = title
        self.color = color
        self.fill = fill
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fill ?? color.opacity(0.12), in: Capsule())
    }
}

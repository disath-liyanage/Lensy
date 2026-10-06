import SwiftUI
import SwiftData
import Charts

private var mondayCalendar: Calendar {
    var c = Calendar.current
    c.firstWeekday = 2
    return c
}

private func clock(_ t: TimeInterval) -> String {
    let s = Int(max(t, 0))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

private func hm(_ hours: Double) -> String {
    let m = Int((hours * 60).rounded())
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

enum Period: String, CaseIterable, Hashable {
    case week = "Week"
    case month = "Month"
    case year = "Year"
    case all = "All"
}

private func interval(_ p: Period, anchor: Date) -> DateInterval? {
    let cal = mondayCalendar
    switch p {
    case .week: return cal.dateInterval(of: .weekOfYear, for: anchor)
    case .month: return cal.dateInterval(of: .month, for: anchor)
    case .year: return cal.dateInterval(of: .year, for: anchor)
    case .all: return nil
    }
}

private func shifted(_ p: Period, anchor: Date, by n: Int) -> Date {
    let cal = mondayCalendar
    switch p {
    case .week: return cal.date(byAdding: .weekOfYear, value: n, to: anchor) ?? anchor
    case .month: return cal.date(byAdding: .month, value: n, to: anchor) ?? anchor
    case .year: return cal.date(byAdding: .year, value: n, to: anchor) ?? anchor
    case .all: return anchor
    }
}

private func periodTitle(_ p: Period, _ iv: DateInterval?) -> String {
    guard let iv else { return "All time" }
    switch p {
    case .week:
        let last = iv.end.addingTimeInterval(-1)
        return iv.start.formatted(.dateTime.day().month(.abbreviated))
            + " - "
            + last.formatted(.dateTime.day().month(.abbreviated).year())
    case .month: return iv.start.formatted(.dateTime.month(.wide).year())
    case .year: return iv.start.formatted(.dateTime.year())
    case .all: return "All time"
    }
}

struct DayTotal: Identifiable {
    let day: Date
    let hours: Double
    var id: Date { day }
}

private func dayTotals(_ sessions: [WearSession], in iv: DateInterval) -> [DayTotal] {
    let cal = mondayCalendar
    var result: [DayTotal] = []
    var day = cal.startOfDay(for: iv.start)
    while day < iv.end {
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let secs = sessions.reduce(0.0) { acc, s in
            let a = max(s.startedAt, day)
            let b = min(s.endedAt ?? .now, next)
            return acc + max(0, b.timeIntervalSince(a))
        }
        result.append(DayTotal(day: day, hours: secs / 3600))
        day = next
    }
    return result
}

private func timeRange(_ s: WearSession) -> String {
    let start = s.startedAt.formatted(date: .omitted, time: .shortened)
    guard let end = s.endedAt else { return start + " - now" }
    let cal = mondayCalendar
    let days = cal.dateComponents(
        [.day],
        from: cal.startOfDay(for: s.startedAt),
        to: cal.startOfDay(for: end)
    ).day ?? 0
    return start + " - " + end.formatted(date: .omitted, time: .shortened)
        + (days > 0 ? " (+\(days)d)" : "")
}

struct PillBar<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var icon: (Option) -> String? = { _ in nil }
    var compact = false
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        if let name = icon(option) { Image(systemName: name) }
                        Text(title(option))
                    }
                    .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    .padding(.horizontal, compact ? 10 : 14)
                    .padding(.vertical, compact ? 4 : 6)
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.accentColor)
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.6), in: Capsule())
    }
}

enum MainTab: String, CaseIterable, Hashable {
    case timer = "Timer"
    case history = "History"
    case reports = "Reports"

    var icon: String {
        switch self {
        case .timer: "timer"
        case .history: "clock.arrow.circlepath"
        case .reports: "chart.bar.xaxis"
        }
    }
}

struct PeriodBar: View {
    @Binding var period: Period
    @Binding var anchor: Date
    let options: [Period]

    var body: some View {
        let iv = interval(period, anchor: anchor)
        HStack(spacing: 12) {
            PillBar(options: options, selection: $period, title: { $0.rawValue }, compact: true)
            Spacer()
            if period == .all {
                Text("All time")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            } else {
                Button {
                    anchor = shifted(period, anchor: anchor, by: -1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Text(periodTitle(period, iv))
                    .font(.callout.weight(.medium))
                    .frame(minWidth: 150)

                Button {
                    anchor = shifted(period, anchor: anchor, by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .disabled(iv?.contains(.now) ?? true)
            }
        }
        .onChange(of: period) { anchor = .now }
    }
}

struct ContentView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncService.self) private var sync

    @Query(
        filter: #Predicate<WearSession> { $0.deletedAt == nil },
        sort: \WearSession.startedAt,
        order: .reverse
    )
    private var sessions: [WearSession]

    @AppStorage("wearLimitHours") private var limit = 14
    @State private var tab: MainTab = .timer
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if auth.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !auth.isLoggedIn {
                LoginView()
            } else {
                mainView
            }
        }
        .frame(minWidth: 640, minHeight: 680)
        .task {
            sync.refreshActive()
            await auth.restore()
            await sync.sync(force: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await sync.sync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Task { await sync.sync() }
        }
    }

    private var mainView: some View {
        VStack(spacing: 0) {
            PillBar(
                options: MainTab.allCases,
                selection: $tab,
                title: { $0.rawValue },
                icon: { $0.icon }
            )
            .padding(.top, 10)
            .padding(.bottom, 6)

            Group {
                switch tab {
                case .timer: TimerTab(sessions: sessions, limit: limit)
                case .history: HistoryTab(sessions: sessions, limit: limit)
                case .reports: ReportsTab(sessions: sessions, limit: limit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            Text(sync.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .help(sync.status)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { accountMenu }
        }
        .confirmationDialog(
            "Some records haven't synced",
            isPresented: $confirmSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign out and discard them", role: .destructive) {
                Task { await finishSignOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They only exist on this Mac. Check your connection and try again, or sign out and lose them.")
        }
    }

    private var accountMenu: some View {
        Menu {
            if let email = auth.email { Text(email) }
            Divider()
            Menu("Wear limit: \(limit) hours") {
                Picker("Wear limit", selection: $limit) {
                    ForEach(8...18, id: \.self) { Text("\($0) hours").tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Divider()
            Button("Sign out", role: .destructive) {
                Task { await requestSignOut() }
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
    }

    private func requestSignOut() async {
        await sync.sync(force: true)
        if sync.unsyncedCount() > 0 {
            confirmSignOut = true
        } else {
            await finishSignOut()
        }
    }

    private func finishSignOut() async {
        await auth.signOut()
        sync.wipeLocal()
        tab = .timer
    }
}

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncService.self) private var sync
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Lensy")
                .font(.largeTitle.weight(.semibold))
            Text("Sign in to track your lens wear")
                .foregroundStyle(.secondary)

            VStack(spacing: 10) {
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(width: 280)

            if let e = auth.errorMessage {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(width: 280)
            }

            Button {
                busy = true
                Task {
                    await auth.signIn(email: email, password: password)
                    if auth.isLoggedIn { await sync.sync(force: true) }
                    busy = false
                }
            } label: {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Sign in")
                    }
                }
                .frame(width: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(busy || email.isEmpty || password.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { auth.errorMessage = nil }
    }
}

struct TimerTab: View {
    @Environment(SyncService.self) private var sync
    let sessions: [WearSession]
    let limit: Int

    var body: some View {
        let cal = mondayCalendar
        let weekIV = interval(.week, anchor: .now) ?? DateInterval(start: .now, duration: 86400)
        let weekDays = dayTotals(sessions, in: weekIV)
        let week = weekDays.reduce(0) { $0 + $1.hours }
        let worn = weekDays.filter { $0.hours > 0 }
        let avg = worn.isEmpty ? 0 : week / Double(worn.count)
        let today = weekDays.first { cal.isDateInToday($0.day) }?.hours ?? 0

        VStack(spacing: 28) {
            Spacer(minLength: 0)

            if let start = sync.activeStartedAt {
                LiveRing(start: start, limit: limit)
            } else {
                RingView(
                    progress: 0,
                    color: .secondary,
                    title: "Lenses out",
                    subtitle: "Press Start when you put them in"
                )
            }

            Button {
                if sync.activeStartedAt == nil { sync.start() } else { sync.stop() }
            } label: {
                Label(
                    sync.activeStartedAt == nil ? "Start" : "Stop",
                    systemImage: sync.activeStartedAt == nil ? "play.fill" : "stop.fill"
                )
                .frame(width: 160)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(sync.activeStartedAt == nil ? Color.accentColor : Color.red)

            HStack(spacing: 12) {
                StatTile(title: "Today", value: hm(today))
                StatTile(title: "This week", value: hm(week))
                StatTile(title: "Avg per day worn", value: hm(avg))
            }

            Spacer(minLength: 0)
        }
        .padding(24)
    }
}

struct LiveRing: View {
    let start: Date
    let limit: Int
    var size: CGFloat = 260

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            let cap = Double(limit) * 3600
            RingView(
                progress: elapsed / cap,
                color: elapsed > cap ? .red : (elapsed > cap * 0.85 ? .orange : .green),
                title: clock(elapsed),
                subtitle: elapsed > cap
                    ? "Over your \(limit)h limit"
                    : "Started " + start.formatted(date: .omitted, time: .shortened),
                size: size
            )
        }
    }
}

struct RingView: View {
    let progress: Double
    let color: Color
    let title: String
    let subtitle: String
    var size: CGFloat = 260

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.06)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: size * 0.146, weight: .semibold, design: .rounded).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                Text(subtitle)
                    .font(size < 200 ? .caption2 : .caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, size * 0.14)
        }
        .frame(width: size, height: size)
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct DayGroup: Identifiable {
    let day: Date
    let items: [WearSession]
    var id: Date { day }
    var total: Double { items.reduce(0) { $0 + $1.duration } / 3600 }
}

struct HistoryTab: View {
    @Environment(SyncService.self) private var sync
    let sessions: [WearSession]
    let limit: Int

    @State private var period: Period = .week
    @State private var anchor = Date.now
    @State private var editing: WearSession?
    @State private var adding = false
    @State private var toDelete: WearSession?

    var body: some View {
        let iv = interval(period, anchor: anchor)
        let visible = sessions.filter { iv?.contains($0.startedAt) ?? true }
        let cal = mondayCalendar
        let groups = Dictionary(grouping: visible) { cal.startOfDay(for: $0.startedAt) }
            .map { DayGroup(day: $0.key, items: $0.value.sorted { $0.startedAt > $1.startedAt }) }
            .sorted { $0.day > $1.day }
        let total = visible.reduce(0) { $0 + $1.duration } / 3600
        let avg = groups.isEmpty ? 0 : total / Double(groups.count)

        VStack(spacing: 14) {
            HStack {
                PeriodBar(period: $period, anchor: $anchor, options: Period.allCases)
                Button {
                    adding = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }

            HStack(spacing: 12) {
                StatTile(title: "Total worn", value: hm(total))
                StatTile(title: "Sessions", value: "\(visible.count)")
                StatTile(title: "Avg per day", value: hm(avg))
            }

            if visible.isEmpty {
                ContentUnavailableView(
                    "No sessions",
                    systemImage: "eye",
                    description: Text("Nothing recorded in this period.")
                )
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.items) { s in row(s) }
                        } header: {
                            HStack {
                                Text(g.day.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                                Spacer()
                                Text(hm(g.total)).monospacedDigit()
                            }
                            .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding([.horizontal, .top], 20)
        .sheet(item: $editing) { SessionEditor(session: $0) }
        .sheet(isPresented: $adding) { SessionEditor(session: nil) }
        .confirmationDialog(
            "Delete this session?",
            isPresented: Binding(
                get: { toDelete != nil },
                set: { if !$0 { toDelete = nil } }
            ),
            titleVisibility: .visible,
            presenting: toDelete
        ) { s in
            Button("Delete", role: .destructive) {
                sync.delete(s)
                toDelete = nil
            }
            Button("Cancel", role: .cancel) { toDelete = nil }
        } message: { s in
            Text(s.startedAt.formatted(date: .abbreviated, time: .shortened) + ", " + hm(s.duration / 3600))
        }
    }

    private func row(_ s: WearSession) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRange(s))
                    .monospacedDigit()
                if !s.note.isEmpty {
                    Text(s.note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if s.endedAt == nil {
                Text("Running")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.green.opacity(0.18), in: Capsule())
            } else if s.duration > Double(limit) * 3600 {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Over your wear limit")
            }
            Text(hm(s.duration / 3600))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Button {
                editing = s
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button {
                toDelete = s
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}

struct SessionEditor: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    let session: WearSession?
    private let wasRunning: Bool

    @State private var start: Date
    @State private var end: Date
    @State private var running: Bool
    @State private var note: String

    init(session: WearSession?) {
        self.session = session
        let active = session != nil && session?.endedAt == nil
        wasRunning = active
        _start = State(initialValue: session?.startedAt ?? Date.now.addingTimeInterval(-8 * 3600))
        _end = State(initialValue: session?.endedAt ?? .now)
        _running = State(initialValue: active)
        _note = State(initialValue: session?.note ?? "")
    }

    private var valid: Bool { running || end > start }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(session == nil ? "Add session" : "Edit session")
                .font(.headline)

            Form {
                DatePicker("Lenses in", selection: $start, in: ...Date.now)
                if wasRunning {
                    Toggle("Still running", isOn: $running)
                }
                if !running {
                    DatePicker("Lenses out", selection: $end, in: ...Date.now)
                    LabeledContent("Duration") {
                        Text(valid ? hm(end.timeIntervalSince(start) / 3600) : "End must be after start")
                            .foregroundStyle(valid ? Color.secondary : Color.red)
                    }
                }
                TextField("Note", text: $note)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    sync.save(session, start: start, end: running ? nil : end, note: note)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!valid)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct ReportsTab: View {
    let sessions: [WearSession]
    let limit: Int

    @State private var period: Period = .week
    @State private var anchor = Date.now

    var body: some View {
        let iv = interval(period, anchor: anchor) ?? DateInterval(start: .now, duration: 86400)
        let days = dayTotals(sessions, in: iv)
        let total = days.reduce(0) { $0 + $1.hours }
        let worn = days.filter { $0.hours > 0 }
        let inRange = sessions.filter { $0.endedAt != nil && iv.contains($0.startedAt) }
        let longest = inRange.map(\.duration).max() ?? 0
        let over = inRange.filter { $0.duration > Double(limit) * 3600 }.count
        let avg = worn.isEmpty ? 0 : total / Double(worn.count)
        let peak = (days.map(\.hours).max() ?? 0) + 1

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PeriodBar(period: $period, anchor: $anchor, options: [.week, .month])

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                    spacing: 12
                ) {
                    StatTile(title: "Total worn", value: hm(total))
                    StatTile(title: "Days worn", value: "\(worn.count) of \(days.count)")
                    StatTile(title: "Avg per day worn", value: hm(avg))
                    StatTile(title: "Longest session", value: hm(longest / 3600))
                    StatTile(title: "Sessions", value: "\(inRange.count)")
                    StatTile(
                        title: "Over \(limit)h limit",
                        value: "\(over)",
                        tint: over > 0 ? .orange : .primary
                    )
                }

                Text("Hours worn per day")
                    .font(.headline)

                Chart {
                    ForEach(days) { t in
                        BarMark(
                            x: .value("Day", t.day, unit: .day),
                            y: .value("Hours", t.hours)
                        )
                        .foregroundStyle(t.hours > Double(limit) ? Color.red : Color.accentColor)
                    }
                    RuleMark(y: .value("Limit", limit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("limit \(limit)h")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }
                .chartXScale(domain: iv.start...iv.end)
                .chartYScale(domain: 0...max(Double(limit) + 2, peak))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: period == .week ? 1 : 5)) { _ in
                        AxisGridLine()
                        AxisValueLabel(
                            format: period == .week
                                ? .dateTime.weekday(.abbreviated)
                                : .dateTime.day()
                        )
                    }
                }
                .frame(height: 260)
            }
            .padding(24)
        }
    }
}

struct MenuLabel: View {
    @Environment(SyncService.self) private var sync

    private static let icon: NSImage = {
        let base = NSImage(named: "MenuIcon")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!
        let img = (base.copy() as? NSImage) ?? base
        let h: CGFloat = 18
        img.size = NSSize(width: h * img.size.width / max(img.size.height, 1), height: h)
        img.isTemplate = true
        return img
    }()

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: Self.icon)
            Text(sync.menuTitle)
        }
    }
}

struct MenuContent: View {
    @Environment(SyncService.self) private var sync
    @AppStorage("wearLimitHours") private var limit = 14

    var body: some View {
        VStack(spacing: 14) {
            if let start = sync.activeStartedAt {
                LiveRing(start: start, limit: limit, size: 180)
                Button("Stop") { sync.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.link)
        }
        .padding()
        .frame(width: 240)
    }
}

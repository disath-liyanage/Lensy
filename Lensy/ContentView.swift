import SwiftUI
import SwiftData
import Charts

private func clock(_ t: TimeInterval) -> String {
    let s = Int(max(t, 0))
    return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

private func hm(_ hours: Double) -> String {
    let m = Int((hours * 60).rounded())
    return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}

private func whenText(_ d: Date) -> String {
    let cal = Calendar.current
    let t = d.formatted(date: .omitted, time: .shortened)
    if cal.isDateInToday(d) { return t }
    if cal.isDateInYesterday(d) { return "Yesterday " + t }
    if cal.isDateInTomorrow(d) { return "Tomorrow " + t }
    return d.formatted(.dateTime.weekday(.abbreviated)) + " " + t
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

extension View {
    func card(padding: CGFloat = 12) -> some View {
        self
            .padding(padding)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
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
                    withAnimation(.snappy(duration: 0.25)) { selection = option }
                } label: {
                    HStack(spacing: 6) {
                        if let name = icon(option) { Image(systemName: name) }
                        Text(title(option))
                    }
                    .font(compact ? .caption.weight(.medium) : .callout.weight(.medium))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, compact ? 10 : 14)
                    .padding(.vertical, compact ? 4 : 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(Color.primary.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: ns)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassEffect(.regular, in: .capsule)
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
    @Environment(NotificationService.self) private var notifier

    @Query(sort: \WearSession.startedAt, order: .reverse)
    private var all: [WearSession]

    @AppStorage("wearLimitHours") private var limit = 14
    @State private var tab: MainTab = .timer
    @State private var confirmSignOut = false
    @State private var showSettings = false

    private var sessions: [WearSession] { all.filter { $0.deletedAt == nil } }

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
        .toolbar(removing: .title)
        .frame(minWidth: 680, minHeight: 760)
        .task {
            sync.refreshActive()
            await auth.restore()
            if auth.isLoggedIn { await notifier.requestAccess() }
            await sync.sync(force: true)
        }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn { Task { await notifier.requestAccess() } }
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
            Group {
                switch tab {
                case .timer: TimerTab(sessions: sessions, limit: limit)
                case .history: HistoryTab(sessions: sessions, limit: limit)
                case .reports: ReportsTab(sessions: sessions, limit: limit)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            SyncStatusView()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
        .overlay(alignment: .bottom) { undoToast }
        .animation(.snappy, value: sync.lastDeleted == nil)
        .background { shortcuts }
        .toolbar {
            ToolbarItem(placement: .principal) {
                PillBar(
                    options: MainTab.allCases,
                    selection: $tab,
                    title: { $0.rawValue },
                    icon: { $0.icon }
                )
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) { accountMenu }
        }
        .sheet(isPresented: $showSettings) { SettingsSheet() }
        .sheet(isPresented: Binding(
            get: { notifier.askWornTime },
            set: { notifier.askWornTime = $0 }
        )) {
            WornTimeSheet()
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

    private var shortcuts: some View {
        Group {
            Button("Timer") { tab = .timer }
                .keyboardShortcut("1", modifiers: .command)
            Button("History") { tab = .history }
                .keyboardShortcut("2", modifiers: .command)
            Button("Reports") { tab = .reports }
                .keyboardShortcut("3", modifiers: .command)
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var undoToast: some View {
        if sync.lastDeleted != nil {
            HStack(spacing: 12) {
                Image(systemName: "trash")
                Text("Session deleted")
                Button("Undo") { sync.undoDelete() }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 52)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var accountMenu: some View {
        Menu {
            if let email = auth.email { Text(email) }
            Divider()
            Button("Settings...") { showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
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

struct SyncStatusView: View {
    @Environment(SyncService.self) private var sync

    var body: some View {
        HStack(spacing: 6) {
            switch sync.state {
            case .idle:
                Image(systemName: "icloud")
                Text("Not synced yet")
            case .syncing:
                ProgressView().controlSize(.mini)
                Text("Syncing...")
            case .synced(let date):
                Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                Text("Synced " + date.formatted(date: .omitted, time: .shortened))
            case .failed(let message):
                Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange)
                Text(message)
                Button("Retry") { Task { await sync.sync(force: true) } }
                    .buttonStyle(.link)
            }
            if sync.pending > 0 {
                Text("- \(sync.pending) waiting")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncService.self) private var sync
    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @FocusState private var emailFocused: Bool

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
                    .focused($emailFocused)
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
        .onAppear {
            auth.errorMessage = nil
            emailFocused = true
        }
    }
}

struct SheetHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String
    var icon: String? = nil
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                if let icon {
                    Image(systemName: icon)
                        .font(.caption2)
                }
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct TimerTab: View {
    @Environment(SyncService.self) private var sync
    @Environment(NotificationService.self) private var notifier
    @AppStorage("maxDaysPerWeek") private var maxDays = 6
    let sessions: [WearSession]
    let limit: Int

    @State private var restWarning: Int?
    @State private var adjusting = false

    private var running: Bool { sync.activeStartedAt != nil }

    private func weeklyWarning() -> Int? {
        let cal = mondayCalendar
        guard let week = cal.dateInterval(of: .weekOfYear, for: .now) else { return nil }
        let days = wornDays(sessions, in: week)
        if days.contains(cal.startOfDay(for: .now)) { return nil }
        return days.count >= maxDays ? days.count : nil
    }

    private var weekLine: some View {
        let cal = mondayCalendar
        let week = cal.dateInterval(of: .weekOfYear, for: .now)
            ?? DateInterval(start: .now, duration: 7 * 86400)
        let worn = wornDays(sessions, in: week)
        let days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: week.start) }

        return HStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let isToday = cal.isDateInToday(day)
                    Circle()
                        .fill(worn.contains(day) ? Color.green : Color.clear)
                        .overlay(
                            Circle().strokeBorder(
                                isToday ? Color.accentColor : Color.primary.opacity(0.25),
                                lineWidth: isToday ? 2 : 1
                            )
                        )
                        .frame(width: 12, height: 12)
                }
            }
            Text("\(worn.count) of \(maxDays) days this week")
                .font(.callout)
                .foregroundStyle(worn.count >= maxDays ? Color.orange : Color.secondary)
        }
    }

    private var statTiles: some View {
        let cal = mondayCalendar
        let weekIV = interval(.week, anchor: .now) ?? DateInterval(start: .now, duration: 86400)
        let days = dayTotals(sessions, in: weekIV)
        let week = days.reduce(0) { $0 + $1.hours }
        let worn = days.filter { $0.hours >= 1.0 / 60 }
        let avg = worn.isEmpty ? 0 : week / Double(worn.count)
        let today = days.first { cal.isDateInToday($0.day) }?.hours ?? 0

        return HStack(spacing: 12) {
            StatTile(title: "Today", value: hm(today), icon: "sun.max")
            StatTile(title: "Week total", value: hm(week), icon: "calendar")
            StatTile(title: "Avg per day worn", value: hm(avg), icon: "chart.bar")
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 0)

            if let start = sync.activeStartedAt {
                LiveRing(start: start, limit: limit, size: 240, showRemoveAt: false)

                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Put on").font(.caption2).foregroundStyle(.secondary)
                        Text(whenText(start)).font(.callout.weight(.medium))
                    }
                    Spacer()
                    Divider().frame(height: 24)
                    Spacer()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Remove at").font(.caption2).foregroundStyle(.secondary)
                        Text(whenText(start.addingTimeInterval(Double(limit) * 3600))).font(.callout.weight(.medium))
                    }
                    Spacer()
                    Button {
                        adjusting = true
                    } label: {
                        Image(systemName: "pencil").font(.callout)
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                    .background(.primary.opacity(0.1), in: Circle())
                    .help("Adjust start time")
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(.quaternary.opacity(0.5), in: Capsule())
                .frame(maxWidth: 340)

            } else {
                RingView(
                    progress: 0,
                    color: .secondary,
                    title: "Lenses out",
                    subtitle: "Press Start when you put them in",
                    size: 240
                )
            }

            Button {
                if running {
                    sync.stop()
                } else if let worn = weeklyWarning() {
                    restWarning = worn
                } else {
                    sync.start()
                }
            } label: {
                Label(
                    running ? "Stop" : "Start",
                    systemImage: running ? "stop.fill" : "play.fill"
                )
                .frame(width: 150)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(running ? Color.red : Color.accentColor)

            if !running {
                Button {
                    notifier.askWornTime = true
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                        Text("Already wearing them?")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                }
                .buttonStyle(.plain)
            }

            TimelineView(.periodic(from: .now, by: 30)) { _ in
                VStack(spacing: 12) {
                    weekLine
                    statTiles
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .animation(.snappy, value: running)
        .sheet(isPresented: $adjusting) {
            AdjustStartSheet(initial: sync.activeStartedAt ?? .now)
        }
        .alert(
            "Take a rest day?",
            isPresented: Binding(
                get: { restWarning != nil },
                set: { if !$0 { restWarning = nil } }
            )
        ) {
            Button("Start anyway", role: .destructive) { sync.start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You've already worn your lenses on \(restWarning ?? maxDays) of 7 days this week, and your limit is \(maxDays). A rest day helps keep your eyes healthy.")
        }
    }
}

struct LiveRing: View {
    let start: Date
    let limit: Int
    var size: CGFloat = 260
    var showRemoveAt = true

    private func subtitle(elapsed: TimeInterval, cap: Double) -> String {
        let remaining = cap - elapsed
        let removeAt = start.addingTimeInterval(cap)
        if remaining <= 0 {
            let over = "Over by " + hm(-remaining / 3600)
            return showRemoveAt ? "Remove lenses now\n" + over : over
        }
        let left = hm(remaining / 3600) + " left"
        return showRemoveAt ? "Remove at " + whenText(removeAt) + "\n" + left : left
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(start)
            let cap = Double(limit) * 3600
            let remaining = cap - elapsed
            RingView(
                progress: elapsed / cap,
                color: remaining <= 0 ? .red : (remaining < cap * 0.15 ? .orange : .green),
                title: clock(elapsed),
                subtitle: subtitle(elapsed: elapsed, cap: cap),
                size: size
            )
        }
    }
}

struct RingView: View {
    let progress: Double
    let color: Color
    let title: String
    var subtitle: String = ""
    var size: CGFloat = 260

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: size * 0.06)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(color, style: StrokeStyle(lineWidth: size * 0.06, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: progress)
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: size * 0.146, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .animation(.snappy, value: title)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(size < 200 ? .caption2 : .caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, size * 0.14)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            subtitle.isEmpty
                ? title
                : title + ", " + subtitle.replacingOccurrences(of: "\n", with: ", ")
        )
    }
}

struct WornTimeSheet: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wearLimitHours") private var limit = 14
    @State private var hours = 1
    @State private var minutes = 0

    private var started: Date {
        Date.now.addingTimeInterval(-Double(hours * 3600 + minutes * 60))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Already wearing them?")
                .font(.headline)
            Text("How long have you had your lenses in?")
                .foregroundStyle(.secondary)

            HStack(spacing: 28) {
                Stepper("\(hours) h", value: $hours, in: 0...20)
                Stepper("\(minutes) min", value: $minutes, in: 0...55, step: 5)
            }

            Divider()

            LabeledContent("Put on at") {
                Text(started.formatted(date: .omitted, time: .shortened))
            }
            LabeledContent("Remove at") {
                Text(started.addingTimeInterval(Double(limit) * 3600)
                    .formatted(date: .omitted, time: .shortened))
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start timer") {
                    sync.start(at: started)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct AdjustStartSheet: View {
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @AppStorage("wearLimitHours") private var limit = 14
    @State private var start: Date

    private let nudges = [-60, -30, -15, -5, 5, 15]

    init(initial: Date) {
        _start = State(initialValue: initial)
    }

    private func label(_ m: Int) -> String {
        let sign = m < 0 ? "-" : "+"
        let a = abs(m)
        return a >= 60 ? "\(sign)\(a / 60)h" : "\(sign)\(a)m"
    }

    private func nudge(_ m: Int) {
        start = min(start.addingTimeInterval(Double(m) * 60), Date.now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetHeader(
                title: "Adjust start time",
                subtitle: "Forgot to press Start? Set when you actually put them in."
            )

            DatePicker(
                "Put on",
                selection: $start,
                in: Date.now.addingTimeInterval(-48 * 3600)...Date.now,
                displayedComponents: [.date, .hourAndMinute]
            )

            HStack(spacing: 8) {
                ForEach(nudges, id: \.self) { m in
                    Button(label(m)) { nudge(m) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(m > 0 && start.addingTimeInterval(Double(m) * 60) > Date.now)
                }
            }

            Divider()

            LabeledContent("Worn so far") {
                Text(hm(Date.now.timeIntervalSince(start) / 3600)).monospacedDigit()
            }
            LabeledContent("Remove at") {
                Text(whenText(start.addingTimeInterval(Double(limit) * 3600))).monospacedDigit()
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    sync.adjustStart(to: start)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

struct SettingsSheet: View {
    @Environment(SyncService.self) private var sync
    @Environment(NotificationService.self) private var notifier
    @Environment(\.dismiss) private var dismiss

    @AppStorage("wearLimitHours") private var limit = 14
    @AppStorage("maxDaysPerWeek") private var maxDays = 6
    @AppStorage("putOnReminder") private var putOnOn = true
    @AppStorage("removeReminder") private var removeOn = true
    @AppStorage("putOnMinutes") private var putOnMinutes = 480
    @AppStorage("snoozeMinutes") private var snooze = 15

    private var putOnTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: putOnMinutes / 60,
                    minute: putOnMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: {
                let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
                putOnMinutes = (c.hour ?? 8) * 60 + (c.minute ?? 0)
            }
        )
    }

    private var settingsKey: String {
        "\(limit)|\(maxDays)|\(putOnOn)|\(removeOn)|\(putOnMinutes)|\(snooze)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings")
                .font(.headline)

            Form {
                Section("Wear") {
                    Stepper("Wear time: \(limit) hours", value: $limit, in: 4...20)
                    Stepper("Max days per week: \(maxDays)", value: $maxDays, in: 1...7)
                }

                Section("Reminders") {
                    Toggle("Remind me to put lenses in", isOn: $putOnOn)
                    if putOnOn {
                        DatePicker("Time", selection: putOnTime, displayedComponents: .hourAndMinute)
                    }
                    Toggle("Remind me to take lenses out", isOn: $removeOn)
                    Picker("Snooze for", selection: $snooze) {
                        ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                    }
                    if notifier.denied {
                        Text("Notifications are turned off for Lensy. Turn them on in System Settings > Notifications.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Section("Test") {
                    HStack {
                        Button("Test put-on reminder") { notifier.sendTest(category: "puton") }
                        Button("Test remove reminder") { notifier.sendTest(category: "remove") }
                    }
                    Text("Arrives in about 10 seconds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onChange(of: settingsKey) { sync.replanReminders() }
        .task { await notifier.refreshAuthorization() }
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
                StatTile(title: "Total worn", value: hm(total), icon: "clock")
                StatTile(title: "Sessions", value: "\(visible.count)", icon: "number")
                StatTile(title: "Avg per day", value: hm(avg), icon: "chart.bar")
            }

            if visible.isEmpty {
                ContentUnavailableView {
                    Label("No sessions", systemImage: "eye")
                } description: {
                    Text("Nothing recorded in this period.")
                } actions: {
                    Button("Add a session") { adding = true }
                }
            } else {
                List {
                    ForEach(groups) { g in
                        Section {
                            ForEach(g.items) { s in
                                HistoryRow(
                                    session: s,
                                    limit: limit,
                                    onEdit: { editing = s },
                                    onDelete: { sync.delete(s) }
                                )
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        sync.delete(s)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                    Button {
                                        editing = s
                                    } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                            }
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
        .padding([.horizontal, .top], 24)
        .sheet(item: $editing) { SessionEditor(session: $0) }
        .sheet(isPresented: $adding) { SessionEditor(session: nil) }
    }
}

struct DurationBar: View {
    let fraction: Double

    var body: some View {
        let f = min(max(fraction, 0), 1)
        Capsule()
            .fill(.quaternary)
            .frame(width: 56, height: 5)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(fraction > 1 ? Color.red : (fraction > 0.85 ? Color.orange : Color.green))
                    .frame(width: 56 * f)
            }
    }
}

struct HistoryRow: View {
    let session: WearSession
    let limit: Int
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let s = session
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
            } else {
                if s.duration > Double(limit) * 3600 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Over your wear limit")
                }
                DurationBar(fraction: s.duration / (Double(limit) * 3600))
            }
            Text(hm(s.duration / 3600))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            HStack(spacing: 8) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Edit")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
                .help("Delete")
            }
            .opacity(hovering ? 1 : 0.35)
            .animation(.snappy(duration: 0.15), value: hovering)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button("Delete", role: .destructive, action: onDelete)
        }
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
    @AppStorage("maxDaysPerWeek") private var maxDays = 6
    let sessions: [WearSession]
    let limit: Int

    @State private var period: Period = .week
    @State private var anchor = Date.now
    @State private var selectedDay: Date?

    var body: some View {
        let cal = mondayCalendar
        let iv = interval(period, anchor: anchor) ?? DateInterval(start: .now, duration: 86400)
        let days = dayTotals(sessions, in: iv)
        let total = days.reduce(0) { $0 + $1.hours }
        let worn = days.filter { $0.hours >= 1.0 / 60 }
        let inRange = sessions.filter { $0.endedAt != nil && iv.contains($0.startedAt) }
        let longest = inRange.map(\.duration).max() ?? 0
        let over = inRange.filter { $0.duration > Double(limit) * 3600 }.count
        let avg = worn.isEmpty ? 0 : total / Double(worn.count)
        let peak = (days.map(\.hours).max() ?? 0) + 1
        let tooManyDays = period == .week && worn.count >= maxDays
        let selected = selectedDay.flatMap { sel in
            days.first { cal.isDate($0.day, inSameDayAs: sel) }
        }

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PeriodBar(period: $period, anchor: $anchor, options: [.week, .month])

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3),
                    spacing: 12
                ) {
                    StatTile(title: "Total worn", value: hm(total), icon: "clock")
                    StatTile(
                        title: "Days worn",
                        value: "\(worn.count) of \(days.count)",
                        icon: "calendar",
                        tint: tooManyDays ? .orange : .primary
                    )
                    StatTile(title: "Avg per day worn", value: hm(avg), icon: "chart.bar")
                    StatTile(title: "Longest session", value: hm(longest / 3600), icon: "hourglass")
                    StatTile(title: "Sessions", value: "\(inRange.count)", icon: "number")
                    StatTile(
                        title: "Over \(limit)h limit",
                        value: "\(over)",
                        icon: "exclamationmark.triangle",
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
                        .opacity(selected == nil || selected?.day == t.day ? 1 : 0.45)
                    }
                    RuleMark(y: .value("Limit", limit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing) {
                            Text("limit \(limit)h")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    if let s = selected {
                        RuleMark(x: .value("Selected", s.day, unit: .day))
                            .foregroundStyle(.secondary.opacity(0.35))
                            .annotation(
                                position: .top,
                                spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
                            ) {
                                VStack(spacing: 2) {
                                    Text(s.day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    Text(hm(s.hours))
                                        .font(.caption.weight(.semibold))
                                }
                                .padding(6)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                            }
                    }
                }
                .chartXSelection(value: $selectedDay)
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
                .overlay {
                    if total == 0 {
                        Text("No wear recorded in this period")
                            .foregroundStyle(.secondary)
                    }
                }
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
                LiveRing(start: start, limit: limit, size: 190)
                Text("Put on " + whenText(start))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    sync.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 150, height: 34)
                        .background(Color.red, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .frame(width: 250)
    }
}

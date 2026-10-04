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

struct DayTotal: Identifiable {
    let day: Date
    let hours: Double
    var id: Date { day }
}

private func dayTotals(_ sessions: [WearSession], days: Int) -> [DayTotal] {
    let cal = Calendar.current
    let today = cal.startOfDay(for: .now)
    return (0..<days).reversed().map { offset in
        let start = cal.date(byAdding: .day, value: -offset, to: today)!
        let end = cal.date(byAdding: .day, value: 1, to: start)!
        let secs = sessions.reduce(0.0) { acc, s in
            let a = max(s.startedAt, start)
            let b = min(s.endedAt ?? .now, end)
            return acc + max(0, b.timeIntervalSince(a))
        }
        return DayTotal(day: start, hours: secs / 3600)
    }
}

enum MainTab: String, CaseIterable, Identifiable {
    case timer = "Timer"
    case history = "History"
    case reports = "Reports"
    var id: String { rawValue }
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
    @State private var showLogin = false

    var body: some View {
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
            bottomBar
        }
        .frame(minWidth: 560, minHeight: 620)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) {
                    ForEach(MainTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
            }
        }
        .sheet(isPresented: $showLogin) { LoginSheet() }
        .task {
            sync.refreshActive()
            await auth.restore()
            if !auth.isLoggedIn { showLogin = true }
            await sync.sync()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await sync.sync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Task { await sync.sync() }
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(auth.isLoggedIn ? sync.status : "Not syncing")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Stepper("Wear limit: \(limit)h", value: $limit, in: 6...24)
                .font(.caption)
                .controlSize(.small)
            if auth.isLoggedIn {
                Button("Sign out") { Task { await auth.signOut() } }
                    .buttonStyle(.link)
                    .font(.caption)
            } else {
                Button("Sign in") { showLogin = true }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

struct TimerTab: View {
    @Environment(SyncService.self) private var sync
    let sessions: [WearSession]
    let limit: Int

    var body: some View {
        let totals = dayTotals(sessions, days: 7)
        let week = totals.reduce(0) { $0 + $1.hours }
        let worn = totals.filter { $0.hours > 0 }
        let avg = worn.isEmpty ? 0 : week / Double(worn.count)

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
                StatTile(title: "Today", value: hm(totals.last?.hours ?? 0))
                StatTile(title: "Last 7 days", value: hm(week))
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

struct MenuLabel: View {
    @Environment(SyncService.self) private var sync

    private var icon: NSImage {
        let base = NSImage(named: "MenuIcon")
            ?? NSImage(systemSymbolName: "eye", accessibilityDescription: nil)!
        let img = (base.copy() as? NSImage) ?? base
        let h: CGFloat = 18
        let w = h * img.size.width / max(img.size.height, 1)
        img.size = NSSize(width: w, height: h)
        img.isTemplate = true
        return img
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(nsImage: icon)
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

struct HistoryTab: View {
    @Environment(SyncService.self) private var sync
    let sessions: [WearSession]
    let limit: Int

    private var finished: [WearSession] { sessions.filter { $0.endedAt != nil } }

    var body: some View {
        if finished.isEmpty {
            ContentUnavailableView(
                "No sessions yet",
                systemImage: "eye",
                description: Text("Finished wear sessions show up here.")
            )
        } else {
            List(finished) { s in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.startedAt.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                        Text(s.startedAt.formatted(date: .omitted, time: .shortened)
                             + " - "
                             + (s.endedAt ?? .now).formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if s.duration > Double(limit) * 3600 {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(hm(s.duration / 3600))
                        .monospacedDigit()
                }
                .contextMenu {
                    Button("Delete", role: .destructive) { sync.delete(s) }
                }
            }
        }
    }
}

struct ReportsTab: View {
    let sessions: [WearSession]
    let limit: Int
    @State private var range = 14

    var body: some View {
        let totals = dayTotals(sessions, days: range)
        let total = totals.reduce(0) { $0 + $1.hours }
        let worn = totals.filter { $0.hours > 0 }
        let rangeStart = totals.first?.day ?? .now
        let inRange = sessions.filter { $0.endedAt != nil && $0.startedAt >= rangeStart }
        let longest = inRange.map(\.duration).max() ?? 0
        let over = inRange.filter { $0.duration > Double(limit) * 3600 }.count
        let avg = worn.isEmpty ? 0 : total / Double(worn.count)
        let peak = (totals.map(\.hours).max() ?? 0) + 1

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Range", selection: $range) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    StatTile(title: "Total worn", value: hm(total))
                    StatTile(title: "Days worn", value: "\(worn.count) of \(range)")
                    StatTile(title: "Avg per day worn", value: hm(avg))
                    StatTile(title: "Longest session", value: hm(longest / 3600))
                    StatTile(title: "Sessions", value: "\(inRange.count)")
                    StatTile(title: "Over \(limit)h limit", value: "\(over)", tint: over > 0 ? .orange : .primary)
                }

                Text("Hours worn per day")
                    .font(.headline)

                Chart {
                    ForEach(totals) { t in
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
                .chartYScale(domain: 0...max(Double(limit) + 2, peak))
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : (range == 14 ? 2 : 5))) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    }
                }
                .frame(height: 240)
            }
            .padding(24)
        }
    }
}

struct LoginSheet: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncService.self) private var sync
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 14) {
            Text("Sign in to sync")
                .font(.headline)
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
            if let e = auth.errorMessage {
                Text(e)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Not now") { dismiss() }
                Spacer()
                Button("Sign in") {
                    Task {
                        await auth.signIn(email: email, password: password)
                        if auth.isLoggedIn {
                            dismiss()
                            await sync.sync()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 320)
        .onAppear { auth.errorMessage = nil }
    }
}

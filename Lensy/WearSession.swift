import Foundation
import SwiftData
import Supabase
import UserNotifications
import AppKit
import AppIntents

nonisolated struct DefaultsStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws {
        UserDefaults.standard.set(value, forKey: "auth." + key)
    }

    func retrieve(key: String) throws -> Data? {
        UserDefaults.standard.data(forKey: "auth." + key)
    }

    func remove(key: String) throws {
        UserDefaults.standard.removeObject(forKey: "auth." + key)
    }
}

nonisolated let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://cljpjblzsrvnepfxsccf.supabase.co")!,
    supabaseKey: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNsanBqYmx6c3J2bmVwZnhzY2NmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTExMDk0NDEsImV4cCI6MjEwNjY4NTQ0MX0.5rvumC-tljK484FIWy42iwT-tCcMAMM597q-DMBX7lQ",
    options: SupabaseClientOptions(
        auth: .init(storage: DefaultsStorage(), emitLocalSessionAsInitialSession: true)
    )
)

@Model
final class WearSession {
    var id: UUID = UUID()
    var startedAt: Date = Date()
    var endedAt: Date? = nil
    var note: String = ""
    var updatedAt: Date = Date()
    var deletedAt: Date? = nil
    var needsSync: Bool = true

    init(startedAt: Date = .now) {
        self.startedAt = startedAt
    }

    var duration: TimeInterval {
        (endedAt ?? .now).timeIntervalSince(startedAt)
    }

    func touch() {
        updatedAt = .now
        needsSync = true
    }
}

nonisolated struct SessionDTO: Codable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var note: String
    var updatedAt: Date
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, note
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(startedAt, forKey: .startedAt)
        try c.encode(endedAt, forKey: .endedAt)
        try c.encode(note, forKey: .note)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(deletedAt, forKey: .deletedAt)
    }
}

var mondayCalendar: Calendar {
    var c = Calendar.current
    c.firstWeekday = 2
    return c
}

func wornDays(_ sessions: [WearSession], in iv: DateInterval) -> Set<Date> {
    let cal = mondayCalendar
    var result = Set<Date>()
    var day = cal.startOfDay(for: iv.start)
    while day < iv.end {
        let next = cal.date(byAdding: .day, value: 1, to: day)!
        let secs = sessions.reduce(0.0) { acc, s in
            let a = max(s.startedAt, day)
            let b = min(s.endedAt ?? .now, next)
            return acc + max(0, b.timeIntervalSince(a))
        }
        if secs >= 60 { result.insert(day) }
        day = next
    }
    return result
}

enum SyncState: Equatable {
    case idle
    case syncing
    case synced(Date)
    case failed(String)
}

@Observable @MainActor
final class AuthStore {
    var isLoggedIn = false
    var isLoading = true
    var errorMessage: String?
    var email: String?

    func restore() async {
        let session = supabase.auth.currentSession
        isLoggedIn = session != nil
        email = session?.user.email
        isLoading = false
    }

    func signIn(email: String, password: String) async {
        do {
            try await supabase.auth.signIn(email: email, password: password)
            isLoggedIn = true
            self.email = supabase.auth.currentSession?.user.email ?? email
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        isLoggedIn = false
        email = nil
    }
}

@Observable @MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    var askWornTime = false
    var showSettings = false
    var denied = false

    @ObservationIgnored weak var sync: SyncService?
    @ObservationIgnored private var lastSignature = ""
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: "snooze", title: "Snooze", options: [])
        let wearing = UNNotificationAction(
            identifier: "alreadyWearing",
            title: "Already wearing",
            options: [.foreground]
        )
        let out = UNNotificationAction(identifier: "lensesOut", title: "Lenses are out", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "puton", actions: [wearing, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "remove", actions: [snooze, out], intentIdentifiers: [], options: [])
        ])
    }

    private var defaults: UserDefaults { .standard }
    private var limitHours: Int { defaults.object(forKey: "wearLimitHours") as? Int ?? 14 }
    private var snoozeMinutes: Int { defaults.object(forKey: "snoozeMinutes") as? Int ?? 15 }
    private var putOnEnabled: Bool { defaults.object(forKey: "putOnReminder") as? Bool ?? true }
    private var removeEnabled: Bool { defaults.object(forKey: "removeReminder") as? Bool ?? true }
    private var putOnMinutes: Int { defaults.object(forKey: "putOnMinutes") as? Int ?? 480 }

    func requestAccess() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshAuthorization()
    }

    func refreshAuthorization() async {
        let s = await center.notificationSettings()
        denied = s.authorizationStatus == .denied
    }

    func cancelAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        lastSignature = ""
    }

    func reschedule(activeStart: Date?, skipDays: Set<Date>, force: Bool = false) {
        let today = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        let skips = skipDays.map { $0.timeIntervalSince1970 }.sorted()
        let sig = "\(activeStart?.timeIntervalSince1970 ?? 0)|\(limitHours)|\(snoozeMinutes)|\(putOnEnabled)|\(removeEnabled)|\(putOnMinutes)|\(today)|\(skips)"
        guard force || sig != lastSignature else { return }
        lastSignature = sig

        let putOnIDs = (0..<14).map { "puton-day-\($0)" }
        var pending = ["remove-main"] + putOnIDs
        let delivered: [String]
        if activeStart == nil {
            pending.append("remove-snooze")
            delivered = ["remove-main", "remove-snooze"]
        } else {
            pending.append("puton-snooze")
            delivered = ["puton-snooze"] + putOnIDs
        }
        center.removePendingNotificationRequests(withIdentifiers: pending)
        center.removeDeliveredNotifications(withIdentifiers: delivered)

        if let start = activeStart, removeEnabled {
            let fireAt = start.addingTimeInterval(Double(limitHours) * 3600)
            if fireAt > Date.now.addingTimeInterval(5) {
                add(
                    id: "remove-main",
                    category: "remove",
                    title: "Time to take your lenses out",
                    body: "You've reached your \(limitHours) hour wear time.",
                    at: fireAt
                )
            }
        }

        if putOnEnabled {
            let cal = Calendar.current
            let startOfToday = cal.startOfDay(for: .now)
            for offset in 0..<14 {
                guard let day = cal.date(byAdding: .day, value: offset, to: startOfToday),
                      !skipDays.contains(day),
                      let fireAt = cal.date(byAdding: .minute, value: putOnMinutes, to: day),
                      fireAt > Date.now
                else { continue }
                add(
                    id: "puton-day-\(offset)",
                    category: "puton",
                    title: "Time to put your lenses in",
                    body: "Tap Already wearing if they're in already.",
                    at: fireAt
                )
            }
        }
    }

    private func add(id: String, category: String, title: String, body: String, at date: Date) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    private func scheduleIn(category: String, id: String, seconds: TimeInterval) {
        let isPutOn = category == "puton"
        let content = UNMutableNotificationContent()
        content.title = isPutOn ? "Time to put your lenses in" : "Time to take your lenses out"
        content.body = isPutOn
            ? "Tap Already wearing if they're in already."
            : "You've passed your \(limitHours) hour wear time."
        content.sound = .default
        content.categoryIdentifier = category
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(seconds, 1), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    func snooze(category: String) {
        scheduleIn(
            category: category,
            id: category == "puton" ? "puton-snooze" : "remove-snooze",
            seconds: Double(snoozeMinutes) * 60
        )
    }

    func sendTest(category: String) {
        scheduleIn(category: category, id: "test-\(category)", seconds: 10)
    }
    
    func openSettings() {
        showSettings = true
        bringToFront()
    }

    private func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
            NSWorkspace.shared.open(Bundle.main.bundleURL)
        }
    }

    private func handle(action: String, category: String) {
        switch action {
        case "snooze":
            snooze(category: category)
        case "alreadyWearing":
            bringToFront()
            askWornTime = true
        case "lensesOut":
            sync?.stop()
        case UNNotificationDefaultActionIdentifier:
            bringToFront()
        default:
            break
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        await handle(action: action, category: category)
    }
}

@Observable @MainActor
final class SyncService {
    static var shared: SyncService?

    var activeStartedAt: Date?
    var menuTitle = ""
    var state: SyncState = .idle
    var pending = 0
    var lastDeleted: WearSession?

    @ObservationIgnored weak var notifier: NotificationService?
    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var lastSync = Date.distantPast
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var undoTask: Task<Void, Never>?

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    private var maxDays: Int {
        UserDefaults.standard.object(forKey: "maxDaysPerWeek") as? Int ?? 6
    }

    var signedIn: Bool { supabase.auth.currentSession != nil }

    private func dto(_ s: WearSession) -> SessionDTO {
        SessionDTO(
            id: s.id,
            startedAt: s.startedAt,
            endedAt: s.endedAt,
            note: s.note,
            updatedAt: s.updatedAt,
            deletedAt: s.deletedAt
        )
    }

    private func fetchActive() -> WearSession? {
        let d = FetchDescriptor<WearSession>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return (try? context.fetch(d))?.first
    }

    private func liveSessions() -> [WearSession] {
        ((try? context.fetch(FetchDescriptor<WearSession>())) ?? [])
            .filter { $0.deletedAt == nil }
    }

    func daysWornThisWeek() -> Int {
        guard let week = mondayCalendar.dateInterval(of: .weekOfYear, for: .now) else { return 0 }
        return wornDays(liveSessions(), in: week).count
    }

    func weeklyWarningCount() -> Int? {
        let cal = mondayCalendar
        guard let week = cal.dateInterval(of: .weekOfYear, for: .now) else { return nil }
        let days = wornDays(liveSessions(), in: week)
        if days.contains(cal.startOfDay(for: .now)) { return nil }
        return days.count >= maxDays ? days.count : nil
    }

    func refreshActive() {
        let current = fetchActive()?.startedAt
        if current != activeStartedAt { activeStartedAt = current }
        let running = current != nil
        if UserDefaults.standard.bool(forKey: "timerRunning") != running {
            UserDefaults.standard.set(running, forKey: "timerRunning")
        }
        updateTicker()
        updatePending()
        planReminders()
    }

    func replanReminders() {
        planReminders()
    }

    private func updatePending() {
        let n = unsyncedCount()
        if n != pending { pending = n }
    }

    private func planReminders() {
        guard let notifier else { return }
        guard supabase.auth.currentSession != nil else {
            notifier.cancelAll()
            return
        }
        let cal = mondayCalendar
        let live = liveSessions()
        let today = cal.startOfDay(for: .now)

        var skip = Set<Date>()
        if live.contains(where: { cal.startOfDay(for: $0.startedAt) == today }) {
            skip.insert(today)
        }
        if let week = cal.dateInterval(of: .weekOfYear, for: .now),
           wornDays(live, in: week).count >= maxDays {
            var d = today
            while d < week.end {
                skip.insert(d)
                d = cal.date(byAdding: .day, value: 1, to: d)!
            }
        }
        notifier.reschedule(activeStart: activeStartedAt, skipDays: skip)
    }

    private func updateTicker() {
        guard activeStartedAt != nil else {
            ticker?.invalidate()
            ticker = nil
            if menuTitle != "" { menuTitle = "" }
            return
        }
        tick()
        if ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.tick() }
            }
        }
    }

    private func tick() {
        guard let start = activeStartedAt else { return }
        let minutes = Int(Date.now.timeIntervalSince(start)) / 60
        let text = String(format: "%d:%02d", minutes / 60, minutes % 60)
        if text != menuTitle { menuTitle = text }
    }

    func start(at date: Date = .now) {
        guard fetchActive() == nil else { return }
        context.insert(WearSession(startedAt: date))
        try? context.save()
        refreshActive()
        Task { await sync(force: true) }
    }

    func stop() {
        guard let s = fetchActive() else { return }
        s.endedAt = .now
        s.touch()
        try? context.save()
        refreshActive()
        Task { await sync(force: true) }
    }

    func delete(_ s: WearSession) {
        s.deletedAt = .now
        s.touch()
        try? context.save()
        refreshActive()
        Task { await sync(force: true) }

        lastDeleted = s
        undoTask?.cancel()
        undoTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.lastDeleted = nil
        }
    }

    func undoDelete() {
        guard let s = lastDeleted else { return }
        s.deletedAt = nil
        s.touch()
        try? context.save()
        lastDeleted = nil
        undoTask?.cancel()
        refreshActive()
        Task { await sync(force: true) }
    }

    func save(_ existing: WearSession?, start: Date, end: Date?, note: String) {
        let s: WearSession
        if let existing {
            s = existing
        } else {
            s = WearSession(startedAt: start)
            context.insert(s)
        }
        s.startedAt = start
        s.endedAt = end
        s.note = note
        s.touch()
        try? context.save()
        refreshActive()
        Task { await sync(force: true) }
    }
    
    func adjustStart(to date: Date) {
        guard let s = fetchActive() else { return }
        s.startedAt = min(date, .now)
        s.touch()
        try? context.save()
        refreshActive()
        Task { await sync(force: true) }
    }

    func unsyncedCount() -> Int {
        let d = FetchDescriptor<WearSession>(predicate: #Predicate { $0.needsSync == true })
        return (try? context.fetchCount(d)) ?? 0
    }

    func wipeLocal() {
        try? context.delete(model: WearSession.self)
        try? context.save()
        state = .idle
        lastSync = .distantPast
        refreshActive()
    }

    private func friendly(_ error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
                 .cannotConnectToHost, .timedOut, .dnsLookupFailed:
                return "No connection"
            default:
                break
            }
        }
        return "Couldn't sync"
    }

    func sync(force: Bool = false) async {
        guard supabase.auth.currentSession != nil else { return }
        if !force && Date.now.timeIntervalSince(lastSync) < 20 { return }
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        state = .syncing
        do {
            try await pull()
            try await push()
            state = .synced(.now)
        } catch {
            print("SYNC ERROR:", error)
            state = .failed(friendly(error))
        }
        lastSync = .now
        isSyncing = false
        refreshActive()
        if syncAgain {
            syncAgain = false
            await sync(force: true)
        }
    }

    func waitForSync(timeout: TimeInterval = 8) async {
        let deadline = Date.now.addingTimeInterval(timeout)
        await sync(force: true)
        while (isSyncing || syncAgain) && Date.now < deadline {
            try? await Task.sleep(for: .milliseconds(150))
        }
    }

    private func pull() async throws {
        let rows: [SessionDTO] = try await supabase
            .from("wear_sessions")
            .select()
            .execute()
            .value
        let local = try context.fetch(FetchDescriptor<WearSession>())
        let byID = Dictionary(local.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for r in rows {
            if let s = byID[r.id] {
                guard r.updatedAt > s.updatedAt else { continue }
                apply(r, to: s)
            } else {
                let s = WearSession(startedAt: r.startedAt)
                s.id = r.id
                apply(r, to: s)
                context.insert(s)
            }
        }
        try context.save()
        resolveDoubleActive()
    }

    private func apply(_ r: SessionDTO, to s: WearSession) {
        s.startedAt = r.startedAt
        s.endedAt = r.endedAt
        s.note = r.note
        s.updatedAt = r.updatedAt
        s.deletedAt = r.deletedAt
        s.needsSync = false
    }

    private func resolveDoubleActive() {
        let d = FetchDescriptor<WearSession>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        let open = (try? context.fetch(d)) ?? []
        for dup in open.dropFirst() {
            dup.deletedAt = .now
            dup.touch()
        }
        try? context.save()
    }

    private func repairDuplicateIDs() {
        let all = (try? context.fetch(
            FetchDescriptor<WearSession>(sortBy: [SortDescriptor(\.startedAt)])
        )) ?? []
        var seen = Set<UUID>()
        for s in all {
            if !seen.insert(s.id).inserted {
                s.id = UUID()
                s.touch()
            }
        }
        try? context.save()
    }

    private func push() async throws {
        repairDuplicateIDs()

        let dirty = try context.fetch(
            FetchDescriptor<WearSession>(predicate: #Predicate { $0.needsSync == true })
        )
        let closed = dirty.filter { $0.endedAt != nil || $0.deletedAt != nil }
        let open = dirty.filter { $0.endedAt == nil && $0.deletedAt == nil }

        for batch in [closed, open] where !batch.isEmpty {
            let sent = batch.map { ($0, $0.updatedAt) }
            try await supabase
                .from("wear_sessions")
                .upsert(batch.map { dto($0) })
                .execute()
            for (s, at) in sent where s.updatedAt == at {
                s.needsSync = false
            }
            try context.save()
        }
    }
}

private func wearLimitHours() -> Int {
    UserDefaults.standard.object(forKey: "wearLimitHours") as? Int ?? 14
}

private func spoken(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds / 60))
    let h = total / 60
    let m = total % 60
    let hours = "\(h) hour\(h == 1 ? "" : "s")"
    let mins = "\(m) minute\(m == 1 ? "" : "s")"
    if h == 0 { return mins }
    if m == 0 { return hours }
    return hours + " " + mins
}

private func clockTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
}

struct StartWearingIntent: AppIntent {
    static let title: LocalizedStringResource = "Put lenses in"
    static let description = IntentDescription("Starts the lens wear timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sync = SyncService.shared, sync.signedIn else {
            return .result(dialog: "Open Lensy and sign in first.")
        }
        if sync.activeStartedAt != nil {
            return .result(dialog: "Your timer is already running.")
        }
        if let worn = sync.weeklyWarningCount() {
            try await requestConfirmation(
                actionName: .continue,
                dialog: "You've already worn your lenses on \(worn) of 7 days this week. Start anyway?"
            )
        }
        sync.start()
        await sync.waitForSync()
        let removeAt = Date.now.addingTimeInterval(Double(wearLimitHours()) * 3600)
        return .result(dialog: "Timer started. Take them out around \(clockTime(removeAt)).")
    }
}

struct StopWearingIntent: AppIntent {
    static let title: LocalizedStringResource = "Take lenses out"
    static let description = IntentDescription("Stops the lens wear timer.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sync = SyncService.shared, sync.signedIn else {
            return .result(dialog: "Open Lensy and sign in first.")
        }
        guard let start = sync.activeStartedAt else {
            return .result(dialog: "Your lenses aren't being timed right now.")
        }
        let worn = Date.now.timeIntervalSince(start)
        sync.stop()
        await sync.waitForSync()
        return .result(dialog: "Done. You wore them for \(spoken(worn)).")
    }
}

struct AlreadyWearingIntent: AppIntent {
    static let title: LocalizedStringResource = "Already wearing lenses"
    static let description = IntentDescription("Starts the timer with the time you've already worn them.")

    @Parameter(title: "Hours", requestValueDialog: "How many hours have you been wearing them?")
    var hours: Int

    @Parameter(title: "Minutes", requestValueDialog: "And how many minutes?")
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Already wearing for \(\.$hours) hours and \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sync = SyncService.shared, sync.signedIn else {
            return .result(dialog: "Open Lensy and sign in first.")
        }
        if sync.activeStartedAt != nil {
            return .result(dialog: "Your timer is already running.")
        }
        guard hours >= 0, minutes >= 0, minutes < 60, hours * 60 + minutes <= 20 * 60 else {
            return .result(dialog: "That doesn't look right. Use 0 to 20 hours and 0 to 59 minutes.")
        }
        let start = Date.now.addingTimeInterval(-Double(hours * 60 + minutes) * 60)
        sync.start(at: start)
        await sync.waitForSync()
        let removeAt = start.addingTimeInterval(Double(wearLimitHours()) * 3600)
        return .result(dialog: "Timer started from \(clockTime(start)). Take them out around \(clockTime(removeAt)).")
    }
}

struct WearStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Lens status"
    static let description = IntentDescription("Tells you how long you've worn your lenses.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let sync = SyncService.shared, sync.signedIn else {
            return .result(dialog: "Open Lensy and sign in first.")
        }
        guard let start = sync.activeStartedAt else {
            let days = sync.daysWornThisWeek()
            return .result(dialog: "Your lenses are out. You've worn them on \(days) of 7 days this week.")
        }
        let elapsed = Date.now.timeIntervalSince(start)
        let cap = Double(wearLimitHours()) * 3600
        if elapsed > cap {
            return .result(dialog: "You're \(spoken(elapsed - cap)) past your wear time. Time to take them out.")
        }
        let removeAt = start.addingTimeInterval(cap)
        return .result(dialog: "They've been in for \(spoken(elapsed)). Take them out at \(clockTime(removeAt)).")
    }
}

struct LensyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWearingIntent(),
            phrases: [
                "Lenses in with \(.applicationName)",
                "Put my lenses in with \(.applicationName)"
            ],
            shortTitle: "Lenses in",
            systemImageName: "eye"
        )
        AppShortcut(
            intent: StopWearingIntent(),
            phrases: [
                "Lenses out with \(.applicationName)",
                "Take my lenses out with \(.applicationName)"
            ],
            shortTitle: "Lenses out",
            systemImageName: "eye.slash"
        )
        AppShortcut(
            intent: AlreadyWearingIntent(),
            phrases: [
                "Already wearing with \(.applicationName)",
                "I'm already wearing my lenses in \(.applicationName)"
            ],
            shortTitle: "Already wearing",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: WearStatusIntent(),
            phrases: [
                "Lens status with \(.applicationName)",
                "How long have I worn my lenses in \(.applicationName)"
            ],
            shortTitle: "Lens status",
            systemImageName: "timer"
        )
    }
}

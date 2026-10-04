import Foundation
import SwiftData
import Supabase

let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://YOUR-PROJECT.supabase.co")!,
    supabaseKey: "YOUR-ANON-KEY"
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

struct SessionDTO: Codable {
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

    init(_ s: WearSession) {
        id = s.id
        startedAt = s.startedAt
        endedAt = s.endedAt
        note = s.note
        updatedAt = s.updatedAt
        deletedAt = s.deletedAt
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

@Observable @MainActor
final class AuthStore {
    var isLoggedIn = false
    var isLoading = true
    var errorMessage: String?

    func restore() async {
        isLoggedIn = supabase.auth.currentSession != nil
        isLoading = false
    }

    func signIn(email: String, password: String) async {
        do {
            try await supabase.auth.signIn(email: email, password: password)
            isLoggedIn = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signUp(email: String, password: String) async {
        do {
            try await supabase.auth.signUp(email: email, password: password)
            await signIn(email: email, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
        isLoggedIn = false
    }
}

@Observable @MainActor
final class SyncService {
    var activeStartedAt: Date?
    var status = ""

    @ObservationIgnored private let container: ModelContainer
    @ObservationIgnored private var isSyncing = false
    @ObservationIgnored private var syncAgain = false

    init(container: ModelContainer) {
        self.container = container
    }

    private var context: ModelContext { container.mainContext }

    private func fetchActive() -> WearSession? {
        let d = FetchDescriptor<WearSession>(
            predicate: #Predicate { $0.endedAt == nil && $0.deletedAt == nil },
            sortBy: [SortDescriptor(\.startedAt)]
        )
        return (try? context.fetch(d))?.first
    }

    func refreshActive() {
        activeStartedAt = fetchActive()?.startedAt
    }

    func start() {
        guard fetchActive() == nil else { return }
        context.insert(WearSession())
        try? context.save()
        refreshActive()
        Task { await sync() }
    }

    func stop() {
        guard let s = fetchActive() else { return }
        s.endedAt = .now
        s.touch()
        try? context.save()
        refreshActive()
        Task { await sync() }
    }

    func sync() async {
        guard supabase.auth.currentSession != nil else { return }
        if isSyncing {
            syncAgain = true
            return
        }
        isSyncing = true
        status = "Syncing..."
        do {
            try await pull()
            try await push()
            status = "Synced " + Date.now.formatted(date: .omitted, time: .shortened)
        } catch {
            status = "Sync failed: \(error.localizedDescription)"
        }
        isSyncing = false
        refreshActive()
        if syncAgain {
            syncAgain = false
            await sync()
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

    private func push() async throws {
        let dirty = try context.fetch(
            FetchDescriptor<WearSession>(predicate: #Predicate { $0.needsSync == true })
        )
        let closed = dirty.filter { $0.endedAt != nil || $0.deletedAt != nil }
        let open = dirty.filter { $0.endedAt == nil && $0.deletedAt == nil }

        for batch in [closed, open] where !batch.isEmpty {
            let sent = batch.map { ($0, $0.updatedAt) }
            try await supabase
                .from("wear_sessions")
                .upsert(batch.map { SessionDTO($0) })
                .execute()
            for (s, at) in sent where s.updatedAt == at {
                s.needsSync = false
            }
            try context.save()
        }
    }
}
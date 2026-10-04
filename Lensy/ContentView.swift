import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(SyncService.self) private var sync

    @Query(
        filter: #Predicate<WearSession> { $0.endedAt != nil && $0.deletedAt == nil },
        sort: \WearSession.startedAt,
        order: .reverse
    )
    private var finished: [WearSession]

    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            if let start = sync.activeStartedAt {
                Text(start, style: .timer)
                    .font(.system(size: 48, weight: .semibold).monospacedDigit())
                Button("Stop") { sync.stop() }
            } else {
                Button("Start") { sync.start() }
            }

            Divider()

            List(finished) { s in
                HStack {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text(Duration.seconds(s.duration)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .monospacedDigit()
                }
            }

            footer
        }
        .padding()
        .frame(minWidth: 360, minHeight: 460)
        .task {
            sync.refreshActive()
            await auth.restore()
            await sync.sync()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await sync.sync() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            Task { await sync.sync() }
        }
        .alert("Error", isPresented: Binding(
            get: { auth.errorMessage != nil },
            set: { _ in auth.errorMessage = nil }
        )) {
            Button("OK") {}
        } message: {
            Text(auth.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private var footer: some View {
        if auth.isLoggedIn {
            HStack {
                Text(sync.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Sign out") { Task { await auth.signOut() } }
                    .font(.caption)
            }
        } else {
            VStack(spacing: 8) {
                TextField("Email", text: $email)
                SecureField("Password", text: $password)
                HStack {
                    Button("Sign in") {
                        Task {
                            await auth.signIn(email: email, password: password)
                            await sync.sync()
                        }
                    }
                    Button("Sign up") {
                        Task {
                            await auth.signUp(email: email, password: password)
                            await sync.sync()
                        }
                    }
                }
            }
            .frame(width: 260)
        }
    }
}

struct MenuLabel: View {
    @Environment(SyncService.self) private var sync

    var body: some View {
        if let start = sync.activeStartedAt {
            Text(start, style: .timer)
        } else {
            Image(systemName: "eye")
        }
    }
}

struct MenuContent: View {
    @Environment(SyncService.self) private var sync

    var body: some View {
        VStack(spacing: 12) {
            if let start = sync.activeStartedAt {
                Text(start, style: .timer)
                    .font(.largeTitle.monospacedDigit())
                Button("Stop") { sync.stop() }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
    }
}
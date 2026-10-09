import SwiftUI
import SwiftData

@main
struct LensyApp: App {
    let container: ModelContainer
    @State private var auth = AuthStore()
    @State private var sync: SyncService
    @State private var notifier: NotificationService
    @AppStorage("timerRunning") private var timerRunning = false

    init() {
        let c: ModelContainer
        do {
            c = try ModelContainer(for: WearSession.self)
        } catch {
            print("CONTAINER ERROR:", error)
            c = try! ModelContainer(
                for: WearSession.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }
        container = c

        let s = SyncService(container: c)
        let n = NotificationService()
        n.sync = s
        s.notifier = n
        SyncService.shared = s
        s.refreshActive()
        _sync = State(initialValue: s)
        _notifier = State(initialValue: n)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(auth)
                .environment(sync)
                .environment(notifier)
        }
        .modelContainer(container)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") { notifier.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: $timerRunning) {
            MenuContent()
                .environment(sync)
                .environment(notifier)
        } label: {
            MenuLabel()
                .environment(sync)
        }
        .menuBarExtraStyle(.window)
    }
}

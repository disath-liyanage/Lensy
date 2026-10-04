import SwiftUI
import SwiftData

@main
struct LensyApp: App {
    @AppStorage("isRunning") private var isRunning = false

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([WearSession.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra(isInserted: $isRunning) {
            MenuContent()
        } label: {
            MenuLabel()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(sharedModelContainer)
    }
}

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var context
    @AppStorage("isRunning") private var isRunning = false

    @Query(filter: #Predicate<WearSession> { $0.endedAt == nil })
    private var active: [WearSession]

    @Query(sort: \WearSession.startedAt, order: .reverse)
    private var sessions: [WearSession]

    var body: some View {
        VStack(spacing: 16) {
            if let session = active.first {
                Text(session.startedAt, style: .timer)
                    .font(.system(size: 48, weight: .semibold).monospacedDigit())
                Button("Stop") {
                    session.endedAt = .now
                    try? context.save()
                }
            } else {
                Button("Start") {
                    context.insert(WearSession())
                    try? context.save()
                }
            }

            Divider()

            List(sessions.filter { $0.endedAt != nil }) { s in
                HStack {
                    Text(s.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Spacer()
                    Text(Duration.seconds(s.duration)
                        .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .frame(minWidth: 360, minHeight: 420)
        .onChange(of: active.count, initial: true) { _, count in
            isRunning = count > 0
        }
    }
}

struct MenuLabel: View {
    @Query(filter: #Predicate<WearSession> { $0.endedAt == nil })
    private var active: [WearSession]

    var body: some View {
        if let session = active.first {
            Text(session.startedAt, style: .timer)
        } else {
            Image(systemName: "eye")
        }
    }
}

struct MenuContent: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<WearSession> { $0.endedAt == nil })
    private var active: [WearSession]

    var body: some View {
        VStack(spacing: 12) {
            if let session = active.first {
                Text(session.startedAt, style: .timer)
                    .font(.largeTitle.monospacedDigit())
                Button("Stop") {
                    session.endedAt = .now
                    try? context.save()
                }
            }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding()
        .frame(width: 220)
    }
}

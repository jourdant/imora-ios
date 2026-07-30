import SwiftUI

@main
struct ImoraApp: App {
    @State private var session = SessionStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

struct RootView: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.state {
            case .restoring:
                ProgressView()
            case .loggedOut:
                LoginFlowView()
            case .loggedIn:
                MainTabView()
            }
        }
        .animation(.smooth, value: session.state)
        .task { await session.restore() }
        .onChange(of: scenePhase) { _, phase in
            // returning to the foreground picks up photos taken meanwhile.
            if phase == .active { session.backup?.startIfIdle() }
        }
    }
}

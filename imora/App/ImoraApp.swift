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
            case .loggedOut:
                LoginFlowView()
            case .loggedIn:
                MainTabView()
            }
        }
        .animation(.smooth, value: session.state)
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // returning to the foreground picks up photos taken meanwhile
                // and reconnects the realtime channel, which resyncs grids.
                session.backup?.startIfIdle()
                session.realtime?.setActive(true)
            case .background:
                session.realtime?.setActive(false)
            default:
                break
            }
        }
    }
}

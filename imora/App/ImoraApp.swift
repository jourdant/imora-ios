import SwiftUI
import UserNotifications

@main
struct ImoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    init() {
        // set before any scene exists so a launch from a notification tap is
        // still routed instead of dropped.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        LocalNotifications.shared.registerCategories()
        ContinuedProcessing.registerAll()
        // builds the background session and attaches its delegate, so uploads
        // that finished while the app was gone are delivered on this launch.
        BackgroundUploader.shared.attach()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

/// exists for one callback: the system relaunches the app when background
/// uploads finish and hands over a completion handler that has to be called
/// once their events are delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        BackgroundUploader.shared.setBackgroundCompletionHandler(
            BackgroundUploader.LaunchCompletion(run: completionHandler)
        )
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
                // the socket is down while backgrounded, so the inbox fetch is
                // what surfaces anything raised in the meantime.
                Task { await session.notifications?.load() }
                Task { await LocalNotifications.shared.refreshAuthorization() }
                // whatever the share extension staged while we were away.
                adoptSharedItems()
            case .background:
                session.realtime?.setActive(false)
            default:
                break
            }
        }
    }

    /// the extension cannot open us - ios forbids it - so the app checks the
    /// shared inbox itself every time it comes forward.
    private func adoptSharedItems() {
        guard let uploads = session.shareUploads else { return }
        uploads.reload()
        if uploads.hasWork { NotificationRouter.shared.showsShareUpload = true }
    }
}

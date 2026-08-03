import SwiftUI
import UserNotifications

@main
struct ImoraApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var session = SessionStore()

    init() {
        // set before any scene exists so a backup report landing mid-launch
        // is still presented.
        UNUserNotificationCenter.current().delegate = NotificationDelegate.shared
        ContinuedProcessing.registerAll()
        // builds the background sessions and attaches their delegates, so
        // uploads that finished while the app was gone - backup runs and
        // share-sheet drops alike - are delivered on this launch.
        BackgroundUploader.shared.attach()
        ShareUploadCoordinator.shared.attach()
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
/// once their events are delivered. the identifier routes between the backup
/// session and the sessions the share extension started.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if identifier.hasPrefix(ShareTransfer.sessionPrefix) {
            ShareUploadCoordinator.shared.handleEvents(
                identifier: identifier,
                completion: ShareUploadCoordinator.LaunchCompletion(run: completionHandler)
            )
        } else {
            BackgroundUploader.shared.setBackgroundCompletionHandler(
                BackgroundUploader.LaunchCompletion(run: completionHandler)
            )
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
                // the socket is down while backgrounded, so the inbox fetch is
                // what surfaces anything raised in the meantime.
                Task { await session.notifications?.load() }
                Task { await LocalNotifications.shared.refreshAuthorization() }
                // uploads the share extension queued while we were away: drain
                // what finished, hurry along what the system kept waiting.
                ShareUploadCoordinator.shared.adoptPending()
            case .background:
                session.realtime?.setActive(false)
            default:
                break
            }
        }
    }
}

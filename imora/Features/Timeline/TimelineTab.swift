import SwiftUI

struct TimelineTab: View {
    @Environment(SessionStore.self) private var session
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            TimelineScreen(
                title: "Photos",
                filter: TimelineFilter(withPartners: true, withStacked: true),
                mergesLocalPhotos: true
            ) {
                MemoryLane()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        NotificationRouter.shared.openInbox()
                    } label: {
                        Image(systemName: "bell")
                    }
                    // ios 26 renders toolbar badges; zero draws nothing.
                    .badge(session.notifications?.unreadCount ?? 0)
                    .accessibilityIdentifier("notifications-open")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        ProfileAvatar(size: 30)
                    }
                    .accessibilityIdentifier("profile-avatar")
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
        }
    }
}

/// small circular avatar for the signed-in user.
struct ProfileAvatar: View {
    @Environment(SessionStore.self) private var session
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let user = session.user, let client = session.client,
               user.profileImagePath?.isEmpty == false {
                RemoteImage(url: client.profileImageURL(userID: user.id), targetPixelSize: 120)
            } else {
                Circle()
                    .fill(.indigo.gradient)
                    .overlay {
                        Text(initials)
                            .font(.system(size: size * 0.42, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
    }

    private var initials: String {
        let name = session.user?.name ?? ""
        let parts = name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters)
    }
}

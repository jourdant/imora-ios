import SwiftUI

/// circular avatar for any server user, with an initials fallback.
struct UserAvatar: View {
    @Environment(SessionStore.self) private var session
    let user: User
    var size: CGFloat = 36

    var body: some View {
        Group {
            if user.id == session.user?.id,
               let image = session.optimisticProfileImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if user.profileImagePath?.isEmpty == false, let client = session.client {
                RemoteImage(url: profileImageURL(client: client), targetPixelSize: 120)
            } else {
                Circle()
                    .fill(fallbackColor.gradient)
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
        let parts = user.name.split(separator: " ")
        let letters = parts.prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters)
    }

    private var fallbackColor: Color {
        switch user.avatarColor {
        case "red": .red
        case "orange": .orange
        case "yellow": .yellow
        case "green": .green
        case "blue": .blue
        case "purple": .purple
        case "pink": .pink
        case "amber": .orange
        case "gray": .gray
        default: .indigo
        }
    }

    private func profileImageURL(client: ImmichClient) -> URL {
        guard user.id == session.user?.id, let key = session.profileImageCacheKey else {
            return client.profileImageURL(userID: user.id)
        }
        return client.profileImageURL(userID: user.id)
            .appending(queryItems: [URLQueryItem(name: "c", value: key)])
    }
}

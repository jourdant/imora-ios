import SwiftUI

/// opt-in for device photos in the timeline. the app never asks for library
/// access at launch, so this banner is where the choice first appears. once
/// answered or dismissed it stays gone - the backup settings screen keeps a
/// second way in.
struct LocalPhotosBanner: View {
    @Environment(SessionStore.self) private var session
    @AppStorage("imora.localPhotos.bannerDismissed") private var dismissed = false

    var body: some View {
        if !dismissed && PhotoAccess.shared.canAsk {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.title3)
                        .foregroundStyle(.indigo)
                    Text("Show photos from this device?")
                        .font(.subheadline.weight(.semibold))
                }

                Text("Photos and videos on this device can appear in your timeline and back up to your server. This needs access to your photo library.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                HStack(spacing: 14) {
                    Button {
                        allowAccess()
                    } label: {
                        Text("Allow Access")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.indigo)
                    .accessibilityIdentifier("local-photos-allow")

                    Button("Not Now") {
                        withAnimation(.smooth) { dismissed = true }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("local-photos-dismiss")
                }
                .padding(.top, 2)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.fill.tertiary, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    private func allowAccess() {
        Task {
            guard await PhotoLibraryService.requestFullAccess() else { return }
            await session.adoptPhotoAccess()
        }
    }
}

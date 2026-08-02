import SwiftUI

struct MainTabView: View {
    /// tap targets from notifications land here, so the shell owns both the
    /// inbox sheet and the tab switch an album deep link needs.
    @Bindable private var router = NotificationRouter.shared
    @State private var selection: TabKey = .photos

    enum TabKey: Hashable {
        case photos, albums, library, search
    }

    var body: some View {
        TabView(selection: $selection) {
            Tab("Photos", systemImage: "photo.on.rectangle.angled", value: TabKey.photos) {
                TimelineTab()
            }
            Tab("Albums", systemImage: "rectangle.stack", value: TabKey.albums) {
                AlbumsTab()
            }
            Tab("Library", systemImage: "books.vertical", value: TabKey.library) {
                LibraryTab()
            }
            Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .search) {
                SearchTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .sheet(isPresented: $router.showsInbox) {
            NotificationsScreen()
        }
        .sheet(isPresented: $router.showsShareUpload) {
            ShareUploadScreen()
        }
        .onChange(of: router.pendingAlbumID) { _, id in
            // the albums tab picks the id up itself; switching to it is what
            // makes the tab exist in the first place.
            if id != nil { selection = .albums }
        }
        .onChange(of: router.showsPhotos) { _, wants in
            guard wants else { return }
            selection = .photos
            router.showsPhotos = false
        }
    }
}

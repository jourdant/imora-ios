import SwiftUI

struct MainTabView: View {
    @Environment(SessionStore.self) private var session
    /// in-app navigation targets land here, so the shell owns both the inbox
    /// sheet and the tab switch an album deep link needs.
    @Bindable private var router = NotificationRouter.shared
    @Bindable private var timelineRouter = TimelineNavigationRouter.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: TabKey = .photos

    enum TabKey: Hashable {
        case photos, albums, library, search
        /// the library's destinations as sidebar entries of their own.
        case favorites, people, places, archive, trash

        var isLibrarySection: Bool {
            switch self {
            case .favorites, .people, .places, .archive, .trash: true
            case .photos, .albums, .library, .search: false
            }
        }
    }

    /// the sidebar only exists at regular width, and without it the section's
    /// tabs would land in a "more" tab that duplicates the library.
    private var showsLibrarySection: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        ZStack {
            AssetViewerOpeningChromePrewarmer()
                .ignoresSafeArea()
                .background {
                    VStack(spacing: 0) {
                        Color.black.frame(height: 132)
                        Spacer(minLength: 0)
                        Color.black.frame(height: 112)
                    }
                    .ignoresSafeArea()
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            TabView(selection: $selection) {
                Tab("Photos", systemImage: "photo.on.rectangle.angled", value: TabKey.photos) {
                    TimelineTab()
                }
                Tab("Albums", systemImage: "rectangle.stack", value: TabKey.albums) {
                    AlbumsTab()
                }
                // the tab bar keeps the library as one entry that lists its
                // destinations; the ipad sidebar spells them out below
                // instead, the way photos lays its own sidebar out.
                Tab("Library", systemImage: "books.vertical", value: TabKey.library) {
                    LibraryTab()
                }
                .defaultVisibility(.hidden, for: .sidebar)
                if #available(iOS 27.0, *) {
                    Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .prominent) {
                        SearchTab()
                    }
                } else {
                    Tab("Search", systemImage: "magnifyingglass", value: TabKey.search, role: .search) {
                        SearchTab()
                    }
                }
                if showsLibrarySection {
                    TabSection("Library") {
                        Tab("Favorites", systemImage: "heart", value: TabKey.favorites) {
                            LibrarySectionTab(destination: .favorites)
                        }
                        if session.preferences?.peopleEnabled != false {
                            Tab("People", systemImage: "person.2", value: TabKey.people) {
                                LibrarySectionTab(destination: .people)
                            }
                        }
                        Tab("Places", systemImage: "mappin.and.ellipse", value: TabKey.places) {
                            LibrarySectionTab(destination: .places)
                        }
                        Tab("Archive", systemImage: "archivebox", value: TabKey.archive) {
                            LibrarySectionTab(destination: .archive)
                        }
                        if session.features?.trash != false {
                            Tab("Trash", systemImage: "trash", value: TabKey.trash) {
                                LibrarySectionTab(destination: .trash)
                            }
                        }
                    }
                    .defaultVisibility(.hidden, for: .tabBar)
                }
            }
            // a plain tab bar on iphone, a tab bar with a sidebar on ipad.
            .tabViewStyle(.sidebarAdaptable)
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .onChange(of: showsLibrarySection) { _, shows in
            // a section tab selected at regular width has nowhere to go once
            // the sidebar folds away, so the library list takes over.
            if !shows, selection.isLibrarySection { selection = .library }
        }
        .sheet(isPresented: $router.showsInbox) {
            NotificationsScreen()
        }
        .onChange(of: router.pendingAlbumID) { _, id in
            // the albums tab picks the id up itself; switching to it is what
            // makes the tab exist in the first place.
            if id != nil { selection = .albums }
        }
        .onChange(of: timelineRouter.pendingTarget) { _, target in
            if target != nil { selection = .photos }
        }
    }
}

import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Photos", systemImage: "photo.on.rectangle.angled") {
                TimelineTab()
            }
            Tab("Albums", systemImage: "rectangle.stack") {
                AlbumsTab()
            }
            Tab("Library", systemImage: "books.vertical") {
                LibraryTab()
            }
            Tab("Search", systemImage: "magnifyingglass", role: .search) {
                SearchTab()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}

import Foundation

/// Counts logical library assets. A Live Photo and its motion resource are one photo.
nonisolated struct MediaCounts: Equatable, Sendable {
    var photos = 0
    var videos = 0
    var total: Int { photos + videos }

    init(photos: Int = 0, videos: Int = 0) {
        self.photos = photos
        self.videos = videos
    }

    var text: String {
        "\(photos.formatted()) \(photos == 1 ? "photo" : "photos") and \(videos.formatted()) \(videos == 1 ? "video" : "videos")"
    }

    func progressText(of total: Self) -> String {
        "\(photos.formatted()) of \(total.photos.formatted()) \(total.photos == 1 ? "photo" : "photos") and \(videos.formatted()) of \(total.videos.formatted()) \(total.videos == 1 ? "video" : "videos")"
    }
}

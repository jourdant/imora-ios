import Foundation

/// mirrors the immich mobile SearchFilter model. the active text field decides
/// the endpoint: a context query goes to /search/smart, everything else -
/// filename, description, ocr or filter-only - goes to /search/metadata.
nonisolated struct SearchFilter: Equatable {
    enum TextType: String, CaseIterable, Identifiable {
        case context
        case filename
        case description
        case ocr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .context: "Context"
            case .filename: "File Name"
            case .description: "Description"
            case .ocr: "Text (OCR)"
            }
        }

        var prompt: String {
            switch self {
            case .context: "Sunrise on the beach"
            case .filename: "File name or extension"
            case .description: "Search by description"
            case .ocr: "Text in your photos"
            }
        }
    }

    enum MediaType: String, CaseIterable, Identifiable {
        case all
        case image
        case video

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: "All"
            case .image: "Image"
            case .video: "Video"
            }
        }

        /// uppercase wire value, nil means no type filter.
        var wireValue: String? {
            switch self {
            case .all: nil
            case .image: "IMAGE"
            case .video: "VIDEO"
            }
        }
    }

    /// none = no filter, unrated = explicit null, stars = 1...5.
    enum Rating: Equatable, Hashable {
        case any
        case unrated
        case stars(Int)
    }

    var context = ""
    var filename = ""
    var descriptionText = ""
    var ocr = ""
    /// bcp47-ish tag sent with smart search, e.g. "en-US".
    var language: String?
    /// smart search by visual similarity to this asset instead of a query.
    var queryAssetID: String?

    var people: [Person] = []
    var tags: [Tag] = []
    var country: String?
    var state: String?
    var city: String?
    var make: String?
    var model: String?
    var takenAfter: Date?
    var takenBefore: Date?
    /// human label for the chip, set by the date picker ("Last 3 months").
    var dateLabel: String?
    var rating: Rating = .any
    var notInAlbum = false
    var isArchive = false
    var isFavorite = false
    var mediaType: MediaType = .all

    var usesSmartSearch: Bool { !context.isEmpty || queryAssetID != nil }

    var isEmpty: Bool {
        context.isEmpty && filename.isEmpty && descriptionText.isEmpty && ocr.isEmpty && queryAssetID == nil
            && people.isEmpty && tags.isEmpty
            && country == nil && state == nil && city == nil
            && make == nil && model == nil
            && takenAfter == nil && takenBefore == nil
            && rating == .any
            && !notInAlbum && !isArchive && !isFavorite
            && mediaType == .all
    }

    /// replaces the query text, keeping the four fields mutually exclusive.
    mutating func setText(_ text: String, type: TextType) {
        context = type == .context ? text : ""
        filename = type == .filename ? text : ""
        descriptionText = type == .description ? text : ""
        ocr = type == .ocr ? text : ""
    }

    var activeText: String {
        [context, filename, descriptionText, ocr].first { !$0.isEmpty } ?? ""
    }

    // MARK: - request bodies

    /// smart search sends 100 per page, metadata search 1000, same as the
    /// flutter client.
    var pageSize: Int { usesSmartSearch ? 100 : 1000 }

    func requestBody(page: Int) -> SearchRequestBody {
        SearchRequestBody(filter: self, page: page)
    }
}

/// encodable body shared by /search/smart and /search/metadata. mirrors the
/// flutter repository: visibility is always sent, favorite and not-in-album
/// only when true, personIds and tagIds always, rating null means unrated.
nonisolated struct SearchRequestBody: Encodable {
    let filter: SearchFilter
    let page: Int

    private enum CodingKeys: String, CodingKey {
        case query, queryAssetId, language, originalFileName, description, ocr
        case country, state, city, make, model
        case takenAfter, takenBefore
        case visibility, rating, isFavorite, isNotInAlbum
        case personIds, tagIds, type, page, size, order
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        if filter.usesSmartSearch {
            if let queryAssetID = filter.queryAssetID {
                try container.encode(queryAssetID, forKey: .queryAssetId)
            } else {
                try container.encode(filter.context, forKey: .query)
            }
            if let language = filter.language {
                try container.encode(language, forKey: .language)
            }
        } else {
            if !filter.filename.isEmpty { try container.encode(filter.filename, forKey: .originalFileName) }
            if !filter.descriptionText.isEmpty { try container.encode(filter.descriptionText, forKey: .description) }
            if !filter.ocr.isEmpty { try container.encode(filter.ocr, forKey: .ocr) }
        }

        try container.encodeIfPresent(filter.country, forKey: .country)
        try container.encodeIfPresent(filter.state, forKey: .state)
        try container.encodeIfPresent(filter.city, forKey: .city)
        try container.encodeIfPresent(filter.make, forKey: .make)
        try container.encodeIfPresent(filter.model, forKey: .model)

        let iso = ISO8601DateFormatter()
        if let takenAfter = filter.takenAfter {
            try container.encode(iso.string(from: takenAfter), forKey: .takenAfter)
        }
        if let takenBefore = filter.takenBefore {
            try container.encode(iso.string(from: takenBefore), forKey: .takenBefore)
        }

        try container.encode(filter.isArchive ? "archive" : "timeline", forKey: .visibility)

        switch filter.rating {
        case .any: break
        case .unrated: try container.encodeNil(forKey: .rating)
        case .stars(let count): try container.encode(count, forKey: .rating)
        }

        if filter.isFavorite { try container.encode(true, forKey: .isFavorite) }
        if filter.notInAlbum { try container.encode(true, forKey: .isNotInAlbum) }

        try container.encode(filter.people.map(\.id), forKey: .personIds)
        try container.encode(filter.tags.map(\.id), forKey: .tagIds)

        if let type = filter.mediaType.wireValue {
            try container.encode(type, forKey: .type)
        }

        try container.encode(page, forKey: .page)
        try container.encode(filter.pageSize, forKey: .size)
    }
}

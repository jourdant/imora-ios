import SwiftUI

/// which filter sheet is open.
nonisolated enum FilterSheet: String, Identifiable {
    case people, location, camera, date, mediaType, rating, display, tags
    var id: String { rawValue }
}

// MARK: - chips row

/// horizontal row of filter chips under the search bar, like the flutter app.
struct FilterChipsRow: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    @Binding var activeSheet: FilterSheet?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(.people, icon: "person.2", label: "People", summary: peopleSummary)
                chip(.location, icon: "mappin.and.ellipse", label: "Location", summary: locationSummary)
                if session.preferences?.tagsEnabled != false {
                    chip(.tags, icon: "tag", label: "Tags", summary: tagsSummary)
                }
                chip(.camera, icon: "camera", label: "Camera", summary: cameraSummary)
                chip(.date, icon: "calendar", label: "Date", summary: filter.dateLabel)
                chip(.mediaType, icon: "play.square.stack", label: "Media Type", summary: mediaTypeSummary)
                if session.preferences?.ratingsEnabled == true {
                    chip(.rating, icon: "star", label: "Rating", summary: ratingSummary)
                }
                chip(.display, icon: "slider.horizontal.3", label: "Display Options", summary: displaySummary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .accessibilityIdentifier("filter-chips")
    }

    @ViewBuilder private func chip(_ sheet: FilterSheet, icon: String, label: String, summary: String?) -> some View {
        let isActive = summary != nil
        Button {
            activeSheet = sheet
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.footnote)
                Text(summary ?? label)
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? Color.accentColor : .primary)
            .background(
                isActive ? AnyShapeStyle(Color.accentColor.opacity(0.15)) : AnyShapeStyle(.fill.tertiary),
                in: .capsule
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter-chip-\(sheet.rawValue)")
    }

    private var peopleSummary: String? {
        guard !filter.people.isEmpty else { return nil }
        return filter.people.map { $0.name.isEmpty ? "No Name" : $0.name }.joined(separator: ", ")
    }

    private var locationSummary: String? {
        let parts = [filter.country, filter.state, filter.city].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var tagsSummary: String? {
        filter.tags.isEmpty ? nil : filter.tags.map(\.value).joined(separator: ", ")
    }

    private var cameraSummary: String? {
        let parts = [filter.make, filter.model].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var mediaTypeSummary: String? {
        filter.mediaType == .all ? nil : filter.mediaType.title
    }

    private var ratingSummary: String? {
        switch filter.rating {
        case .any: nil
        case .unrated: "Unrated"
        case .stars(let count): "\(count) Star\(count == 1 ? "" : "s")"
        }
    }

    private var displaySummary: String? {
        var parts: [String] = []
        if filter.notInAlbum { parts.append("Not in album") }
        if filter.isArchive { parts.append("Archive") }
        if filter.isFavorite { parts.append("Favorite") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - sheet scaffold

/// shared chrome: title, clear and apply, both dismiss like the flutter
/// bottom sheets.
private struct FilterSheetScaffold<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onClear: () -> Void
    let onApply: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear") {
                            onClear()
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Apply") {
                            onApply()
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("filter-apply")
                    }
                }
        }
    }
}

// MARK: - people

struct PeoplePickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var people: [Person] = []
    /// by id: the people in the filter were captured whenever it was applied,
    /// and any server-side edit since - a rename, a new portrait - makes the
    /// refetched value compare unequal to the one held here.
    @State private var selected: Set<String> = []
    @State private var searchText = ""
    @State private var isLoadingPeople = true

    private var visible: [Person] {
        guard !searchText.isEmpty else { return people }
        return people.filter { $0.name.localizedStandardContains(searchText) }
    }

    var body: some View {
        FilterSheetScaffold(title: "Select People") {
            apply { $0.people = [] }
        } onApply: {
            apply { $0.people = people.filter { selected.contains($0.id) } }
        } content: {
            List(visible) { person in
                Button {
                    if selected.contains(person.id) {
                        selected.remove(person.id)
                    } else {
                        selected.insert(person.id)
                    }
                } label: {
                    HStack(spacing: 12) {
                        if let url = session.personThumbnailURL(person) {
                            RemoteImage(url: url, targetPixelSize: 120)
                                .frame(width: 48, height: 48)
                                .clipShape(.circle)
                        }
                        Text(person.name.isEmpty ? "No Name" : person.name)
                            .foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(person.id) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter people")
            .overlay {
                // keyed on the load, not on emptiness - a server with no
                // recognized faces used to spin here forever.
                if isLoadingPeople, people.isEmpty {
                    ProgressView()
                } else if people.isEmpty {
                    ContentUnavailableView("No people", systemImage: "person.2.slash")
                }
            }
            .task {
                selected = Set(filter.people.map(\.id))
                defer { isLoadingPeople = false }
                if let response = try? await session.client?.people() {
                    people = response.people.filter { !($0.isHidden ?? false) }
                }
            }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - location

struct LocationPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var country: String?
    @State private var state: String?
    @State private var city: String?
    @State private var countries: [String] = []
    @State private var states: [String] = []
    @State private var cities: [String] = []

    var body: some View {
        FilterSheetScaffold(title: "Location") {
            apply { $0.country = nil; $0.state = nil; $0.city = nil }
        } onApply: {
            apply { $0.country = country; $0.state = state; $0.city = city }
        } content: {
            Form {
                suggestionPicker("Country", selection: $country, options: countries)
                suggestionPicker("State", selection: $state, options: states)
                suggestionPicker("City", selection: $city, options: cities)
            }
            .onChange(of: country) {
                state = nil
                city = nil
            }
            .onChange(of: state) {
                city = nil
            }
            .task {
                country = filter.country
                state = filter.state
                city = filter.city
                // the country list never depends on the selection; once.
                guard let client = session.client else { return }
                countries = (try? await client.searchSuggestions(type: "country")) ?? []
            }
            // task id cancellation replaces the unstructured tasks the
            // onChange handlers used to spawn, whose slow responses could
            // land out of order and leave country a's cities under country b.
            .task(id: [country, state]) {
                guard let client = session.client else { return }
                async let statesTask = try? client.searchSuggestions(type: "state", country: country)
                async let citiesTask = try? client.searchSuggestions(type: "city", country: country, state: state)
                let states = (await statesTask) ?? []
                let cities = (await citiesTask) ?? []
                guard !Task.isCancelled else { return }
                self.states = states
                self.cities = cities
            }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

/// optional-string picker fed by /search/suggestions values.
@ViewBuilder func suggestionPicker(_ title: String, selection: Binding<String?>, options: [String]) -> some View {
    Picker(title, selection: selection) {
        Text("Any").tag(String?.none)
        ForEach(options, id: \.self) { option in
            Text(option).tag(Optional(option))
        }
    }
    .pickerStyle(.menu)
}

// MARK: - camera

struct CameraPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var make: String?
    @State private var model: String?
    @State private var makes: [String] = []
    @State private var models: [String] = []

    var body: some View {
        FilterSheetScaffold(title: "Camera") {
            apply { $0.make = nil; $0.model = nil }
        } onApply: {
            apply { $0.make = make; $0.model = model }
        } content: {
            Form {
                suggestionPicker("Make", selection: $make, options: makes)
                suggestionPicker("Model", selection: $model, options: models)
            }
            .onChange(of: make) {
                model = nil
            }
            .task {
                make = filter.make
                model = filter.model
                guard let client = session.client else { return }
                makes = (try? await client.searchSuggestions(type: "camera-make")) ?? []
            }
            // same stale-response guard as the location sheet.
            .task(id: make) {
                guard let client = session.client else { return }
                let models = (try? await client.searchSuggestions(type: "camera-model", make: make)) ?? []
                guard !Task.isCancelled else { return }
                self.models = models
            }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - date

struct DatePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var showCustomRange = false
    @State private var customStart = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var year = Calendar.current.component(.year, from: Date())

    private var years: [Int] {
        Array((2000...Calendar.current.component(.year, from: Date())).reversed())
    }

    var body: some View {
        FilterSheetScaffold(title: "Date Range") {
            apply { next in
                next.takenAfter = nil
                next.takenBefore = nil
                next.dateLabel = nil
            }
        } onApply: {
            if showCustomRange {
                applyCustomRange()
            }
        } content: {
            List {
                quickOption("Last month", months: 1)
                quickOption("Last 3 months", months: 3)
                quickOption("Last 9 months", months: 9)

                HStack {
                    Text("In year")
                    Spacer()
                    Picker("In year", selection: $year) {
                        ForEach(years, id: \.self) { value in
                            Text(String(value)).tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    Button("Select") { applyYear() }
                        .buttonStyle(.bordered)
                }

                Button {
                    withAnimation(.snappy) { showCustomRange.toggle() }
                } label: {
                    HStack {
                        Text("Custom range")
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: showCustomRange ? "chevron.up" : "chevron.down")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if showCustomRange {
                    DatePicker("Start", selection: $customStart, in: ...Date(), displayedComponents: .date)
                    DatePicker("End", selection: $customEnd, in: ...Date(), displayedComponents: .date)
                }
            }
            .task {
                if let after = filter.takenAfter { customStart = after }
                if let before = filter.takenBefore {
                    customEnd = before
                    showCustomRange = filter.dateLabel?.hasPrefix("Last") == false && !(filter.dateLabel?.hasPrefix("In ") ?? false)
                }
            }
        }
    }

    @ViewBuilder private func quickOption(_ title: String, months: Int) -> some View {
        Button {
            let calendar = Calendar.current
            let now = Date()
            let anchor = calendar.date(byAdding: .month, value: -months, to: now) ?? now
            let start = calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? anchor
            apply { next in
                next.takenAfter = start
                next.takenBefore = now
                next.dateLabel = title
            }
            dismiss()
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                if filter.dateLabel == title {
                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                }
            }
        }
    }

    private func applyYear() {
        var components = DateComponents()
        components.year = year
        components.month = 1
        components.day = 1
        let calendar = Calendar.current
        let start = calendar.date(from: components) ?? Date()
        let end = min(Date(), calendar.date(from: DateComponents(year: year, month: 12, day: 31, hour: 23, minute: 59, second: 59)) ?? Date())
        apply { next in
            next.takenAfter = start
            next.takenBefore = end
            next.dateLabel = "In \(String(year))"
        }
        dismiss()
    }

    private func applyCustomRange() {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: customStart)
        let end = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: customEnd) ?? customEnd
        let sameDay = calendar.isDate(customStart, inSameDayAs: customEnd)
        let label = sameDay
            ? customStart.formatted(date: .abbreviated, time: .omitted)
            : "\(customStart.formatted(date: .abbreviated, time: .omitted)) – \(customEnd.formatted(date: .abbreviated, time: .omitted))"
        apply { next in
            next.takenAfter = start
            next.takenBefore = end
            next.dateLabel = label
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - media type

struct MediaTypePickerSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var selection: SearchFilter.MediaType = .all

    var body: some View {
        FilterSheetScaffold(title: "Media Type") {
            apply { $0.mediaType = .all }
        } onApply: {
            apply { $0.mediaType = selection }
        } content: {
            List(SearchFilter.MediaType.allCases) { type in
                Button {
                    selection = type
                } label: {
                    HStack {
                        Text(type.title).foregroundStyle(.primary)
                        Spacer()
                        if selection == type {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .accessibilityIdentifier("media-type-\(type.rawValue)")
            }
            .task { selection = filter.mediaType }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - rating

struct RatingPickerSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var selection: SearchFilter.Rating = .any

    private let options: [SearchFilter.Rating] = [.unrated, .stars(1), .stars(2), .stars(3), .stars(4), .stars(5)]

    var body: some View {
        FilterSheetScaffold(title: "Rating") {
            apply { $0.rating = .any }
        } onApply: {
            apply { $0.rating = selection }
        } content: {
            List(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    HStack {
                        switch option {
                        case .any, .unrated:
                            Text("Unrated").foregroundStyle(.primary)
                        case .stars(let count):
                            HStack(spacing: 3) {
                                ForEach(0..<count, id: \.self) { _ in
                                    Image(systemName: "star.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.yellow)
                                }
                            }
                        }
                        Spacer()
                        if selection == option {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .task { selection = filter.rating }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - display options

struct DisplayOptionsSheet: View {
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var notInAlbum = false
    @State private var isArchive = false
    @State private var isFavorite = false

    var body: some View {
        FilterSheetScaffold(title: "Display Options") {
            apply { $0.notInAlbum = false; $0.isArchive = false; $0.isFavorite = false }
        } onApply: {
            apply { $0.notInAlbum = notInAlbum; $0.isArchive = isArchive; $0.isFavorite = isFavorite }
        } content: {
            Form {
                Toggle("Not in any album", isOn: $notInAlbum)
                    .accessibilityIdentifier("display-not-in-album")
                Toggle("Favorite", isOn: $isFavorite)
                    .accessibilityIdentifier("display-favorite")
                Toggle("Archive", isOn: $isArchive)
                    .accessibilityIdentifier("display-archive")
            }
            .task {
                notInAlbum = filter.notInAlbum
                isArchive = filter.isArchive
                isFavorite = filter.isFavorite
            }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

// MARK: - tags

struct TagsPickerSheet: View {
    @Environment(SessionStore.self) private var session
    let filter: SearchFilter
    let onApply: (SearchFilter) -> Void

    @State private var tags: [Tag] = []
    @State private var selected: Set<Tag> = []
    @State private var searchText = ""

    private var visible: [Tag] {
        guard !searchText.isEmpty else { return tags }
        return tags.filter { $0.value.localizedStandardContains(searchText) }
    }

    var body: some View {
        FilterSheetScaffold(title: "Tags") {
            apply { $0.tags = [] }
        } onApply: {
            apply { $0.tags = tags.filter(selected.contains) }
        } content: {
            List(visible) { tag in
                Button {
                    if selected.contains(tag) {
                        selected.remove(tag)
                    } else {
                        selected.insert(tag)
                    }
                } label: {
                    HStack {
                        Label(tag.value, systemImage: "tag")
                            .foregroundStyle(.primary)
                        Spacer()
                        if selected.contains(tag) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Filter tags")
            .task {
                selected = Set(filter.tags)
                tags = (try? await session.client?.tags()) ?? []
            }
        }
    }

    private func apply(_ mutate: (inout SearchFilter) -> Void) {
        var next = filter
        mutate(&next)
        onApply(next)
    }
}

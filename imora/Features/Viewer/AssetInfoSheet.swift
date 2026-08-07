import SwiftUI
import MapKit

/// photos-style info panel: date, caption, people, map, technical details,
/// rating and containing albums. owners can edit caption, date and location.
struct AssetInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    /// fires after an adjust-date save so the viewer can refresh its copy:
    /// utc capture instant + photographer-local offset in hours.
    var onDateAdjusted: ((Date, Double) -> Void)? = nil

    private enum LoadState {
        case loading
        case loaded(AssetDetail)
        case failed(String)
    }

    @State private var loadState = LoadState.loading
    @State private var albums: [Album] = []
    @State private var descriptionDraft = ""
    @State private var savedDescription = ""
    /// which asset the caption draft belongs to.
    @State private var draftAssetID: String?
    @State private var isSavingCaption = false
    @State private var rating = 0
    @State private var showAdjustDate = false
    @State private var showAdjustLocation = false
    @State private var renamingPerson: Person?
    @State private var personNameDraft = ""
    @State private var editError: String?
    @FocusState private var descriptionFocused: Bool

    /// mutations are for the signed-in owner only; unknown user counts as
    /// owner so an offline session stays usable.
    private var isOwner: Bool {
        guard let userID = session.user?.id else { return true }
        return asset.ownerId == userID
    }

    private var detail: AssetDetail? {
        if case .loaded(let detail) = loadState { return detail }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    dateHeader

                    switch loadState {
                    case .loading:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 80)
                    case .failed(let message):
                        ContentUnavailableView {
                            Label("Couldn't Load Info", systemImage: "exclamationmark.circle")
                        } description: {
                            Text(message)
                        } actions: {
                            Button("Try Again") { Task { await load() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 36)
                    case .loaded(let detail):
                        detailContent(detail)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // awaited: dismissing first would strand the failure
                        // alert on a sheet that is already gone.
                        Task {
                            if await commitDescription() { dismiss() }
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .accessibilityIdentifier("asset-details")
        .task(id: asset.id) { await load() }
        .sheet(isPresented: $showAdjustDate) {
            if let detail {
                AdjustDateTimeSheet(asset: asset, detail: detail) { fileCreatedAt, offsetHours in
                    onDateAdjusted?(fileCreatedAt, offsetHours)
                    Task { await load() }
                }
            }
        }
        .sheet(isPresented: $showAdjustLocation) {
            if let detail {
                AdjustLocationSheet(asset: asset, detail: detail) {
                    Task { await load() }
                }
            }
        }
        .alert("Name", isPresented: Binding(
            get: { renamingPerson != nil },
            set: { if !$0 { renamingPerson = nil } }
        )) {
            TextField("Name", text: $personNameDraft)
            Button("Save") {
                guard let person = renamingPerson else { return }
                Task { await renamePerson(person, to: personNameDraft) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(editError ?? "", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - date header

    private var dateHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(asset.localDate, format: .dateTime.weekday(.wide).month(.wide).day().year().utc())
                    .font(.title3.weight(.semibold))
                HStack(spacing: 5) {
                    Text(asset.localDate, format: .dateTime.hour().minute().utc())
                    Text("GMT\(Self.offsetLabel(hours: asset.localOffsetHours))")
                        .foregroundStyle(.tertiary)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isOwner, !asset.isLocal, detail != nil {
                Button {
                    showAdjustDate = true
                } label: {
                    Text("Adjust")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .accessibilityIdentifier("info-adjust-date")
            }
        }
    }

    static func offsetLabel(hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let sign = totalMinutes < 0 ? "-" : "+"
        let absolute = abs(totalMinutes)
        return String(format: "%@%02d:%02d", sign, absolute / 60, absolute % 60)
    }

    // MARK: - sections

    @ViewBuilder private func detailContent(_ detail: AssetDetail) -> some View {
        captionSection

        if let people = detail.people?.filter({ $0.isHidden != true }), !people.isEmpty {
            peopleSection(people)
        }

        if let exif = detail.exifInfo, hasCoordinates(exif) {
            locationSection(exif)
        } else if isOwner, !asset.isLocal {
            addLocationRow
        }

        detailsSection(detail)

        // rating is a server concept; a device-only photo has none to show.
        if session.preferences?.ratingsEnabled == true, !asset.isLocal {
            ratingSection
        }

        if !albums.isEmpty {
            albumsSection
        }
    }

    // MARK: - caption

    @ViewBuilder private var captionSection: some View {
        if isOwner, !asset.isLocal {
            infoSection("Caption") {
                TextField("Add a caption", text: $descriptionDraft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($descriptionFocused)
                    .onChange(of: descriptionFocused) { was, isNow in
                        if was, !isNow { Task { await commitDescription() } }
                    }
                    .accessibilityIdentifier("info-caption")
            }
        } else if !savedDescription.isEmpty {
            infoSection("Caption") {
                Text(savedDescription)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// writes the draft back to the asset it was typed on - the sheet stays up
    /// while the pager moves behind it, so `asset` may already be a different
    /// photo by the time this runs.
    @discardableResult
    private func commitDescription() async -> Bool {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSavingCaption, trimmed != savedDescription,
              let target = draftAssetID, let client = session.client
        else { return true }
        isSavingCaption = true
        defer { isSavingCaption = false }
        do {
            try await client.updateAsset(id: target, description: trimmed)
            if draftAssetID == target { savedDescription = trimmed }
            return true
        } catch {
            if draftAssetID == target { descriptionDraft = savedDescription }
            editError = "Could not save the caption: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - people

    private func peopleSection(_ people: [Person]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("People")
                .font(.headline)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(people) { person in
                        personCell(person)
                    }
                }
            }
        }
    }

    @ViewBuilder private func personCell(_ person: Person) -> some View {
        NavigationLink {
            PersonScreen(person: person)
        } label: {
            VStack(spacing: 6) {
                if let client = session.client {
                    RemoteImage(
                        url: client.personThumbnailURL(personID: person.id),
                        targetPixelSize: 160
                    )
                    .frame(width: 72, height: 72)
                    .clipShape(.circle)
                }
                if person.name.isEmpty {
                    Text("Add a Name")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                } else {
                    Text(person.name)
                        .font(.caption)
                        .lineLimit(1)
                    if let age = ageLabel(of: person) {
                        Text(age)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 80)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            person.name.isEmpty
                ? TapGesture().onEnded {
                    personNameDraft = ""
                    renamingPerson = person
                }
                : nil
        )
        .contextMenu {
            Button {
                personNameDraft = person.name
                renamingPerson = person
            } label: {
                Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
            }
        }
    }

    /// age at the time the photo was taken, like the reference client.
    private func ageLabel(of person: Person) -> String? {
        guard let raw = person.birthDate, let birth = APIDate.parse(raw) ?? Self.dateOnly(raw) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let months = calendar.dateComponents([.month], from: birth, to: asset.localDate).month ?? 0
        guard months >= 0 else { return nil }
        if months <= 11 { return "\(months) months old" }
        if months < 24 { return "1 year, \(months - 12) months old" }
        return "Age \(months / 12)"
    }

    private static func dateOnly(_ raw: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: String(raw.prefix(10)))
    }

    private func renamePerson(_ person: Person, to name: String) async {
        guard let client = session.client else { return }
        do {
            try await client.updatePerson(id: person.id, name: name)
            await load()
        } catch {
            editError = "Could not rename: \(error.localizedDescription)"
        }
    }

    // MARK: - location

    private func hasCoordinates(_ exif: ExifInfo) -> Bool {
        guard let latitude = exif.latitude, let longitude = exif.longitude else { return false }
        return latitude != 0 || longitude != 0
    }

    private func locationSection(_ exif: ExifInfo) -> some View {
        let latitude = exif.latitude ?? 0
        let longitude = exif.longitude ?? 0
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let place = [exif.city, exif.state]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")

        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Location")
                    .font(.headline)
                Spacer()
                if isOwner, !asset.isLocal {
                    Button {
                        showAdjustLocation = true
                    } label: {
                        Text("Adjust")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .accessibilityIdentifier("info-adjust-location")
                }
            }

            Button {
                openInMaps(coordinate: coordinate, name: place)
            } label: {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))) {
                    Marker(place, coordinate: coordinate)
                }
                .frame(height: 180)
                .clipShape(.rect(cornerRadius: 16))
                .allowsHitTesting(false)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                if !place.isEmpty {
                    Text(place)
                        .font(.subheadline.weight(.medium))
                }
                Text("\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var addLocationRow: some View {
        Button {
            showAdjustLocation = true
        } label: {
            Label("Add a Location", systemImage: "location")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        }
        .accessibilityIdentifier("info-add-location")
    }

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = name.isEmpty ? "Photo Location" : name
        item.openInMaps()
    }

    // MARK: - details

    @ViewBuilder private func detailsSection(_ detail: AssetDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Details")
                .font(.headline)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: fileIcon(for: detail.type))
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(.quaternary, in: .circle)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(detail.originalFileName)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if detail.isEdited == true {
                                Text("Edited")
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.tertiary.opacity(0.6), in: .capsule)
                            }
                        }

                        if let summary = fileSummary(detail) {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = detail.originalFileName
                    } label: {
                        Label("Copy File Name", systemImage: "doc.on.doc")
                    }
                }

                if let exif = detail.exifInfo, let camera = cameraName(exif) {
                    Divider()
                        .padding(.vertical, 12)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Image(systemName: "camera")
                                .font(.system(size: 15, weight: .semibold))
                                .frame(width: 34, height: 34)
                                .background(.quaternary, in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(camera)
                                    .font(.subheadline.weight(.semibold))
                                if let lens = exif.lensModel, !lens.isEmpty {
                                    Text(lens)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        let specifications = cameraSpecifications(exif)
                        if !specifications.isEmpty {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 8) {
                                    specificationChips(specifications)
                                }
                                VStack(alignment: .leading, spacing: 8) {
                                    specificationChips(specifications)
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - rating

    private var ratingSection: some View {
        infoSection("Rating") {
            HStack(spacing: 10) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        Task { await setRating(star == rating ? 0 : star) }
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 26))
                            .foregroundStyle(star <= rating ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOwner)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setRating(_ value: Int) async {
        guard let client = session.client else { return }
        let previous = rating
        rating = value
        do {
            try await client.updateAsset(id: asset.id, rating: value)
        } catch {
            rating = previous
            editError = "Could not save the rating: \(error.localizedDescription)"
        }
    }

    // MARK: - albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Appears In")
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailScreen(album: album)
                    } label: {
                        HStack(spacing: 12) {
                            if let client = session.client, let cover = album.albumThumbnailAssetId {
                                RemoteImage(
                                    url: client.thumbnailURL(assetID: cover),
                                    targetPixelSize: 120
                                )
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 8))
                            } else {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                                    .frame(width: 44, height: 44)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(album.albumName)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Text("^[\(album.assetCount) item](inflect: true)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Image(systemName: "chevron.forward")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)

                    if album.id != albums.last?.id {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        }
    }

    // MARK: - shared pieces

    private func infoSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content()
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        }
    }

    @ViewBuilder private func specificationChips(_ specifications: [String]) -> some View {
        ForEach(Array(specifications.enumerated()), id: \.offset) { _, specification in
            Text(specification)
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(.tertiary.opacity(0.65), in: .capsule)
        }
    }

    private func fileIcon(for type: AssetType) -> String {
        switch type {
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .other: "doc"
        }
    }

    private func fileSummary(_ detail: AssetDetail) -> String? {
        var parts: [String] = []

        if let mime = detail.originalMimeType?.split(separator: "/").last {
            parts.append(mime.uppercased())
        }
        if let dimensions = dimensions(detail) {
            parts.append(dimensions)
        }
        if let bytes = detail.exifInfo?.fileSizeInByte {
            parts.append(ByteCountFormatStyle().format(bytes))
        }
        if let duration = asset.durationLabel {
            parts.append(duration)
        }

        return parts.isEmpty ? nil : parts.joined(separator: "  •  ")
    }

    private func dimensions(_ detail: AssetDetail) -> String? {
        let width = detail.width ?? detail.exifInfo?.exifImageWidth.map { Int($0) }
        let height = detail.height ?? detail.exifInfo?.exifImageHeight.map { Int($0) }
        guard let width, let height else { return nil }
        return "\(width) × \(height)"
    }

    private func cameraName(_ exif: ExifInfo) -> String? {
        let parts = [exif.make, exif.model]
            .compactMap { (value: String?) -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func cameraSpecifications(_ exif: ExifInfo) -> [String] {
        var specifications: [String] = []
        if let focalLength = exif.focalLength {
            specifications.append("\(focalLength.formatted(.number.precision(.fractionLength(0...1)))) mm")
        }
        if let fNumber = exif.fNumber {
            specifications.append("ƒ/\(fNumber.formatted(.number.precision(.fractionLength(0...1))))")
        }
        if let exposureTime = exif.exposureTime, !exposureTime.isEmpty {
            specifications.append(exposureTime)
        }
        if let iso = exif.iso {
            specifications.append("ISO \(Int(iso))")
        }
        return specifications
    }

    // MARK: - loading

    private func load() async {
        // paging behind the open sheet swaps the asset: flush the caption the
        // user typed for the previous one before adopting the new one, or it
        // would be written onto the photo that just slid into view.
        if let draftAssetID, draftAssetID != asset.id {
            await commitDescription()
            descriptionFocused = false
        }
        let isNewAsset = draftAssetID != asset.id
        if isNewAsset {
            draftAssetID = asset.id
            descriptionDraft = ""
            savedDescription = ""
            rating = 0
            albums = []
        }

        // device-only assets answer from photokit: same layout, no server
        // notions like people, caption or rating.
        if asset.isLocal {
            if detail == nil { loadState = .loading }
            var local: AssetDetail?
            if let localIdentifier = asset.localIdentifier {
                local = await PhotoLibraryService.localDetail(localIdentifier: localIdentifier)
            }
            guard draftAssetID == asset.id else { return }
            if let local {
                loadState = .loaded(local)
            } else {
                loadState = .failed("This photo could not be read from the library.")
            }
            return
        }

        guard let client = session.client else {
            loadState = .failed("Not signed in.")
            return
        }
        if detail == nil { loadState = .loading }
        let account = client.apiURL.host().map { SessionCache.accountKey(host: $0) }

        do {
            let detail = try await client.assetDetail(id: asset.id)
            guard draftAssetID == asset.id else { return }
            loadState = .loaded(detail)
            savedDescription = detail.exifInfo?.description ?? ""
            if !descriptionFocused { descriptionDraft = savedDescription }
            rating = detail.exifInfo?.rating.map { Int($0) } ?? 0

            let loaded = (try? await client.albums(assetID: asset.id)) ?? []
            guard draftAssetID == asset.id else { return }
            albums = loaded
            if let account {
                let envelope = CachedAssetInfo(detail: detail, albums: loaded)
                Task.detached(priority: .utility) {
                    OfflineCache.store(envelope, key: "asset-info/\(detail.id)", account: account)
                }
            }
        } catch {
            // offline: the last fetched copy still answers most questions.
            guard draftAssetID == asset.id else { return }
            if let account,
               let cached: CachedAssetInfo = OfflineCache.value(key: "asset-info/\(asset.id)", account: account) {
                loadState = .loaded(cached.detail)
                savedDescription = cached.detail.exifInfo?.description ?? ""
                if !descriptionFocused { descriptionDraft = savedDescription }
                rating = cached.detail.exifInfo?.rating.map { Int($0) } ?? 0
                albums = cached.albums
            } else {
                loadState = .failed(error.localizedDescription)
            }
        }
    }
}

/// offline copy of the info sheet payload, one file per asset.
private nonisolated struct CachedAssetInfo: Codable {
    let detail: AssetDetail
    let albums: [Album]
}

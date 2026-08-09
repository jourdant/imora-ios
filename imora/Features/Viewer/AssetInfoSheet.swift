import SwiftUI
import MapKit

/// Photos-style metadata content for the viewer's native information sheet.
/// The presenting screen owns the vertical scroll view and sheet behavior.
struct AssetInfoPanel: View {
    @Environment(SessionStore.self) private var session

    let asset: Asset
    /// Fires after an adjust-date save so the viewer can refresh its copy:
    /// UTC capture instant + photographer-local offset in hours.
    var onDateAdjusted: ((Date, Double) -> Void)? = nil
    /// The viewer owns presentation of the album picker because it knows the
    /// remote ID for local assets that have just been backed up.
    var onAddToAlbum: (() -> Void)? = nil

    private enum LoadState {
        case loading
        case loaded(AssetDetail)
        case failed(String)
    }

    @State private var loadState = LoadState.loading
    @State private var albums: [Album] = []
    @State private var descriptionDraft = ""
    @State private var savedDescription = ""
    /// Which asset the caption draft belongs to.
    @State private var draftAssetID: String?
    @State private var isSavingCaption = false
    @State private var rating = 0
    @State private var showAdjustDate = false
    @State private var showAdjustLocation = false
    @State private var renamingPerson: Person?
    @State private var personNameDraft = ""
    @State private var editError: String?
    @FocusState private var descriptionFocused: Bool

    /// Mutations are for the signed-in owner only; unknown user counts as
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
        VStack(alignment: .leading, spacing: 0) {
            panelHeader
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                switch loadState {
                case .loading:
                    loadingState
                case .failed(let message):
                    failureState(message)
                case .loaded(let detail):
                    detailContent(detail)
                }
            }
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("asset-details")
        .task(id: asset.id) { await load() }
        .onDisappear {
            Task { await commitDescription() }
        }
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

    // MARK: - Panel header

    private var panelHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Information")
                .font(.title2.bold())
            Spacer()
            if isSavingCaption {
                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Saving caption")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text("Loading photo information…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureState(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Couldn't Load Info", systemImage: "exclamationmark.circle")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") { Task { await load() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.tint)
                .buttonStyle(.plain)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Capture date

    private var captureDateRow: some View {
        HStack(alignment: .center, spacing: 12) {
            metadataIcon("calendar")

            VStack(alignment: .leading, spacing: 3) {
                Text(asset.localDate, format: .dateTime.weekday(.wide).month(.wide).day().year().utc())
                    .font(.subheadline.weight(.semibold))
                HStack(spacing: 5) {
                    Text(asset.localDate, format: .dateTime.hour().minute().utc())
                    Text("GMT\(GMTOffsetFormatter.label(hours: asset.localOffsetHours))")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isOwner, !asset.isLocal, detail != nil {
                Button("Adjust") { showAdjustDate = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("info-adjust-date")
            }
        }
        .padding(14)
    }

    // MARK: - Sections

    @ViewBuilder private func detailContent(_ detail: AssetDetail) -> some View {
        captionSection
        sectionDivider
        peopleSection(detail.people?.filter { $0.isHidden != true } ?? [])
        sectionDivider
        detailsSection(detail)
        sectionDivider
        locationSection(detail.exifInfo)

        if session.preferences?.tagsEnabled != false {
            sectionDivider
            tagsSection(detail.tags ?? [])
        }

        if session.preferences?.ratingsEnabled == true {
            sectionDivider
            ratingSection
        }

        sectionDivider
        albumsSection
    }

    // MARK: - Caption

    @ViewBuilder private var captionSection: some View {
        if isOwner, !asset.isLocal {
            infoSection("Caption") {
                TextField("Add a caption", text: $descriptionDraft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.vertical, 4)
                    .focused($descriptionFocused)
                    .onChange(of: descriptionFocused) { was, isNow in
                        if was, !isNow { Task { await commitDescription() } }
                    }
                    .accessibilityIdentifier("info-caption")
            }
        } else {
            infoSection("Caption") {
                if savedDescription.isEmpty {
                    emptyState(
                        systemImage: "text.bubble",
                        title: "No Caption",
                        message: asset.isLocal
                            ? "Back up this item before adding a caption."
                            : "No caption has been added."
                    )
                } else {
                    Text(savedDescription)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Writes the draft back to the asset it was typed on. The panel can stay
    /// mounted while the pager moves, so `asset` may already be another photo.
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

    // MARK: - People

    private func peopleSection(_ people: [Person]) -> some View {
        infoSection("People") {
            if people.isEmpty {
                emptyState(
                    systemImage: "person.crop.circle.badge.questionmark",
                    title: "No People",
                    message: peopleEmptyMessage
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(people) { person in
                            personCell(person)
                        }
                    }
                }
            }
        }
    }

    private var peopleEmptyMessage: String {
        if session.preferences?.peopleEnabled == false {
            return "People recognition is turned off."
        }
        if asset.isLocal {
            return "Back up this item to make people available here."
        }
        return "No people have been identified in this item."
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
                } else {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 72, height: 72)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
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
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            person.name.isEmpty && isOwner
                ? TapGesture().onEnded {
                    personNameDraft = ""
                    renamingPerson = person
                }
                : nil
        )
        .contextMenu {
            if isOwner {
                Button {
                    personNameDraft = person.name
                    renamingPerson = person
                } label: {
                    Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
                }
            }
        }
    }

    /// Age at the time the photo was taken, like the reference client.
    private func ageLabel(of person: Person) -> String? {
        guard let raw = person.birthDate,
              let birth = APIDate.parse(raw) ?? Self.dateOnly(raw)
        else { return nil }
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

    // MARK: - Location

    @ViewBuilder private func locationSection(_ exif: ExifInfo?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Location")
                Spacer()
                if isOwner, !asset.isLocal, detail != nil {
                    Button(hasCoordinates(exif) ? "Adjust" : "Add") {
                        showAdjustLocation = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(
                        hasCoordinates(exif) ? "info-adjust-location" : "info-add-location"
                    )
                }
            }

            if let exif, hasCoordinates(exif) {
                locatedContent(exif)
            } else {
                emptyState(
                    systemImage: "map",
                    title: "No Location",
                    message: asset.isLocal
                        ? "No location is stored with this item."
                        : "Add a location to make this item easier to find."
                )
            }
        }
        .padding(.vertical, 20)
    }

    private func hasCoordinates(_ exif: ExifInfo?) -> Bool {
        guard let latitude = exif?.latitude, let longitude = exif?.longitude else { return false }
        return latitude != 0 || longitude != 0
    }

    private func locatedContent(_ exif: ExifInfo) -> some View {
        let latitude = exif.latitude ?? 0
        let longitude = exif.longitude ?? 0
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        let place = [exif.city, exif.state, exif.country]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: ", ")
        let markerName = place.isEmpty ? "Photo Location" : place

        return Button {
            openInMaps(coordinate: coordinate, name: markerName)
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))) {
                    Marker(markerName, coordinate: coordinate)
                }
                .frame(height: 190)
                .clipShape(.rect(cornerRadius: 18))
                .allowsHitTesting(false)

                HStack(spacing: 10) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.body.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        if !place.isEmpty {
                            Text(place)
                                .font(.subheadline.weight(.medium))
                        }
                        Text("\(latitude.formatted(.number.precision(.fractionLength(4)))), \(longitude.formatted(.number.precision(.fractionLength(4))))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens this location in Maps")
    }

    private func openInMaps(coordinate: CLLocationCoordinate2D, name: String) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let item = MKMapItem(location: location, address: nil)
        item.name = name
        item.openInMaps()
    }

    // MARK: - Technical details

    private func detailsSection(_ detail: AssetDetail) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Details")

            VStack(spacing: 0) {
                captureDateRow
                metadataDivider
                fileRow(detail)
                metadataDivider
                cameraRow(detail.exifInfo)
                metadataDivider
                captureMetrics(detail.exifInfo)
            }
            .background(surfaceFill, in: .rect(cornerRadius: 18))
        }
        .padding(.vertical, 20)
    }

    private func fileRow(_ detail: AssetDetail) -> some View {
        HStack(alignment: .top, spacing: 12) {
            metadataIcon(fileIcon(for: detail.type))

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
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                UIPasteboard.general.string = detail.originalFileName
            } label: {
                Label("Copy File Name", systemImage: "doc.on.doc")
            }
        }
    }

    private func cameraRow(_ exif: ExifInfo?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            metadataIcon("camera")

            VStack(alignment: .leading, spacing: 3) {
                Text(exif.flatMap(cameraName) ?? "Camera not available")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(nonEmpty(exif?.lensModel) ?? "Lens not available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    private func captureMetrics(_ exif: ExifInfo?) -> some View {
        HStack(alignment: .top, spacing: 0) {
            captureMetric("Focal", value: focalLength(exif))
            metricDivider
            captureMetric("Aperture", value: aperture(exif))
            metricDivider
            captureMetric("Shutter", value: exposure(exif))
            metricDivider
            captureMetric("ISO", value: iso(exif))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 12)
    }

    private func captureMetric(_ title: String, value: String?) -> some View {
        VStack(spacing: 3) {
            Text(value ?? "—")
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var metricDivider: some View {
        Divider()
            .frame(height: 38)
    }

    private var metadataDivider: some View {
        Divider()
            .padding(.leading, 52)
    }

    private func metadataIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
    }

    // MARK: - Tags

    private func tagsSection(_ tags: [Tag]) -> some View {
        infoSection("Tags") {
            if tags.isEmpty {
                emptyState(
                    systemImage: "tag.slash",
                    title: "No Tags",
                    message: asset.isLocal
                        ? "Back up this item before adding tags."
                        : "No tags have been added to this item."
                )
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(tags) { tag in
                            Label(tag.value, systemImage: "tag.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(surfaceFill, in: .capsule)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Rating

    private var ratingSection: some View {
        infoSection("Rating") {
            if asset.isLocal {
                emptyState(
                    systemImage: "star.slash",
                    title: "Not Rated",
                    message: "Back up this item before adding a rating."
                )
            } else {
                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { star in
                        Button {
                            Task { await setRating(star == rating ? 0 : star) }
                        } label: {
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .font(.system(size: 26))
                                .foregroundStyle(
                                    star <= rating ? Color.accentColor : Color.secondary.opacity(0.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isOwner)
                        .accessibilityLabel("\(star) stars")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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

    // MARK: - Albums

    private var albumsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Appears In")

            if albums.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    emptyState(
                        systemImage: "rectangle.stack.badge.plus",
                        title: "No Albums",
                        message: albumsEmptyMessage
                    )

                    if let onAddToAlbum {
                        Button(action: onAddToAlbum) {
                            Label("Add to Album", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("info-add-to-album")
                    }
                }
            } else {
                albumRows
            }
        }
        .padding(.vertical, 20)
        .padding(.bottom, 20)
    }

    private var albumsEmptyMessage: String {
        if asset.isLocal, onAddToAlbum == nil {
            return "Back up this item before adding it to an album."
        }
        return "This item isn't in an album yet."
    }

    private var albumRows: some View {
        VStack(spacing: 0) {
            ForEach(albums) { album in
                NavigationLink {
                    AlbumDetailScreen(album: album)
                } label: {
                    HStack(spacing: 12) {
                        albumThumbnail(album)

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
                        .padding(.leading, 56)
                }
            }
        }
    }

    @ViewBuilder private func albumThumbnail(_ album: Album) -> some View {
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
                .overlay {
                    Image(systemName: "rectangle.stack")
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Shared pieces

    private var surfaceFill: Color {
        Color(uiColor: .secondarySystemBackground)
    }

    private func infoSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionLabel(title)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 20)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.headline)
    }

    private var sectionDivider: some View {
        Divider()
    }

    private func emptyState(systemImage: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if let megapixels = megapixels(detail) {
            parts.append(megapixels)
        }
        if let dimensions = dimensions(detail) {
            parts.append(dimensions)
        }
        if let size = fileSize(detail.exifInfo) {
            parts.append(size)
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

    private func megapixels(_ detail: AssetDetail) -> String? {
        let width = detail.width ?? detail.exifInfo?.exifImageWidth.map { Int($0) }
        let height = detail.height ?? detail.exifInfo?.exifImageHeight.map { Int($0) }
        guard let width, let height, width > 0, height > 0 else { return nil }
        let value = Double(width) * Double(height) / 1_000_000
        return "\(value.formatted(.number.precision(.fractionLength(0...1)))) MP"
    }

    private func cameraName(_ exif: ExifInfo) -> String? {
        let make = nonEmpty(exif.make)
        let model = nonEmpty(exif.model)
        guard let make else { return model }
        guard let model else { return make }
        if model.localizedCaseInsensitiveContains(make) { return model }
        return "\(make) \(model)"
    }

    private func focalLength(_ exif: ExifInfo?) -> String? {
        guard let focalLength = exif?.focalLength else { return nil }
        let value = focalLength.formatted(.number.precision(.fractionLength(0...1)))
        return "\(value) mm"
    }

    private func aperture(_ exif: ExifInfo?) -> String? {
        guard let fNumber = exif?.fNumber else { return nil }
        let value = fNumber.formatted(.number.precision(.fractionLength(0...1)))
        return "ƒ/\(value)"
    }

    private func exposure(_ exif: ExifInfo?) -> String? {
        guard let value = nonEmpty(exif?.exposureTime) else { return nil }
        if value.localizedCaseInsensitiveContains("s") { return value }
        return "\(value) s"
    }

    private func iso(_ exif: ExifInfo?) -> String? {
        guard let value = exif?.iso else { return nil }
        return "ISO \(Int(value))"
    }

    private func fileSize(_ exif: ExifInfo?) -> String? {
        guard let bytes = exif?.fileSizeInByte else { return nil }
        return ByteCountFormatStyle().format(bytes)
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Loading

    private func load() async {
        // Paging swaps the asset while this panel stays mounted. Flush the old
        // draft before adopting the next photo so it cannot be saved to it.
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
            loadState = .loading
        }

        // Device-only assets answer from PhotoKit. Server concepts remain as
        // explicit empty sections instead of disappearing from the layout.
        if asset.isLocal {
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
            // Offline: the last fetched copy still answers most questions.
            guard draftAssetID == asset.id else { return }
            if let account,
               let cached: CachedAssetInfo = OfflineCache.value(
                   key: "asset-info/\(asset.id)",
                   account: account
               ) {
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

/// Temporary source-compatibility wrapper for call sites that still use the
/// old name. New viewer layouts should embed `AssetInfoPanel` directly.
struct AssetInfoSheet: View {
    let asset: Asset
    var onDateAdjusted: ((Date, Double) -> Void)? = nil

    var body: some View {
        AssetInfoPanel(asset: asset, onDateAdjusted: onDateAdjusted)
    }

    static func offsetLabel(hours: Double) -> String {
        GMTOffsetFormatter.label(hours: hours)
    }
}

private enum GMTOffsetFormatter {
    static func label(hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        let sign = totalMinutes < 0 ? "-" : "+"
        let absolute = abs(totalMinutes)
        return String(format: "%@%02d:%02d", sign, absolute / 60, absolute % 60)
    }
}

/// Offline copy of the info panel payload, one file per asset.
private nonisolated struct CachedAssetInfo: Codable {
    let detail: AssetDetail
    let albums: [Album]
}

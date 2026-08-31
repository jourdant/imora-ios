import SwiftUI
import MapKit

private nonisolated struct AssetCoordinateValue: Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

private struct AlbumMembershipRollback {
    let album: Album?
    let index: Int?
}

private extension Person {
    func renamed(_ name: String) -> Person {
        var copy = self
        copy.name = name
        return copy
    }
}

/// Photos-style metadata content for the viewer's native information sheet.
/// The presenting screen owns the vertical scroll view and sheet behavior.
struct AssetInfoPanel: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let asset: Asset
    /// The regular-width sheet retains an explicit title. Compact inline
    /// presentations can omit it because the surrounding viewer flow already
    /// establishes the information context and vertical space is at a premium.
    var showsHeader = true
    /// compact viewers keep this panel mounted below the fold on every page.
    /// false holds the network and disk work back until the user actually
    /// pulls the information up - otherwise every swipe costs two requests,
    /// a cache write and a map for a panel never seen.
    var isRevealed = true
    /// Fires after an adjust-date save so the viewer can refresh its copy:
    /// UTC capture instant + photographer-local offset in hours.
    var onDateAdjusted: ((String, Date, Double) -> Void)? = nil
    /// The viewer owns presentation of the album picker because it knows the
    /// remote ID for local assets that have just been backed up.
    var onAddToAlbum: (() -> Void)? = nil
    /// Navigation belongs to the full-screen viewer, not to this sheet. These
    /// callbacks let the presenter dismiss information before pushing.
    var onOpenPerson: ((Person) -> Void)? = nil
    var onOpenAlbum: ((Album) -> Void)? = nil
    var albumMembershipUpdate: AlbumMembershipUpdate? = nil

    private enum LoadState {
        case loading
        case loaded(AssetDetail)
        case failed(String)
    }

    private struct CaptureMetricValue: Identifiable {
        let title: String
        let value: String
        var id: String { title }
    }

    @State private var loadState = LoadState.loading
    /// details already fetched this session, so revisits paint instantly.
    @State private var detailsByAsset: [String: AssetDetail] = [:]
    @State private var albumsByAsset: [String: [Album]] = [:]
    @State private var albumRevisions: [String: UInt64] = [:]
    @State private var albumMembershipRollbacks: [UUID: AlbumMembershipRollback] = [:]
    @State private var descriptionDraft = ""
    @State private var captionsByAsset: [String: String] = [:]
    /// Which asset the caption draft belongs to.
    @State private var draftAssetID: String?
    @State private var ratingsByAsset: [String: Int] = [:]
    @State private var showAdjustDate = false
    @State private var showAdjustLocation = false
    @State private var locationsByAsset: [String: AssetCoordinateValue?] = [:]
    @State private var canonicalLocationsByAsset: [String: AssetCoordinateValue?] = [:]
    @State private var dateMutations = AssetOptimisticField<AssetDateAdjustment>()
    @State private var captionMutations = AssetOptimisticField<String>()
    @State private var ratingMutations = AssetOptimisticField<Int>()
    @State private var locationMutations = AssetOptimisticField<AssetCoordinateValue?>()
    @State private var loadGeneration: UInt64 = 0
    @State private var renamingPerson: Person?
    @State private var personNameDraft = ""
    @State private var personNameOverrides: [String: String] = [:]
    @State private var renamingPersonIDs: Set<String> = []
    @State private var peopleByAsset: [String: [Person]] = [:]
    @State private var peopleMutations = AssetOptimisticField<[Person]>()
    @State private var showAddPeople = false
    @State private var removingPerson: Person?
    @FocusState private var descriptionFocused: Bool

    private var savedDescription: String { captionsByAsset[asset.id] ?? "" }
    private var rating: Int { ratingsByAsset[asset.id] ?? 0 }
    private var albums: [Album] { albumsByAsset[asset.id] ?? [] }

    private var canEditCaption: Bool { isOwner && !asset.isLocal }
    private var showsCaptionSection: Bool { canEditCaption || !savedDescription.isEmpty }
    private var showsPeopleSection: Bool { !displayedPeople.isEmpty || canTagPeople }
    private var showsAlbumsSection: Bool { !albums.isEmpty || onAddToAlbum != nil }
    private var showsRatingSection: Bool {
        session.preferences?.ratingsEnabled == true
            && !asset.isLocal
            && (isOwner || rating > 0)
    }

    /// People shown for the current asset: the optimistic projection when one
    /// exists, otherwise the loaded detail's visible people.
    private var displayedPeople: [Person] {
        peopleByAsset[asset.id] ?? detail?.people?.filter { $0.isHidden != true } ?? []
    }

    /// Manual tagging talks to the server, so it needs an owned server asset
    /// and the people section enabled.
    private var canTagPeople: Bool {
        isOwner && !asset.isLocal && session.client != nil
            && session.preferences?.peopleEnabled != false
    }

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
            if showsHeader {
                panelHeader
                Divider()
            }

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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("asset-details")
        .task(id: "\(asset.id)|\(isRevealed)") {
            guard isRevealed else { return }
            await load()
        }
        .onDisappear {
            Task { await commitDescription() }
        }
        .onChange(of: albumMembershipUpdate) { _, update in
            guard let update else { return }
            applyAlbumMembership(update)
        }
        .sheet(isPresented: $showAdjustDate) {
            if let detail {
                AdjustDateTimeSheet(asset: asset, detail: detail) { adjustment in
                    submitDate(adjustment, for: asset.id)
                }
            }
        }
        .sheet(isPresented: $showAdjustLocation) {
            if detail != nil {
                AdjustLocationSheet(
                    initialCoordinate: displayedLocation(for: asset.id)?.coordinate,
                    onSave: { coordinate in
                        submitLocation(AssetCoordinateValue(coordinate), for: asset.id)
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showAddPeople) {
            FaceTagSheet(asset: asset, taggedPeople: displayedPeople) { person, region in
                submitTagPerson(person, region: region, for: asset.id)
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
    }

    // MARK: - Panel header

    private var panelHeader: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Information")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Spacer()
            captionSavingStatus
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    @ViewBuilder private var captionSavingStatus: some View {
        if captionMutations.isPending(for: asset.id) {
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
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(.rect)
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
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier("info-adjust-date")
            }
        }
        .padding(14)
    }

    // MARK: - Sections

    @ViewBuilder private func detailContent(_ detail: AssetDetail) -> some View {
        if showsCaptionSection {
            captionSection
            sectionDivider
        }

        detailsSection(detail)

        if showsLocationSection(detail.exifInfo) {
            sectionDivider
            locationSection(detail.exifInfo)
        }

        if showsPeopleSection {
            sectionDivider
            peopleSection(displayedPeople)
        }

        if showsAlbumsSection {
            sectionDivider
            albumsSection
        }

        if session.preferences?.tagsEnabled != false, let tags = detail.tags, !tags.isEmpty {
            sectionDivider
            tagsSection(tags)
        }

        if showsRatingSection {
            sectionDivider
            ratingSection
        }
    }

    // MARK: - Caption

    private var captionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Caption")
                Spacer()
                if !showsHeader { captionSavingStatus }
            }

            if canEditCaption {
                TextField("Add a caption", text: $descriptionDraft, axis: .vertical)
                    .font(.body)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(minHeight: 44, alignment: .topLeading)
                    .background(surfaceFill, in: .rect(cornerRadius: 12))
                    .contentShape(.rect(cornerRadius: 12))
                    .focused($descriptionFocused)
                    .onChange(of: descriptionFocused) { was, isNow in
                        if was, !isNow { Task { await commitDescription() } }
                    }
                    .accessibilityIdentifier("info-caption")
            } else {
                Text(savedDescription)
                    .font(.body)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .background(surfaceFill, in: .rect(cornerRadius: 12))
            }
        }
        .padding(.vertical, 20)
    }

    /// Writes the draft back to the asset it was typed on. The panel can stay
    /// mounted while the pager moves, so `asset` may already be another photo.
    @discardableResult
    private func commitDescription() async -> Bool {
        let trimmed = descriptionDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let target = draftAssetID,
              trimmed != (captionsByAsset[target] ?? ""),
              let client = session.client
        else { return true }
        if draftAssetID == target { descriptionDraft = trimmed }
        captionMutations.submit(
            assetID: target,
            current: captionsByAsset[target] ?? "",
            desired: trimmed,
            errorMessage: "Couldn’t save the caption",
            apply: applyCaptionProjection,
            request: { value in
                _ = try await client.updateAsset(id: target, description: value)
                return value
            }
        )
        return true
    }

    private func applyCaptionProjection(assetID: String, value: String) {
        let previousProjection = captionsByAsset[assetID] ?? ""
        captionsByAsset[assetID] = value
        guard draftAssetID == assetID, descriptionDraft == previousProjection else { return }
        descriptionDraft = value
    }

    private func submitDate(_ adjustment: AssetDateAdjustment, for assetID: String) {
        guard let client = session.client else { return }
        let current = AssetDateAdjustment(
            instant: asset.fileCreatedAt,
            offsetHours: asset.localOffsetHours,
            apiTimestamp: ""
        )
        dateMutations.submit(
            assetID: assetID,
            current: current,
            desired: adjustment,
            errorMessage: "Couldn’t adjust the date",
            apply: { id, value in
                onDateAdjusted?(id, value.instant, value.offsetHours)
            },
            request: { value in
                _ = try await client.updateAsset(id: assetID, dateTimeOriginal: value.apiTimestamp)
                return value
            }
        )
    }

    private func submitLocation(_ desired: AssetCoordinateValue, for assetID: String) {
        guard let client = session.client else { return }
        let current = displayedLocation(for: assetID)
        locationMutations.submit(
            assetID: assetID,
            current: current,
            desired: desired,
            errorMessage: "Couldn’t save the location",
            apply: { id, value in
                locationsByAsset[id] = value
            },
            request: { value in
                guard let value else { return nil }
                _ = try await client.updateAsset(
                    id: assetID,
                    latitude: value.latitude,
                    longitude: value.longitude
                )
                return value
            },
            latestCommit: { id, _ in
                guard draftAssetID == id else { return }
                Task {
                    await Task.yield()
                    await load()
                }
            },
            reportFailure: { message, error in
                ErrorToastCenter.shared.show(message, error: error)
                guard draftAssetID == assetID else { return }
                Task {
                    await Task.yield()
                    await load()
                }
            }
        )
    }

    private func displayedLocation(for assetID: String) -> AssetCoordinateValue? {
        if let stored = locationsByAsset[assetID] { return stored }
        return canonicalLocationsByAsset[assetID] ?? nil
    }

    private func applyAlbumMembership(_ update: AlbumMembershipUpdate) {
        var values = albumsByAsset[update.assetID] ?? []
        switch update.change {
        case .project(let album):
            if albumMembershipRollbacks[update.operationID] == nil {
                albumMembershipRollbacks[update.operationID] = AlbumMembershipRollback(
                    album: values.first(where: { $0.id == album.id }),
                    index: values.firstIndex(where: { $0.id == album.id })
                )
            }
            if let index = values.firstIndex(where: { $0.id == album.id }) {
                values[index] = album
            } else {
                values.append(album)
            }
        case .commit(let album):
            albumMembershipRollbacks.removeValue(forKey: update.operationID)
            if let index = values.firstIndex(where: { $0.id == album.id }) {
                values[index] = album
            } else {
                values.append(album)
            }
        case .rollback(let id):
            let snapshot = albumMembershipRollbacks.removeValue(forKey: update.operationID)
            values.removeAll { $0.id == id }
            if let album = snapshot?.album {
                values.insert(album, at: min(snapshot?.index ?? values.count, values.count))
            }
        case .replace(let id, let album):
            albumMembershipRollbacks.removeValue(forKey: update.operationID)
            if let index = values.firstIndex(where: { $0.id == id }) {
                values[index] = album
            } else if !values.contains(where: { $0.id == album.id }) {
                values.append(album)
            }
        }
        albumsByAsset[update.assetID] = values
        albumRevisions[update.assetID, default: 0] &+= 1
    }

    // MARK: - People

    private func peopleSection(_ people: [Person]) -> some View {
        infoSection("People") {
            if people.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    emptyState(
                        systemImage: "person.crop.circle.badge.questionmark",
                        title: "No People",
                        message: peopleEmptyMessage
                    )

                    if canTagPeople {
                        Button {
                            showAddPeople = true
                        } label: {
                            Label("Add People", systemImage: "plus.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.tint)
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                        .accessibilityIdentifier("info-add-person")
                    }
                }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(people) { person in
                            personCell(person)
                        }

                        if canTagPeople {
                            addPersonCell
                        }
                    }
                }
            }
        }
    }

    /// Trailing tile of the people strip that opens the tagging sheet.
    private var addPersonCell: some View {
        Button {
            showAddPeople = true
        } label: {
            VStack(spacing: 6) {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 72, height: 72)
                    .overlay {
                        Image(systemName: "plus")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.tint)
                    }
                Text("Add")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
            .frame(width: 84)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("info-add-person")
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

    private func personCell(_ person: Person) -> some View {
        let person = person.renamed(personNameOverrides[person.id] ?? person.name)
        return Button {
            if person.name.isEmpty, isOwner {
                personNameDraft = ""
                renamingPerson = person
            } else {
                onOpenPerson?(person)
            }
        } label: {
            VStack(spacing: 6) {
                if let url = session.personThumbnailURL(person), !person.isPending {
                    RemoteImage(url: url, targetPixelSize: 160)
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
        .disabled(renamingPersonIDs.contains(person.id) || person.isPending)
        .accessibilityIdentifier("info-person-\(person.id)")
        .contextMenu {
            if isOwner, !person.isPending {
                Button {
                    personNameDraft = person.name
                    renamingPerson = person
                } label: {
                    Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
                }

                if canTagPeople {
                    Button(role: .destructive) {
                        removingPerson = person
                    } label: {
                        Label("Remove from This Item", systemImage: "person.badge.minus")
                    }
                }
            }
        }
        // The iOS 26 dialog morphs out of its presenting control, so the
        // attachment lives on each cell and only the matching one presents.
        .confirmationDialog(
            person.name.isEmpty ? "Remove This Person?" : "Remove \(person.name)?",
            isPresented: Binding(
                get: { removingPerson?.id == person.id },
                set: { if !$0, removingPerson?.id == person.id { removingPerson = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                submitRemovePerson(person, for: asset.id)
            }
        } message: {
            Text("This person's tag will be removed from this item.")
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
        guard renamingPersonIDs.insert(person.id).inserted else { return }
        defer { renamingPersonIDs.remove(person.id) }
        let previous = personNameOverrides[person.id] ?? person.name
        personNameOverrides[person.id] = name
        do {
            try await client.updatePerson(id: person.id, name: name)
        } catch {
            personNameOverrides[person.id] = previous
            ErrorToastCenter.shared.show("Couldn’t rename this person", error: error)
        }
    }

    /// Tags one person at the face region chosen in the tag sheet. A pending
    /// person is created on the server first, then the face row is stored.
    private func submitTagPerson(_ person: Person, region: FaceRegion, for assetID: String) {
        guard let client = session.client else { return }
        let current = displayedPeople
        let isNewPerson = !current.contains { $0.id == person.id }
        // the picker hides people already on the asset, so this only guards
        // a refresh that tagged the same person mid-flow.
        let desired = isNewPerson ? current + [person] : current

        peopleMutations.submit(
            assetID: assetID,
            current: current,
            desired: desired,
            errorMessage: "Couldn’t tag this person",
            apply: { id, value in peopleByAsset[id] = value },
            request: { projected in
                var kept = projected
                var resolved = person
                if person.isPending {
                    resolved = try await client.createPerson(name: person.name)
                }
                try await client.createFace(
                    assetID: assetID,
                    personID: resolved.id,
                    imageWidth: region.imageWidth,
                    imageHeight: region.imageHeight,
                    x: region.x,
                    y: region.y,
                    width: region.width,
                    height: region.height
                )
                // Swap the pending placeholder for the server person.
                if let index = kept.firstIndex(where: { $0.id == person.id }) {
                    kept[index] = resolved
                }
                return kept
            }
        )
    }

    /// Untags a person by deleting every face row of theirs on this asset.
    private func submitRemovePerson(_ person: Person, for assetID: String) {
        guard let client = session.client else { return }
        let current = displayedPeople
        let desired = current.filter { $0.id != person.id }
        guard desired.count != current.count else { return }

        peopleMutations.submit(
            assetID: assetID,
            current: current,
            desired: desired,
            errorMessage: "Couldn’t remove this person",
            apply: { id, value in peopleByAsset[id] = value },
            request: { projected in
                let faces = try await client.assetFaces(assetID: assetID)
                for face in faces where face.person?.id == person.id {
                    try await client.deleteFace(id: face.id)
                }
                return projected
            }
        )
    }

    // MARK: - Location

    private func showsLocationSection(_ exif: ExifInfo?) -> Bool {
        displayedLocation(for: asset.id) != nil
            || storedCoordinate(exif) != nil
            || (isOwner && !asset.isLocal)
    }

    @ViewBuilder private func locationSection(_ exif: ExifInfo?) -> some View {
        let displayed = displayedLocation(for: asset.id)
        let coordinate = displayed?.coordinate ?? storedCoordinate(exif)
        let canonical = canonicalLocationsByAsset[asset.id] ?? nil
        let hidesStalePlaceName = displayed != canonical
            || locationMutations.isPending(for: asset.id)
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                sectionLabel("Location")
                Spacer()
                if isOwner, !asset.isLocal, detail != nil {
                    Button(coordinate == nil ? "Add" : "Adjust") {
                        showAdjustLocation = true
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(.rect)
                    .accessibilityIdentifier(
                        coordinate == nil ? "info-add-location" : "info-adjust-location"
                    )
                }
            }

            if let coordinate {
                locatedContent(
                    exif,
                    coordinate: coordinate,
                    hidesStalePlaceName: hidesStalePlaceName
                )
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

    private func storedCoordinate(_ exif: ExifInfo?) -> CLLocationCoordinate2D? {
        guard let latitude = exif?.latitude, let longitude = exif?.longitude else { return nil }
        guard latitude != 0 || longitude != 0 else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func locatedContent(
        _ exif: ExifInfo?,
        coordinate: CLLocationCoordinate2D,
        hidesStalePlaceName: Bool
    ) -> some View {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        let place = hidesStalePlaceName ? "" : [exif?.city, exif?.state, exif?.country]
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
                .frame(height: 148)
                .clipShape(.rect(cornerRadius: 14))
                .allowsHitTesting(false)
                .accessibilityHidden(true)

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(place.isEmpty ? "Photo location" : place)
        .accessibilityValue(
            "Latitude \(latitude.formatted(.number.precision(.fractionLength(4)))), longitude \(longitude.formatted(.number.precision(.fractionLength(4))))"
        )
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
        let exif = detail.exifInfo
        let showsCamera = exif.flatMap(cameraName) != nil || nonEmpty(exif?.lensModel) != nil
        let showsMetrics = hasCaptureMetrics(exif)

        return VStack(alignment: .leading, spacing: 14) {
            sectionLabel("Details")

            VStack(spacing: 0) {
                captureDateRow
                metadataDivider
                fileRow(detail)

                if showsCamera {
                    metadataDivider
                    cameraRow(exif)
                }

                if showsMetrics {
                    metadataDivider
                    captureMetrics(exif)
                }
            }
            .background(surfaceFill, in: .rect(cornerRadius: 16))
        }
        .padding(.vertical, 20)
    }

    private func hasCaptureMetrics(_ exif: ExifInfo?) -> Bool {
        !captureMetricValues(exif).isEmpty
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
        let camera = exif.flatMap(cameraName)
        let lens = nonEmpty(exif?.lensModel)

        return HStack(alignment: .top, spacing: 12) {
            metadataIcon("camera")

            VStack(alignment: .leading, spacing: 3) {
                if let camera {
                    Text(camera)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                }

                if let lens {
                    Text(lens)
                        .font(camera == nil ? .subheadline.weight(.semibold) : .caption)
                        .foregroundStyle(camera == nil ? .primary : .secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
    }

    @ViewBuilder private func captureMetrics(_ exif: ExifInfo?) -> some View {
        let metrics = captureMetricValues(exif)
        if dynamicTypeSize.isAccessibilitySize {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())],
                spacing: 12
            ) {
                ForEach(metrics) { metric in
                    captureMetric(metric)
                }
            }
            .padding(12)
        } else {
            HStack(alignment: .top, spacing: 0) {
                ForEach(Array(metrics.enumerated()), id: \.element.id) { index, metric in
                    if index > 0 { metricDivider }
                    captureMetric(metric)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 12)
        }
    }

    private func captureMetricValues(_ exif: ExifInfo?) -> [CaptureMetricValue] {
        [
            focalLength(exif).map { CaptureMetricValue(title: "Focal", value: $0) },
            aperture(exif).map { CaptureMetricValue(title: "Aperture", value: $0) },
            exposure(exif).map { CaptureMetricValue(title: "Shutter", value: $0) },
            iso(exif).map { CaptureMetricValue(title: "ISO", value: $0) },
        ]
        .compactMap { $0 }
    }

    private func captureMetric(_ metric: CaptureMetricValue) -> some View {
        VStack(spacing: 3) {
            Text(metric.value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                .minimumScaleFactor(dynamicTypeSize.isAccessibilitySize ? 0.85 : 0.65)
            Text(metric.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metric.value)
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

    // MARK: - Rating

    private var ratingSection: some View {
        infoSection("Rating") {
            HStack(spacing: 4) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        Task { await setRating(star == rating ? 0 : star) }
                    } label: {
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 26))
                            .foregroundStyle(
                                star <= rating ? Color.accentColor : Color.secondary.opacity(0.5)
                            )
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isOwner)
                    .accessibilityLabel(star == 1 ? "1 star" : "\(star) stars")
                    .accessibilityValue(star == rating ? "Selected" : "Not selected")
                    .accessibilityAddTraits(star == rating ? .isSelected : [])
                    .accessibilityHint(
                        star == rating ? "Double-tap to clear the rating" : "Double-tap to set the rating"
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func setRating(_ value: Int) async {
        guard let client = session.client else { return }
        let assetID = asset.id
        ratingMutations.submit(
            assetID: assetID,
            current: ratingsByAsset[assetID] ?? 0,
            desired: value,
            errorMessage: "Couldn’t save the rating",
            apply: { id, projected in ratingsByAsset[id] = projected },
            request: { projected in
                _ = try await client.updateAsset(id: assetID, rating: projected)
                return projected
            }
        )
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
                        .frame(minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                        .accessibilityIdentifier("info-add-to-album")
                    }
                }
            } else {
                albumRows
            }
        }
        .padding(.vertical, 20)
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
                Button {
                    onOpenAlbum?(album)
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
                .disabled(album.isPending)
                .accessibilityIdentifier("info-album-\(album.id)")

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
            .accessibilityAddTraits(.isHeader)
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
        case .image: asset.isLivePhoto ? "livephoto" : "photo"
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
        } else if asset.isLivePhoto {
            parts.append("Live Photo")
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
        let requestedAsset = asset
        let assetID = requestedAsset.id
        // Paging swaps the asset while this panel stays mounted. Flush the old
        // draft before adopting the next photo so it cannot be saved to it.
        if let draftAssetID, draftAssetID != assetID {
            await commitDescription()
            descriptionFocused = false
        }
        let isNewAsset = draftAssetID != assetID
        if isNewAsset {
            draftAssetID = assetID
            descriptionDraft = captionsByAsset[assetID] ?? ""
            // paging back to an asset already seen this session shows its
            // detail immediately and revalidates behind it, instead of
            // spinning through a whole refetch on a slow server.
            if let known = detailsByAsset[assetID] {
                loadState = .loaded(known)
            } else {
                loadState = .loading
            }
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        let captionSnapshot = captionMutations.loadSnapshot(for: assetID)
        let ratingSnapshot = ratingMutations.loadSnapshot(for: assetID)
        let locationSnapshot = locationMutations.loadSnapshot(for: assetID)
        let peopleSnapshot = peopleMutations.loadSnapshot(for: assetID)
        let albumRevision = albumRevisions[assetID, default: 0]

        // Device-only assets answer from PhotoKit. Server concepts remain as
        // explicit empty sections instead of disappearing from the layout.
        if requestedAsset.isLocal {
            var local: AssetDetail?
            if let localIdentifier = requestedAsset.localIdentifier {
                local = await PhotoLibraryService.localDetail(localIdentifier: localIdentifier)
            }
            guard draftAssetID == assetID, loadGeneration == generation else { return }
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
            let detail = try await client.assetDetail(id: assetID)
            guard draftAssetID == assetID, loadGeneration == generation else { return }
            detailsByAsset[assetID] = detail
            loadState = .loaded(detail)
            adoptMetadata(
                detail,
                assetID: assetID,
                captionSnapshot: captionSnapshot,
                ratingSnapshot: ratingSnapshot,
                locationSnapshot: locationSnapshot,
                peopleSnapshot: peopleSnapshot
            )

            let loaded = (try? await client.albums(assetID: assetID)) ?? []
            guard draftAssetID == assetID, loadGeneration == generation else { return }
            if albumRevisions[assetID, default: 0] == albumRevision {
                albumsByAsset[assetID] = loaded
            }
            if let account {
                let envelope = CachedAssetInfo(
                    detail: detail,
                    albums: albumsByAsset[assetID] ?? loaded
                )
                Task.detached(priority: .utility) {
                    OfflineCache.store(envelope, key: "asset-info/\(detail.id)", account: account)
                }
            }
        } catch {
            // Offline: the last fetched copy still answers most questions.
            // read off main - it is a per-asset file and the panel may be
            // asking mid-swipe.
            guard draftAssetID == assetID, loadGeneration == generation else { return }
            let cachedInfo: CachedAssetInfo?
            if let account {
                cachedInfo = await Task.detached(priority: .userInitiated) {
                    OfflineCache.value(CachedAssetInfo.self, key: "asset-info/\(assetID)", account: account)
                }.value
                guard draftAssetID == assetID, loadGeneration == generation else { return }
            } else {
                cachedInfo = nil
            }
            if let cached = cachedInfo {
                detailsByAsset[assetID] = cached.detail
                loadState = .loaded(cached.detail)
                adoptMetadata(
                    cached.detail,
                    assetID: assetID,
                    captionSnapshot: captionSnapshot,
                    ratingSnapshot: ratingSnapshot,
                    locationSnapshot: locationSnapshot,
                    peopleSnapshot: peopleSnapshot
                )
                if albumRevisions[assetID, default: 0] == albumRevision {
                    albumsByAsset[assetID] = cached.albums
                }
            } else {
                loadState = .failed(error.localizedDescription)
            }
        }
    }

    private func adoptMetadata(
        _ detail: AssetDetail,
        assetID: String,
        captionSnapshot: AssetOptimisticField<String>.LoadSnapshot,
        ratingSnapshot: AssetOptimisticField<Int>.LoadSnapshot,
        locationSnapshot: AssetOptimisticField<AssetCoordinateValue?>.LoadSnapshot,
        peopleSnapshot: AssetOptimisticField<[Person]>.LoadSnapshot
    ) {
        if captionMutations.canAdoptServerValue(for: assetID, since: captionSnapshot) {
            let serverValue = detail.exifInfo?.description ?? ""
            let previousProjection = captionsByAsset[assetID] ?? ""
            captionMutations.adoptServerValue(serverValue, for: assetID)
            captionsByAsset[assetID] = serverValue
            if draftAssetID == assetID,
               !descriptionFocused || descriptionDraft == previousProjection {
                descriptionDraft = serverValue
            }
        }

        if ratingMutations.canAdoptServerValue(for: assetID, since: ratingSnapshot) {
            let serverValue = detail.exifInfo?.rating.map { Int($0) } ?? 0
            ratingMutations.adoptServerValue(serverValue, for: assetID)
            ratingsByAsset[assetID] = serverValue
        }

        if locationMutations.canAdoptServerValue(for: assetID, since: locationSnapshot) {
            let serverValue = storedCoordinate(detail.exifInfo).map(AssetCoordinateValue.init)
            locationMutations.adoptServerValue(serverValue, for: assetID)
            canonicalLocationsByAsset[assetID] = serverValue
            locationsByAsset[assetID] = serverValue
        }

        if peopleMutations.canAdoptServerValue(for: assetID, since: peopleSnapshot) {
            let serverValue = detail.people?.filter { $0.isHidden != true } ?? []
            peopleMutations.adoptServerValue(serverValue, for: assetID)
            peopleByAsset[assetID] = serverValue
        }
    }
}

/// Temporary source-compatibility wrapper for call sites that still use the
/// old name. New viewer layouts should embed `AssetInfoPanel` directly.
struct AssetInfoSheet: View {
    let asset: Asset
    var onDateAdjusted: ((String, Date, Double) -> Void)? = nil

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

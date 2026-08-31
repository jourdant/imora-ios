import SwiftUI

/// timeline filtered to a person, headed by their portrait and vitals, with
/// naming, favorite, hide, birth date and merge management in the toolbar.
struct PersonScreen: View {
    @Environment(SessionStore.self) private var session
    @Environment(\.scenePhase) private var scenePhase

    @State private var person: Person
    @State private var assetCount: Int?
    @State private var resyncTrigger = 0
    @State private var showRename = false
    @State private var draftName = ""
    @State private var showBirthDate = false
    @State private var showMerge = false
    @State private var mutationInFlight = false
    /// the grid is standing in for a photo picker, so it shows no header, no
    /// portrait and no way out other than cancelling.
    @State private var isPickingFeatured = false
    @State private var toast: String?

    init(person: Person) {
        _person = State(initialValue: person)
    }

    var body: some View {
        TimelineScreen(
            // the hero already carries the portrait and name, so the bar
            // stays empty until the picker needs it.
            title: isPickingFeatured ? "Select Featured Photo" : "",
            filter: TimelineFilter(personId: person.id),
            emptyIcon: "person.crop.circle",
            emptyMessage: "No photos of this person",
            showsLargeTitle: false,
            resyncTrigger: resyncTrigger,
            onPickAsset: isPickingFeatured ? { asset in Task { await setFeaturedPhoto(asset) } } : nil,
            trailingItems: {
                ToolbarItem(placement: .topBarTrailing) {
                    if isPickingFeatured {
                        Button("Cancel") { isPickingFeatured = false }
                            .accessibilityIdentifier("person-cancel-featured")
                    } else {
                        Menu {
                            menuItems
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .accessibilityLabel("More")
                        .accessibilityIdentifier("person-menu")
                    }
                }
            },
            header: {
                if !isPickingFeatured {
                    PersonHeader(
                        person: person,
                        assetCount: assetCount,
                        onEditName: {
                            draftName = person.name
                            showRename = true
                        },
                        onEditPortrait: { if !mutationInFlight { isPickingFeatured = true } },
                        onEditBirthDate: { showBirthDate = true }
                    )
                }
            }
        )
        // a merge can hand the screen over to the surviving person, and the
        // grid's filter is frozen at init - fresh identity refetches it.
        .id(person.id)
        // going back mid-pick would leave the person entirely, so cancelling
        // is the only way out of the mode.
        .navigationBarBackButtonHidden(isPickingFeatured)
        .overlay(alignment: .top) {
            if let toast {
                ToastBanner(text: toast) { self.toast = nil }
            }
        }
        .alert(person.name.isEmpty ? "Add a Name" : "Rename", isPresented: $showRename) {
            TextField("Name", text: $draftName)
            Button("Save") {
                let requestedName = draftName
                Task { await rename(to: requestedName) }
            }
            .disabled(mutationInFlight)
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showBirthDate) {
            PersonBirthDateSheet(person: person) { value in
                Task { await setBirthDate(value) }
            }
        }
        .sheet(isPresented: $showMerge) {
            MergePeopleSheet(target: person) { survivor, mergedIDs in
                // an unnamed page can itself be merged away - the screen then
                // becomes the survivor. otherwise absorbed people bring their
                // assets, so the grid resyncs and the count refreshes.
                if mergedIDs.contains(person.id) {
                    person = survivor
                    assetCount = nil
                }
                resyncTrigger += 1
                Task { await refresh() }
            }
        }
        .task { await refresh() }
        // the portrait may have been changed elsewhere while imora sat in the
        // background, and returning to the app does not re-run the task.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    @ViewBuilder private var menuItems: some View {
        let isFavorite = person.isFavorite == true
        let isHidden = person.isHidden == true

        Button {
            Task { await setFavorite(!isFavorite) }
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
        }
        .disabled(mutationInFlight)

        Button {
            showBirthDate = true
        } label: {
            Label(
                person.birthDate == nil ? "Set Date of Birth" : "Edit Date of Birth",
                systemImage: "birthday.cake"
            )
        }
        .disabled(mutationInFlight)

        Button {
            showMerge = true
        } label: {
            Label("Merge People", systemImage: "arrow.triangle.merge")
        }
        .disabled(mutationInFlight)

        Divider()

        Button {
            Task { await setHidden(!isHidden) }
        } label: {
            Label(isHidden ? "Unhide Person" : "Hide Person", systemImage: isHidden ? "eye" : "eye.slash")
        }
        .disabled(mutationInFlight)
    }

    // MARK: - loading

    private func refresh() async {
        guard let client = session.client else { return }
        async let freshPerson = client.person(id: person.id)
        async let statistics = client.personStatistics(id: person.id)
        if let fresh = try? await freshPerson { person = fresh }
        if let statistics = try? await statistics { assetCount = statistics.assets }
    }

    // MARK: - mutations

    /// optimistic person edit with the smallest safe rollback - the whole
    /// previous value.
    private func perform(
        errorMessage: String,
        apply: (inout Person) -> Void,
        request: @escaping () async throws -> Void
    ) async {
        guard !mutationInFlight else { return }
        mutationInFlight = true
        defer { mutationInFlight = false }
        let previous = person
        var projected = person
        apply(&projected)
        let next = projected
        await OptimisticAction.perform(
            errorMessage: errorMessage,
            apply: { person = next },
            rollback: { person = previous },
            request: request
        )
    }

    private func rename(to requestedName: String) async {
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t rename this person. The server is not available.")
            return
        }
        await perform(
            errorMessage: "Couldn’t rename this person",
            apply: { $0.name = requestedName },
            request: { try await client.updatePerson(id: person.id, name: requestedName) }
        )
    }

    private func setFavorite(_ value: Bool) async {
        guard let client = session.client else { return }
        await perform(
            errorMessage: value ? "Couldn’t favorite this person" : "Couldn’t unfavorite this person",
            apply: { $0.isFavorite = value },
            request: { try await client.updatePerson(id: person.id, isFavorite: value) }
        )
    }

    private func setHidden(_ value: Bool) async {
        guard let client = session.client else { return }
        await perform(
            errorMessage: value ? "Couldn’t hide this person" : "Couldn’t unhide this person",
            apply: { $0.isHidden = value },
            request: { try await client.updatePerson(id: person.id, isHidden: value) }
        )
    }

    /// the portrait is re-rendered server side in a job, so the new face only
    /// reaches the avatars once the socket says it is ready.
    private func setFeaturedPhoto(_ asset: Asset) async {
        // another edit is still going: keep the picker up rather than drop the
        // tap on the floor.
        guard !mutationInFlight else { return }
        isPickingFeatured = false
        guard let client = session.client else {
            ErrorToastCenter.shared.show("Couldn’t set the featured photo. The server is not available.")
            return
        }
        mutationInFlight = true
        defer { mutationInFlight = false }
        do {
            try await client.updatePerson(id: person.id, featureFaceAssetID: asset.id)
            toast = "Featured photo updated"
        } catch {
            ErrorToastCenter.shared.show("Couldn’t set the featured photo", error: error)
        }
    }

    private func setBirthDate(_ value: String?) async {
        guard let client = session.client else { return }
        await perform(
            errorMessage: "Couldn’t save the date of birth",
            apply: { $0.birthDate = value },
            request: { try await client.updatePerson(id: person.id, birthDate: .some(value)) }
        )
    }
}

/// hero above the person's grid: the portrait bleeds into a soft backdrop
/// made of itself, with the name and vitals as glass chips underneath.
private struct PersonHeader: View {
    @Environment(SessionStore.self) private var session
    let person: Person
    let assetCount: Int?
    let onEditName: () -> Void
    let onEditPortrait: () -> Void
    let onEditBirthDate: () -> Void

    private let portraitSide: CGFloat = 132

    var body: some View {
        VStack(spacing: 14) {
            Button(action: onEditPortrait) { portrait }
                .buttonStyle(.plain)
                .accessibilityLabel("Featured photo")
                .accessibilityHint("Choose a different photo")
                .accessibilityIdentifier("person-featured-photo")

            Button(action: onEditName) {
                HStack(spacing: 8) {
                    Text(person.name.isEmpty ? "Add a Name" : person.name)
                        .font(.title.weight(.bold))
                        .foregroundStyle(person.name.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                    if person.isFavorite == true {
                        Image(systemName: "heart.fill")
                            .font(.headline)
                            .foregroundStyle(.pink)
                            .symbolEffect(.bounce, value: person.isFavorite)
                            .accessibilityLabel("Favorite")
                    }
                    Image(systemName: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 24)
            }
            .buttonStyle(.plain)
            .accessibilityHint(person.name.isEmpty ? "Add a name" : "Rename")
            .accessibilityIdentifier("person-name")

            chips
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .background {
            // the header scrolls under the bar, so the backdrop is stretched
            // well past its own top edge to reach the status bar.
            GeometryReader { proxy in
                backdrop
                    .frame(width: proxy.size.width, height: proxy.size.height + backdropOverflow)
                    .offset(y: -backdropOverflow)
            }
        }
    }

    private let backdropOverflow: CGFloat = 320

    /// the portrait itself, blown up and blurred, dissolving into the
    /// screen background so the hero feels lit by the person.
    @ViewBuilder private var backdrop: some View {
        if let url = session.personThumbnailURL(person) {
            RemoteImage(url: url, targetPixelSize: 64)
                .scaleEffect(1.6)
                .blur(radius: 48, opaque: true)
                .saturation(1.4)
                .opacity(0.55)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .black.opacity(0.6), location: 0.75),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
                .clipped()
                .accessibilityHidden(true)
        }
    }

    private var portrait: some View {
        PersonAvatar(person: person, targetPixelSize: 480, showsFavorite: false)
            .frame(width: portraitSide, height: portraitSide)
            .padding(4)
            .glassEffect(.regular, in: .circle)
            .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .glassEffect(.regular, in: .circle)
                    .accessibilityHidden(true)
            }
    }

    private var chips: some View {
        HStack(spacing: 8) {
            if let assetCount {
                chip(
                    "\(assetCount) \(assetCount == 1 ? "Photo" : "Photos")",
                    systemImage: "photo.on.rectangle",
                    tinted: false
                )
            }

            Button(action: onEditBirthDate) {
                chip(
                    birthLabel ?? "Add Birthday",
                    systemImage: "birthday.cake",
                    tinted: birthLabel == nil
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("person-birthdate")

            if person.isHidden == true {
                chip("Hidden", systemImage: "eye.slash", tinted: false)
            }
        }
        .padding(.horizontal, 16)
    }

    private func chip(_ text: String, systemImage: String, tinted: Bool) -> some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(tinted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(.regular, in: .capsule)
    }

    /// "Jan 5, 1990 · Age 36" once a birth date is set.
    private var birthLabel: String? {
        guard let raw = person.birthDate,
              let display = PersonBirthDate.displayLabel(raw)
        else { return nil }
        guard let age = PersonBirthDate.ageLabel(raw) else { return display }
        return "\(display) · \(age)"
    }
}

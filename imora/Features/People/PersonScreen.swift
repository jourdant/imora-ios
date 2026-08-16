import SwiftUI

/// timeline filtered to a person, headed by their portrait and vitals, with
/// naming, favorite, hide, birth date and merge management in the toolbar.
struct PersonScreen: View {
    @Environment(SessionStore.self) private var session

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
            title: isPickingFeatured ? "Select Featured Photo" : (person.name.isEmpty ? "Unnamed" : person.name),
            filter: TimelineFilter(personId: person.id),
            emptyIcon: "person.crop.circle",
            emptyMessage: "No photos of this person",
            showsLargeTitle: false,
            resyncTrigger: resyncTrigger,
            onPickAsset: isPickingFeatured ? { asset in Task { await setFeaturedPhoto(asset) } } : nil,
            header: {
                if !isPickingFeatured {
                    PersonHeader(
                        person: person,
                        assetCount: assetCount,
                        onEditName: {
                            draftName = person.name
                            showRename = true
                        },
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
        .toolbar {
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
        }
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
    }

    @ViewBuilder private var menuItems: some View {
        let isFavorite = person.isFavorite == true
        let isHidden = person.isHidden == true

        Button {
            draftName = person.name
            showRename = true
        } label: {
            Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
        }
        .disabled(mutationInFlight)

        Button {
            Task { await setFavorite(!isFavorite) }
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
        }
        .disabled(mutationInFlight)

        Button {
            isPickingFeatured = true
        } label: {
            Label("Select Featured Photo", systemImage: "person.crop.square")
        }
        .disabled(mutationInFlight)
        .accessibilityIdentifier("person-featured-photo")

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

/// portrait, name and vitals above the person's grid.
private struct PersonHeader: View {
    let person: Person
    let assetCount: Int?
    let onEditName: () -> Void
    let onEditBirthDate: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            PersonAvatar(person: person, targetPixelSize: 480, showsFavorite: false)
                .frame(width: 104, height: 104)

            VStack(spacing: 4) {
                Button(action: onEditName) {
                    HStack(spacing: 6) {
                        Text(person.name.isEmpty ? "Add a Name" : person.name)
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(person.name.isEmpty ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        if person.isFavorite == true {
                            Image(systemName: "heart.fill")
                                .font(.subheadline)
                                .foregroundStyle(.pink)
                                .accessibilityLabel("Favorite")
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("person-name")

                if let metaLabel {
                    Text(metaLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Button(action: onEditBirthDate) {
                Label(birthLabel ?? "Add Date of Birth", systemImage: "birthday.cake")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(birthLabel == nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .glassEffect(.regular, in: .capsule)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("person-birthdate")
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 18)
    }

    /// item count and hidden state on one quiet line.
    private var metaLabel: String? {
        var parts: [String] = []
        if let assetCount {
            parts.append("\(assetCount) \(assetCount == 1 ? "Item" : "Items")")
        }
        if person.isHidden == true {
            parts.append("Hidden")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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

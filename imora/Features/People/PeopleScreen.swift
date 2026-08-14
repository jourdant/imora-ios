import SwiftUI

/// full grid of everyone the server recognizes, with hidden people management,
/// favorites, merging and birth dates a long press away.
struct PeopleScreen: View {
    @Environment(SessionStore.self) private var session

    @State private var people: [Person] = []
    @State private var isLoading = true
    @State private var showHidden = false
    @State private var searchText = ""
    @State private var renamingPerson: Person?
    @State private var renameDraft = ""
    @State private var birthDatePerson: Person?
    @State private var mergeTarget: Person?
    /// serializes mutations per person so a re-opened context menu cannot
    /// stack conflicting requests.
    @State private var mutatingIDs = Set<String>()

    private var visiblePeople: [Person] {
        filtered(people.filter { $0.isHidden != true })
    }

    private var hiddenPeople: [Person] {
        filtered(people.filter { $0.isHidden == true })
    }

    private func filtered(_ list: [Person]) -> [Person] {
        guard !searchText.isEmpty else { return list }
        return list.filter { $0.name.localizedStandardContains(searchText) }
    }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 96, maximum: 140), spacing: 14)]
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !visiblePeople.isEmpty {
                    grid(visiblePeople)
                }

                if showHidden, !hiddenPeople.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Hidden", systemImage: "eye.slash")
                            .font(.headline)
                            .foregroundStyle(.secondary)
                        grid(hiddenPeople)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .navigationTitle("People")
        .navigationSubtitle(subtitle)
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, prompt: "Search people")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: $showHidden.animation(.smooth(duration: 0.25))) {
                        Label("Show Hidden People", systemImage: "eye.slash")
                    }
                    .accessibilityIdentifier("people-show-hidden")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .overlay {
            if isLoading && people.isEmpty {
                ProgressView()
            } else if visiblePeople.isEmpty && (!showHidden || hiddenPeople.isEmpty) {
                if !searchText.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    ContentUnavailableView(
                        "No People",
                        systemImage: "person.2.slash",
                        description: Text("People show up here once faces are recognized.")
                    )
                }
            }
        }
        .task { await load() }
        // returning from a person page picks up renames, merges and hides.
        .onAppear {
            if !people.isEmpty {
                Task { await load() }
            }
        }
        .alert(
            renamingPerson?.name.isEmpty == false ? "Rename" : "Add a Name",
            isPresented: Binding(
                get: { renamingPerson != nil },
                set: { if !$0 { renamingPerson = nil } }
            )
        ) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let renamingPerson {
                    Task { await rename(renamingPerson, to: renameDraft) }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $birthDatePerson) { person in
            PersonBirthDateSheet(person: person) { value in
                Task { await setBirthDate(person, to: value) }
            }
        }
        .sheet(item: $mergeTarget) { person in
            MergePeopleSheet(target: person) { _, mergedIDs in
                people.removeAll { mergedIDs.contains($0.id) }
            }
        }
    }

    private var subtitle: String {
        let count = people.count { $0.isHidden != true }
        guard count > 0 else { return "" }
        return "\(count) \(count == 1 ? "Person" : "People")"
    }

    private func grid(_ list: [Person]) -> some View {
        LazyVGrid(columns: columns, spacing: 18) {
            ForEach(list) { person in
                NavigationLink(value: person) {
                    PersonGridCell(person: person)
                }
                .buttonStyle(PressableCardStyle())
                .disabled(mutatingIDs.contains(person.id))
                .accessibilityIdentifier("people-cell-\(person.id)")
                .contextMenu { contextMenu(for: person) }
            }
        }
    }

    @ViewBuilder private func contextMenu(for person: Person) -> some View {
        let isFavorite = person.isFavorite == true
        let isHidden = person.isHidden == true

        Button {
            Task { await setFavorite(person, to: !isFavorite) }
        } label: {
            Label(isFavorite ? "Unfavorite" : "Favorite", systemImage: isFavorite ? "heart.slash" : "heart")
        }

        Button {
            renameDraft = person.name
            renamingPerson = person
        } label: {
            Label(person.name.isEmpty ? "Add a Name" : "Rename", systemImage: "pencil")
        }

        Button {
            birthDatePerson = person
        } label: {
            Label(
                person.birthDate == nil ? "Set Date of Birth" : "Edit Date of Birth",
                systemImage: "birthday.cake"
            )
        }

        Button {
            mergeTarget = person
        } label: {
            Label("Merge People", systemImage: "arrow.triangle.merge")
        }

        Divider()

        Button {
            Task { await setHidden(person, to: !isHidden) }
        } label: {
            Label(isHidden ? "Unhide" : "Hide", systemImage: isHidden ? "eye" : "eye.slash")
        }
    }

    // MARK: - loading

    private func load() async {
        guard let client = session.client else {
            isLoading = false
            return
        }
        // hidden people ride along so managing them needs no second fetch.
        // pages are 1-based and usually just one.
        var all: [Person] = []
        var page = 1
        while true {
            guard let response = try? await client.people(withHidden: true, page: page) else {
                isLoading = false
                return
            }
            all.append(contentsOf: response.people)
            guard response.hasNextPage == true else { break }
            page += 1
        }
        people = all
        isLoading = false
    }

    // MARK: - mutations

    private func update(_ id: String, _ mutation: (inout Person) -> Void) {
        guard let index = people.firstIndex(where: { $0.id == id }) else { return }
        mutation(&people[index])
    }

    private func setFavorite(_ person: Person, to value: Bool) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.isFavorite
        await OptimisticAction.perform(
            errorMessage: value ? "Couldn’t favorite this person" : "Couldn’t unfavorite this person",
            apply: { update(person.id) { $0.isFavorite = value } },
            rollback: { update(person.id) { $0.isFavorite = previous } },
            request: { try await client.updatePerson(id: person.id, isFavorite: value) }
        )
    }

    private func setHidden(_ person: Person, to value: Bool) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.isHidden
        await OptimisticAction.perform(
            errorMessage: value ? "Couldn’t hide this person" : "Couldn’t unhide this person",
            apply: { update(person.id) { $0.isHidden = value } },
            rollback: { update(person.id) { $0.isHidden = previous } },
            request: { try await client.updatePerson(id: person.id, isHidden: value) }
        )
    }

    private func rename(_ person: Person, to requestedName: String) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.name
        await OptimisticAction.perform(
            errorMessage: "Couldn’t rename this person",
            apply: { update(person.id) { $0.name = requestedName } },
            rollback: { update(person.id) { $0.name = previous } },
            request: { try await client.updatePerson(id: person.id, name: requestedName) }
        )
    }

    private func setBirthDate(_ person: Person, to value: String?) async {
        guard let client = session.client, !mutatingIDs.contains(person.id) else { return }
        mutatingIDs.insert(person.id)
        defer { mutatingIDs.remove(person.id) }
        let previous = person.birthDate
        await OptimisticAction.perform(
            errorMessage: "Couldn’t save the date of birth",
            apply: { update(person.id) { $0.birthDate = value } },
            rollback: { update(person.id) { $0.birthDate = previous } },
            request: { try await client.updatePerson(id: person.id, birthDate: .some(value)) }
        )
    }
}

private struct PersonGridCell: View {
    let person: Person

    private var isHidden: Bool { person.isHidden == true }

    var body: some View {
        VStack(spacing: 7) {
            PersonAvatar(person: person, targetPixelSize: 320)
                .opacity(isHidden ? 0.45 : 1)
                .overlay {
                    if isHidden {
                        Image(systemName: "eye.slash.fill")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .black.opacity(0.5), radius: 3)
                    }
                }

            Text(person.name.isEmpty ? "Unnamed" : person.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(person.name.isEmpty ? .secondary : .primary)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [person.name.isEmpty ? "Unnamed person" : person.name]
        if person.isFavorite == true { parts.append("favorite") }
        if isHidden { parts.append("hidden") }
        return parts.joined(separator: ", ")
    }
}

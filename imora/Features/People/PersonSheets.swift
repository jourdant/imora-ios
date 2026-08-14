import SwiftUI

/// picks or clears a person's date of birth. the value travels as the api's
/// date-only wire string, nil meaning clear.
struct PersonBirthDateSheet: View {
    @Environment(\.dismiss) private var dismiss
    let person: Person
    let onSave: (String?) -> Void

    @State private var date: Date

    init(person: Person, onSave: @escaping (String?) -> Void) {
        self.person = person
        self.onSave = onSave
        let current = person.birthDate.flatMap(PersonBirthDate.parse)
        _date = State(initialValue: current ?? Self.defaultDate)
    }

    /// an unset picker starts thirty years back, like the reference client.
    private static var defaultDate: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let year = calendar.component(.year, from: .now) - 30
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? .now
    }

    private var displayName: String {
        person.name.isEmpty ? "this person" : person.name
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "Date of Birth",
                        selection: $date,
                        in: ...Date.now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    // the wire format is a utc calendar date, so the picker
                    // works in utc to keep the chosen day exact.
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    .accessibilityIdentifier("birthdate-picker")
                } footer: {
                    Text("Used to show how old \(displayName) is in a photo.")
                }

                if person.birthDate != nil {
                    Section {
                        Button("Remove Date of Birth", role: .destructive) {
                            onSave(nil)
                            dismiss()
                        }
                        .accessibilityIdentifier("birthdate-remove")
                    }
                }
            }
            .navigationTitle("Date of Birth")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(PersonBirthDate.string(from: date))
                        dismiss()
                    }
                    .accessibilityIdentifier("birthdate-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// picks people to fold together, mirroring the web merge selector:
/// similarity order, five at most. a named person always survives an unnamed
/// target so a merge never buries a name.
struct MergePeopleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session
    let target: Person
    /// surviving person and the ids the server confirmed merged away.
    let onMerged: (Person, [String]) -> Void

    @State private var candidates: [Person] = []
    @State private var selectedIDs: [String] = []
    @State private var query = ""
    @State private var isLoading = true
    @State private var isMerging = false

    private static let selectionLimit = 5

    private var explainer: String {
        if target.name.isEmpty {
            return "Choose up to \(Self.selectionLimit) people to merge with this person. If you pick someone with a name, the photos are kept under them."
        }
        return "Choose up to \(Self.selectionLimit) people to merge into \(target.name). Their photos move over and the merged people are removed."
    }

    private var visible: [Person] {
        guard !query.isEmpty else { return candidates }
        return candidates.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(visible) { person in
                        candidateRow(person)
                    }
                } header: {
                    Text(explainer)
                        .textCase(nil)
                } footer: {
                    if !isLoading, !candidates.isEmpty {
                        Text("Ordered by similarity.")
                    }
                }
            }
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Search people"
            )
            .overlay {
                if isLoading {
                    ProgressView()
                } else if candidates.isEmpty {
                    ContentUnavailableView(
                        "No One to Merge",
                        systemImage: "person.2.slash",
                        description: Text("There are no other people on this server.")
                    )
                }
            }
            .navigationTitle("Merge People")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isMerging)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isMerging {
                        ProgressView()
                    } else {
                        Button("Merge") {
                            Task { await merge() }
                        }
                        .disabled(selectedIDs.isEmpty)
                        .accessibilityIdentifier("merge-confirm")
                    }
                }
            }
            .task { await load() }
            .interactiveDismissDisabled(isMerging)
        }
    }

    private func candidateRow(_ person: Person) -> some View {
        let isSelected = selectedIDs.contains(person.id)
        let atLimit = selectedIDs.count >= Self.selectionLimit
        let unavailable = isMerging || (!isSelected && atLimit)
        return Button {
            if isSelected {
                selectedIDs.removeAll { $0 == person.id }
            } else if !atLimit {
                selectedIDs.append(person.id)
            }
        } label: {
            HStack(spacing: 12) {
                PersonAvatar(person: person, targetPixelSize: 120, showsFavorite: false)
                    .frame(width: 48, height: 48)
                Text(person.name.isEmpty ? "Unnamed" : person.name)
                    .foregroundStyle(person.name.isEmpty ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
            .contentShape(.rect)
        }
        // plain style keeps the row in label colors instead of the tint.
        .buttonStyle(.plain)
        .opacity(unavailable && !isMerging ? 0.4 : 1)
        .disabled(unavailable)
        .accessibilityIdentifier("merge-candidate-\(person.id)")
    }

    private func load() async {
        defer { isLoading = false }
        guard let client = session.client else { return }
        // similarity order puts likely duplicates first. plain order is the
        // fallback for servers that reject the parameter.
        var response = try? await client.people(closestPersonID: target.id)
        if response == nil {
            response = try? await client.people()
        }
        candidates = (response?.people ?? []).filter { $0.id != target.id }
    }

    private func merge() async {
        guard let client = session.client, !isMerging else { return }
        isMerging = true
        defer { isMerging = false }
        let selected = candidates.filter { selectedIDs.contains($0.id) }
        // like the web selector, an unnamed target swaps direction so the
        // first named pick survives and keeps its name.
        var survivor = target
        if target.name.isEmpty, let named = selected.first(where: { !$0.name.isEmpty }) {
            survivor = named
        }
        let victimIDs = ([target] + selected).map(\.id).filter { $0 != survivor.id }
        do {
            let results = try await client.mergePerson(targetID: survivor.id, ids: victimIDs)
            let mergedIDs = results.filter(\.success).map(\.id)
            let failed = victimIDs.count - mergedIDs.count
            if failed > 0 {
                ErrorToastCenter.shared.show("Couldn’t merge \(failed) \(failed == 1 ? "person" : "people").")
            }
            // dismissed before the callback so a host that swaps to the
            // survivor never remounts under a live sheet.
            dismiss()
            if !mergedIDs.isEmpty {
                onMerged(survivor, mergedIDs)
            }
        } catch {
            ErrorToastCenter.shared.show("Couldn’t merge the selected people.", error: error)
        }
    }
}

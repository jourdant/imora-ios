import SwiftUI

extension Person {
    /// placeholder for a person the server has not created yet, so a new tag
    /// can render before POST /people answers.
    static func pending(name: String) -> Person {
        Person(
            id: "optimistic-person-\(UUID().uuidString)",
            name: name,
            thumbnailPath: nil,
            isHidden: false,
            birthDate: nil,
            isFavorite: nil
        )
    }

    var isPending: Bool { id.hasPrefix("optimistic-person-") }
}

/// face box in the pixel space of the preview it was drawn on. the server
/// normalizes against this frame, so it only has to be self-consistent.
nonisolated struct FaceRegion: Equatable, Sendable {
    let imageWidth: Int
    let imageHeight: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

/// tag one person on the current asset in two steps: position a box over
/// the face on the full-size photo, then pick who it is. native port of the
/// immich web face editor, which draws a draggable rect on the preview and
/// reports it in that preview's pixels.
struct FaceTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    /// people already tagged on this asset, hidden from the picker.
    var taggedPeople: [Person] = []
    let onTag: (Person, FaceRegion) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    /// normalized to the preview, like the web editor before conversion.
    @State private var box = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
    @State private var people: [Person] = []
    @State private var isLoading = true
    @State private var query = ""
    @State private var showNewPerson = false
    @State private var newPersonName = ""
    @State private var showPersonPicker = false

    private var selectablePeople: [Person] {
        let taggedIDs = Set(taggedPeople.map(\.id))
        return people.filter { !taggedIDs.contains($0.id) }
    }

    private var visiblePeople: [Person] {
        guard !query.isEmpty else { return selectablePeople }
        return selectablePeople.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            regionStep
                .navigationDestination(isPresented: $showPersonPicker) {
                    personStep
                }
        }
        .task { await loadImage() }
        .task { await loadPeople() }
    }

    // MARK: - step 1, face region

    private var regionStep: some View {
        canvasArea
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom) {
                Text("Move and resize the box over the face.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity)
            }
            .background {
                Color.black.ignoresSafeArea()
            }
            .environment(\.colorScheme, .dark)
            .navigationTitle("Tag a Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Next") { showPersonPicker = true }
                        .disabled(image == nil)
                        .accessibilityIdentifier("tag-person-next")
                }
            }
    }

    @ViewBuilder private var canvasArea: some View {
        if let image {
            FaceBoxCanvas(image: image, box: $box)
                .aspectRatio(
                    image.size.width / max(image.size.height, 1),
                    contentMode: .fit
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 16)
                .accessibilityIdentifier("tag-person-canvas")
        } else if loadFailed {
            VStack(spacing: 10) {
                Text("Couldn't load the photo.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Try Again") { Task { await loadImage() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.tint)
                    .buttonStyle(.plain)
            }
        } else {
            ProgressView()
        }
    }

    // MARK: - step 2, person picker

    private var personStep: some View {
        List {
            Section {
                Button {
                    newPersonName = ""
                    showNewPerson = true
                } label: {
                    Label("New Person", systemImage: "plus")
                }
                .accessibilityIdentifier("tag-person-new")
            }

            Section {
                ForEach(visiblePeople) { person in
                    personRow(person)
                }
            } footer: {
                if !isLoading, visiblePeople.isEmpty, query.isEmpty {
                    Text(
                        people.isEmpty
                            ? "No people on this server yet. Name a new person to start."
                            : "Everyone is already tagged on this item. Name a new person to add someone else."
                    )
                }
            }
        }
        .overlay {
            if isLoading {
                ProgressView()
            }
        }
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search people"
        )
        .navigationTitle("Choose a Person")
        .navigationBarTitleDisplayMode(.inline)
        .alert("New Person", isPresented: $showNewPerson) {
            TextField("Name", text: $newPersonName)
            Button("Create") {
                let name = newPersonName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                commit(.pending(name: name))
            }
            .disabled(newPersonName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func personRow(_ person: Person) -> some View {
        Button {
            commit(person)
        } label: {
            HStack(spacing: 12) {
                if let url = session.personThumbnailURL(person) {
                    RemoteImage(url: url, targetPixelSize: 120)
                        .frame(width: 48, height: 48)
                        .clipShape(.circle)
                } else {
                    Circle()
                        .fill(.quaternary)
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "person.fill")
                                .foregroundStyle(.secondary)
                        }
                }

                Text(person.name.isEmpty ? "Unnamed" : person.name)
                    .foregroundStyle(person.name.isEmpty ? Color.secondary : Color.primary)

                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tag-person-row-\(person.id)")
    }

    // MARK: - loading

    /// same url and pixel size as the viewer page, so this is usually a
    /// cache hit and the box is drawn on exactly what the viewer showed.
    private func loadImage() async {
        guard let client = session.client else {
            loadFailed = true
            return
        }
        loadFailed = false
        let url = client.thumbnailURL(assetID: asset.id, size: "preview", cacheKey: asset.thumbhash)
        image = try? await ImageLoader.shared.image(for: url, targetPixelSize: pagePixelSize)
        if image == nil { loadFailed = true }
    }

    private func loadPeople() async {
        // the shared people cache paints the list instantly on a slow server.
        if people.isEmpty, let account = session.client?.offlineAccountKey {
            let cached = await Task.detached(priority: .userInitiated) {
                OfflineCache.value([Person].self, key: "people", account: account)
            }.value
            if let cached, people.isEmpty {
                people = cached.filter { !($0.isHidden ?? false) }
                isLoading = false
            }
        }
        if let response = try? await session.client?.people() {
            people = response.people.filter { !($0.isHidden ?? false) }
        }
        isLoading = false
    }

    // MARK: - commit

    /// converts the normalized box into the loaded preview's pixel space,
    /// floored and clamped like the web editor's getFaceCoordinates.
    private func commit(_ person: Person) {
        guard let image else { return }
        let pixelWidth = max(1, image.size.width * image.scale)
        let pixelHeight = max(1, image.size.height * image.scale)
        let clamped = box.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let region = FaceRegion(
            imageWidth: Int(pixelWidth.rounded()),
            imageHeight: Int(pixelHeight.rounded()),
            x: max(0, Int((clamped.minX * pixelWidth).rounded(.down))),
            y: max(0, Int((clamped.minY * pixelHeight).rounded(.down))),
            width: max(1, Int((clamped.width * pixelWidth).rounded(.down))),
            height: max(1, Int((clamped.height * pixelHeight).rounded(.down)))
        )
        onTag(person, region)
        dismiss()
    }
}

// MARK: - box canvas

/// draggable, corner-resizable face box over the aspect-fit preview, the
/// native sibling of the web face editor's fabric rect. the box binding is
/// normalized to the image, which fills this view exactly.
private struct FaceBoxCanvas: View {
    let image: UIImage
    @Binding var box: CGRect

    private enum DragMode: Equatable {
        case move
        case corner(right: Bool, bottom: Bool)
    }

    @State private var dragMode: DragMode?
    @State private var dragStartBox = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = CGRect(
                x: box.minX * size.width,
                y: box.minY * size.height,
                width: box.width * size.width,
                height: box.height * size.height
            )

            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()

                boxFrame(frame)
            }
            .contentShape(.rect)
            .gesture(boxGesture(size: size))
        }
        .clipShape(.rect(cornerRadius: 12))
    }

    private func boxFrame(_ frame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(0.95), lineWidth: 2)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
                .shadow(color: .black.opacity(0.4), radius: 2)

            // corner grips.
            ForEach(0..<4, id: \.self) { index in
                let isRight = index % 2 == 1
                let isBottom = index >= 2
                Circle()
                    .fill(.white)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.35), radius: 1.5)
                    .offset(
                        x: (isRight ? frame.maxX : frame.minX) - 5.5,
                        y: (isBottom ? frame.maxY : frame.minY) - 5.5
                    )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - gesture

    private func boxGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragMode == nil {
                    dragStartBox = box
                    dragMode = Self.mode(
                        at: value.startLocation,
                        frame: CGRect(
                            x: box.minX * size.width,
                            y: box.minY * size.height,
                            width: box.width * size.width,
                            height: box.height * size.height
                        )
                    )
                }
                guard let mode = dragMode else { return }
                let delta = CGSize(
                    width: value.translation.width / size.width,
                    height: value.translation.height / size.height
                )
                let minSide = CGSize(width: 24 / size.width, height: 24 / size.height)
                box = Self.apply(mode: mode, delta: delta, start: dragStartBox, minSide: minSide)
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    /// corners beat inside; a touch outside the box does nothing.
    private static func mode(at point: CGPoint, frame: CGRect) -> DragMode? {
        let grip: CGFloat = 28
        let nearLeft = abs(point.x - frame.minX) < grip
        let nearRight = abs(point.x - frame.maxX) < grip
        let nearTop = abs(point.y - frame.minY) < grip
        let nearBottom = abs(point.y - frame.maxY) < grip

        if nearRight, nearBottom { return .corner(right: true, bottom: true) }
        if nearLeft, nearBottom { return .corner(right: false, bottom: true) }
        if nearRight, nearTop { return .corner(right: true, bottom: false) }
        if nearLeft, nearTop { return .corner(right: false, bottom: false) }
        if frame.insetBy(dx: -grip, dy: -grip).contains(point) { return .move }
        return nil
    }

    /// resizes against the opposite corner as anchor, clamped to the unit
    /// square with a touch-sized minimum side.
    private static func apply(mode: DragMode, delta: CGSize, start: CGRect, minSide: CGSize) -> CGRect {
        switch mode {
        case .move:
            var rect = start
            rect.origin.x = min(max(0, start.minX + delta.width), 1 - start.width)
            rect.origin.y = min(max(0, start.minY + delta.height), 1 - start.height)
            return rect

        case .corner(let isRight, let isBottom):
            var newWidth = max(minSide.width, start.width + (isRight ? delta.width : -delta.width))
            var newHeight = max(minSide.height, start.height + (isBottom ? delta.height : -delta.height))

            let anchorX = isRight ? start.minX : start.maxX
            let anchorY = isBottom ? start.minY : start.maxY
            var minX = isRight ? anchorX : anchorX - newWidth
            var minY = isBottom ? anchorY : anchorY - newHeight

            if minX < 0 { newWidth += minX; minX = 0 }
            if minY < 0 { newHeight += minY; minY = 0 }
            newWidth = min(newWidth, 1 - minX)
            newHeight = min(newHeight, 1 - minY)

            return CGRect(x: minX, y: minY, width: newWidth, height: newHeight)
        }
    }
}

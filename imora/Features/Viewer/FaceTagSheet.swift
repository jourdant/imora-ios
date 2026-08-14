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

/// tag one person on the current asset: position a box over the face, then
/// pick who it is. native port of the immich web face editor, which draws a
/// draggable rect on the preview and reports it in that preview's pixels.
struct FaceTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let onTag: (Person, FaceRegion) -> Void

    @State private var image: UIImage?
    @State private var loadFailed = false
    /// normalized to the preview, like the web editor before conversion.
    @State private var box = CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3)
    @State private var people: [Person] = []
    @State private var selection: Person?
    @State private var isLoading = true
    @State private var query = ""
    @State private var showNewPerson = false
    @State private var newPersonName = ""

    private var visiblePeople: [Person] {
        guard !query.isEmpty else { return people }
        return people.filter { $0.name.localizedStandardContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                canvasArea
                    .padding(.horizontal, 16)
                    .padding(.top, 12)

                Text("Move and resize the box over the face.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                peopleList
            }
            .navigationTitle("Tag a Person")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        if let selection { commit(selection) }
                    }
                    .disabled(selection == nil || image == nil)
                    .accessibilityIdentifier("tag-person-confirm")
                }
            }
            .task { await loadImage() }
            .task { await loadPeople() }
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
    }

    @ViewBuilder private var canvasArea: some View {
        if let image {
            FaceBoxCanvas(image: image, box: $box)
                .aspectRatio(
                    image.size.width / max(image.size.height, 1),
                    contentMode: .fit
                )
                .frame(maxWidth: .infinity, maxHeight: 300)
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
            .frame(maxWidth: .infinity, minHeight: 220)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var peopleList: some View {
        List {
            Section {
                Button {
                    newPersonName = ""
                    showNewPerson = true
                } label: {
                    Label("New Person", systemImage: "plus")
                }
                .disabled(image == nil)
                .accessibilityIdentifier("tag-person-new")
            }

            Section {
                ForEach(visiblePeople) { person in
                    personRow(person)
                }
            } footer: {
                if !isLoading, people.isEmpty {
                    Text("No people on this server yet. Name a new person to start.")
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
    }

    private func personRow(_ person: Person) -> some View {
        let isSelected = selection?.id == person.id
        return Button {
            selection = isSelected ? nil : person
        } label: {
            HStack(spacing: 12) {
                if let client = session.client {
                    RemoteImage(
                        url: client.personThumbnailURL(personID: person.id),
                        targetPixelSize: 120
                    )
                    .frame(width: 48, height: 48)
                    .clipShape(.circle)
                }
                Text(person.name.isEmpty ? "Unnamed" : person.name)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            }
        }
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
        // already-tagged people stay listed: a person can legitimately get a
        // second face region on the same asset.
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

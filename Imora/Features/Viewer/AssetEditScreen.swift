import SwiftUI

// MARK: - aspect presets

/// crop aspect choices mirroring the official editor. ratios are the visual
/// width over height; nil means unconstrained.
nonisolated enum EditAspect: String, CaseIterable, Identifiable {
    case free
    case original
    case square
    case wide16x9
    case classic3x2
    case photo7x5
    case standard4x3
    case tall9x16
    case tall2x3
    case tall5x7
    case tall3x4

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: "Free"
        case .original: "Original"
        case .square: "Square"
        case .wide16x9: "16:9"
        case .classic3x2: "3:2"
        case .photo7x5: "7:5"
        case .standard4x3: "4:3"
        case .tall9x16: "9:16"
        case .tall2x3: "2:3"
        case .tall5x7: "5:7"
        case .tall3x4: "3:4"
        }
    }

    /// visual ratio; original resolves against the image, free is nil.
    func ratio(originalAspect: CGFloat) -> CGFloat? {
        switch self {
        case .free: nil
        case .original: originalAspect
        case .square: 1
        case .wide16x9: 16 / 9
        case .classic3x2: 3 / 2
        case .photo7x5: 7 / 5
        case .standard4x3: 4 / 3
        case .tall9x16: 9 / 16
        case .tall2x3: 2 / 3
        case .tall5x7: 5 / 7
        case .tall3x4: 3 / 4
        }
    }
}

// MARK: - transform composition

/// folds an arbitrary rotate and mirror sequence into the canonical
/// rotation-outermost, vertical-mirror-innermost form the official editor
/// uses, so any stored edit list round-trips into ui state.
nonisolated enum EditTransform {
    struct State: Equatable {
        var rotation = 0.0
        var flipH = false
        var flipV = false
        var crop = CGRect(x: 0, y: 0, width: 1, height: 1)

        var normalizedRotation: Double {
            (rotation.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        }

        var isIdentity: Bool {
            normalizedRotation == 0 && !flipH && !flipV && crop == CGRect(x: 0, y: 0, width: 1, height: 1)
        }
    }

    static func state(from edits: [AssetEdit], originalWidth: Int, originalHeight: Int) -> State {
        var state = State()
        // 2x2 row-major matrix (a b; c d) accumulating rotates and mirrors.
        var a = 1.0, b = 0.0, c = 0.0, d = 1.0

        for edit in edits {
            switch edit {
            case .crop(let x, let y, let width, let height):
                guard originalWidth > 0, originalHeight > 0 else { break }
                state.crop = CGRect(
                    x: Double(x) / Double(originalWidth),
                    y: Double(y) / Double(originalHeight),
                    width: Double(width) / Double(originalWidth),
                    height: Double(height) / Double(originalHeight)
                )
            case .rotate(let angle):
                let radians = angle * .pi / 180
                multiplyLeft(cos(radians), -sin(radians), sin(radians), cos(radians), into: &a, &b, &c, &d)
            case .mirror(let axis):
                if axis == "horizontal" {
                    multiplyLeft(-1, 0, 0, 1, into: &a, &b, &c, &d)
                } else {
                    multiplyLeft(1, 0, 0, -1, into: &a, &b, &c, &d)
                }
            }
        }

        // both canonical forms - r(θ) and r(θ)·mirrorV - carry a = cos θ and
        // c = sin θ, so one atan2 recovers the angle with its sign. acos or
        // asin alone would fold 190° back to 170° and mirror a straighten
        // made in another client.
        let epsilon = 1e-6
        let rotation = atan2(c, a) * 180 / .pi
        state.rotation = rotation < 0 ? 360 + rotation : rotation
        state.flipV = abs(a) < epsilon ? abs(b - c) < epsilon : abs(a + d) < epsilon
        return state
    }

    /// canonical wire order: crop, mirror horizontal, mirror vertical, rotate.
    /// a non-positive original size means the true pixel dimensions are
    /// unknown, and a crop expressed in the wrong space would cut the picture
    /// somewhere else entirely - emit the orientation edits only.
    static func edits(from state: State, originalWidth: Int, originalHeight: Int) -> [AssetEdit] {
        var edits: [AssetEdit] = []

        if originalWidth > 0, originalHeight > 0 {
            // both edges are clamped first and the size derived from them, so
            // a rect that drifted outside the unit square shrinks instead of
            // keeping a width its clamped origin can no longer support.
            let x = clampPixel(state.crop.minX, span: originalWidth)
            let y = clampPixel(state.crop.minY, span: originalHeight)
            let width = clampPixel(state.crop.maxX, span: originalWidth) - x
            let height = clampPixel(state.crop.maxY, span: originalHeight) - y
            if width > 0, height > 0, width != originalWidth || height != originalHeight {
                edits.append(.crop(x: x, y: y, width: width, height: height))
            }
        }

        if state.flipH { edits.append(.mirror(axis: "horizontal")) }
        if state.flipV { edits.append(.mirror(axis: "vertical")) }

        let rotation = state.normalizedRotation
        if rotation != 0 { edits.append(.rotate(angle: rotation)) }

        return edits
    }

    private static func clampPixel(_ fraction: CGFloat, span: Int) -> Int {
        max(0, min(Int((fraction * CGFloat(span)).rounded(.towardZero)), span))
    }

    /// left-multiplies the accumulator: total = edit x total.
    private static func multiplyLeft(
        _ ea: Double, _ eb: Double, _ ec: Double, _ ed: Double,
        into a: inout Double, _ b: inout Double, _ c: inout Double, _ d: inout Double
    ) {
        let na = ea * a + eb * c
        let nb = ea * b + eb * d
        let nc = ec * a + ed * c
        let nd = ec * b + ed * d
        a = na; b = nb; c = nc; d = nd
    }
}

// MARK: - editor screen

/// how the editor closed. a save whose follow-up refresh failed still counts
/// as saved - it only lacks the new thumbhash.
nonisolated enum AssetEditOutcome {
    case cancelled
    case saved(AssetDetail?)
}

/// A local render that lets the viewer show the accepted edit intent while
/// the server replaces its derivative files.
nonisolated struct AssetEditProjection: Equatable, Sendable {
    let operationID: UUID
    let assetID: String
    let imageData: Data
}

enum AssetEditPreviewRenderer {
    static func render(_ image: UIImage, state: EditTransform.State) -> Data? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let uprightSize = CGSize(
            width: max(image.size.width * image.scale, 1),
            height: max(image.size.height * image.scale, 1)
        )
        let upright = UIGraphicsImageRenderer(size: uprightSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: uprightSize))
        }
        guard let source = upright.cgImage else { return nil }

        let crop = state.crop.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let pixelCrop = CGRect(
            x: crop.minX * CGFloat(source.width),
            y: crop.minY * CGFloat(source.height),
            width: crop.width * CGFloat(source.width),
            height: crop.height * CGFloat(source.height)
        ).integral
        guard pixelCrop.width > 0, pixelCrop.height > 0,
              let cropped = source.cropping(to: pixelCrop)
        else { return nil }

        let input = UIImage(cgImage: cropped)
        let radians = CGFloat(state.normalizedRotation * .pi / 180)
        let rawCosine = abs(cos(radians))
        let rawSine = abs(sin(radians))
        let cosine: CGFloat = rawCosine < 0.000_001 ? 0 : rawCosine
        let sine: CGFloat = rawSine < 0.000_001 ? 0 : rawSine
        let outputSize = CGSize(
            width: max(input.size.width * cosine + input.size.height * sine, 1),
            height: max(input.size.width * sine + input.size.height * cosine, 1)
        )
        let rendered = UIGraphicsImageRenderer(size: outputSize, format: format).image { context in
            let cg = context.cgContext
            cg.translateBy(x: outputSize.width / 2, y: outputSize.height / 2)
            cg.rotate(by: radians)
            cg.scaleBy(x: state.flipH ? -1 : 1, y: state.flipV ? -1 : 1)
            input.draw(in: CGRect(
                x: -input.size.width / 2,
                y: -input.size.height / 2,
                width: input.size.width,
                height: input.size.height
            ))
        }
        return rendered.pngData()
    }
}

/// native crop, rotate and mirror editor over the server-side edit list. the
/// picture itself is never re-encoded on device: the server re-renders.
struct AssetEditScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let onProjected: (AssetEditProjection) -> Void
    let onReverted: (UUID) -> Void
    let onCommitted: (UUID, AssetDetail?) -> Void
    let onFinished: (AssetEditOutcome) -> Void

    init(
        asset: Asset,
        onProjected: @escaping (AssetEditProjection) -> Void = { _ in },
        onReverted: @escaping (UUID) -> Void = { _ in },
        onCommitted: @escaping (UUID, AssetDetail?) -> Void = { _, _ in },
        onFinished: @escaping (AssetEditOutcome) -> Void
    ) {
        self.asset = asset
        self.onProjected = onProjected
        self.onReverted = onReverted
        self.onCommitted = onCommitted
        self.onFinished = onFinished
    }

    private enum LoadState {
        case loading
        case failed(String)
        case ready
    }

    @State private var loadState = LoadState.loading
    @State private var image: UIImage?
    @State private var originalWidth = 0
    @State private var originalHeight = 0
    @State private var state = EditTransform.State()
    @State private var initialState = EditTransform.State()
    @State private var hadServerEdits = false
    @State private var aspect = EditAspect.free
    @State private var isSaving = false
    @State private var showDiscard = false

    private var hasChanges: Bool { state != initialState }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                switch loadState {
                case .loading:
                    ProgressView()
                        .tint(.white)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Couldn't Load Photo", systemImage: "exclamationmark.circle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                case .ready:
                    if let image {
                        editorBody(image)
                    }
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        guard !isSaving else { return }
                        if hasChanges {
                            showDiscard = true
                        } else {
                            finish(.cancelled)
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("edit-cancel")
                    // ios 26 morphs the dialog out of its source control, so it
                    // belongs on Cancel - from the screen root it anchors to the
                    // window and floats detached.
                    .confirmationDialog(
                        "Discard Edits?",
                        isPresented: $showDiscard,
                        titleVisibility: .visible
                    ) {
                        Button("Discard Changes", role: .destructive) {
                            guard !isSaving else { return }
                            finish(.cancelled)
                        }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Button("Done") { beginSave() }
                            .fontWeight(.semibold)
                            .disabled(!hasChanges)
                            .accessibilityIdentifier("edit-done")
                    }
                }
            }
        }
        // scoped to this subtree: preferredColorScheme is a window preference
        // and would leave the whole app dark after the cover is dismissed.
        .environment(\.colorScheme, .dark)
        .interactiveDismissDisabled(hasChanges || isSaving)
        .task { await load() }
    }

    // MARK: - layout

    private func editorBody(_ image: UIImage) -> some View {
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let rotated = state.normalizedRotation.truncatingRemainder(dividingBy: 180) != 0
                let available = CGSize(
                    width: max(proxy.size.width - 24, 1),
                    height: max(proxy.size.height - 24, 1)
                )
                let fitBox = rotated
                    ? CGSize(width: available.height, height: available.width)
                    : available
                let canvasSize = Self.aspectFit(CGSize(width: image.size.width, height: image.size.height), into: fitBox)

                CropCanvas(
                    image: image,
                    crop: $state.crop,
                    lockedAspect: canvasAspectRatio,
                    isEnabled: canCrop && !isSaving
                )
                .frame(width: canvasSize.width, height: canvasSize.height)
                .scaleEffect(x: state.flipH ? -1 : 1, y: state.flipV ? -1 : 1)
                .rotationEffect(.degrees(state.rotation))
                .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }

            controls
        }
        .allowsHitTesting(!isSaving)
    }

    /// aspect the crop must keep in canvas space: the visual pick, inverted
    /// while the canvas is rotated sideways.
    private var canvasAspectRatio: CGFloat? { canvasAspectRatio(for: aspect) }

    private func canvasAspectRatio(for choice: EditAspect) -> CGFloat? {
        guard let image else { return nil }
        let originalAspect = image.size.width / max(image.size.height, 1)
        guard let visual = choice.ratio(originalAspect: originalAspect) else { return nil }
        let rotated = state.normalizedRotation.truncatingRemainder(dividingBy: 180) != 0
        return rotated ? 1 / visual : visual
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                HStack(spacing: 4) {
                    editorButton("rotate.left", label: "Rotate left") {
                        withAnimation(.smooth(duration: 0.3)) {
                            state.rotation -= 90
                            reapplyAspect()
                        }
                    }
                    editorButton("rotate.right", label: "Rotate right") {
                        withAnimation(.smooth(duration: 0.3)) {
                            state.rotation += 90
                            reapplyAspect()
                        }
                    }
                }

                Spacer()

                Button("Reset") {
                    withAnimation(.smooth(duration: 0.3)) {
                        state = EditTransform.State()
                        aspect = .free
                    }
                }
                .font(.subheadline.weight(.medium))
                .disabled(state.isIdentity)
                .accessibilityIdentifier("edit-reset")

                Spacer()

                HStack(spacing: 4) {
                    editorButton("arrow.left.and.right.righttriangle.left.righttriangle.right", label: "Flip horizontal") {
                        withAnimation(.smooth(duration: 0.25)) {
                            if state.normalizedRotation.truncatingRemainder(dividingBy: 180) == 0 {
                                state.flipH.toggle()
                            } else {
                                state.flipV.toggle()
                            }
                        }
                    }
                    editorButton("arrow.up.and.down.righttriangle.up.righttriangle.down", label: "Flip vertical") {
                        withAnimation(.smooth(duration: 0.25)) {
                            if state.normalizedRotation.truncatingRemainder(dividingBy: 180) == 0 {
                                state.flipV.toggle()
                            } else {
                                state.flipH.toggle()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)

            if canCrop {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(EditAspect.allCases) { choice in
                        Button {
                            aspect = choice
                            applyAspect(choice)
                        } label: {
                            Text(choice.title)
                                .font(.footnote.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(
                                    aspect == choice ? AnyShapeStyle(.white.opacity(0.25)) : AnyShapeStyle(.white.opacity(0.08)),
                                    in: .capsule
                                )
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
            }
        }
        .padding(.vertical, 14)
        .background(.black)
    }

    private func editorButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    /// largest centered crop with the chosen ratio.
    private func applyAspect(_ choice: EditAspect) {
        guard let ratio = canvasAspectRatio(for: choice), let image else {
            return
        }
        let imageAspect = image.size.width / max(image.size.height, 1)
        var width: CGFloat = 1
        var height: CGFloat = 1
        // normalized space is stretched by the image aspect: a crop with
        // visual ratio r spans w/h = r/imageaspect in normalized units.
        let normalizedRatio = ratio / imageAspect
        if normalizedRatio >= 1 {
            height = 1 / normalizedRatio
        } else {
            width = normalizedRatio
        }
        withAnimation(.smooth(duration: 0.25)) {
            state.crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
        }
    }

    private func reapplyAspect() {
        guard aspect != .free else { return }
        applyAspect(aspect)
    }

    // MARK: - loading and saving

    private func load() async {
        guard let client = session.client else { return }
        loadState = .loading
        do {
            // the editor always starts from the unedited picture and replays
            // stored edits as ui state, like the official clients.
            let url = client.thumbnailURL(assetID: asset.id, size: "preview", edited: false)
            async let imageTask = ImageLoader.shared.image(for: url, targetPixelSize: 2048)
            async let detailTask = client.assetDetail(id: asset.id)
            async let editsTask = client.assetEdits(id: asset.id)

            let image = try await imageTask
            let detail = try await detailTask
            // saving replaces the whole edit list, so an unreadable one must
            // not be mistaken for an empty one: that would silently drop a
            // crop the asset already carries.
            let edits: [AssetEdit]
            do {
                edits = try await editsTask
            } catch {
                guard detail.isEdited != true else {
                    loadState = .failed("This photo's existing edits could not be loaded.")
                    return
                }
                edits = []
            }

            let (width, height) = Self.resolveOriginalSize(detail: detail, image: image)
            // an existing crop that cannot be placed would be seeded as the
            // full frame and then written back as none, quietly undoing it.
            let hasCrop = edits.contains { if case .crop = $0 { true } else { false } }
            guard width > 0 || !hasCrop else {
                loadState = .failed("This photo's original dimensions are unknown, so its crop can't be edited.")
                return
            }

            self.image = image
            (originalWidth, originalHeight) = (width, height)
            let seeded = EditTransform.state(from: edits, originalWidth: originalWidth, originalHeight: originalHeight)
            state = seeded
            initialState = seeded
            hadServerEdits = !edits.isEmpty
            loadState = .ready
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

    /// crop parameters are pixels in the upright original, so exif is the
    /// source of truth: the asset's own width and height already describe the
    /// EDITED output, and normalizing a stored crop against those would place
    /// it in a space that no longer exists. the asset dims are only a safe
    /// fallback while nothing is applied on top. the exif pair can be
    /// pre-rotation, so trust whichever orientation matches the upright
    /// render. zeros mean unknown - the preview is downsampled, so its own
    /// size would put crops in the wrong space entirely.
    private static func resolveOriginalSize(detail: AssetDetail, image: UIImage) -> (Int, Int) {
        var width = Int(detail.exifInfo?.exifImageWidth ?? 0)
        var height = Int(detail.exifInfo?.exifImageHeight ?? 0)
        if width <= 0 || height <= 0, detail.isEdited != true {
            width = detail.width ?? 0
            height = detail.height ?? 0
        }
        guard width > 0, height > 0 else { return (0, 0) }
        let imageAspect = Double(image.size.width / max(image.size.height, 1))
        let straight = Double(width) / Double(height)
        let swapped = Double(height) / Double(width)
        if abs(imageAspect - swapped) < abs(imageAspect - straight) {
            swap(&width, &height)
        }
        return (width, height)
    }

    /// cropping needs the true pixel size to express the rect in.
    private var canCrop: Bool { originalWidth > 0 && originalHeight > 0 }

    private func beginSave() {
        guard !isSaving, hasChanges,
              let client = session.client,
              let image
        else { return }
        isSaving = true
        showDiscard = false
        let savedState = state
        let edits = EditTransform.edits(
            from: savedState,
            originalWidth: originalWidth,
            originalHeight: originalHeight
        )
        if edits.isEmpty, !hadServerEdits {
            isSaving = false
            finish(.cancelled)
            return
        }
        guard let preview = AssetEditPreviewRenderer.render(image, state: savedState) else {
            isSaving = false
            ErrorToastCenter.shared.show("Couldn’t prepare the edited preview.")
            return
        }

        let operationID = UUID()
        let projection = AssetEditProjection(
            operationID: operationID,
            assetID: asset.id,
            imageData: preview
        )
        let realtime = session.realtime
        onProjected(projection)
        dismiss()
        Task {
            await persist(
                edits: edits,
                operationID: operationID,
                client: client,
                realtime: realtime
            )
        }
    }

    private func persist(
        edits: [AssetEdit],
        operationID: UUID,
        client: ImmichClient,
        realtime: RealtimeHub?
    ) async {
        do {
            if edits.isEmpty {
                try await client.clearEdits(id: asset.id)
            } else {
                try await client.applyEdits(id: asset.id, edits: edits)
            }

            // hold until the server re-rendered derivatives, like the
            // official client; falls through after ten seconds regardless.
            if let realtime {
                _ = await realtime.waitForAssetEvent(
                    named: ["AssetEditReadyV2", "AssetEditReadyV1"],
                    assetID: asset.id,
                    timeout: .seconds(10)
                )
            }

            // the write already succeeded, so a failed refresh only costs the
            // new thumbhash - it must not read as a cancelled edit.
            let detail = try? await client.assetDetail(id: asset.id)
            onCommitted(operationID, detail)
            onFinished(.saved(detail))
        } catch {
            onReverted(operationID)
            ErrorToastCenter.shared.show("Couldn’t save the edits. The change was undone", error: error)
        }
    }

    private func finish(_ outcome: AssetEditOutcome) {
        onFinished(outcome)
        dismiss()
    }

    static func aspectFit(_ size: CGSize, into box: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return box }
        let scale = min(box.width / size.width, box.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}

// MARK: - crop canvas

/// fitted image with a draggable crop frame: corner and edge handles, thirds
/// grid, dimmed outside, optional locked aspect. crop is normalized 0...1.
struct CropCanvas: View {
    let image: UIImage
    @Binding var crop: CGRect
    var lockedAspect: CGFloat?
    var isEnabled = true

    private enum DragMode: Equatable {
        case move
        case corner(horizontal: Bool, vertical: Bool)
        case edge(Edge)
    }

    @State private var dragMode: DragMode?
    @State private var dragStartCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// smallest crop side in normalized units.
    private static let minSide: CGFloat = 0.1

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let frame = CGRect(
                x: crop.minX * size.width,
                y: crop.minY * size.height,
                width: crop.width * size.width,
                height: crop.height * size.height
            )

            ZStack {
                Image(uiImage: image)
                    .resizable()

                // dimmed surround with a clear window over the crop.
                Rectangle()
                    .fill(.black.opacity(0.55))
                    .mask {
                        Rectangle()
                            .overlay(alignment: .topLeading) {
                                Rectangle()
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.minX, y: frame.minY)
                                    .blendMode(.destinationOut)
                            }
                            .compositingGroup()
                    }

                if isEnabled {
                    cropFrame(frame)
                }
            }
            .contentShape(.rect)
            .gesture(cropGesture(size: size), isEnabled: isEnabled)
        }
    }

    private func cropFrame(_ frame: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            // thirds grid.
            Path { path in
                for step in 1..<3 {
                    let x = frame.minX + frame.width * CGFloat(step) / 3
                    path.move(to: CGPoint(x: x, y: frame.minY))
                    path.addLine(to: CGPoint(x: x, y: frame.maxY))
                    let y = frame.minY + frame.height * CGFloat(step) / 3
                    path.move(to: CGPoint(x: frame.minX, y: y))
                    path.addLine(to: CGPoint(x: frame.maxX, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.5)

            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)

            // photos-style corner brackets.
            ForEach(0..<4, id: \.self) { index in
                let isRight = index % 2 == 1
                let isBottom = index >= 2
                CornerBracket(isRight: isRight, isBottom: isBottom)
                    .stroke(.white, lineWidth: 3)
                    .frame(width: 20, height: 20)
                    .offset(
                        x: (isRight ? frame.maxX - 18.5 : frame.minX - 1.5),
                        y: (isBottom ? frame.maxY - 18.5 : frame.minY - 1.5)
                    )
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - gesture

    private func cropGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragMode == nil {
                    dragStartCrop = crop
                    dragMode = Self.mode(
                        at: value.startLocation,
                        frame: CGRect(
                            x: crop.minX * size.width,
                            y: crop.minY * size.height,
                            width: crop.width * size.width,
                            height: crop.height * size.height
                        )
                    )
                }
                guard let mode = dragMode else { return }
                let delta = CGSize(
                    width: value.translation.width / size.width,
                    height: value.translation.height / size.height
                )
                crop = Self.apply(
                    mode: mode,
                    delta: delta,
                    start: dragStartCrop,
                    aspect: lockedAspect.map { $0 * size.height / size.width }
                )
            }
            .onEnded { _ in
                dragMode = nil
            }
    }

    /// hit zones: corners beat edges beat inside; outside the frame pans
    /// nothing.
    private static func mode(at point: CGPoint, frame: CGRect) -> DragMode? {
        let grip: CGFloat = 28
        let nearLeft = abs(point.x - frame.minX) < grip
        let nearRight = abs(point.x - frame.maxX) < grip
        let nearTop = abs(point.y - frame.minY) < grip
        let nearBottom = abs(point.y - frame.maxY) < grip
        let insideX = point.x > frame.minX - grip && point.x < frame.maxX + grip
        let insideY = point.y > frame.minY - grip && point.y < frame.maxY + grip

        if nearLeft, nearTop { return .corner(horizontal: false, vertical: false) }
        if nearRight, nearTop { return .corner(horizontal: true, vertical: false) }
        if nearLeft, nearBottom { return .corner(horizontal: false, vertical: true) }
        if nearRight, nearBottom { return .corner(horizontal: true, vertical: true) }
        if nearLeft, insideY { return .edge(.leading) }
        if nearRight, insideY { return .edge(.trailing) }
        if nearTop, insideX { return .edge(.top) }
        if nearBottom, insideX { return .edge(.bottom) }
        if frame.contains(point) { return .move }
        return nil
    }

    /// aspect here is normalized-space width over height.
    private static func apply(mode: DragMode, delta: CGSize, start: CGRect, aspect: CGFloat?) -> CGRect {
        var rect = start

        switch mode {
        case .move:
            rect.origin.x = min(max(0, start.minX + delta.width), 1 - start.width)
            rect.origin.y = min(max(0, start.minY + delta.height), 1 - start.height)
            return rect

        case .corner(let isRight, let isBottom):
            var newWidth = start.width + (isRight ? delta.width : -delta.width)
            var newHeight = start.height + (isBottom ? delta.height : -delta.height)
            newWidth = max(minSide, newWidth)
            newHeight = max(minSide, newHeight)

            if let aspect {
                // let the dominant axis lead, derive the other.
                if abs(delta.width) >= abs(delta.height) {
                    newHeight = newWidth / aspect
                } else {
                    newWidth = newHeight * aspect
                }
                if newHeight < minSide {
                    newHeight = minSide
                    newWidth = newHeight * aspect
                }
                if newWidth < minSide {
                    newWidth = minSide
                    newHeight = newWidth / aspect
                }
            }

            // anchor the opposite corner.
            let anchorX = isRight ? start.minX : start.maxX
            let anchorY = isBottom ? start.minY : start.maxY
            var minX = isRight ? anchorX : anchorX - newWidth
            var minY = isBottom ? anchorY : anchorY - newHeight

            // clamp inside the unit square, shrinking if the anchor pins us.
            if minX < 0 { newWidth += minX; minX = 0 }
            if minY < 0 { newHeight += minY; minY = 0 }
            if minX + newWidth > 1 { newWidth = 1 - minX }
            if minY + newHeight > 1 { newHeight = 1 - minY }
            if let aspect {
                let fromWidth = newWidth / aspect
                if fromWidth <= newHeight {
                    newHeight = fromWidth
                } else {
                    newWidth = newHeight * aspect
                }
                if !isRight { minX = anchorX - newWidth }
                if !isBottom { minY = anchorY - newHeight }
            }
            return sanitize(CGRect(x: minX, y: minY, width: newWidth, height: newHeight), aspect: aspect)

        case .edge(let edge):
            switch edge {
            // the far edge is the anchor, so it also caps how far this one can
            // travel. max(0,) keeps that cap valid when the anchor itself sits
            // closer to the origin than the minimum side.
            case .leading:
                let newMinX = min(max(0, start.minX + delta.width), max(0, start.maxX - minSide))
                rect.origin.x = newMinX
                rect.size.width = start.maxX - newMinX
            case .trailing:
                rect.size.width = min(max(minSide, start.width + delta.width), 1 - start.minX)
            case .top:
                let newMinY = min(max(0, start.minY + delta.height), max(0, start.maxY - minSide))
                rect.origin.y = newMinY
                rect.size.height = start.maxY - newMinY
            case .bottom:
                rect.size.height = min(max(minSide, start.height + delta.height), 1 - start.minY)
            }

            if let aspect {
                // edges keep the perpendicular dimension centered.
                switch edge {
                case .leading, .trailing:
                    let newHeight = min(rect.width / aspect, 1)
                    let centerY = start.midY
                    rect.origin.y = min(max(0, centerY - newHeight / 2), max(0, 1 - newHeight))
                    rect.size.height = newHeight
                    rect.size.width = newHeight * aspect
                    if edge == .leading { rect.origin.x = start.maxX - rect.width }
                case .top, .bottom:
                    let newWidth = min(rect.height * aspect, 1)
                    let centerX = start.midX
                    rect.origin.x = min(max(0, centerX - newWidth / 2), max(0, 1 - newWidth))
                    rect.size.width = newWidth
                    rect.size.height = newWidth / aspect
                    if edge == .top { rect.origin.y = start.maxY - rect.height }
                }
            }
            return sanitize(rect, aspect: aspect)
        }
    }

    /// last line of defence for the resize branches: the crop must stay inside
    /// the unit square with usable sides, because the saved pixel rect is
    /// derived from it and a rect poking outside would cut a region the user
    /// never framed.
    private static func sanitize(_ rect: CGRect, aspect: CGFloat?) -> CGRect {
        var width = min(max(rect.width, minSide), 1)
        var height = min(max(rect.height, minSide), 1)

        if let aspect, aspect > 0 {
            // grow the short side back to the locked ratio, then shrink both
            // if that pushed past the unit square.
            height = width / aspect
            if height < minSide {
                height = minSide
                width = height * aspect
            }
            if width > 1 {
                width = 1
                height = width / aspect
            }
            if height > 1 {
                height = 1
                width = height * aspect
            }
            width = min(width, 1)
            height = min(height, 1)
        }

        return CGRect(
            x: min(max(0, rect.minX), 1 - width),
            y: min(max(0, rect.minY), 1 - height),
            width: width,
            height: height
        )
    }
}

/// one l-shaped crop corner.
private nonisolated struct CornerBracket: Shape {
    let isRight: Bool
    let isBottom: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let x = isRight ? rect.maxX : rect.minX
        let y = isBottom ? rect.maxY : rect.minY
        path.move(to: CGPoint(x: x, y: isBottom ? y - rect.height : y + rect.height))
        path.addLine(to: CGPoint(x: x, y: y))
        path.addLine(to: CGPoint(x: isRight ? x - rect.width : x + rect.width, y: y))
        return path
    }
}

// MARK: - profile picture crop

/// square crop over the rendered picture, uploaded as the account's profile
/// image.
struct ProfilePictureCropScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SessionStore.self) private var session

    let asset: Asset
    let onDone: (String) -> Void

    @State private var image: UIImage?
    /// seeded from the image aspect once it loads: normalized space is
    /// stretched, so a literal square rect here would not be a square crop.
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    GeometryReader { proxy in
                        let available = CGSize(width: max(proxy.size.width - 24, 1), height: max(proxy.size.height - 24, 1))
                        let canvasSize = AssetEditScreen.aspectFit(image.size, into: available)
                        CropCanvas(image: image, crop: $crop, lockedAspect: 1)
                            .frame(width: canvasSize.width, height: canvasSize.height)
                            .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                    }
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Profile Picture")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(image == nil || session.isProfileImageMutationInFlight)
                            .accessibilityIdentifier("profile-crop-save")
                    }
                }
            }
            .alert(error ?? "", isPresented: Binding(
                get: { error != nil },
                set: { if !$0 { error = nil } }
            )) {
                Button("OK", role: .cancel) {}
            }
        }
        // scoped to this subtree: preferredColorScheme is a window preference
        // and would leave the whole app dark after the cover is dismissed.
        .environment(\.colorScheme, .dark)
        .task { await load() }
    }

    private func load() async {
        guard let client = session.client else { return }
        let url = client.thumbnailURL(assetID: asset.id, size: "preview")
        let loaded = try? await ImageLoader.shared.image(for: url, targetPixelSize: 2048)
        guard let loaded else {
            error = "Could not load the photo."
            return
        }
        image = loaded
        // largest centered square: a visual 1:1 spans 1/imageAspect wide in
        // normalized units, so the picture's own proportions decide which
        // side is the full one.
        let imageAspect = loaded.size.width / max(loaded.size.height, 1)
        var width: CGFloat = 1
        var height: CGFloat = 1
        let normalized = 1 / imageAspect
        if normalized >= 1 {
            height = 1 / normalized
        } else {
            width = normalized
        }
        crop = CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func save() async {
        guard let client = session.client, let image, let cgImage = image.cgImage else { return }
        isSaving = true
        defer { isSaving = false }

        let pixelWidth = CGFloat(cgImage.width)
        let pixelHeight = CGFloat(cgImage.height)
        let cropped = cgImage.cropping(to: CGRect(
            x: crop.minX * pixelWidth,
            y: crop.minY * pixelHeight,
            width: crop.width * pixelWidth,
            height: crop.height * pixelHeight
        ).integral) ?? cgImage

        guard let data = UIImage(cgImage: cropped).pngData() else {
            ErrorToastCenter.shared.show("Couldn’t prepare the profile picture.")
            return
        }

        guard let projection = session.beginProfileImageMutation(data: data) else { return }
        dismiss()
        do {
            try await client.setProfileImage(data: data, filename: "profile-picture.png", mimeType: "image/png")
            await session.refreshUser()
            let cacheKey = UUID().uuidString
            guard session.acceptProfileImageMutation(projection, cacheKey: cacheKey) else { return }
            var canonicalImageIsCached = false
            if let user = session.user {
                let url = client.profileImageURL(userID: user.id)
                    .appending(queryItems: [URLQueryItem(name: "c", value: cacheKey)])
                canonicalImageIsCached = (try? await ImageLoader.shared.image(
                    for: url,
                    targetPixelSize: 120
                )) != nil
            }
            session.finishProfileImageMutation(
                projection,
                canonicalImageIsCached: canonicalImageIsCached
            )
            onDone("Profile picture updated")
        } catch {
            session.rollbackProfileImageMutation(projection)
            ErrorToastCenter.shared.show("Couldn’t set the profile picture", error: error)
        }
    }
}

import Observation
import SwiftUI
import UIKit

@MainActor
struct AssetViewerOpeningChromePresentation: Hashable {
    enum Kind: Hashable {
        case local
        case remote
        case trashed
    }

    let assetID: String
    let title: String
    let subtitle: String
    let backupSymbol: String?
    let kind: Kind
    let showsShare: Bool
    let showsFavorite: Bool
    let favoriteSymbol: String
    let showsEdit: Bool
    let showsDelete: Bool
    let showsRestore: Bool
    let showsPermanentDelete: Bool

    static let placeholder = Self(
        assetID: "",
        title: "Today",
        subtitle: "",
        backupSymbol: "checkmark.icloud",
        kind: .remote,
        showsShare: true,
        showsFavorite: true,
        favoriteSymbol: "heart",
        showsEdit: true,
        showsDelete: true,
        showsRestore: false,
        showsPermanentDelete: false
    )

    init(asset: Asset, session: SessionStore) {
        let localID = asset.localIdentifier
        let remoteID = localID.flatMap { session.backup?.remoteIdentifierByLocalId[$0] }
        let pairedLocalID = localID
            ?? session.backup?.pairedLocalIdentifierByRemoteId[asset.id]
        let ownsAsset = asset.isLocal
            || session.user?.id == nil
            || session.user?.id == asset.ownerId
        let availability = AssetActionAvailability(
            asset: asset,
            ownsAsset: ownsAsset,
            localRemoteIdentifier: remoteID,
            pairedLocalIdentifier: pairedLocalID
        )
        let labels = Self.labels(for: asset)

        assetID = asset.id
        title = labels.title
        subtitle = labels.subtitle
        backupSymbol = Self.backupSymbol(for: asset, session: session, remoteID: remoteID)
        kind = asset.isLocal ? .local : asset.isTrashed ? .trashed : .remote
        showsShare = asset.isLocal ? localID != nil : session.client != nil
        showsFavorite = availability.canFavorite
        favoriteSymbol = asset.isFavorite ? "heart.fill" : "heart"
        showsEdit = availability.canEdit
        showsDelete = availability.canDeleteFromDevice || availability.canTrashEverywhere
        showsRestore = availability.canRestore
        showsPermanentDelete = availability.canDeletePermanently
    }

    private init(
        assetID: String,
        title: String,
        subtitle: String,
        backupSymbol: String?,
        kind: Kind,
        showsShare: Bool,
        showsFavorite: Bool,
        favoriteSymbol: String,
        showsEdit: Bool,
        showsDelete: Bool,
        showsRestore: Bool,
        showsPermanentDelete: Bool
    ) {
        self.assetID = assetID
        self.title = title
        self.subtitle = subtitle
        self.backupSymbol = backupSymbol
        self.kind = kind
        self.showsShare = showsShare
        self.showsFavorite = showsFavorite
        self.favoriteSymbol = favoriteSymbol
        self.showsEdit = showsEdit
        self.showsDelete = showsDelete
        self.showsRestore = showsRestore
        self.showsPermanentDelete = showsPermanentDelete
    }

    private static func labels(for asset: Asset) -> (title: String, subtitle: String) {
        let date = asset.localDate
        let day = relativeDayLabel(for: date) ?? date.formatted(dateTitleFormat(for: date))
        let time = date.formatted(.dateTime.hour().minute().utc())
        guard let place = asset.city ?? asset.country else {
            return (day, time)
        }
        return (place, "\(day), \(time)")
    }

    private static func relativeDayLabel(for date: Date) -> String? {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Date().addingTimeInterval(TimeInterval(TimeZone.current.secondsFromGMT()))
        if calendar.isDate(date, inSameDayAs: today) { return String(localized: "Today") }
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
              calendar.isDate(date, inSameDayAs: yesterday)
        else { return nil }
        return String(localized: "Yesterday")
    }

    private static func dateTitleFormat(for date: Date) -> Date.FormatStyle {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().utc()
        guard calendar.component(.year, from: date) != calendar.component(.year, from: Date()) else {
            return style
        }
        return style.year()
    }

    private static func backupSymbol(
        for asset: Asset,
        session: SessionStore,
        remoteID: String?
    ) -> String? {
        if let localID = asset.localIdentifier {
            switch session.backup?.uploadStates[localID] {
            case .uploading:
                return "icloud.and.arrow.up"
            case .failed:
                return "exclamationmark.icloud"
            case nil:
                return asset.isLocalBackedUp || remoteID != nil
                    ? "checkmark.icloud"
                    : "icloud.slash"
            }
        }
        return asset.isTrashed ? nil : "checkmark.icloud"
    }
}

@MainActor
@Observable
private final class AssetViewerOpeningChromeModel {
    var presentation = AssetViewerOpeningChromePresentation.placeholder
}

@MainActor
private struct AssetViewerOpeningChromeSource: View {
    let model: AssetViewerOpeningChromeModel

    var body: some View {
        NavigationStack {
            Color.clear
                .ignoresSafeArea()
                .toolbar { toolbarContent }
                .toolbarVisibility(.visible, for: .navigationBar, .bottomBar)
                .toolbarBackgroundVisibility(.hidden, for: .navigationBar, .bottomBar)
                .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
                .navigationBarTitleDisplayMode(.inline)
        }
        .containerBackground(Color.clear, for: .navigation)
        .tint(.white)
        .preferredColorScheme(.dark)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        let presentation = model.presentation

        ToolbarItem(placement: .topBarLeading) {
            Button {} label: {
                Image(systemName: "chevron.backward")
            }
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 1) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(presentation.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: 136, idealWidth: 156, maxWidth: 210)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .glassEffect(.regular, in: .capsule)
        }

        ToolbarItemGroup(placement: .topBarTrailing) {
            if let symbol = presentation.backupSymbol {
                Image(systemName: symbol)
            }
            Button {} label: {
                Image(systemName: "ellipsis")
            }
        }

        switch presentation.kind {
        case .local:
            localToolbarItems(presentation)
        case .remote:
            remoteToolbarItems(presentation)
        case .trashed:
            trashedToolbarItems(presentation)
        }
    }

    @ToolbarContentBuilder
    private func remoteToolbarItems(
        _ presentation: AssetViewerOpeningChromePresentation
    ) -> some ToolbarContent {
        if presentation.showsShare {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "square.and.arrow.up")
            }
        }

        ToolbarSpacer(.flexible, placement: .bottomBar)

        if presentation.showsFavorite {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: presentation.favoriteSymbol)
            }
            ToolbarSpacer(.fixed, placement: .bottomBar)
        }

        ToolbarItem(placement: .bottomBar) {
            Image(systemName: "info.circle")
        }

        if presentation.showsEdit {
            ToolbarSpacer(.fixed, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "slider.horizontal.3")
            }
        }

        if presentation.showsDelete {
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private func localToolbarItems(
        _ presentation: AssetViewerOpeningChromePresentation
    ) -> some ToolbarContent {
        if presentation.showsShare {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Image(systemName: "info.circle")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        if presentation.showsDelete {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "trash")
            }
        }
    }

    @ToolbarContentBuilder
    private func trashedToolbarItems(
        _ presentation: AssetViewerOpeningChromePresentation
    ) -> some ToolbarContent {
        if presentation.showsRestore {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "arrow.uturn.backward")
            }
        }
        if presentation.showsRestore, presentation.showsPermanentDelete {
            ToolbarSpacer(.flexible, placement: .bottomBar)
        }
        if presentation.showsPermanentDelete {
            ToolbarItem(placement: .bottomBar) {
                Image(systemName: "trash")
            }
        }
    }
}

@MainActor
private struct AssetViewerOpeningChromeGeometry: Equatable {
    let bounds: CGRect
    let safeAreaInsets: UIEdgeInsets
    let displayScale: CGFloat
    let horizontalSizeClass: Int
    let verticalSizeClass: Int
    let contentSizeCategory: String
    let layoutDirection: Int

    init(window: UIWindow, traits: UITraitCollection) {
        bounds = window.bounds
        safeAreaInsets = window.safeAreaInsets
        displayScale = window.screen.scale
        horizontalSizeClass = traits.horizontalSizeClass.rawValue
        verticalSizeClass = traits.verticalSizeClass.rawValue
        contentSizeCategory = traits.preferredContentSizeCategory.rawValue
        layoutDirection = traits.layoutDirection.rawValue
    }
}

@MainActor
private final class AssetViewerOpeningChromeRendererController:
    UIHostingController<AssetViewerOpeningChromeSource>
{
    let model: AssetViewerOpeningChromeModel

    init() {
        let model = AssetViewerOpeningChromeModel()
        self.model = model
        super.init(rootView: AssetViewerOpeningChromeSource(model: model))
    }

    @available(*, unavailable)
    required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        AssetViewerOpeningChromeCache.shared.register(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        if view.window == nil {
            AssetViewerOpeningChromeCache.shared.unregister(self)
        }
        super.viewDidDisappear(animated)
    }

    var geometry: AssetViewerOpeningChromeGeometry? {
        guard let window = view.window else { return nil }
        return AssetViewerOpeningChromeGeometry(window: window, traits: traitCollection)
    }

    func stage(_ presentation: AssetViewerOpeningChromePresentation) {
        model.presentation = presentation
        view.setNeedsLayout()
    }

    func capture(
        _ presentation: AssetViewerOpeningChromePresentation
    ) -> AssetViewerPreparedOpeningChrome? {
        guard let window = view.window,
              let geometry,
              !view.bounds.isEmpty
        else { return nil }
        guard model.presentation == presentation else { return nil }
        view.layoutIfNeeded()
        guard let snapshot = view.snapshotView(afterScreenUpdates: true) else { return nil }

        snapshot.frame = view.bounds
        snapshot.isUserInteractionEnabled = false
        snapshot.accessibilityElementsHidden = true

        let topHeight = min(view.bounds.height, view.safeAreaInsets.top + 64)
        let bottomHeight = min(view.bounds.height, view.safeAreaInsets.bottom + 60)
        let path = UIBezierPath(
            rect: CGRect(x: 0, y: 0, width: view.bounds.width, height: topHeight)
        )
        path.append(
            UIBezierPath(
                rect: CGRect(
                    x: 0,
                    y: view.bounds.height - bottomHeight,
                    width: view.bounds.width,
                    height: bottomHeight
                )
            )
        )
        let mask = CAShapeLayer()
        mask.frame = snapshot.bounds
        mask.path = path.cgPath
        snapshot.layer.mask = mask

        return AssetViewerPreparedOpeningChrome(
            presentation: presentation,
            sourceWindow: window,
            geometry: geometry,
            frameInWindow: view.convert(view.bounds, to: window),
            safeAreaInsets: view.safeAreaInsets,
            snapshot: snapshot
        )
    }
}

@MainActor
private struct AssetViewerPreparedOpeningChrome {
    let presentation: AssetViewerOpeningChromePresentation
    weak var sourceWindow: UIWindow?
    let geometry: AssetViewerOpeningChromeGeometry
    let frameInWindow: CGRect
    let safeAreaInsets: UIEdgeInsets
    let snapshot: UIView
}

@MainActor
final class AssetViewerOpeningChromeOverlay: UIView {
    private let chromeView: UIView
    private let topShield = UIView()
    private let bottomShield = UIView()
    private let closeButton = UIButton(type: .custom)
    private let onClose: () -> Void

    init(
        frame: CGRect,
        snapshot: UIView,
        safeAreaInsets: UIEdgeInsets,
        onClose: @escaping () -> Void
    ) {
        chromeView = snapshot
        self.onClose = onClose
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        accessibilityViewIsModal = false

        let localBounds = CGRect(origin: .zero, size: frame.size)
        topShield.frame = CGRect(
            x: 0,
            y: 0,
            width: localBounds.width,
            height: min(localBounds.height, safeAreaInsets.top + 64)
        )
        bottomShield.frame = CGRect(
            x: 0,
            y: max(0, localBounds.height - safeAreaInsets.bottom - 60),
            width: localBounds.width,
            height: min(localBounds.height, safeAreaInsets.bottom + 60)
        )
        for shield in [topShield, bottomShield] {
            shield.backgroundColor = .black
            shield.alpha = 0
            shield.isUserInteractionEnabled = false
            addSubview(shield)
        }

        chromeView.frame = localBounds
        chromeView.alpha = 0
        addSubview(chromeView)

        closeButton.frame = CGRect(
            x: 8,
            y: max(0, safeAreaInsets.top - 8),
            width: 60,
            height: 60
        )
        closeButton.backgroundColor = .clear
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityIdentifier = "viewer-close"
        closeButton.addTarget(self, action: #selector(close), for: .touchUpInside)
        addSubview(closeButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        closeButton.frame.contains(point)
    }

    func reveal() {
        chromeView.alpha = 1
    }

    func prepareForHandoff() {
        topShield.alpha = 1
        bottomShield.alpha = 1
    }

    @objc private func close() {
        onClose()
    }
}

@MainActor
final class AssetViewerOpeningChromeCache {
    static let shared = AssetViewerOpeningChromeCache()

    private weak var renderer: AssetViewerOpeningChromeRendererController?
    private var preparedByAssetID: [String: AssetViewerPreparedOpeningChrome] = [:]
    private var preparationOrder: [String] = []
    private var requestedPresentations: [AssetViewerOpeningChromePresentation] = []
    private var requestOwner: UUID?
    private var prewarmTask: Task<Void, Never>?
    private var generation = 0

    private let maximumPreparedCount = 8
    private let maximumVisibleCount = 8
    private let prewarmDelay = Duration.milliseconds(240)
    private let renderSettleDelay = Duration.milliseconds(34)

    private init() {}

    fileprivate func register(_ renderer: AssetViewerOpeningChromeRendererController) {
        self.renderer = renderer
        schedulePrewarmingIfNeeded()
    }

    fileprivate func unregister(_ renderer: AssetViewerOpeningChromeRendererController) {
        guard self.renderer === renderer else { return }
        self.renderer = nil
        cancelPrewarming()
        preparedByAssetID.removeAll()
        preparationOrder.removeAll()
    }

    func prewarm(owner: UUID, assets: [Asset], session: SessionStore) {
        var seen = Set<String>()
        var requested: [AssetViewerOpeningChromePresentation] = []
        requested.reserveCapacity(min(assets.count, maximumVisibleCount))
        for asset in assets where seen.insert(asset.id).inserted {
            requested.append(
                AssetViewerOpeningChromePresentation(asset: asset, session: session)
            )
            if requested.count == maximumVisibleCount { break }
        }
        let changed = requestOwner != owner || requested != requestedPresentations
        requestOwner = owner
        requestedPresentations = requested
        touchPreparedEntries(for: requested)
        guard changed || prewarmTask == nil else { return }
        schedulePrewarmingIfNeeded(restartsDelay: changed)
    }

    func cancelPrewarming(owner: UUID) {
        guard requestOwner == owner else { return }
        cancelPrewarming()
    }

    private func cancelPrewarming() {
        generation &+= 1
        prewarmTask?.cancel()
        prewarmTask = nil
    }

    func take(
        presentation: AssetViewerOpeningChromePresentation,
        in container: UIView,
        onClose: @escaping () -> Void
    ) -> AssetViewerOpeningChromeOverlay? {
        cancelPrewarming()
        let assetID = presentation.assetID
        guard let prepared = preparedByAssetID[assetID],
              prepared.presentation == presentation,
              let sourceWindow = prepared.sourceWindow,
              sourceWindow === container.window,
              prepared.geometry == AssetViewerOpeningChromeGeometry(
                window: sourceWindow,
                traits: container.traitCollection
              )
        else { return nil }
        preparedByAssetID[assetID] = nil
        preparationOrder.removeAll { $0 == assetID }
        let frame = container.convert(prepared.frameInWindow, from: sourceWindow)
        return AssetViewerOpeningChromeOverlay(
            frame: frame,
            snapshot: prepared.snapshot,
            safeAreaInsets: prepared.safeAreaInsets,
            onClose: onClose
        )
    }

    private func schedulePrewarmingIfNeeded(restartsDelay: Bool = false) {
        guard renderer != nil,
              requestedPresentations.contains(where: needsPreparation)
        else { return }
        if restartsDelay {
            generation &+= 1
            prewarmTask?.cancel()
            prewarmTask = nil
        }
        guard prewarmTask == nil else { return }
        let generation = generation
        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: self.prewarmDelay)
                try await self.prepareRequestedChrome(generation: generation)
            } catch {}
            guard self.generation == generation else { return }
            self.prewarmTask = nil
        }
    }

    private func prepareRequestedChrome(generation: Int) async throws {
        for presentation in requestedPresentations where needsPreparation(presentation) {
            try Task.checkCancellation()
            guard self.generation == generation, let renderer else { return }
            renderer.stage(presentation)
            try await Task.sleep(for: renderSettleDelay)
            try Task.checkCancellation()
            guard self.generation == generation,
                  requestedPresentations.contains(presentation),
                  let prepared = renderer.capture(presentation)
            else { continue }
            store(prepared)
            await Task.yield()
        }
    }

    private func needsPreparation(
        _ presentation: AssetViewerOpeningChromePresentation
    ) -> Bool {
        guard let prepared = preparedByAssetID[presentation.assetID],
              prepared.presentation == presentation,
              let renderer,
              prepared.sourceWindow === renderer.view.window,
              let geometry = renderer.geometry
        else { return true }
        return prepared.geometry != geometry
    }

    private func touchPreparedEntries(
        for presentations: [AssetViewerOpeningChromePresentation]
    ) {
        for presentation in presentations where !needsPreparation(presentation) {
            let assetID = presentation.assetID
            preparationOrder.removeAll { $0 == assetID }
            preparationOrder.append(assetID)
        }
    }

    private func store(_ prepared: AssetViewerPreparedOpeningChrome) {
        let assetID = prepared.presentation.assetID
        preparedByAssetID[assetID] = prepared
        preparationOrder.removeAll { $0 == assetID }
        preparationOrder.append(assetID)
        while preparationOrder.count > maximumPreparedCount {
            let evictedID = preparationOrder.removeFirst()
            preparedByAssetID[evictedID] = nil
        }
    }

}

struct AssetViewerOpeningChromePrewarmer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        AssetViewerOpeningChromeRendererController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

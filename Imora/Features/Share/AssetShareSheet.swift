import os
import Photos
import SwiftUI
import UniformTypeIdentifiers

private nonisolated enum AssetShareProviderLog {
    private static let logger = Logger(
        subsystem: "com.vexcited.imora",
        category: "share-provider"
    )

    static func activityCompleted(
        type: UIActivity.ActivityType?,
        completed: Bool,
        error: (any Error)?
    ) {
        let activity = type?.rawValue ?? "none"
        guard let error else {
            logger.info(
                "activity finished; type \(activity, privacy: .public); completed \(completed, privacy: .public)"
            )
            return
        }
        let nsError = error as NSError
        logger.error(
            "activity failed; type \(activity, privacy: .public); completed \(completed, privacy: .public); domain \(nsError.domain, privacy: .public); code \(nsError.code, privacy: .public); message \(nsError.localizedDescription, privacy: .private(mask: .hash))"
        )
    }

    static func lifecycle(
        _ event: String,
        requestID: UUID,
        owner: AnyObject? = nil
    ) {
        let ownerDescription = owner.map {
            String(describing: ObjectIdentifier($0))
        } ?? "none"
        logger.info(
            "lifecycle \(event, privacy: .public); request \(requestID.uuidString, privacy: .public); owner \(ownerDescription, privacy: .public)"
        )
    }
}
@MainActor
private final class AssetShareRequestLifecycle {
    var isFinished = false
}

/// one share: which assets, with the metadata options captured from the
/// saved defaults at creation. options apply once, at export time.
struct AssetShareRequest: Identifiable {
    let id = UUID()
    let assets: [Asset]
    let options: AssetShareOptions
    private let lifecycle = AssetShareRequestLifecycle()

    init(assets: [Asset], options: AssetShareOptions = .current) {
        self.assets = assets
        self.options = options
    }

    fileprivate var isFinished: Bool { lifecycle.isFinished }

    fileprivate func markFinished() {
        lifecycle.isFinished = true
    }
}

/// the system share sheet fed ready files: every selected asset exports up
/// front behind a blocking progress dialog, then the sheet receives
/// content-typed file urls that third-party recipients group and accept
/// reliably.
struct AssetSharePresenter: UIViewControllerRepresentable {
    @Environment(SessionStore.self) private var session
    @Binding var request: AssetShareRequest?
    /// fires once a recipient has actually taken the items, so the caller can
    /// close the sheet and drop its selection - not on a plain dismiss.
    var onShared: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> AssetSharePresentationHostController {
        let controller = AssetSharePresentationHostController()
        let coordinator = context.coordinator
        controller.onDidAppear = { [weak coordinator] controller in
            coordinator?.presentIfPossible(from: controller)
        }
        return controller
    }

    func updateUIViewController(
        _ controller: AssetSharePresentationHostController,
        context: Context
    ) {
        context.coordinator.update(
            parent: self,
            client: session.client,
            localIdentifierByRemoteID: session.backup?.localIdentifierByRemoteId ?? [:],
            remoteIdentifierByLocalID: session.backup?.remoteIdentifierByLocalId ?? [:],
            host: controller
        )
    }

    static func dismantleUIViewController(
        _ controller: AssetSharePresentationHostController,
        coordinator: Coordinator
    ) {
        controller.onDidAppear = nil
        coordinator.dismantle()
    }

    @MainActor
    final class Coordinator {
        private var parent: AssetSharePresenter
        private weak var host: AssetSharePresentationHostController?
        private var pending: AssetSharePendingPresentation?
        private var activeSession: AssetSharePresentationSession?
        private var consumedRequestIDs: Set<UUID> = []
        private var presentationTask: Task<Void, Never>?
        private var retryTask: Task<Void, Never>?
        private var presentationFailureTask: Task<Void, Never>?

        init(parent: AssetSharePresenter) {
            self.parent = parent
        }

        func update(
            parent: AssetSharePresenter,
            client: ImmichClient?,
            localIdentifierByRemoteID: [String: String],
            remoteIdentifierByLocalID: [String: String],
            host: AssetSharePresentationHostController
        ) {
            self.parent = parent
            self.host = host
            guard let request = parent.request else {
                pending = nil
                presentationTask?.cancel()
                presentationTask = nil
                retryTask?.cancel()
                retryTask = nil
                presentationFailureTask?.cancel()
                presentationFailureTask = nil
                return
            }
            AssetShareProviderLog.lifecycle(
                "coordinator update",
                requestID: request.id,
                owner: self
            )
            guard !request.isFinished,
                  !consumedRequestIDs.contains(request.id)
            else {
                consumeRequest(request.id)
                return
            }
            guard activeSession?.requestID != request.id else { return }
            let resolved = AssetSharePendingPresentation(
                request: request,
                client: client,
                sources: AssetShareSource.resolve(
                    assets: request.assets,
                    localIdentifierByRemoteID: localIdentifierByRemoteID,
                    remoteIdentifierByLocalID: remoteIdentifierByLocalID
                )
            )
            if let pending, pending.request.id == request.id {
                guard !pending.hasSameSources(as: resolved) else { return }
                presentationTask?.cancel()
            }
            pending = resolved
            AssetShareProviderLog.lifecycle(
                "request queued",
                requestID: request.id,
                owner: self
            )
            presentIfPossible(from: host)
        }

        func presentIfPossible(from host: AssetSharePresentationHostController) {
            guard activeSession == nil, let pending,
                  host.viewIfLoaded?.window != nil
            else { return }
            guard !pending.request.isFinished,
                  !consumedRequestIDs.contains(pending.request.id)
            else {
                self.pending = nil
                return
            }
            presentationTask?.cancel()
            presentationTask = Task { @MainActor [weak self, weak host] in
                await Self.nextRunLoop()
                await Self.nextRunLoop()
                guard !Task.isCancelled, let self, let host else { return }
                await presentPending(from: host)
            }
        }

        func dismantle() {
            let requestIDs = [
                activeSession?.requestID,
                pending?.request.id,
                parent.request?.id,
            ].compactMap { $0 }
            for requestID in requestIDs {
                consumeRequest(requestID)
            }
            presentationTask?.cancel()
            presentationTask = nil
            retryTask?.cancel()
            retryTask = nil
            presentationFailureTask?.cancel()
            presentationFailureTask = nil
            pending = nil
            host = nil
            let session = activeSession
            activeSession = nil
            session?.abort()
        }

        private func presentPending(
            from host: AssetSharePresentationHostController
        ) async {
            guard let pending, activeSession == nil,
                  !pending.request.isFinished,
                  !consumedRequestIDs.contains(pending.request.id)
            else { return }
            let presenter = Self.presentationOwner(for: host)
            guard presenter.viewIfLoaded?.window != nil else { return }
            guard presenter.presentedViewController == nil else {
                retryWhenPresentationSettles(from: host, controller: presenter)
                return
            }

            if let transition = Self.activeTransition(from: presenter) {
                let registered = transition.animate(alongsideTransition: nil) { [weak self, weak host] _ in
                    guard let self, let host else { return }
                    presentIfPossible(from: host)
                }
                if registered { return }
            }

            guard !Task.isCancelled else { return }
            let requestID = pending.request.id
            let request = pending.request
            let sources = pending.sources
            let client = pending.client
            self.pending = nil

            // export every selected asset up front, behind a blocking progress
            // dialog, so the sheet receives ready, content-typed file urls -
            // the only mechanism that reliably delivers videos to third-party
            // extensions and lets them group the share. metadata options come
            // from the saved defaults captured on the request.
            let prepared = await AssetSharePresenter.prepareShare(
                request: request,
                options: request.options,
                client: client,
                sources: sources
            )
            guard !Task.isCancelled,
                  !consumedRequestIDs.contains(requestID),
                  !request.isFinished,
                  let prepared
            else {
                consumeRequest(requestID)
                return
            }

            // the presenter may have changed during the export; re-resolve the
            // topmost controller before presenting.
            let sheetPresenter = Self.presentationOwner(for: host)
            guard host.viewIfLoaded?.window != nil,
                  sheetPresenter.viewIfLoaded?.window != nil
            else {
                consumeRequest(requestID)
                return
            }

            AssetShareProviderLog.lifecycle(
                "session created",
                requestID: requestID,
                owner: self
            )
            let shareSession = AssetSharePresenter.makeSession(
                request: request,
                prepared: prepared
            )
            shareSession.onRequestFinished = { [weak self] requestID in
                self?.consumeRequest(requestID)
            }
            shareSession.onPresented = { [weak self, weak shareSession] in
                guard let shareSession else { return }
                self?.sessionDidAppear(shareSession)
            }
            shareSession.onCleanup = { [weak self] requestID in
                self?.sessionDidCleanUp(requestID)
            }
            shareSession.onShared = { [weak self] in
                self?.parent.onShared?()
            }
            activeSession = shareSession

            // ipad anchors the activity popover to the bottom centre; iphone
            // uses the stock bottom-sheet presentation (no private hooks now, so
            // it slides up from the bottom on its own).
            if sheetPresenter.traitCollection.horizontalSizeClass == .regular,
               let popover = shareSession.controller.popoverPresentationController {
                popover.sourceView = sheetPresenter.view
                popover.sourceRect = CGRect(
                    x: sheetPresenter.view.bounds.midX,
                    y: sheetPresenter.view.bounds.maxY,
                    width: 1,
                    height: 1
                )
                popover.permittedArrowDirections = []
            }
            shareSession.installPresentationDelegateIfNeeded()
            sheetPresenter.present(shareSession.controller, animated: true) {
                shareSession.installPresentationDelegateIfNeeded()
            }
            schedulePresentationFailureRecovery(
                for: shareSession,
                pending: pending,
                host: host
            )
        }

        private func consumeRequest(_ requestID: UUID) {
            AssetShareProviderLog.lifecycle(
                "request consumed",
                requestID: requestID,
                owner: self
            )
            consumedRequestIDs.insert(requestID)
            if pending?.request.id == requestID {
                pending?.request.markFinished()
                pending = nil
            }
            if activeSession?.requestID == requestID {
                activeSession?.markRequestFinished()
            }
            if parent.request?.id == requestID {
                parent.request?.markFinished()
                parent.request = nil
            }
            presentationTask?.cancel()
            presentationTask = nil
            retryTask?.cancel()
            retryTask = nil
            presentationFailureTask?.cancel()
            presentationFailureTask = nil
        }

        private func sessionDidCleanUp(_ requestID: UUID) {
            guard activeSession?.requestID == requestID else { return }
            presentationFailureTask?.cancel()
            presentationFailureTask = nil
            activeSession = nil
            guard let host else { return }
            presentIfPossible(from: host)
        }

        private func sessionDidAppear(
            _ session: AssetSharePresentationSession
        ) {
            guard activeSession === session else { return }
            presentationFailureTask?.cancel()
            presentationFailureTask = nil
            consumeRequest(session.requestID)
        }

        private func schedulePresentationFailureRecovery(
            for session: AssetSharePresentationSession,
            pending failedPresentation: AssetSharePendingPresentation,
            host: AssetSharePresentationHostController
        ) {
            presentationFailureTask?.cancel()
            guard !session.hasAppeared else {
                presentationFailureTask = nil
                return
            }
            presentationFailureTask = Task { @MainActor [
                weak self,
                weak session,
                weak host,
            ] in
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled,
                      let self,
                      let session,
                      let host,
                      activeSession === session,
                      !session.hasAppeared,
                      session.controller.presentingViewController == nil,
                      session.controller.viewIfLoaded?.window == nil,
                      !session.controller.isBeingPresented,
                      !session.controller.isBeingDismissed,
                      pending == nil,
                      parent.request?.id == failedPresentation.request.id,
                      !failedPresentation.request.isFinished,
                      !consumedRequestIDs.contains(failedPresentation.request.id)
                else { return }

                presentationFailureTask = nil
                pending = failedPresentation
                session.abort()
                if activeSession === session {
                    activeSession = nil
                    presentIfPossible(from: host)
                }
            }
        }

        private func retryWhenPresentationSettles(
            from host: AssetSharePresentationHostController,
            controller: UIViewController
        ) {
            if let transition = Self.activeTransition(from: controller) {
                let registered = transition.animate(alongsideTransition: nil) { [weak self, weak host] _ in
                    guard let self, let host else { return }
                    presentIfPossible(from: host)
                }
                if registered { return }
            }

            retryTask?.cancel()
            retryTask = Task { @MainActor [weak self, weak host] in
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, let host else { return }
                retryTask = nil
                presentIfPossible(from: host)
            }
        }

        private static func presentationOwner(
            for host: AssetSharePresentationHostController
        ) -> UIViewController {
            // present from the key window's topmost view controller - the same
            // full-screen context photos uses - so the sheet slides up from the
            // bottom. presenting from the zero-sized swiftui background host or a
            // layout container gave a reduced context that floated it mid-screen.
            if let root = Self.keyWindow(near: host)?.rootViewController {
                var top = root
                while let presented = top.presentedViewController,
                      !presented.isBeingDismissed {
                    top = presented
                }
                return top
            }
            var owner: UIViewController = host
            while let parent = owner.parent { owner = parent }
            return owner
        }

        private static func keyWindow(
            near host: AssetSharePresentationHostController
        ) -> UIWindow? {
            if let window = host.viewIfLoaded?.window, window.isKeyWindow {
                return window
            }
            let scenes = UIApplication.shared.connectedScenes
            let scene = host.viewIfLoaded?.window?.windowScene
                ?? scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
                ?? scenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.windows.first { $0.isKeyWindow }
                ?? scene?.windows.first
                ?? host.viewIfLoaded?.window
        }

        private static func activeTransition(
            from controller: UIViewController
        ) -> UIViewControllerTransitionCoordinator? {
            var candidates = [controller]
            var index = 0
            while candidates.indices.contains(index) {
                let candidate = candidates[index]
                index += 1
                if let transition = candidate.transitionCoordinator,
                   transition.isAnimated {
                    return transition
                }
                if let presented = candidate.presentedViewController {
                    candidates.append(presented)
                }
                candidates.append(contentsOf: candidate.children)
            }
            return nil
        }

        private static func nextRunLoop() async {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async {
                    continuation.resume()
                }
            }
        }
    }

    /// exports every selected asset up front - behind a centered dialog that
    /// blocks the whole app until it finishes or is cancelled - then hands the
    /// sheet ready, content-typed file urls. this is what lets recipients like
    /// telegram group the share and reliably receive videos: a lazily-vended
    /// item reaches them as a bare file-url document, but a real file url
    /// passed directly is registered under its true image/movie type.
    @MainActor
    private static func prepareShare(
        request: AssetShareRequest,
        options: AssetShareOptions,
        client: ImmichClient?,
        sources: [AssetShareSource]
    ) async -> AssetSharePreparedShare? {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "share/\(request.id.uuidString)-\(UUID().uuidString)"
        )
        let preparationProgress = AssetSharePreparationProgress(
            sourceIDs: sources.map(\.id)
        )
        let exporter = AssetShareExporter(
            directory: directory,
            client: client,
            options: options,
            progress: { sourceID, token, progress in
                preparationProgress.update(
                    sourceID: sourceID,
                    token: token,
                    progress: progress
                )
            }
        )
        let transfer = AssetShareTransferLifetime(
            directory: directory,
            exporter: exporter
        )
        let failures = AssetShareFailureRelay()

        let dialog = AssetSharePreparationDialog()
        let cancellation = AssetShareCancellationBox()
        dialog.onCancel = {
            cancellation.cancel()
            Task { await exporter.cancelAll() }
        }
        dialog.install(progress: preparationProgress)

        let exported = await withTaskGroup(
            of: (Int, Result<AssetShareExportedFile, any Error>).self
        ) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        return (index, .success(try await exporter.exportedFile(for: source)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            var results = [Result<AssetShareExportedFile, any Error>?](
                repeating: nil,
                count: sources.count
            )
            for await (index, result) in group {
                results[index] = result
            }
            return results
        }

        dialog.remove()
        preparationProgress.stopObserving()

        guard !cancellation.isCancelled else { return nil }

        var files: [AssetShareExportedFile] = []
        var failureCount = 0
        var firstFailure: (any Error)?
        for result in exported {
            switch result {
            case .success(let file):
                files.append(file)
            default:
                failureCount += 1
                if case .failure(let error) = result,
                   firstFailure == nil,
                   !AssetShareFailureRelay.isCancellation(error) {
                    firstFailure = error
                }
            }
        }
        guard !files.isEmpty else {
            if let firstFailure {
                failures.report(
                    "Couldn’t prepare the selected items",
                    error: firstFailure
                )
            }
            return nil
        }
        // a partly failed batch still shares, but never silently: the sheet
        // holds fewer items than were selected.
        if let firstFailure {
            failures.report(
                "Couldn’t prepare \(failureCount) of \(sources.count) items",
                error: firstFailure
            )
        }
        return AssetSharePreparedShare(
            exported: files,
            transfer: transfer
        )
    }

    private static func makeSession(
        request: AssetShareRequest,
        prepared: AssetSharePreparedShare
    ) -> AssetSharePresentationSession {
        // a plain activity controller fed url-backed item sources: it slides up
        // from the bottom, the system builds the header thumbnail and summary
        // from the on-disk files, and third-party recipients group the media -
        // none of which the private photos header path allowed.
        let failures = AssetShareFailureRelay()
        let controller = AssetShareActivityViewController(
            activityItems: prepared.exported.map { AssetShareItemSource(exported: $0) },
            applicationActivities: nil
        )
        let session = AssetSharePresentationSession(
            request: request,
            transfer: prepared.transfer,
            failures: failures,
            controller: controller
        )
        session.installLifecycleCallbacks()
        return session
    }
}

/// vends one already-exported file to the activity sheet. the item is the plain
/// on-disk url, so the system introspects it for the header thumbnail and
/// summary and third-party extensions receive a real file, while the concrete
/// type identifier makes the sheet read a video as a video, not a generic
/// document, and lets recipients bucket the media for grouping.
///
/// the sheet resolves items on a background queue while the main thread blocks
/// waiting for them, so this source has to live off the main actor: a
/// main-actor witness would trap in its objc thunk under swift 6.
private nonisolated final class AssetShareItemSource: NSObject, UIActivityItemSource, Sendable {
    private let fileURL: URL
    private let contentType: UTType

    init(exported: AssetShareExportedFile) {
        fileURL = exported.fileURL
        contentType = exported.contentType
    }

    func activityViewControllerPlaceholderItem(
        _ controller: UIActivityViewController
    ) -> Any {
        fileURL
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        fileURL
    }

    func activityViewController(
        _ controller: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        contentType.identifier
    }
}

/// aggregates every asset's export into one progress snapshot for the card shown
/// over the sheet while items are being prepared. acquisition (download/photokit)
/// is weighted as the bulk of the work, metadata rewriting the tail.
private nonisolated final class AssetSharePreparationProgress: @unchecked Sendable {
    struct Snapshot: Sendable {
        let fraction: Double
        let isIndeterminate: Bool
        let title: String
    }

    private enum Phase {
        case idle
        case preparing
        case acquiring(Double)
        case processing(Double)
        case terminal(Double)

        var fraction: Double {
            switch self {
            case .idle, .preparing:
                0
            case .acquiring(let fraction):
                min(0.82, max(0, fraction) * 0.82)
            case .processing(let fraction):
                0.82 + min(0.17, max(0, fraction) * 0.17)
            case .terminal(let fraction):
                min(1, max(0, fraction))
            }
        }

        var isProcessing: Bool {
            if case .processing = self { return true }
            return false
        }

        var isTerminal: Bool {
            if case .terminal = self { return true }
            return false
        }

        var isIndeterminate: Bool {
            if case .preparing = self { return true }
            return false
        }
    }

    private struct Slot {
        var token: UUID?
        var phase = Phase.idle
    }

    private let lock = NSLock()
    private var slots: [UUID: Slot]
    private var observer: (@MainActor @Sendable (Snapshot) -> Void)?
    private var deliveryScheduled = false

    init(sourceIDs: [UUID]) {
        slots = Dictionary(
            uniqueKeysWithValues: sourceIDs.map { ($0, Slot()) }
        )
    }

    func update(
        sourceID: UUID,
        token: UUID,
        progress: AssetShareExportProgress
    ) {
        let shouldSchedule = lock.withLock {
            guard var slot = slots[sourceID] else { return false }
            switch progress {
            case .preparing:
                if slot.token != token {
                    slot = Slot(token: token, phase: .preparing)
                } else if case .idle = slot.phase {
                    slot.phase = .preparing
                }
            case .acquiring(let fraction):
                guard slot.token == token else { return false }
                switch slot.phase {
                case .preparing where fraction <= 0:
                    break
                case .preparing, .idle:
                    slot.phase = .acquiring(fraction)
                case .acquiring(let current):
                    slot.phase = .acquiring(max(current, fraction))
                case .processing, .terminal:
                    return false
                }
            case .processing(let fraction):
                guard slot.token == token else { return false }
                switch slot.phase {
                case .terminal:
                    return false
                case .processing(let current):
                    slot.phase = .processing(max(current, fraction))
                case .idle, .preparing, .acquiring:
                    slot.phase = .processing(fraction)
                }
            case .completed:
                guard slot.token == token else { return false }
                guard !slot.phase.isTerminal else { return false }
                slot.phase = .terminal(1)
            case .failed, .cancelled:
                guard slot.token == token else { return false }
                guard !slot.phase.isTerminal else { return false }
                slot.phase = .terminal(slot.phase.fraction)
            }
            slots[sourceID] = slot
            guard observer != nil, !deliveryScheduled else { return false }
            deliveryScheduled = true
            return true
        }
        if shouldSchedule { scheduleDelivery() }
    }

    func observe(
        _ observer: @escaping @MainActor @Sendable (Snapshot) -> Void
    ) {
        let snapshot = lock.withLock {
            self.observer = observer
            return makeSnapshot()
        }
        Task { @MainActor in observer(snapshot) }
    }

    func stopObserving() {
        lock.withLock {
            observer = nil
            deliveryScheduled = false
        }
    }

    private func scheduleDelivery() {
        Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let delivery = takeDelivery() else { return }
            delivery.observer(delivery.snapshot)
        }
    }

    private func takeDelivery() -> (
        observer: @MainActor @Sendable (Snapshot) -> Void,
        snapshot: Snapshot
    )? {
        lock.withLock {
            deliveryScheduled = false
            guard let observer else { return nil }
            return (observer, makeSnapshot())
        }
    }

    private func makeSnapshot() -> Snapshot {
        let phases = slots.values.map(\.phase)
        let fraction = phases.isEmpty
            ? 0
            : phases.reduce(0) { $0 + $1.fraction } / Double(phases.count)
        let isProcessing = phases.contains(where: \.isProcessing)
        let isIndeterminate = phases.contains(where: \.isIndeterminate)
        let item = slots.count == 1 ? "Item" : "Items"
        let title = isProcessing
            ? "Processing \(item)..."
            : "Preparing \(item)..."
        return Snapshot(
            fraction: min(1, max(0, fraction)),
            isIndeterminate: isIndeterminate,
            title: title
        )
    }
}

@MainActor
private final class AssetShareFailureRelay {
    private var didReport = false

    func report(_ message: String, error: any Error) {
        guard !didReport, !Self.isCancellation(error) else { return }
        didReport = true
        AssetShareFailureNoticeCenter.shared.enqueue(message, error: error)
    }

    fileprivate static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || PhotoLibraryService.isUserCancelled(error) {
            return true
        }
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain,
           error.code == NSUserCancelledError {
            return true
        }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
              underlying !== error
        else { return false }
        return isCancellation(underlying)
    }
}

@MainActor
private final class AssetShareFailureNoticeCenter: NSObject {
    static let shared = AssetShareFailureNoticeCenter()

    private var pending: [(message: String, error: NSError)] = []
    private var observesActivation = false

    func enqueue(_ message: String, error: any Error) {
        pending.append((message, error as NSError))
        flushIfPossible()
    }

    @objc private func sceneDidActivate() {
        flushIfPossible()
    }

    private func flushIfPossible() {
        let isForegroundActive = UIApplication.shared.connectedScenes.contains {
            $0.activationState == .foregroundActive
        }
        guard isForegroundActive else {
            beginObservingActivation()
            return
        }

        let notices = pending
        pending.removeAll()
        stopObservingActivation()
        for notice in notices {
            ErrorToastCenter.shared.show(notice.message, error: notice.error)
        }
    }

    private func beginObservingActivation() {
        guard !observesActivation else { return }
        observesActivation = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sceneDidActivate),
            name: UIScene.didActivateNotification,
            object: nil
        )
    }

    private func stopObservingActivation() {
        guard observesActivation else { return }
        observesActivation = false
        NotificationCenter.default.removeObserver(
            self,
            name: UIScene.didActivateNotification,
            object: nil
        )
    }
}

final class AssetSharePresentationHostController: UIViewController {
    var onDidAppear: ((AssetSharePresentationHostController) -> Void)?

    override func loadView() {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        view.accessibilityElementsHidden = true
        self.view = view
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?(self)
    }
}

private final class AssetShareActivityViewController: UIActivityViewController {
    var onDidAppear: (() -> Void)?
    var onDidDisappear: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        onDidAppear?()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDidDisappear?()
    }
}

private struct AssetSharePreparedShare {
    let exported: [AssetShareExportedFile]
    let transfer: AssetShareTransferLifetime
}

@MainActor
private final class AssetShareCancellationBox {
    private(set) var isCancelled = false
    func cancel() { isCancelled = true }
}

/// the modal dialog shown while assets export up front, before the share
/// sheet appears. it fills its own window with a dimmed scrim that swallows
/// every touch, so nothing else can happen until preparation finishes or the
/// user cancels. it only appears once the work has outlived a short grace
/// period, so instant local shares never flash it.
@MainActor
private final class AssetSharePreparationDialog {
    var onCancel: (() -> Void)?
    private let card = AssetShareProgressView()
    private let scrim = UIView()
    private var window: UIWindow?
    private var installTask: Task<Void, Never>?

    func install(progress: AssetSharePreparationProgress) {
        // observed from the start, so the card is current the instant it shows.
        progress.observe { [weak card] snapshot in
            card?.update(snapshot)
        }
        installTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.present()
        }
    }

    func remove() {
        installTask?.cancel()
        installTask = nil
        guard let window else { return }
        self.window = nil
        let card = card
        let scrim = scrim
        UIView.animate(
            withDuration: 0.2,
            animations: {
                card.alpha = 0
                scrim.alpha = 0
            },
            completion: { _ in window.isHidden = true }
        )
        UIAccessibility.post(notification: .screenChanged, argument: nil)
    }

    private func present() {
        guard window == nil, let scene = Self.activeScene() else { return }
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .clear
        window.windowLevel = .alert
        let root = UIViewController()
        root.view.backgroundColor = .clear
        window.rootViewController = root
        window.isHidden = false
        self.window = window

        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        scrim.frame = root.view.bounds
        scrim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrim.alpha = 0
        root.view.addSubview(scrim)

        card.onCancel = { [weak self] in self?.onCancel?() }
        card.translatesAutoresizingMaskIntoConstraints = false
        card.alpha = 0
        card.transform = CGAffineTransform(scaleX: 1.1, y: 1.1)
        card.accessibilityViewIsModal = true
        root.view.addSubview(card)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: root.view.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 288),
        ])
        UIView.animate(
            withDuration: 0.35,
            delay: 0,
            usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0
        ) {
            self.scrim.alpha = 1
            self.card.alpha = 1
            self.card.transform = .identity
        }
        UIAccessibility.post(notification: .screenChanged, argument: card)
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes
        return scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.compactMap { $0 as? UIWindowScene }.first
    }
}

/// the dialog card: title with spinner, progress bar, percentage and a full
/// width cancel action separated by a hairline, laid out like an alert.
private final class AssetShareProgressView: UIVisualEffectView {
    var onCancel: (() -> Void)?

    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let percentageLabel = UILabel()
    private let bar = UIProgressView(progressViewStyle: .default)
    private let cancelButton = UIButton(type: .system)

    init() {
        super.init(effect: UIGlassEffect())
        layer.cornerRadius = 28
        layer.cornerCurve = .continuous
        clipsToBounds = true

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        let percentageBase = UIFont.preferredFont(forTextStyle: .subheadline)
        percentageLabel.font = UIFontMetrics(forTextStyle: .subheadline).scaledFont(
            for: .monospacedDigitSystemFont(
                ofSize: percentageBase.pointSize,
                weight: .regular
            )
        )
        percentageLabel.adjustsFontForContentSizeCategory = true
        percentageLabel.textColor = .secondaryLabel
        percentageLabel.textAlignment = .center

        bar.trackTintColor = .tertiarySystemFill

        var configuration = UIButton.Configuration.plain()
        configuration.title = "Cancel"
        cancelButton.configuration = configuration
        cancelButton.addAction(
            UIAction { [weak self] _ in self?.onCancel?() },
            for: .primaryActionTriggered
        )

        activityIndicator.hidesWhenStopped = true
        let heading = UIStackView(arrangedSubviews: [activityIndicator, titleLabel])
        heading.axis = .horizontal
        heading.spacing = 8
        heading.alignment = .center

        let content = UIStackView(arrangedSubviews: [heading, bar, percentageLabel])
        content.axis = .vertical
        content.spacing = 12
        content.alignment = .center
        content.translatesAutoresizingMaskIntoConstraints = false

        let separator = UIView()
        separator.backgroundColor = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(content)
        contentView.addSubview(separator)
        contentView.addSubview(cancelButton)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            bar.widthAnchor.constraint(equalTo: content.widthAnchor),
            separator.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 0.5),
            cancelButton.topAnchor.constraint(equalTo: separator.bottomAnchor),
            cancelButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            cancelButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ snapshot: AssetSharePreparationProgress.Snapshot) {
        let percentage = Int((snapshot.fraction * 100).rounded())
        if snapshot.isIndeterminate {
            activityIndicator.startAnimating()
        } else {
            activityIndicator.stopAnimating()
        }
        titleLabel.text = snapshot.title
        // a space keeps the line height stable before the first fraction.
        percentageLabel.text = snapshot.isIndeterminate && percentage == 0
            ? " "
            : "\(percentage)%"
        bar.setProgress(Float(snapshot.fraction), animated: true)
    }
}

private struct AssetSharePendingPresentation {
    let request: AssetShareRequest
    let client: ImmichClient?
    let sources: [AssetShareSource]

    func hasSameSources(as other: AssetSharePendingPresentation) -> Bool {
        guard sources.count == other.sources.count else { return false }
        return zip(sources, other.sources).allSatisfy { current, updated in
            current.asset.id == updated.asset.id
                && current.localIdentifier == updated.localIdentifier
                && current.remoteIdentifier == updated.remoteIdentifier
        }
    }
}

@MainActor
private final class AssetSharePresentationSession: NSObject, UIAdaptivePresentationControllerDelegate {
    let requestID: UUID
    let controller: AssetShareActivityViewController
    var onRequestFinished: ((UUID) -> Void)?
    var onPresented: (() -> Void)?
    var onCleanup: ((UUID) -> Void)?
    var onShared: (() -> Void)?
    private(set) var hasAppeared = false

    private let request: AssetShareRequest
    private var transfer: AssetShareTransferLifetime?
    private let failures: AssetShareFailureRelay
    private var didComplete = false
    private var didDisappear = false
    private var dismissalFinished = false
    private var disappearanceGeneration = 0
    private var disappearanceTask: Task<Void, Never>?
    private var cleanupStarted = false

    init(
        request: AssetShareRequest,
        transfer: AssetShareTransferLifetime,
        failures: AssetShareFailureRelay,
        controller: AssetShareActivityViewController
    ) {
        requestID = request.id
        self.request = request
        self.transfer = transfer
        self.failures = failures
        self.controller = controller
    }

    func installLifecycleCallbacks() {
        controller.onDidAppear = { [self] in activityDidAppear() }
        controller.onDidDisappear = { [self] in activityDidDisappear() }
        controller.completionWithItemsHandler = { [self] type, completed, _, error in
            AssetShareProviderLog.activityCompleted(
                type: type,
                completed: completed,
                error: error
            )
            if let error {
                failures.report("Couldn’t share the selected items", error: error)
            }
            // completed means a recipient took the items - close and let the
            // caller drop its selection. a plain dismiss reports false.
            if completed {
                onShared?()
            }
            activityDidComplete()
        }
    }

    func installPresentationDelegateIfNeeded() {
        guard controller.presentationController?.delegate == nil else { return }
        controller.presentationController?.delegate = self
    }

    func markRequestFinished() {
        request.markFinished()
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        activityDidComplete()
        disappearanceGeneration += 1
        didDisappear = true
        dismissalFinished = true
        cleanUpIfReady()
    }

    func abort() {
        guard !cleanupStarted else { return }
        didComplete = true
        didDisappear = true
        dismissalFinished = true
        if controller.presentingViewController != nil {
            controller.dismiss(animated: false)
        }
        beginCleanup()
    }

    private func activityDidAppear() {
        guard !didComplete else { return }
        hasAppeared = true
        disappearanceTask?.cancel()
        disappearanceTask = nil
        disappearanceGeneration += 1
        didDisappear = false
        dismissalFinished = false
        onPresented?()
    }

    private func activityDidDisappear() {
        disappearanceGeneration += 1
        let generation = disappearanceGeneration
        didDisappear = true
        dismissalFinished = false
        if let transition = controller.transitionCoordinator {
            let registered = transition.animate(alongsideTransition: nil) { [self] _ in
                finishDisappearance(generation)
            }
            if registered {
                scheduleDisappearanceCheck(generation)
                return
            }
        }
        disappearanceTask?.cancel()
        disappearanceTask = Task { @MainActor [self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            finishDisappearance(generation)
        }
    }

    private func scheduleDisappearanceCheck(_ generation: Int) {
        disappearanceTask?.cancel()
        disappearanceTask = Task { @MainActor [self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            finishDisappearance(generation)
        }
    }

    private func activityDidComplete() {
        guard !didComplete else { return }
        didComplete = true
        AssetShareProviderLog.lifecycle(
            "activity completed",
            requestID: requestID,
            owner: self
        )
        request.markFinished()
        onRequestFinished?(requestID)
        cleanUpIfReady()
    }

    private func finishDisappearance(_ generation: Int) {
        guard didDisappear, disappearanceGeneration == generation else { return }
        dismissalFinished = true
        cleanUpIfReady()
    }

    private func cleanUpIfReady() {
        guard didComplete, didDisappear, dismissalFinished, !cleanupStarted else {
            return
        }
        beginCleanup()
    }

    private func beginCleanup() {
        guard !cleanupStarted else { return }
        cleanupStarted = true
        AssetShareProviderLog.lifecycle(
            "session cleanup",
            requestID: requestID,
            owner: self
        )

        controller.completionWithItemsHandler = nil
        controller.onDidAppear = nil
        controller.onDidDisappear = nil
        disappearanceTask?.cancel()
        disappearanceTask = nil
        if controller.presentationController?.delegate === self {
            controller.presentationController?.delegate = nil
        }

        let requestID = requestID
        let onCleanup = onCleanup
        self.onRequestFinished = nil
        self.onPresented = nil
        self.onCleanup = nil
        transfer = nil
        onCleanup?(requestID)
    }
}

private nonisolated final class AssetShareTransferLifetime: @unchecked Sendable {
    private let directory: URL
    private let exporter: AssetShareExporter

    init(directory: URL, exporter: AssetShareExporter) {
        self.directory = directory
        self.exporter = exporter
        Self.removeAbandonedDirectories(
            under: directory.deletingLastPathComponent()
        )
    }

    deinit {
        let directory = directory
        let exporter = exporter
        // recipients copy the plain file urls out of process without any
        // completion callback, so the files outlive the sheet by a grace
        // period before the scratch directory goes away.
        Task.detached {
            try? await Task.sleep(for: .seconds(600))
            await exporter.cancelAll()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func removeAbandonedDirectories(under root: URL) {
        Task.detached(priority: .utility) {
            let keys: Set<URLResourceKey> = [
                .contentModificationDateKey,
                .isDirectoryKey,
            ]
            guard let directories = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }
            let cutoff = Date.now.addingTimeInterval(-86_400)
            for directory in directories {
                guard let values = try? directory.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      let modified = values.contentModificationDate,
                      modified < cutoff
                else { continue }
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
}

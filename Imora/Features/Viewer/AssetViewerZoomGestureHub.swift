import ObjectiveC
import Observation
import UIKit

@MainActor
protocol AssetViewerZoomGestureTarget: AnyObject {
    var allowsDoubleTapZoom: Bool { get }
    func routeMediaTap()
    func routeDoubleTap(at point: CGPoint, from view: UIView)
}

@MainActor
protocol AssetViewerZoomCommandTarget: AnyObject {
    var zoomCommandAssetID: String { get }

    @discardableResult
    func routeZoomToFit(completion: @escaping (Bool) -> Void) -> Bool
    func cancelRoutedZoomToFit()
}

@MainActor
@Observable
final class AssetViewerZoomCommandBridge {
    private struct PendingFit {
        let generation: Int
        let targetID: ObjectIdentifier
        let completion: (Bool) -> Void
    }

    @ObservationIgnored private weak var activeTarget: (any AssetViewerZoomCommandTarget)?
    @ObservationIgnored private var commandGeneration = 0
    @ObservationIgnored private var pendingFit: PendingFit?

    func setActive(_ target: any AssetViewerZoomCommandTarget, isActive: Bool) {
        if isActive {
            guard activeTarget !== target else { return }
            let previousTarget = activeTarget
            let cancelledFit = takePendingFit()
            commandGeneration &+= 1
            activeTarget = target
            cancel(cancelledFit, on: previousTarget)
        } else if activeTarget === target {
            let previousTarget = activeTarget
            let cancelledFit = takePendingFit()
            commandGeneration &+= 1
            activeTarget = nil
            cancel(cancelledFit, on: previousTarget)
        }
    }

    @discardableResult
    func fitActivePage(
        assetID: String,
        completion: @escaping (Bool) -> Void
    ) -> Bool {
        guard let activeTarget,
              activeTarget.zoomCommandAssetID == assetID
        else { return false }
        let cancelledFit = takePendingFit()
        if cancelledFit != nil {
            activeTarget.cancelRoutedZoomToFit()
        }
        commandGeneration &+= 1
        let generation = commandGeneration
        let targetID = ObjectIdentifier(activeTarget)
        pendingFit = PendingFit(
            generation: generation,
            targetID: targetID,
            completion: completion
        )
        let started = activeTarget.routeZoomToFit { [weak self] completed in
            self?.resolveFit(
                generation: generation,
                targetID: targetID,
                completed: completed
            )
        }
        if !started {
            discardFit(generation: generation, targetID: targetID)
        }
        cancelledFit?.completion(false)
        return started
    }

    func cancelPendingFit() {
        let target = activeTarget
        let cancelledFit = takePendingFit()
        cancel(cancelledFit, on: target)
    }

    private func takePendingFit() -> PendingFit? {
        guard let pendingFit else { return nil }
        self.pendingFit = nil
        commandGeneration &+= 1
        return pendingFit
    }

    private func cancel(
        _ pendingFit: PendingFit?,
        on target: (any AssetViewerZoomCommandTarget)?
    ) {
        guard let pendingFit else { return }
        target?.cancelRoutedZoomToFit()
        // cancellation can fire inside a representable update or hierarchy
        // teardown, where the completion writing swiftui state synchronously
        // is unsafe. delivery is deferred one tick, the completion is
        // request-scoped so a late cancel cannot clobber a newer fit.
        DispatchQueue.main.async { pendingFit.completion(false) }
    }

    private func resolveFit(
        generation: Int,
        targetID: ObjectIdentifier,
        completed: Bool
    ) {
        guard pendingFit?.generation == generation,
              pendingFit?.targetID == targetID
        else { return }
        guard let activeTarget,
              ObjectIdentifier(activeTarget) == targetID
        else {
            resolveCurrentFit(completed: false)
            return
        }
        resolveCurrentFit(completed: completed)
    }

    private func resolveCurrentFit(completed: Bool) {
        guard let pendingFit else { return }
        self.pendingFit = nil
        commandGeneration &+= 1
        pendingFit.completion(completed)
    }

    private func discardFit(
        generation: Int,
        targetID: ObjectIdentifier
    ) {
        guard pendingFit?.generation == generation,
              pendingFit?.targetID == targetID
        else { return }
        pendingFit = nil
        commandGeneration &+= 1
    }
}

@MainActor
final class AssetViewerZoomGestureHub: NSObject {
    private static var associationKey: UInt8 = 0

    static func attached(to view: UIView) -> AssetViewerZoomGestureHub {
        if let hub = objc_getAssociatedObject(view, &associationKey)
            as? AssetViewerZoomGestureHub {
            return hub
        }
        let hub = AssetViewerZoomGestureHub(view: view)
        objc_setAssociatedObject(
            view,
            &associationKey,
            hub,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return hub
    }

    private weak var gestureView: UIView?
    private weak var singleTapGesture: UITapGestureRecognizer?
    private weak var doubleTapGesture: UITapGestureRecognizer?
    private weak var activeTarget: (any AssetViewerZoomGestureTarget)?

    private init(view: UIView) {
        gestureView = view
        super.init()

        let singleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleSingleTap(_:))
        )
        configure(tap: singleTap)
        view.addGestureRecognizer(singleTap)
        singleTapGesture = singleTap

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        configure(tap: doubleTap)
        view.addGestureRecognizer(doubleTap)
        doubleTapGesture = doubleTap

        singleTap.require(toFail: doubleTap)
    }

    func setActive(_ target: any AssetViewerZoomGestureTarget, isActive: Bool) {
        if isActive {
            activeTarget = target
            singleTapGesture?.isEnabled = true
            doubleTapGesture?.isEnabled = true
        } else if activeTarget === target {
            activeTarget = nil
            singleTapGesture?.isEnabled = false
            doubleTapGesture?.isEnabled = false
        }
    }

    @objc private func handleSingleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        activeTarget?.routeMediaTap()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended,
              let gestureView,
              let activeTarget
        else { return }
        activeTarget.routeDoubleTap(
            at: gesture.location(in: gestureView),
            from: gestureView
        )
    }

    private func configure(tap: UITapGestureRecognizer) {
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
    }
}

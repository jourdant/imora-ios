import CoreGraphics

nonisolated struct AssetViewerInformationZoomHandoff: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let token: Int
        let assetID: String
    }

    enum Effect: Equatable, Sendable {
        case none
        case showInformation
        case hideInformation
        case requestFit(Request)
    }

    private(set) var pendingRequest: Request?
    private var nextToken = 0

    mutating func toggle(
        assetID: String?,
        isInformationPresented: Bool,
        isZoomed: Bool
    ) -> Effect {
        if isInformationPresented {
            pendingRequest = nil
            return .hideInformation
        }
        guard let assetID else { return .none }
        guard pendingRequest == nil else { return .none }
        guard isZoomed else { return .showInformation }

        nextToken &+= 1
        let request = Request(token: nextToken, assetID: assetID)
        pendingRequest = request
        return .requestFit(request)
    }

    mutating func fitCompleted(
        _ request: Request,
        selectedAssetID: String?
    ) -> Effect {
        guard pendingRequest == request else { return .none }
        pendingRequest = nil
        guard selectedAssetID == request.assetID else { return .none }
        return .showInformation
    }

    mutating func fitCancelled(_ request: Request) {
        guard pendingRequest == request else { return }
        pendingRequest = nil
    }

    mutating func cancelPending() {
        pendingRequest = nil
    }
}

nonisolated enum AssetViewerInformationFitEnd {
    enum Resolution: Equatable, Sendable {
        case ignore
        case complete
        case cancel
    }

    static func resolution(
        isApplyingProgrammaticZoom: Bool,
        isZoomAnimating: Bool,
        isZoomed: Bool
    ) -> Resolution {
        if isApplyingProgrammaticZoom || isZoomAnimating { return .ignore }
        return isZoomed ? .cancel : .complete
    }
}

nonisolated enum AssetViewerDoubleTapZoom {
    static let preferredScale: CGFloat = 2.5
    static let fitTolerance: CGFloat = 0.01

    enum Target: Equatable, Sendable {
        case fit(scale: CGFloat)
        case zoom(rect: CGRect)
    }

    static func target(
        currentScale: CGFloat,
        minimumScale: CGFloat,
        maximumScale: CGFloat,
        viewport: CGSize,
        tap: CGPoint
    ) -> Target {
        let minimum = minimumScale.isFinite && minimumScale > 0 ? minimumScale : 1
        guard currentScale.isFinite,
              maximumScale.isFinite,
              viewport.width.isFinite,
              viewport.height.isFinite,
              viewport.width > 0,
              viewport.height > 0,
              tap.x.isFinite,
              tap.y.isFinite
        else { return .fit(scale: minimum) }

        if currentScale > minimum + fitTolerance {
            return .fit(scale: minimum)
        }

        let scale = min(max(minimum, maximumScale), max(minimum, preferredScale))
        guard scale > minimum + fitTolerance else { return .fit(scale: minimum) }
        let size = CGSize(width: viewport.width / scale, height: viewport.height / scale)
        return .zoom(
            rect: CGRect(
                x: tap.x - size.width / 2,
                y: tap.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        )
    }
}

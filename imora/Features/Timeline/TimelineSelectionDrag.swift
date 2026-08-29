import Foundation

nonisolated struct SelectionGridPosition: Hashable {
    let row: Int
    let column: Int
}

nonisolated struct SelectionGridRectangle: Equatable {
    let rows: ClosedRange<Int>
    let columns: ClosedRange<Int>

    init(origin: SelectionGridPosition, target: SelectionGridPosition) {
        rows = min(origin.row, target.row)...max(origin.row, target.row)
        columns = min(origin.column, target.column)...max(origin.column, target.column)
    }

    func contains(_ position: SelectionGridPosition) -> Bool {
        rows.contains(position.row) && columns.contains(position.column)
    }
}

nonisolated struct SelectionRectangleState {
    struct Change: Hashable {
        let assetID: String
        let selects: Bool
    }

    private(set) var selects: Bool?
    private var baselineSelectedIDs = Set<String>()
    private var currentAssetIDs = Set<String>()

    mutating func begin(originIsSelected: Bool, selectedIDs: Set<String>) {
        end()
        selects = !originIsSelected
        baselineSelectedIDs = selectedIDs
    }

    mutating func update(assetIDs: Set<String>) -> [Change] {
        guard let selects else { return [] }
        let changedIDs = currentAssetIDs.symmetricDifference(assetIDs)
        let changes = changedIDs.compactMap { assetID -> Change? in
            let wasSelected = currentAssetIDs.contains(assetID)
                ? selects
                : baselineSelectedIDs.contains(assetID)
            let isSelected = assetIDs.contains(assetID)
                ? selects
                : baselineSelectedIDs.contains(assetID)
            guard wasSelected != isSelected else { return nil }
            return Change(assetID: assetID, selects: isSelected)
        }
        currentAssetIDs = assetIDs
        return changes
    }

    mutating func end() {
        selects = nil
        baselineSelectedIDs.removeAll(keepingCapacity: true)
        currentAssetIDs.removeAll(keepingCapacity: true)
    }
}

nonisolated struct SelectionDirectDragIntent {
    static let timeline = Self(minimumHorizontalRatio: 0.7)

    let minimumHorizontalRatio: CGFloat

    func matches(translation: CGSize) -> Bool {
        let horizontal = abs(translation.width)
        let vertical = abs(translation.height)
        guard horizontal > 0 else { return false }
        return vertical == 0 || horizontal / vertical >= minimumHorizontalRatio
    }
}

nonisolated struct SelectionAutoScrollProfile {
    static let timeline = Self(edgeLength: 110, maximumSpeed: 900)

    let edgeLength: CGFloat
    let maximumSpeed: CGFloat

    func speed(at y: CGFloat, in viewport: ClosedRange<CGFloat>) -> CGFloat {
        guard edgeLength > 0, maximumSpeed > 0 else { return 0 }
        let top = intensity(for: y - viewport.lowerBound)
        let bottom = intensity(for: viewport.upperBound - y)
        guard top != bottom else { return 0 }
        let direction: CGFloat = top > bottom ? -1 : 1
        let intensity = max(top, bottom)
        return direction * maximumSpeed * intensity * intensity
    }

    private func intensity(for distance: CGFloat) -> CGFloat {
        min(1, max(0, 1 - distance / edgeLength))
    }
}

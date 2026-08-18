import Foundation

nonisolated enum TimelineAssetProjection {
    struct Location: Hashable {
        let row: Int
        let run: Int
        let asset: Int
    }

    static func locations(in rows: [TimelineRow]) -> [String: Location] {
        var result: [String: Location] = [:]
        for (rowIndex, row) in rows.enumerated() {
            guard case .tiles(_, let runs) = row else { continue }
            for (runIndex, run) in runs.enumerated() {
                for (assetIndex, asset) in run.assets.enumerated() {
                    result[asset.id] = Location(
                        row: rowIndex,
                        run: runIndex,
                        asset: assetIndex
                    )
                }
            }
        }
        return result
    }

    static func patchRows(
        _ rows: inout [TimelineRow],
        assetsByID: [String: Asset],
        locations: [String: Location]
    ) {
        var changesByRow: [Int: [Int: [Int: (String, Asset)]]] = [:]
        for (id, asset) in assetsByID {
            guard let location = locations[id] else { continue }
            changesByRow[location.row, default: [:]][location.run, default: [:]][location.asset] = (id, asset)
        }

        for (rowIndex, changesByRun) in changesByRow {
            guard rows.indices.contains(rowIndex),
                  case .tiles(let rowID, var runs) = rows[rowIndex]
            else { continue }
            var rowChanged = false
            for (runIndex, changes) in changesByRun {
                guard runs.indices.contains(runIndex) else { continue }
                var assets = runs[runIndex].assets
                var runChanged = false
                for (assetIndex, change) in changes {
                    guard assets.indices.contains(assetIndex),
                          assets[assetIndex].id == change.0,
                          assets[assetIndex] != change.1
                    else { continue }
                    assets[assetIndex] = change.1
                    runChanged = true
                }
                guard runChanged else { continue }
                runs[runIndex] = TileRun(colStart: runs[runIndex].colStart, assets: assets)
                rowChanged = true
            }
            if rowChanged {
                rows[rowIndex] = .tiles(rowID, runs)
            }
        }
    }

    static func patchFlatAssets(
        _ assets: inout [Asset],
        assetsByID: [String: Asset],
        indicesByID: [String: Int]
    ) {
        for (id, asset) in assetsByID {
            guard let index = indicesByID[id],
                  assets.indices.contains(index),
                  assets[index].id == id
            else { continue }
            assets[index] = asset
        }
    }
}

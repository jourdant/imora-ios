import Foundation

/// packs day groups into horizontal bands so short days share a line instead
/// of each taking a full-width stripe. everything is integer column math -
/// pixel positions derive from column indices at render time, which keeps row
/// heights deterministic for the scrubber and scroll compensation.
nonisolated enum TimelineFlowLayout {
    /// one day group placed in a band: which columns it owns and how many
    /// tile rows it needs. tiles fill the block left to right, top to bottom.
    struct Block: Hashable {
        let dayIndex: Int
        let colStart: Int
        let colWidth: Int
        let rowCount: Int
    }

    /// day groups sharing one title band. blocks are top aligned; the band is
    /// as tall as its tallest block.
    struct Band: Hashable {
        let blocks: [Block]

        var rowCount: Int { blocks.lazy.map(\.rowCount).max() ?? 0 }
    }

    /// balanced block shape: fewest rows first, then the narrowest width that
    /// still holds the count, so 4 photos over 3 columns become a 2x2 block
    /// with room for a neighbour instead of a full-width 3+1.
    static func dimensions(count: Int, columns: Int) -> (width: Int, rows: Int) {
        guard count > 0, columns > 0 else { return (0, 0) }
        let rows = (count + columns - 1) / columns
        let width = (count + rows - 1) / rows
        return (width, rows)
    }

    /// greedy left-to-right flow in day order: a day that fits next to the
    /// previous one joins its band, otherwise it starts a new band.
    static func pack(counts: [Int], columns: Int) -> [Band] {
        var bands: [Band] = []
        var current: [Block] = []
        var cursor = 0

        for (index, count) in counts.enumerated() {
            let (width, rows) = dimensions(count: count, columns: columns)
            guard width > 0 else { continue }
            if !current.isEmpty, cursor + width > columns {
                bands.append(Band(blocks: current))
                current = []
                cursor = 0
            }
            current.append(Block(dayIndex: index, colStart: cursor, colWidth: width, rowCount: rows))
            cursor += width
        }
        if !current.isEmpty {
            bands.append(Band(blocks: current))
        }
        return bands
    }
}

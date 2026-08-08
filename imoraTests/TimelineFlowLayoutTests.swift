import Testing
@testable import imora

@Suite("Timeline flow layout")
struct TimelineFlowLayoutTests {
    @Test("blocks take balanced shapes instead of ragged full-width ones")
    func balancedDimensions() {
        #expect(TimelineFlowLayout.dimensions(count: 1, columns: 3) == (1, 1))
        #expect(TimelineFlowLayout.dimensions(count: 2, columns: 3) == (2, 1))
        #expect(TimelineFlowLayout.dimensions(count: 3, columns: 3) == (3, 1))
        #expect(TimelineFlowLayout.dimensions(count: 4, columns: 3) == (2, 2))
        #expect(TimelineFlowLayout.dimensions(count: 5, columns: 3) == (3, 2))
        #expect(TimelineFlowLayout.dimensions(count: 7, columns: 3) == (3, 3))
        #expect(TimelineFlowLayout.dimensions(count: 47, columns: 3) == (3, 16))
        #expect(TimelineFlowLayout.dimensions(count: 5, columns: 5) == (5, 1))
        #expect(TimelineFlowLayout.dimensions(count: 6, columns: 5) == (3, 2))
    }

    @Test("empty and degenerate inputs produce nothing")
    func degenerateInputs() {
        #expect(TimelineFlowLayout.dimensions(count: 0, columns: 3) == (0, 0))
        #expect(TimelineFlowLayout.dimensions(count: 3, columns: 0) == (0, 0))
        #expect(TimelineFlowLayout.pack(counts: [], columns: 3).isEmpty)
        #expect(TimelineFlowLayout.pack(counts: [0, 0], columns: 3).isEmpty)
    }

    @Test("short days share one band")
    func shortDaysShareABand() {
        let bands = TimelineFlowLayout.pack(counts: [2, 1], columns: 3)

        #expect(bands.count == 1)
        #expect(bands[0].blocks == [
            TimelineFlowLayout.Block(dayIndex: 0, colStart: 0, colWidth: 2, rowCount: 1),
            TimelineFlowLayout.Block(dayIndex: 1, colStart: 2, colWidth: 1, rowCount: 1),
        ])
        #expect(bands[0].rowCount == 1)
    }

    @Test("a day that does not fit wraps to the next band")
    func overflowWraps() {
        let bands = TimelineFlowLayout.pack(counts: [2, 2], columns: 3)

        #expect(bands.count == 2)
        #expect(bands[0].blocks == [
            TimelineFlowLayout.Block(dayIndex: 0, colStart: 0, colWidth: 2, rowCount: 1)
        ])
        #expect(bands[1].blocks == [
            TimelineFlowLayout.Block(dayIndex: 1, colStart: 0, colWidth: 2, rowCount: 1)
        ])
    }

    @Test("a tall balanced block can host a short neighbour")
    func tallBlockHostsShortNeighbour() {
        let bands = TimelineFlowLayout.pack(counts: [4, 1], columns: 3)

        #expect(bands.count == 1)
        #expect(bands[0].blocks == [
            TimelineFlowLayout.Block(dayIndex: 0, colStart: 0, colWidth: 2, rowCount: 2),
            TimelineFlowLayout.Block(dayIndex: 1, colStart: 2, colWidth: 1, rowCount: 1),
        ])
        #expect(bands[0].rowCount == 2)
    }

    @Test("large days keep full-width bands of their own")
    func largeDaysStandAlone() {
        let bands = TimelineFlowLayout.pack(counts: [1, 47, 2], columns: 3)

        #expect(bands.count == 3)
        #expect(bands[0].blocks.map(\.dayIndex) == [0])
        #expect(bands[1].blocks.map(\.dayIndex) == [1])
        #expect(bands[1].rowCount == 16)
        #expect(bands[2].blocks.map(\.dayIndex) == [2])
    }

    @Test("day order survives packing across many bands")
    func orderIsStable() {
        let counts = [1, 1, 1, 5, 2, 1, 9, 1, 1, 1, 1]
        let bands = TimelineFlowLayout.pack(counts: counts, columns: 3)
        let indexes = bands.flatMap { $0.blocks.map(\.dayIndex) }

        #expect(indexes == Array(counts.indices))
        for band in bands {
            let total = band.blocks.map(\.colWidth).reduce(0, +)
            #expect(total <= 3)
            var cursor = 0
            for block in band.blocks {
                #expect(block.colStart == cursor)
                cursor += block.colWidth
            }
        }
    }
}

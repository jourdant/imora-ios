import Foundation

/// Concrete progress units passed to `BGContinuedProcessingTask`. Keeping the
/// original units matters: reducing a large transfer to 100 percentage points
/// can leave the scheduler seeing no movement for long enough to expire it.
nonisolated struct ContinuedProgress: Equatable, Sendable {
    private static let fractionScale: Int64 = 1_000_000

    let completedUnitCount: Int64
    let totalUnitCount: Int64

    init(completedUnitCount: Int64, totalUnitCount: Int64) {
        let total = max(1, totalUnitCount)
        self.totalUnitCount = total
        self.completedUnitCount = min(max(0, completedUnitCount), total)
    }

    init(fraction: Double) {
        let finiteFraction = fraction.isFinite ? fraction : 0
        let normalizedFraction = min(max(finiteFraction, 0), 1)
        let completed = Int64((normalizedFraction * Double(Self.fractionScale)).rounded())
        self.init(completedUnitCount: completed, totalUnitCount: Self.fractionScale)
    }
}

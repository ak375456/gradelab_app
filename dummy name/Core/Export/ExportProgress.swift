import Foundation

struct ExportProgress: Equatable, Sendable {
    let fractionCompleted: Double
    let processedDuration: TimeInterval
    let totalDuration: TimeInterval
    let presentationTime: TimeInterval

    init(
        fractionCompleted: Double,
        processedDuration: TimeInterval,
        totalDuration: TimeInterval,
        presentationTime: TimeInterval
    ) {
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
        self.processedDuration = max(processedDuration, 0)
        self.totalDuration = max(totalDuration, 0)
        self.presentationTime = presentationTime
    }

    var percentage: Int {
        Int((fractionCompleted * 100).rounded(.down))
    }

    static func initial(totalDuration: TimeInterval, presentationTime: TimeInterval) -> ExportProgress {
        ExportProgress(
            fractionCompleted: 0,
            processedDuration: 0,
            totalDuration: totalDuration,
            presentationTime: presentationTime
        )
    }
}

enum ExportState: Equatable, Sendable {
    case idle
    case preparing
    /// Estimating scene depth for Relight before the first frame is written.
    case analyzing(ExportProgress)
    case exporting(ExportProgress)
    case finishing(ExportProgress)
    case completed(URL)
    case cancelled
    case failed(String)
}
